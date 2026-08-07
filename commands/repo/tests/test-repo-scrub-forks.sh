#!/usr/bin/env bash
# Test suite for scripts/repo/repo-scrub-forks.sh — the fork-network sweep
# companion to /repo:scrub (rjwalters/repo#185, split out of #174's "scope
# split" comment; #186 depends on this issue's "forks are unremediable"
# finding).
#
# Usage: ./commands/repo/tests/test-repo-scrub-forks.sh
# Exit code 0 = all tests pass, 1 = failures detected.
#
# Structured like commands/repo/tests/test-repo-remote.sh: pure bash, no
# framework, PASS/FAIL/TOTAL counters and a summary block. `pnpm test`
# delegates to this file via hooks/repo/tests/run.sh.
#
# The script under test is a full CLI (main "$@" at EOF) that talks to GitHub
# exclusively through `gh api` / `gh auth status` — this suite stubs `gh` on
# PATH and drives the real script as a subprocess (black-box), asserting on
# stdout/stderr/exit-code, matching the approach in
# .loom/scripts/tests/test-check-duplicate.sh. Real `jq` is required (as the
# script itself requires) and is used both by the stub `gh` and by this
# suite's assertions.
#
# WHY THIS SUITE MATTERS (#185's own incident write-up): the real failure that
# motivated this issue was a sweep that reported a repo clean while two public
# forks (one of them a fork-of-a-fork, one only found by a description
# fingerprint after a visibility change detached it) still carried the
# original content. The cases below pin down exactly those three shapes
# (single-level enumeration, recursive fork-of-fork, fingerprint fallback)
# plus the "never report clean on an inconclusive check" requirement and the
# "never suggest a fix the operator can't perform" framing requirement.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
RSF="$REPO_ROOT/scripts/repo/repo-scrub-forks.sh"

PASS=0
FAIL=0
TOTAL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

if [[ ! -f "$RSF" ]]; then
    echo "FATAL: repo-scrub-forks.sh not found at $RSF" >&2
    exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "FATAL: jq is required to run this test suite" >&2
    exit 1
fi

SCRATCH="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$SCRATCH"' EXIT

# ---------------------------------------------------------------------------
# Assertion helpers (same shape as test-repo-remote.sh / test-check-duplicate.sh)
# ---------------------------------------------------------------------------
ok() { TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1)); printf "  ${GREEN}PASS${NC}: %s\n" "$1"; }
no() {
    TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
    printf "  ${RED}FAIL${NC}: %s\n" "$1"
    [[ -n "${2:-}" ]] && printf "        %s\n" "$2"
    return 0
}
assert_eq()           { if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1" "expected [$2], got [$3]"; fi; }
assert_contains()     { if [[ "$2" == *"$3"* ]]; then ok "$1"; else no "$1" "missing [$3] in [$2]"; fi; }
assert_not_contains() { if [[ "$2" != *"$3"* ]]; then ok "$1"; else no "$1" "unexpected [$3] present in [$2]"; fi; }

# ---------------------------------------------------------------------------
# Fixture encoding helpers — MUST match the encoding used inside the stub gh
# below exactly (both sides are plain string substitution, no shared library).
# ---------------------------------------------------------------------------
keysafe() { printf '%s' "$1" | tr '/.' '__'; }
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

STUB_DIR="$SCRATCH/bin"
F="$SCRATCH/fixtures"
mkdir -p "$STUB_DIR" "$F"

write_root()      { printf '%s' "$2" >"$F/root-$(keysafe "$1").json"; }          # <fullname> <json>
write_forks()     { printf '%s' "$2" >"$F/forks-$(keysafe "$1").json"; }         # <fullname> <json array>
write_readme()    { printf '%s' "$(b64 "$2")" >"$F/readme-$(keysafe "$1").txt"; } # <fullname> <plaintext first line>
write_contents()  { printf '%s' "$(b64 "$3")" >"$F/contents-$(keysafe "$1")-$(keysafe "$2").txt"; } # <fullname> <path> <plaintext>
write_search()    { printf '%s' "$2" >"$F/search-$1.json"; }                      # <description|readme> <json array of fork objects>

reset_fixtures() {
    rm -rf "$F"
    mkdir -p "$F"
}

fork_obj() {  # <full_name> <owner> [default_branch] [description] -> one JSON object
    local fn="$1" owner="$2" branch="${3:-main}" desc="${4:-}"
    jq -n --arg fn "$fn" --arg owner "$owner" --arg branch "$branch" --arg desc "$desc" \
        '{full_name: $fn, owner: {login: $owner}, default_branch: $branch, description: (if $desc == "" then null else $desc end)}'
}

json_array() { jq -s '.' ; }  # combine newline-delimited JSON objects on stdin into an array

# ---------------------------------------------------------------------------
# The stub `gh`. Every case the script issues is handled explicitly; anything
# else is a loud test-authoring bug (unhandled-args exits 9, distinct from any
# code the real script interprets, so an unmocked call fails LOUDLY instead of
# silently returning empty/success).
# ---------------------------------------------------------------------------
cat >"$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
F="${RSF_TEST_FIXTURES:?stub gh: RSF_TEST_FIXTURES not set}"
keysafe() { printf '%s' "$1" | tr '/.' '__'; }

case "$1" in
  auth)
    [[ -f "$F/../auth-fail" ]] && exit 1
    exit 0
    ;;
  api)
    path="$2"
    case "$path" in
      *"/forks?"*)
        fn="${path%%/forks\?*}"; fn="${fn#repos/}"
        key="$(keysafe "$fn")"
        if [[ -f "$F/forks-fail-$key" ]]; then
          echo "gh: rate limit exceeded (stub)" >&2
          exit 1
        fi
        canned="$F/forks-$key.json"
        if [[ -f "$canned" ]]; then cat "$canned"; else echo "[]"; fi
        exit 0
        ;;
      *"/readme")
        fn="${path%/readme}"; fn="${fn#repos/}"
        key="$(keysafe "$fn")"
        canned="$F/readme-$key.txt"
        if [[ ! -f "$canned" ]]; then
          echo "gh: Not Found (HTTP 404)" >&2
          exit 1
        fi
        b64="$(cat "$canned")"
        jq -n --arg c "$b64" '{content:$c, encoding:"base64"}'
        exit 0
        ;;
      *"/contents/"*"?ref="*)
        rest="${path#*/contents/}"
        filepath="${rest%%\?*}"
        fn="${path#repos/}"; fn="${fn%%/contents/*}"
        canned="$F/contents-$(keysafe "$fn")-$(keysafe "$filepath").txt"
        if [[ ! -f "$canned" ]]; then
          echo "gh: Not Found (HTTP 404)" >&2
          exit 1
        fi
        b64="$(cat "$canned")"
        jq -n --arg c "$b64" '{content:$c, encoding:"base64", type:"file"}'
        exit 0
        ;;
      "search/repositories?q="*)
        field="unknown"
        [[ "$path" == *"in%3Adescription"* ]] && field=description
        [[ "$path" == *"in%3Areadme"* ]] && field=readme
        if [[ -f "$F/search-fail-$field" ]]; then
          echo "gh: rate limit exceeded (stub)" >&2
          exit 1
        fi
        canned="$F/search-$field.json"
        items="[]"
        [[ -f "$canned" ]] && items="$(cat "$canned")"
        jq -n --argjson items "$items" '{items: $items}'
        exit 0
        ;;
      "repos/"*)
        fn="${path#repos/}"
        key="$(keysafe "$fn")"
        canned="$F/root-$key.json"
        if [[ ! -f "$canned" ]]; then
          echo "gh: Not Found (HTTP 404)" >&2
          exit 1
        fi
        cat "$canned"
        exit 0
        ;;
      *)
        echo "stub gh: unhandled api path: $path" >&2
        exit 9
        ;;
    esac
    ;;
  *)
    echo "stub gh: unhandled args: $*" >&2
    exit 9
    ;;
esac
STUB
chmod +x "$STUB_DIR/gh"

export RSF_TEST_FIXTURES="$F"
export PATH="$STUB_DIR:$PATH"

RUN_OUT=""; RUN_ERR=""; RUN_RC=0
run_rsf() {
    local errf; errf="$(mktemp)"
    RUN_OUT="$("$RSF" "$@" 2>"$errf")"
    RUN_RC=$?
    RUN_ERR="$(cat "$errf")"; rm -f "$errf"
}

echo "repo-scrub-forks.sh test suite"
echo "==============================="
echo ""

# ---------------------------------------------------------------------------
echo "-- usage errors --"
# ---------------------------------------------------------------------------
reset_fixtures
run_rsf
assert_eq "no action -> usage error (2)" "2" "$RUN_RC"

run_rsf bogus owner/repo
assert_eq "unknown action -> usage error (2)" "2" "$RUN_RC"

run_rsf sweep
assert_eq "sweep with no target -> usage error (2)" "2" "$RUN_RC"

run_rsf sweep not-a-slash --path x
assert_eq "sweep with non owner/repo target -> usage error (2)" "2" "$RUN_RC"
assert_contains "message explains the expected shape" "$RUN_ERR" "owner"

run_rsf sweep root/repo
assert_eq "sweep with zero --path -> usage error (2)" "2" "$RUN_RC"
assert_contains "message explains --path is required" "$RUN_ERR" "--path"

run_rsf sweep root/repo --path x --max-depth notanumber
assert_eq "non-numeric --max-depth -> usage error (2)" "2" "$RUN_RC"

# ---------------------------------------------------------------------------
echo ""
echo "-- gh/jq preflight --"
# ---------------------------------------------------------------------------
touch "$SCRATCH/auth-fail"
run_rsf sweep root/repo --path x
assert_eq "gh not authenticated -> exit 2" "2" "$RUN_RC"
assert_contains "message names gh auth" "$RUN_ERR" "authenticated"
rm -f "$SCRATCH/auth-fail"

# ---------------------------------------------------------------------------
echo ""
echo "-- zero forks: clean report, exit 0, not an error --"
# ---------------------------------------------------------------------------
reset_fixtures
write_root "root/repo" "$(jq -n '{full_name:"root/repo", description:"", default_branch:"main", owner:{login:"root"}}')"
write_forks "root/repo" "[]"
run_rsf sweep root/repo --path secrets.txt --json
assert_eq "zero forks -> exit 0 (not an error)" "0" "$RUN_RC"
assert_contains "JSON reports zero candidates" "$RUN_OUT" '"candidates_checked":0'
assert_contains "JSON reports no findings" "$RUN_OUT" '"findings":[]'

run_rsf sweep root/repo --path secrets.txt
assert_eq "zero forks (text mode) -> exit 0" "0" "$RUN_RC"
assert_contains "text mode says no forks found" "$RUN_ERR" "no forks found"

# ---------------------------------------------------------------------------
echo ""
echo "-- single-level fork enumeration, content confirmed present --"
# ---------------------------------------------------------------------------
reset_fixtures
write_root "root/repo" "$(jq -n '{full_name:"root/repo", description:"", default_branch:"main", owner:{login:"root"}}')"
write_forks "root/repo" "$( { fork_obj "leaker/repo" "leaker" "main" ""; } | json_array )"
write_forks "leaker/repo" "[]"
write_contents "leaker/repo" "secrets.txt" "the leaked content"
run_rsf sweep root/repo --path secrets.txt --json
assert_eq "single-level enumeration with confirmed content -> exit 1 (finding)" "1" "$RUN_RC"
assert_contains "finding names the fork" "$RUN_OUT" '"fork":"leaker/repo"'
assert_contains "finding names the owner" "$RUN_OUT" '"owner":"leaker"'
assert_contains "finding says how it was discovered" "$RUN_OUT" '"discovered_via":"forks-api"'
assert_contains "finding is marked unremediable" "$RUN_OUT" '"remediable":false'
assert_contains "finding's recommended action is outreach" "$RUN_OUT" '"recommended_action":"outreach"'

run_rsf sweep root/repo --path secrets.txt
assert_contains "text mode: UNREMEDIABLE framing present" "$RUN_ERR" "UNREMEDIABLE"
assert_contains "text mode: names the fork and its owner" "$RUN_ERR" "leaker/repo"
assert_contains "text mode: recommends contacting the owner" "$RUN_ERR" "contact leaker"

# ---------------------------------------------------------------------------
echo ""
echo "-- a fork predating the content is NOT a finding (presence-confirmed, not assumed) --"
# ---------------------------------------------------------------------------
reset_fixtures
write_root "root/repo" "$(jq -n '{full_name:"root/repo", description:"", default_branch:"main", owner:{login:"root"}}')"
write_forks "root/repo" "$( { fork_obj "clean-fork/repo" "clean-fork" "main" ""; } | json_array )"
write_forks "clean-fork/repo" "[]"
# no secrets.txt fixture written for clean-fork/repo -> 404 -> not confirmed
run_rsf sweep root/repo --path secrets.txt --json
assert_eq "fork without the content -> exit 0 (not a finding)" "0" "$RUN_RC"
assert_contains "JSON: one candidate checked" "$RUN_OUT" '"candidates_checked":1'
assert_contains "JSON: no findings" "$RUN_OUT" '"findings":[]'

run_rsf sweep root/repo --path secrets.txt
assert_contains "text mode: explicitly says not a finding" "$RUN_ERR" "Not a finding"

# ---------------------------------------------------------------------------
echo ""
echo "-- --pattern narrows a present path to a content match --"
# ---------------------------------------------------------------------------
reset_fixtures
write_root "root/repo" "$(jq -n '{full_name:"root/repo", description:"", default_branch:"main", owner:{login:"root"}}')"
write_forks "root/repo" "$( { fork_obj "hasfile/repo" "hasfile" "main" ""; } | json_array )"
write_forks "hasfile/repo" "[]"
write_contents "hasfile/repo" "README.md" "just an ordinary readme, nothing sensitive here"
run_rsf sweep root/repo --path README.md --pattern 'API_KEY_[0-9]+' --json
assert_eq "path present but pattern does not match -> exit 0" "0" "$RUN_RC"
assert_contains "JSON: no findings when pattern misses" "$RUN_OUT" '"findings":[]'

write_contents "hasfile/repo" "README.md" "oops committed API_KEY_12345 in here"
run_rsf sweep root/repo --path README.md --pattern 'API_KEY_[0-9]+' --json
assert_eq "path present and pattern matches -> exit 1" "1" "$RUN_RC"
assert_contains "finding recorded for the matching fork" "$RUN_OUT" '"fork":"hasfile/repo"'

# ---------------------------------------------------------------------------
echo ""
echo "-- recursive walk: a fork of a fork is a distinct copy (the real incident's shape) --"
# ---------------------------------------------------------------------------
reset_fixtures
write_root "root/repo" "$(jq -n '{full_name:"root/repo", description:"", default_branch:"main", owner:{login:"root"}}')"
write_forks "root/repo" "$( { fork_obj "mid/repo" "mid" "main" ""; } | json_array )"
write_forks "mid/repo" "$( { fork_obj "grandchild/repo" "grandchild" "main" ""; } | json_array )"
write_forks "grandchild/repo" "[]"
write_contents "grandchild/repo" "secrets.txt" "still here, two hops down"
run_rsf sweep root/repo --path secrets.txt --json
assert_eq "fork-of-fork content confirmed -> exit 1" "1" "$RUN_RC"
assert_contains "finding names the grandchild fork" "$RUN_OUT" '"fork":"grandchild/repo"'
assert_contains "finding's parent is the mid fork, not the root" "$RUN_OUT" '"parent":"mid/repo"'

# max-depth caps the walk (documented safety net) rather than silently missing it.
run_rsf sweep root/repo --path secrets.txt --max-depth 1
assert_eq "max-depth 1 stops before the grandchild -> exit 0 (nothing confirmed within depth)" "0" "$RUN_RC"
assert_contains "warns that the network may be deeper" "$RUN_ERR" "max depth"

# ---------------------------------------------------------------------------
echo ""
echo "-- cycle safety: a fork network that revisits a node does not loop forever --"
# ---------------------------------------------------------------------------
reset_fixtures
write_root "root/repo" "$(jq -n '{full_name:"root/repo", description:"", default_branch:"main", owner:{login:"root"}}')"
write_forks "root/repo" "$( { fork_obj "a/repo" "a" "main" ""; } | json_array )"
# a/repo's forks list (erroneously, or via API weirdness) reports root/repo again.
write_forks "a/repo" "$( { fork_obj "root/repo" "root" "main" ""; } | json_array )"
run_rsf sweep root/repo --path secrets.txt --json --max-depth 25
assert_eq "revisited node does not hang or error -> exit 0" "0" "$RUN_RC"

# ---------------------------------------------------------------------------
echo ""
echo "-- fingerprint fallback: detached fork found by exact description match --"
# ---------------------------------------------------------------------------
reset_fixtures
write_root "root/repo" "$(jq -n '{full_name:"root/repo", description:"a very specific unique description", default_branch:"main", owner:{login:"root"}}')"
write_forks "root/repo" "[]"
write_search "description" "$( { fork_obj "detached/repo" "detached" "main" "a very specific unique description"; } | json_array )"
write_search "readme" "[]"
write_contents "detached/repo" "secrets.txt" "still carrying it after detachment"
run_rsf sweep root/repo --path secrets.txt --json
assert_eq "detached fork found via description fingerprint -> exit 1" "1" "$RUN_RC"
assert_contains "finding names the detached fork" "$RUN_OUT" '"fork":"detached/repo"'
assert_contains "finding says it was found via fingerprint" "$RUN_OUT" '"discovered_via":"fingerprint-description"'
assert_contains "finding has no forks-API parent (detached)" "$RUN_OUT" 'no forks-API edge'

# A candidate whose description is merely SIMILAR (not exact) is excluded —
# the issue explicitly asks for "exact matches", not fuzzy ones.
reset_fixtures
write_root "root/repo" "$(jq -n '{full_name:"root/repo", description:"a very specific unique description", default_branch:"main", owner:{login:"root"}}')"
write_forks "root/repo" "[]"
write_search "description" "$( { fork_obj "near-miss/repo" "near-miss" "main" "a very specific unique description (slightly different)"; } | json_array )"
write_search "readme" "[]"
write_contents "near-miss/repo" "secrets.txt" "irrelevant"
run_rsf sweep root/repo --path secrets.txt --json
assert_eq "non-exact description match is excluded -> exit 0" "0" "$RUN_RC"
assert_contains "JSON: no candidates from the near-miss" "$RUN_OUT" '"candidates_checked":0'

# A candidate owned by the SAME owner as root is excluded (not "someone else's" copy).
reset_fixtures
write_root "root/repo" "$(jq -n '{full_name:"root/repo", description:"a very specific unique description", default_branch:"main", owner:{login:"root"}}')"
write_forks "root/repo" "[]"
write_search "description" "$( { fork_obj "root/other-repo" "root" "main" "a very specific unique description"; } | json_array )"
write_search "readme" "[]"
run_rsf sweep root/repo --path secrets.txt --json
assert_eq "same-owner fingerprint hit excluded -> exit 0" "0" "$RUN_RC"
assert_contains "JSON: candidate excluded (self-owner)" "$RUN_OUT" '"candidates_checked":0'

# A fingerprint hit that duplicates a forks-API candidate is not double-counted.
reset_fixtures
write_root "root/repo" "$(jq -n '{full_name:"root/repo", description:"dup description", default_branch:"main", owner:{login:"root"}}')"
write_forks "root/repo" "$( { fork_obj "known/repo" "known" "main" ""; } | json_array )"
write_forks "known/repo" "[]"
write_search "description" "$( { fork_obj "known/repo" "known" "main" "dup description"; } | json_array )"
write_search "readme" "[]"
write_contents "known/repo" "secrets.txt" "present"
run_rsf sweep root/repo --path secrets.txt --json
assert_eq "known/repo counted exactly once" "1" "$RUN_RC"
DUP_COUNT="$(printf '%s' "$RUN_OUT" | jq '[.findings[] | select(.fork == "known/repo")] | length')"
assert_eq "de-duplicated: exactly one finding for known/repo" "1" "$DUP_COUNT"

# ---------------------------------------------------------------------------
echo ""
echo "-- fingerprint fallback: detached fork found by exact README first-line match --"
# ---------------------------------------------------------------------------
reset_fixtures
write_root "root/repo" "$(jq -n '{full_name:"root/repo", description:"", default_branch:"main", owner:{login:"root"}}')"
write_readme "root/repo" "# A Very Specific Readme Title"
write_forks "root/repo" "[]"
write_search "description" "[]"
write_search "readme" "$( { fork_obj "detached2/repo" "detached2" "main" ""; } | json_array )"
write_readme "detached2/repo" "# A Very Specific Readme Title"
write_contents "detached2/repo" "secrets.txt" "found via readme fingerprint"
run_rsf sweep root/repo --path secrets.txt --json
assert_eq "detached fork found via README fingerprint -> exit 1" "1" "$RUN_RC"
assert_contains "finding says it was found via readme fingerprint" "$RUN_OUT" '"discovered_via":"fingerprint-readme"'

# The search hit is confirmed by RE-FETCHING the candidate's own README and
# comparing first lines exactly — "in:readme" only proves the phrase appears
# SOMEWHERE, not that it's the fingerprinted first line.
reset_fixtures
write_root "root/repo" "$(jq -n '{full_name:"root/repo", description:"", default_branch:"main", owner:{login:"root"}}')"
write_readme "root/repo" "# A Very Specific Readme Title"
write_forks "root/repo" "[]"
write_search "description" "[]"
write_search "readme" "$( { fork_obj "false-hit/repo" "false-hit" "main" ""; } | json_array )"
write_readme "false-hit/repo" "# A totally different first line (phrase is buried lower in the file)"
run_rsf sweep root/repo --path secrets.txt --json
assert_eq "readme search hit whose OWN first line differs is excluded -> exit 0" "0" "$RUN_RC"
assert_contains "JSON: candidate excluded (first-line mismatch)" "$RUN_OUT" '"candidates_checked":0'

# ---------------------------------------------------------------------------
echo ""
echo "-- fingerprint search failure degrades coverage but is NON-FATAL --"
# ---------------------------------------------------------------------------
reset_fixtures
write_root "root/repo" "$(jq -n '{full_name:"root/repo", description:"some description", default_branch:"main", owner:{login:"root"}}')"
write_forks "root/repo" "$( { fork_obj "still-found/repo" "still-found" "main" ""; } | json_array )"
write_forks "still-found/repo" "[]"
write_contents "still-found/repo" "secrets.txt" "found despite degraded fingerprinting"
touch "$F/search-fail-description"
run_rsf sweep root/repo --path secrets.txt --json
assert_eq "forks-API finding still reported despite fingerprint failure -> exit 1" "1" "$RUN_RC"
assert_contains "JSON flags fingerprint coverage as degraded" "$RUN_OUT" '"fingerprint_degraded":true'
assert_contains "fork still found via forks-api" "$RUN_OUT" '"fork":"still-found/repo"'

run_rsf sweep root/repo --path secrets.txt
assert_contains "text mode warns about degraded fingerprint coverage" "$RUN_ERR" "degraded"

# ---------------------------------------------------------------------------
echo ""
echo "-- fork-enumeration API failure mid-walk is INCONCLUSIVE, never 'no forks found' --"
# ---------------------------------------------------------------------------
reset_fixtures
write_root "root/repo" "$(jq -n '{full_name:"root/repo", description:"", default_branch:"main", owner:{login:"root"}}')"
write_forks "root/repo" "$( { fork_obj "flaky/repo" "flaky" "main" ""; } | json_array )"
touch "$F/forks-fail-$(keysafe "flaky/repo")"
run_rsf sweep root/repo --path secrets.txt --json
assert_eq "mid-walk forks-API failure -> exit 2 (inconclusive, not an answer)" "2" "$RUN_RC"
assert_contains "message says INCONCLUSIVE" "$RUN_ERR" "INCONCLUSIVE"
# (The error message itself quotes the phrase "not 'no forks found'" to
# EXPLAIN what it refuses to claim — so assert against the actual clean-report
# phrasing emitted on a successful zero-forks sweep, not a bare substring.)
assert_not_contains "never emits the clean-report phrasing on failure" "$RUN_ERR" "no forks found for"
assert_eq "no JSON result emitted on a failed sweep" "" "$RUN_OUT"

# Same failure mode at the ROOT's own top-level forks call.
reset_fixtures
write_root "root/repo" "$(jq -n '{full_name:"root/repo", description:"", default_branch:"main", owner:{login:"root"}}')"
touch "$F/forks-fail-$(keysafe "root/repo")"
run_rsf sweep root/repo --path secrets.txt --json
assert_eq "root-level forks-API failure -> exit 2" "2" "$RUN_RC"

# Root metadata itself unreachable (e.g. renamed/deleted since capture).
reset_fixtures
run_rsf sweep no-such/repo --path secrets.txt
assert_eq "root metadata fetch failure -> exit 2" "2" "$RUN_RC"
assert_contains "message explains the root fetch failed" "$RUN_ERR" "root repo metadata"

# ---------------------------------------------------------------------------
echo ""
echo "-- unremediable framing: outreach only, never a fix the operator can't run --"
# ---------------------------------------------------------------------------
reset_fixtures
write_root "root/repo" "$(jq -n '{full_name:"root/repo", description:"", default_branch:"main", owner:{login:"root"}}')"
write_forks "root/repo" "$( { fork_obj "leaker2/repo" "leaker2" "main" ""; } | json_array )"
write_forks "leaker2/repo" "[]"
write_contents "leaker2/repo" "secrets.txt" "leaked"
run_rsf sweep root/repo --path secrets.txt
assert_not_contains "never suggests deleting someone else's fork directly" "$RUN_ERR" "gh repo delete leaker2"
assert_not_contains "never claims a delete-fork API exists" "$RUN_ERR" "DELETE /repos/leaker2"
assert_contains "explicitly states no such API exists" "$RUN_ERR" "no API to delete a fork you do not own"
assert_contains "leaf-first removal guidance is present" "$RUN_ERR" "LEAF-FIRST"
assert_contains "leaf-first guidance explains WHY (root promotion)" "$RUN_ERR" "promotes a child fork to become the new root"

run_rsf sweep root/repo --path secrets.txt --json
assert_contains "JSON also documents the leaf-first note" "$RUN_OUT" "leaf_first_removal_note"

# ---------------------------------------------------------------------------
echo ""
echo "-- warn-before-private: captures the fork list BEFORE any visibility change --"
# ---------------------------------------------------------------------------
STATE_DIR="$SCRATCH/state"
reset_fixtures
write_root "root/repo" "$(jq -n '{full_name:"root/repo", description:"", default_branch:"main", owner:{login:"root"}}')"
write_forks "root/repo" "[]"
RSF_TEST_FIXTURES="$F" REPO_SCRUB_FORKS_STATE_DIR="$STATE_DIR" run_rsf warn-before-private root/repo --json
assert_eq "no forks -> exit 0 (safe to change visibility)" "0" "$RUN_RC"
assert_contains "JSON reports has_forks:false" "$RUN_OUT" '"has_forks":false'
SNAP1="$(find "$STATE_DIR" -type f -name '*.json' | head -n1)"
[[ -n "$SNAP1" ]] && ok "snapshot file was written even with zero forks" \
  || no "snapshot file was written even with zero forks"

reset_fixtures
rm -rf "$STATE_DIR"
write_root "root/repo" "$(jq -n '{full_name:"root/repo", description:"", default_branch:"main", owner:{login:"root"}}')"
write_forks "root/repo" "$( { fork_obj "someone/repo" "someone" "main" ""; } | json_array )"
write_forks "someone/repo" "[]"
RSF_TEST_FIXTURES="$F" REPO_SCRUB_FORKS_STATE_DIR="$STATE_DIR" run_rsf warn-before-private root/repo --json
assert_eq "forks present -> exit 1 (advisory, not a hard block)" "1" "$RUN_RC"
assert_contains "JSON reports has_forks:true" "$RUN_OUT" '"has_forks":true'
assert_contains "JSON reports fork_count:1" "$RUN_OUT" '"fork_count":1'
SNAP2="$(find "$STATE_DIR" -type f -name '*.json' | head -n1)"
[[ -n "$SNAP2" ]] && assert_contains "persisted snapshot names the fork" "$(cat "$SNAP2")" "someone/repo" \
  || no "persisted snapshot file exists"

RSF_TEST_FIXTURES="$F" REPO_SCRUB_FORKS_STATE_DIR="$STATE_DIR" run_rsf warn-before-private root/repo
assert_contains "text mode warns loudly about scrambled fork/parent relationships" "$RUN_ERR" "WARNING"
assert_contains "text mode explains detachment/re-parenting risk" "$RUN_ERR" "RE-PARENT"
assert_not_contains "warn-before-private never claims to have changed visibility itself" "$RUN_ERR" "made private"
assert_not_contains "warn-before-private never claims to have changed visibility itself" "$RUN_ERR" "now private"

# ---------------------------------------------------------------------------
echo ""
echo "========================================="
echo "  Total:  $TOTAL"
printf "  ${GREEN}Passed${NC}: %s\n" "$PASS"
printf "  ${RED}Failed${NC}: %s\n" "$FAIL"
echo "========================================="

if [[ $FAIL -gt 0 ]]; then
    printf "\n${RED}TESTS FAILED${NC}\n"
    exit 1
fi
printf "\n${GREEN}ALL TESTS PASSED${NC}\n"
exit 0

#!/usr/bin/env bash
# json_escape() parity harness (repo#366) — pins the two shipped copies of
# json_escape() to identical text AND identical behavior, and fails when a
# third copy appears.
#
# Usage: ./commands/repo/tests/test-json-escape-parity.sh
# Exit code 0 = all tests pass, 1 = failures detected.
#
# WHY THIS FILE EXISTS, AND WHY NOT A SHARED lib/json.sh
#
# repo#366 observed that json_escape() is byte-for-byte identical in
# scripts/repo/repo-remote.sh and scripts/repo/repo-scrub-forks.sh, and
# proposed extracting it to lib/json.sh with both scripts sourcing it — citing
# scripts/repo/resync-installed.sh, which already sources lib/render.sh and
# lib/metadata.sh, as precedent.
#
# That precedent does not transfer, and following it would ship a broken tool:
#
#   * install.sh copies repo-remote.sh and repo-scrub-forks.sh into a consumer
#     repo as STANDALONE single files at .claude/skills/repo/scripts/ (see
#     install.sh steps 3d and 3d-2). Nothing under lib/ is installed anywhere
#     in the target — verified by running install.sh against a scratch repo:
#     the whole installed surface is SKILL.md, install-metadata.json,
#     .install-local.json, two hooks, and three scripts. A `source
#     .../lib/json.sh` in either script would resolve to a nonexistent path in
#     EVERY consumer install, including the installs that exist today, and
#     including loom's `fleet add-worker`, which invokes the installed
#     repo-remote.sh path directly.
#
#   * resync-installed.sh gets away with sourcing lib/ only because its ENTIRE
#     JOB is to talk to a source clone: it sources "$SOURCE_ROOT/lib/render.sh"
#     where SOURCE_ROOT is the separate checkout recorded in .install-local.json
#     (contract C6). repo-remote.sh and repo-scrub-forks.sh have no such
#     dependency and must not acquire one — needing a source clone on disk to
#     provision a VM would be a strictly worse contract than eight duplicated
#     lines of string substitution.
#
# Shipping lib/json.sh as a fourth installed file instead (e.g.
# .claude/skills/repo/scripts/lib/json.sh) is possible but is not the "pure
# extraction, no behavior change" the issue scoped: it widens the installed
# surface (a contract-level change touching install.sh, resync-installed.sh's
# plan, INSTALLER-CONTRACT.md, README.md's layout block, and the installer
# tests), converts two self-contained executables into a three-file unit, and
# introduces a hard-fail mode for every install until it is resynced — all to
# retire eight lines of a pure function. That is a net complexity increase,
# which is the opposite of what the proposal set out to do.
#
# So the copies stay, and the REAL harm the issue identified — "no test
# coupling to guarantee they stay in sync" — is fixed directly here. This is
# the same answer this repo already reached in repo#193 for a far larger
# duplication (test-guard-equivalence.sh compares the canonical guard against
# Loom's vendored copy over a shared corpus rather than merging them): when two
# copies must stay independently shippable, the drift is what you test, not
# what you refactor away.
#
# WHAT THIS ASSERTS
#
#   1. Census — exactly the two known definitions exist under scripts/. A third
#      copy fails here, with instructions, rather than drifting unnoticed.
#   2. Text parity — the two definition blocks are byte-for-byte identical.
#   3. Behavior parity + semantics — each copy is evaluated in isolation
#      against a corpus of the inputs that actually distinguish a correct
#      escaper from a broken one (backslash-before-quote ordering, literal
#      "\n" vs. a real newline, CR stripping), and each copy's output is
#      checked to produce valid JSON that round-trips back to the input.
#      Editing one copy's BEHAVIOR without the other now fails; editing both
#      deliberately requires updating the expectations here on purpose.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Assertion helpers (ok/no/skip/assert_eq/assert_contains) plus the
# PASS/FAIL/SKIP/TOTAL counters and color vars are shared across the repo test
# suites — see lib/assert.sh (repo#307).
source "$(dirname "${BASH_SOURCE[0]}")/lib/assert.sh"

# The copies under test. Keep in sync with the census in case 1: adding a file
# here without adding it to EXPECTED_CENSUS (or vice versa) fails case 1.
COPIES=(
    "scripts/repo/repo-remote.sh"
    "scripts/repo/repo-scrub-forks.sh"
)

for rel in "${COPIES[@]}"; do
    if [[ ! -f "$REPO_ROOT/$rel" ]]; then
        echo "FATAL: expected copy not found at $REPO_ROOT/$rel" >&2
        exit 1
    fi
done

# extract_def <file> -> the json_escape() definition block, opening line through
# its closing brace at column 0. Anchored so a mention inside a comment or a
# nested brace cannot terminate it early.
extract_def() {
    awk '
        /^json_escape\(\) \{$/ { inside = 1 }
        inside                 { print }
        inside && /^\}$/       { exit }
    ' "$1"
}

# run_copy <definition> <input> -> the escaper output, trailing newlines intact.
# The X sentinel survives command substitution stripping a trailing newline,
# which matters because a bare "\n" input escapes to a two-character result and
# a bug that emitted a real newline would otherwise look identical.
run_copy() {
    local def="$1" in="$2" out
    out="$(bash -c "$def"$'\n''json_escape "$1"; printf X' _ "$in")"
    printf '%s' "${out%X}"
}

echo "json_escape() parity test suite"
echo "==============================="
echo ""

# ---------------------------------------------------------------------------
echo "-- case 1: census — exactly the known copies define json_escape() --"
# ---------------------------------------------------------------------------
# Deliberately scoped to this repo's own trees. .loom/ is vendored from
# rjwalters/loom (check-main-clean.sh and experiments/judge-fanout-corpus-runner.sh
# carry their own json_escape()) and is not this repo's to police — repo#366
# scoped itself the same way.
EXPECTED_CENSUS="$(printf '%s\n' "${COPIES[@]}" | sort)"
ACTUAL_CENSUS="$(cd "$REPO_ROOT" && grep -rl '^json_escape() {' \
    --include='*.sh' scripts commands hooks lib 2>/dev/null | sort)"
assert_eq "only the known copies define json_escape() under scripts/commands/hooks/lib" \
    "$EXPECTED_CENSUS" "$ACTUAL_CENSUS"
if [[ "$EXPECTED_CENSUS" != "$ACTUAL_CENSUS" ]]; then
    echo "        A copy appeared or moved. Either fold it into one of the existing" >&2
    echo "        call sites, or add it to COPIES[] above so this suite pins it too." >&2
fi

# ---------------------------------------------------------------------------
echo ""
echo "-- case 2: the definitions are byte-for-byte identical --"
# ---------------------------------------------------------------------------
DEF_A="$(extract_def "$REPO_ROOT/${COPIES[0]}")"
DEF_B="$(extract_def "$REPO_ROOT/${COPIES[1]}")"

if [[ -n "$DEF_A" ]]; then
    ok "${COPIES[0]} defines an extractable json_escape() block"
else
    no "${COPIES[0]} defines an extractable json_escape() block" "no block matched"
fi
if [[ -n "$DEF_B" ]]; then
    ok "${COPIES[1]} defines an extractable json_escape() block"
else
    no "${COPIES[1]} defines an extractable json_escape() block" "no block matched"
fi

if [[ -n "$DEF_A" && -n "$DEF_B" ]]; then
    if [[ "$DEF_A" == "$DEF_B" ]]; then
        ok "the two json_escape() definitions are byte-for-byte identical"
    else
        no "the two json_escape() definitions are byte-for-byte identical" \
            "$(diff <(printf '%s\n' "$DEF_A") <(printf '%s\n' "$DEF_B") || true)"
    fi
else
    skip "the two json_escape() definitions are byte-for-byte identical" \
        "one or both blocks could not be extracted"
fi

# ---------------------------------------------------------------------------
echo ""
echo "-- case 3: behavior parity over the corpus --"
# ---------------------------------------------------------------------------
# Each row is <label>|<input>|<expected>. The inputs are the ones that actually
# distinguish a correct escaper from a broken one; a plain string is included so
# a total-failure mode (empty output) is caught too.
CORPUS_LABELS=()
CORPUS_INPUTS=()
CORPUS_EXPECTED=()
corpus() { CORPUS_LABELS+=("$1"); CORPUS_INPUTS+=("$2"); CORPUS_EXPECTED+=("$3"); }

corpus "plain text passes through"        'hello world'   'hello world'
corpus "empty string stays empty"         ''              ''
corpus "backslash is doubled"             'a\b'           'a\\b'
corpus "double quote is escaped"          'say "hi"'      'say \"hi\"'
corpus "newline becomes \\n"              $'a\nb'         'a\nb'
corpus "tab becomes \\t"                  $'a\tb'         'a\tb'
corpus "carriage return is dropped"       $'a\rb'         'ab'
corpus "CRLF collapses to \\n"            $'a\r\nb'       'a\nb'
# Ordering: the backslash pass must run FIRST, otherwise the backslash it
# inserts in front of the quote gets doubled by a later pass.
corpus "backslash before quote"           'a\"b'          'a\\\"b'
# A literal two-character \n must not be mistaken for a newline, and its
# backslash must be doubled like any other.
corpus "literal backslash-n is not a newline" 'a\nb'      'a\\nb'
corpus "combined specials"                $'\\\t"\n'      '\\\t\"\n'

for i in "${!CORPUS_LABELS[@]}"; do
    label="${CORPUS_LABELS[$i]}"
    input="${CORPUS_INPUTS[$i]}"
    expected="${CORPUS_EXPECTED[$i]}"

    out_a="$(run_copy "$DEF_A" "$input")"
    out_b="$(run_copy "$DEF_B" "$input")"

    assert_eq "${COPIES[0]}: $label" "$expected" "$out_a"
    assert_eq "${COPIES[1]}: $label" "$expected" "$out_b"
done

# ---------------------------------------------------------------------------
echo ""
echo "-- case 4: output is valid JSON and round-trips --"
# ---------------------------------------------------------------------------
# The corpus above pins the exact bytes; this pins the PROPERTY those bytes are
# for. A future change that alters both copies in lockstep still has to keep
# producing a parseable JSON string body whose decoded value is the input with
# carriage returns removed (the one lossy transform this escaper performs).
if ! command -v jq >/dev/null 2>&1; then
    skip "escaped output parses as JSON and round-trips" "jq not installed"
else
    SCRATCH="$(mktemp -d)"
    trap 'rm -rf "$SCRATCH"' EXIT

    for i in "${!CORPUS_LABELS[@]}"; do
        label="${CORPUS_LABELS[$i]}"
        input="${CORPUS_INPUTS[$i]}"
        want="${input//$'\r'/}"

        escaped="$(run_copy "$DEF_A" "$input")"
        # Routed through a file, not $(...), because an input whose decoded
        # value ENDS in a newline (the combined-specials row) is exactly the
        # case command substitution would silently erase, turning a real
        # round-trip failure into a pass.
        if printf '"%s"' "$escaped" | jq -er . >"$SCRATCH/out" 2>&1; then
            got="$(cat "$SCRATCH/out"; printf X)"; got="${got%X}"
            got="${got%$'\n'}"   # jq -r appends exactly one newline of its own
            assert_eq "round-trip: $label" "$want" "$got"
        else
            no "round-trip: $label" "not valid JSON: $(cat "$SCRATCH/out")"
        fi
    done
fi

# ---------------------------------------------------------------------------
echo ""
echo "========================================="
echo "  Total:  $TOTAL"
printf "  ${GREEN}Passed${NC}: %s\n" "$PASS"
printf "  ${RED}Failed${NC}: %s\n" "$FAIL"
[[ $SKIP -gt 0 ]] && printf "  ${YELLOW}Skipped${NC}: %s\n" "$SKIP"
echo "========================================="

if [[ $FAIL -gt 0 ]]; then
    printf "\n${RED}TESTS FAILED${NC}\n"
    exit 1
fi
printf "\n${GREEN}ALL TESTS PASSED${NC}\n"
exit 0

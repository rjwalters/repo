#!/usr/bin/env bash
# Test suite for /repo:gitignore's redundancy model and its ignore-status gate —
# the two things that stand between "these two rules look the same" and
# "removing one of them is safe".
#
# Usage: ./commands/repo/tests/test-gitignore-anchoring.sh
# Exit code 0 = all tests pass, 1 = failures detected.
#
# Structured like commands/repo/tests/test-verify-fix-persistence.sh: pure bash,
# no test framework, a fixture section that exercises a faithful transcription of
# the documented check against real `git check-ignore` behavior, then a doc-drift
# section asserting the command files still say what this suite implements.
# `pnpm test` delegates to this file via hooks/repo/tests/run.sh.
#
# WHY THIS FILE EXISTS (repo#531): /repo:audit reported `proofs/.gitignore:
# .vscode/` as redundant with the root `.gitignore`'s `.vscode/*` and recommended
# dropping it. It is not redundant — `.vscode/*` contains a non-trailing slash, so
# it is anchored to the directory of the `.gitignore` that declares it and never
# reaches `proofs/.vscode/`. The removal would have un-ignored the whole subtree,
# and was caught only because a `git check-ignore -v` pass ran before the commit.
#
# The contract under test:
#   1  a rule is redundant only if a rule in the SAME OR AN ANCESTOR .gitignore
#      matches the same paths from where that rule sits — anchored ancestor
#      patterns (`/x`, `dir/x`, `dir/*`) never cover a subdirectory; unanchored
#      ones (`x`, `*.log`, `**/x`) do
#   2  before applying a removal or narrowing, the ignored-path set is captured
#      before and after; any difference REFUSES the edit (report as a finding,
#      do not count as applied)
#   3  the rule-attribution diff is NOT the gate — a genuine dedupe moves
#      coverage to the surviving ancestor rule, which is expected and reported
#   4  the per-rule verification result appears in the report, including when the
#      fixes come from /repo:all's Audit stage

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CMD_DIR="$REPO_ROOT/commands/repo"
GITIGNORE_MD="$CMD_DIR/gitignore.md"
AUDIT_MD="$CMD_DIR/audit.md"

# Assertion helpers (ok/no/skip/assert_eq/assert_contains/assert_not_contains/
# assert_matches) plus the PASS/FAIL/SKIP/TOTAL counters and color vars are
# shared across the repo test suites — see lib/assert.sh (repo#307).
source "$(dirname "${BASH_SOURCE[0]}")/lib/assert.sh"

# Fixture hermeticity (repo#518): a Loom-dispatched session overrides
# core.hooksPath through GIT_CONFIG_* env pairs, which fixture repos inherit
# unless the override is scrubbed — see lib/git-fixture.sh.
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-fixture.sh"
git_fixture_scrub_env

for f in "$GITIGNORE_MD" "$AUDIT_MD"; do
    if [[ ! -f "$f" ]]; then
        echo "FATAL: $f not found" >&2
        exit 1
    fi
done

SCRATCH="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$SCRATCH"' EXIT

# ---------------------------------------------------------------------------
# The check under test — a direct transcription of the documented gate.
# Scratch output lands OUTSIDE the fixture repo, as the doc requires, so the
# snapshot files cannot perturb the listing being compared.
# ---------------------------------------------------------------------------

# ipaths <repo> <pathspec>: the paths ignored today under <pathspec>. Tracked
# files are unaffected by a .gitignore edit, so ignored-untracked is the whole
# exposure.
ipaths() {
    git -C "$1" ls-files --others --ignored --exclude-standard -z -- "$2" \
        | tr '\0' '\n' | sed '/^$/d' | sort
}

# attrib <repo> <pathspec>: `<file>:<line>:<pattern>\t<path>` for each of those.
attrib() {
    ipaths "$1" "$2" \
        | git -C "$1" -c core.excludesFile=/dev/null check-ignore -v --stdin
}

# gate <repo> <pathspec> <mutation-command...>
# Captures the ignored-path set, runs the mutation, captures it again, and
# reverts the mutation when the sets differ — exactly the documented behavior
# ("revert the edit and do not count it as applied"). Sets three globals rather
# than echoing a verdict, so it must be called directly and never inside `$(…)`
# (a command substitution subshell would discard the diffs).
GATE_RESULT=""
GATE_PATHS_DIFF=""
GATE_ATTRIB_DIFF=""
gate() {
    local repo="$1" spec="$2"; shift 2
    local d; d="$(mktemp -d "$SCRATCH/gate.XXXXXX")"
    ipaths "$repo" "$spec" >"$d/paths.before"
    attrib "$repo" "$spec" >"$d/attrib.before" 2>/dev/null
    local snapshot; snapshot="$(mktemp -d "$SCRATCH/snap.XXXXXX")"
    cp -a "$repo/." "$snapshot/"
    "$@"
    ipaths "$repo" "$spec" >"$d/paths.after"
    attrib "$repo" "$spec" >"$d/attrib.after" 2>/dev/null
    GATE_PATHS_DIFF="$(diff -u "$d/paths.before" "$d/paths.after" || true)"
    GATE_ATTRIB_DIFF="$(diff -u "$d/attrib.before" "$d/attrib.after" || true)"
    if [[ -n "$GATE_PATHS_DIFF" ]]; then
        rm -rf "$repo"; mkdir -p "$repo"; cp -a "$snapshot/." "$repo/"
        GATE_RESULT="REFUSED"
    else
        GATE_RESULT="SAFE"
    fi
}

# ---------------------------------------------------------------------------
echo "-- anchoring: an anchored ancestor pattern does not cover a subdirectory --"
# ---------------------------------------------------------------------------
# The exact shape from repo#531: root `.vscode/*` (anchored — non-trailing slash)
# plus `proofs/.gitignore: .vscode/`.
R1="$SCRATCH/anchored"
git_fixture_init "$R1" -b main
mkdir -p "$R1/.vscode" "$R1/proofs/.vscode"
printf '.vscode/*\n' >"$R1/.gitignore"
printf '.vscode/\n' >"$R1/proofs/.gitignore"
touch "$R1/.vscode/settings.json" "$R1/proofs/.vscode/settings.json" "$R1/README.md"

R1_WHY="$(git -C "$R1" -c core.excludesFile=/dev/null check-ignore -v \
    proofs/.vscode/settings.json 2>/dev/null)"
assert_contains "the subdirectory rule is what ignores proofs/.vscode/settings.json" \
    "$R1_WHY" "proofs/.gitignore:1:.vscode/"
# `check-ignore -v` names exactly one rule per path — assert it is not the root's.
assert_eq "the root's anchored .vscode/* is NOT what covers it" "0" \
    "$(printf '%s\n' "$R1_WHY" | grep -c '^\.gitignore:')"

# Prove the ancestor rule genuinely cannot reach it, independent of precedence:
# with the subdirectory .gitignore absent, nothing ignores the path at all.
mv "$R1/proofs/.gitignore" "$SCRATCH/parked-gitignore"
assert_eq "with the subdirectory rule gone, proofs/.vscode/settings.json is unignored" \
    "1" "$(git -C "$R1" check-ignore -q proofs/.vscode/settings.json; echo $?)"
mv "$SCRATCH/parked-gitignore" "$R1/proofs/.gitignore"
assert_eq "restoring the subdirectory rule re-ignores it" \
    "0" "$(git -C "$R1" check-ignore -q proofs/.vscode/settings.json; echo $?)"

# ---------------------------------------------------------------------------
echo ""
echo "-- gate: the repo#531 removal is REFUSED --"
# ---------------------------------------------------------------------------
gate "$R1" "proofs/" rm -f "$R1/proofs/.gitignore"
assert_eq "removing proofs/.gitignore's rule is refused by the gate" "REFUSED" "$GATE_RESULT"
assert_contains "the gate names the path that would un-ignore" \
    "$GATE_PATHS_DIFF" "proofs/.vscode/settings.json"
assert_eq "a refused edit is reverted, so the rule is still on disk" \
    "0" "$(git -C "$R1" check-ignore -q proofs/.vscode/settings.json; echo $?)"

# ---------------------------------------------------------------------------
echo ""
echo "-- gate: a genuinely redundant unanchored pair is still SAFE --"
# ---------------------------------------------------------------------------
# The over-conservatism guard: `*.log` has no slash at all, so the root rule does
# reach the subdirectory and the subdirectory copy really is redundant.
R2="$SCRATCH/unanchored"
git_fixture_init "$R2" -b main
mkdir -p "$R2/sub"
printf '*.log\n' >"$R2/.gitignore"
printf '*.log\n' >"$R2/sub/.gitignore"
touch "$R2/a.log" "$R2/sub/b.log" "$R2/README.md"

gate "$R2" "sub/" rm -f "$R2/sub/.gitignore"
assert_eq "removing the redundant unanchored duplicate is SAFE" "SAFE" "$GATE_RESULT"
assert_eq "no path changed ignore status" "" "$GATE_PATHS_DIFF"
assert_eq "the removal actually happened (not reverted)" \
    "1" "$([[ -f "$R2/sub/.gitignore" ]]; echo $?)"
# Contract 3: the attribution diff DOES change here, which is why it cannot be
# the gate — coverage moved up to the surviving ancestor rule.
assert_matches "coverage moved to the ancestor rule (attribution diff is non-empty)" \
    "$GATE_ATTRIB_DIFF" '\+\.gitignore:1:\*\.log'
assert_eq "sub/b.log is still ignored, now by the root rule" \
    "0" "$(git -C "$R2" check-ignore -q sub/b.log; echo $?)"

# ---------------------------------------------------------------------------
echo ""
echo "-- anchoring: \`**\` crosses directory levels, so it is not anchored --"
# ---------------------------------------------------------------------------
R3="$SCRATCH/globstar"
git_fixture_init "$R3" -b main
mkdir -p "$R3/a/b/build"
printf '**/build/\n' >"$R3/.gitignore"
printf 'build/\n' >"$R3/a/b/.gitignore"
touch "$R3/a/b/build/x" "$R3/README.md"
assert_eq "a root \`**/build/\` reaches a/b/build/x despite containing a slash" \
    "0" "$(git -C "$R3" check-ignore -q a/b/build/x; echo $?)"
gate "$R3" "a/" rm -f "$R3/a/b/.gitignore"
assert_eq "so the nested \`build/\` duplicate is SAFE to remove" "SAFE" "$GATE_RESULT"

# ---------------------------------------------------------------------------
echo ""
echo "-- anchoring: a leading slash anchors the same way a mid-pattern one does --"
# ---------------------------------------------------------------------------
R4="$SCRATCH/leadslash"
git_fixture_init "$R4" -b main
mkdir -p "$R4/a/foo"
printf '/foo\n' >"$R4/.gitignore"
printf 'foo\n' >"$R4/a/.gitignore"
touch "$R4/a/foo/x" "$R4/README.md"
gate "$R4" "a/" rm -f "$R4/a/.gitignore"
assert_eq "a root \`/foo\` does not cover a/foo, so removing \`a/.gitignore: foo\` is REFUSED" \
    "REFUSED" "$GATE_RESULT"
assert_contains "the gate names the path under the anchored-away rule" \
    "$GATE_PATHS_DIFF" "a/foo/x"

# ---------------------------------------------------------------------------
echo ""
echo "-- precedence: identical unanchored text can still be load-bearing --"
# ---------------------------------------------------------------------------
# The second reason the textual model is only a candidate filter: .gitignore
# precedence is deepest-file-last, so a subdirectory rule can be re-establishing
# an ignore that an ancestor's negation cancelled.
R5="$SCRATCH/negation"
git_fixture_init "$R5" -b main
mkdir -p "$R5/sub"
printf '*.log\n!important.log\n' >"$R5/.gitignore"
printf '*.log\n' >"$R5/sub/.gitignore"
touch "$R5/important.log" "$R5/sub/important.log" "$R5/sub/other.log" "$R5/README.md"
assert_eq "sub/important.log is ignored only via the subdirectory rule" \
    "0" "$(git -C "$R5" check-ignore -q sub/important.log; echo $?)"
gate "$R5" "sub/" rm -f "$R5/sub/.gitignore"
assert_eq "the textually-identical subdirectory rule is REFUSED for removal" \
    "REFUSED" "$GATE_RESULT"
assert_contains "the gate names the path the ancestor negation would un-ignore" \
    "$GATE_PATHS_DIFF" "sub/important.log"

# ---------------------------------------------------------------------------
echo ""
echo "-- gate: an over-broad rewrite (newly ignored paths) is REFUSED too --"
# ---------------------------------------------------------------------------
# The gate is symmetric: broadening a rule so it swallows real content is as much
# a status change as un-ignoring one.
R6="$SCRATCH/overbroad"
git_fixture_init "$R6" -b main
mkdir -p "$R6/sub"
printf '*.log\n' >"$R6/sub/.gitignore"
touch "$R6/sub/b.log" "$R6/sub/notes.md"
broaden() { printf '*\n' >"$R6/sub/.gitignore"; }
gate "$R6" "sub/" broaden
assert_eq "widening sub/.gitignore to \`*\` is refused" "REFUSED" "$GATE_RESULT"
assert_contains "the gate names the newly swallowed path" "$GATE_PATHS_DIFF" "sub/notes.md"
assert_eq "the refused rewrite is reverted" "*.log" "$(cat "$R6/sub/.gitignore")"

# ---------------------------------------------------------------------------
echo ""
echo "-- gate: a global excludesFile cannot mask a difference --"
# ---------------------------------------------------------------------------
# `-c core.excludesFile=/dev/null` makes the result a property of the repo rather
# than of the machine: without it, a user's global ignore of `*.log` keeps
# sub/b.log ignored after the repo's own rule is gone, and the gate says SAFE.
R7="$SCRATCH/globalexclude"
git_fixture_init "$R7" -b main
mkdir -p "$R7/sub"
printf '*.log\n' >"$R7/sub/.gitignore"
touch "$R7/sub/b.log"
printf '*.log\n' >"$SCRATCH/global-excludes"
git -C "$R7" config core.excludesFile "$SCRATCH/global-excludes"
R7_ATTRIB_MASKED="$(git -C "$R7" check-ignore -v sub/b.log 2>/dev/null)"
rm -f "$R7/sub/.gitignore"
assert_contains "without the override, the global excludesFile answers for the path" \
    "$(git -C "$R7" check-ignore -v sub/b.log 2>/dev/null)" "global-excludes"
assert_contains "with the override, nothing in the repo ignores it any more" \
    "$(git -C "$R7" -c core.excludesFile=/dev/null check-ignore -v sub/b.log 2>&1; echo "rc=$?")" \
    "rc=1"
assert_contains "the repo's own rule was the real owner before the removal" \
    "$R7_ATTRIB_MASKED" "sub/.gitignore"

# ---------------------------------------------------------------------------
echo ""
echo "-- doc drift: gitignore.md documents the anchoring rule --"
# ---------------------------------------------------------------------------
# Prose assertions run against the whitespace-flattened file (flatten(), repo#363)
# so a sentence that wraps across lines still matches.
GI="$(flatten "$GITIGNORE_MD")"

assert_contains "gitignore.md warns against deduping on matching pattern text" \
    "$GI" "Do not flag a subdirectory rule as redundant with an ancestor's on matching"
assert_matches "it names the anchoring rule (a non-trailing slash anchors)" \
    "$GI" 'anchored.*directory of the `.gitignore` that declares it'
assert_matches "it cites man gitignore for the anchoring clause" \
    "$GI" 'separator at the beginning or middle'
assert_contains "it gives the unanchored row (bare name / glob / trailing slash)" \
    "$GI" '| `name`, `*.log`, `name/`'
assert_contains "it gives the anchored row (leading and mid-pattern slash)" \
    "$GI" '| `/name`, `dir/name`, `dir/*`'
assert_contains "it exempts \`**\`, which crosses directory levels" \
    "$GI" '| `**/name`, `dir/**/name`'
assert_contains "it states the redundancy condition in terms of same-or-ancestor scope" \
    "$GI" "matches the same paths *from where that rule sits*"
assert_contains "it carries the concrete .vscode regression" "$GI" "proofs/.vscode/"
assert_contains "it cites the issue" "$GI" "#531"
assert_contains "it also covers negation precedence as a load-bearing case" \
    "$GI" "deepest-file-last"
assert_contains "it demotes the textual model to a candidate filter" \
    "$GI" "candidate filter only"

# ---------------------------------------------------------------------------
echo ""
echo "-- doc drift: gitignore.md documents the before/after ignore-status gate --"
# ---------------------------------------------------------------------------
assert_contains "there is a dedicated gate section" "$GI" "### Verify a removal changes nothing"
assert_contains "the gate runs git check-ignore -v" "$GI" "check-ignore -v --stdin"
assert_contains "it neutralizes the user's global excludes" \
    "$GI" "core.excludesFile=/dev/null"
assert_contains "it snapshots the ignored-path set before and after" "$GI" "paths.before"
assert_contains "and compares them" "$GI" "paths.after"
assert_matches "the path-set diff is the gate and must be empty" \
    "$GI" 'path-set diff is the gate'
assert_contains "a non-empty diff reverts the edit and does not count as applied" \
    "$GI" "revert the edit and do not count it as applied"
assert_contains "a refused removal is reported as a finding instead" \
    "$GI" "Report it as a finding instead"
assert_contains "the refusal report shape is shown" "$GI" "removal REFUSED"
assert_contains "the verified report shape is shown" "$GI" "verified: 12 paths unchanged"
assert_matches "the attribution diff is explicitly NOT a gate" \
    "$GI" 'attribution diff is not a gate'
assert_contains "the scratch files live outside the repo" \
    "$GI" 'S=$(mktemp -d)'
assert_contains "the gate's limit (paths that do not exist yet) is stated" \
    "$GI" "necessary, not sufficient"
assert_contains "the gate is per rule, not per file" "$GI" "Run the gate per rule, not once per file"
assert_contains "the gate applies to [[all]]'s Audit stage too" \
    "$GI" "Same gate when these fixes are offered from [[all]]'s Audit stage"

# The gate must precede the existing verify-after-write step, since it decides
# whether the edit is applied at all.
GATE_LINE="$(grep -n '^### Verify a removal changes nothing' "$GITIGNORE_MD" | cut -d: -f1)"
AFTER_LINE="$(grep -n '^### Verify after write' "$GITIGNORE_MD" | cut -d: -f1)"
assert_eq "the removal gate is documented before 'Verify after write'" "yes" \
    "$([[ -n "$GATE_LINE" && -n "$AFTER_LINE" && "$GATE_LINE" -lt "$AFTER_LINE" ]] && echo yes || echo no)"

# ---------------------------------------------------------------------------
echo ""
echo "-- doc drift: the verification result is part of the report --"
# ---------------------------------------------------------------------------
# The "For each .gitignore file, show:" list is what /repo:all's Audit stage
# inherits, so the per-rule result has to be a line item there rather than only
# inside the gate section.
INTERACTION="$(awk '/^For each `\.gitignore` file, show:/{f=1} /^By default, apply the clear-cut/{f=0} f{print}' "$GITIGNORE_MD" | tr '\n' ' ' | tr -s ' ')"
assert_contains "the per-file report lists the verification result" \
    "$INTERACTION" "ignore-status verification result for every removal or narrowing"
assert_contains "it is one line per rule, verified or REFUSED" \
    "$INTERACTION" "one line per rule"
assert_contains "the two outcomes are named" "$INTERACTION" "\`verified\` with the path count or \`REFUSED\`"
assert_contains "the line is never omitted" "$INTERACTION" "never omitted"
assert_contains "including from [[all]]'s Audit stage" "$INTERACTION" "Audit stage"

# ---------------------------------------------------------------------------
echo ""
echo "-- doc drift: audit.md carries the anchoring caveat too --"
# ---------------------------------------------------------------------------
AU="$(flatten "$AUDIT_MD")"
assert_contains "audit.md still carries the X + X/ symlink caveat" \
    "$AU" '`X` + `X/` pairs'
assert_contains "audit.md now also carries the anchoring caveat" \
    "$AU" "a subdirectory rule matching an ancestor's pattern text"
assert_matches "it states the anchoring rule in one line" \
    "$AU" 'anchored to its own `.gitignore`'"'"'s directory'
assert_contains "it names the concrete example" "$AU" '`.vscode/*` never covers'
assert_contains "it points at gitignore.md's gate" "$AU" "before/after gate"
assert_contains "it keeps audit.md read-only (candidate redundancy only)" \
    "$AU" "candidate* redundancy"

# ---------------------------------------------------------------------------
echo ""
echo "========================================="
echo "  Total:  $TOTAL"
printf "  ${GREEN}Passed${NC}: %s\n" "$PASS"
printf "  ${RED}Failed${NC}: %s\n" "$FAIL"
printf "  ${YELLOW}Skipped${NC}: %s\n" "$SKIP"
echo "========================================="

if [[ $FAIL -gt 0 ]]; then
    printf "\n${RED}TESTS FAILED${NC}\n"
    exit 1
fi
printf "\n${GREEN}ALL TESTS PASSED${NC}\n"
exit 0

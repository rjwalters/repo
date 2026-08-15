#!/usr/bin/env bash
# Test suite for /repo:all's ownership of Audit-surfaced orphaned files
# (repo#301) — the stage assignment that decides whether a correctly-surfaced
# orphan gets acted on, deferred with a name, or quietly lost.
#
# Usage: ./commands/repo/tests/test-all-orphans-stage.sh
# Exit code 0 = all tests pass, 1 = failures detected.
#
# Structured like commands/repo/tests/test-early-sync-switch.sh: pure bash, no
# test framework, PASS/FAIL/SKIP/TOTAL counters and a summary block. `pnpm test`
# delegates to this file via hooks/repo/tests/run.sh.
#
# WHY THIS FILE EXISTS (repo#301): a /repo:all run in a consumer repo on
# 2026-08-14 surfaced two TRACKED generated files (`vite.config.d.ts`,
# `vitest.config.d.ts`) committed by a scaffold, no longer emitted, referenced
# nowhere. Correct finding — and then no stage owned it. Every other Audit
# finding class has a later home (docs -> stage 4, branch/worktree hygiene ->
# stage 7); orphans had none, and Tidy is NOT that home: its SAFE tier is safe
# precisely because those files are regenerable or never committed, and it says
# so ("Nothing in this category may be tracked by git"). The operator handled it
# by asking mid-Audit, which worked but is not what the doc described.
#
# The contract under test:
#   1  stage 1 (Audit) explicitly claims orphaned files, and the claim sits
#      inside stage 1 — before stage 2 — so it is a stage assignment and not a
#      loose remark somewhere in the file
#   2  findings are split by TRACKED-NESS, by a transcribable git command;
#      untracked ones route to Tidy (stage 5), tracked ones are handled in
#      stage 1, so no file is ever put behind two gates in one run
#   3  removal of a tracked file is per-file and behind an explicit yes, INCLUDING
#      under the default (non---ask) form, and is explicitly NOT folded into
#      Tidy's auto-applied SAFE tier
#   4  anything not removed is carried into the Final Summary as deferred and
#      named individually — a count alone sends the user back to re-run the audit
#   5  Tidy's stage in all.md does not quietly acquire tracked-file removal
#   6  the anchors this reasoning leans on still exist in audit.md, orphans.md,
#      and tidy.md (read-only posture, report-and-wait, "never tracked" SAFE tier)
#
# Two sections: a fixture section that runs the documented tracked-ness check
# against a real git repository (tracked, untracked, gitignored, spaces in the
# path, never-committed-but-staged), and a doc-drift section asserting all.md
# still says what this suite implements.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CMD_DIR="$REPO_ROOT/commands/repo"

ALL_MD="$CMD_DIR/all.md"
AUDIT_MD="$CMD_DIR/audit.md"
ORPHANS_MD="$CMD_DIR/orphans.md"
TIDY_MD="$CMD_DIR/tidy.md"

PASS=0
FAIL=0
SKIP=0
TOTAL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

for f in "$ALL_MD" "$AUDIT_MD" "$ORPHANS_MD" "$TIDY_MD"; do
    if [[ ! -f "$f" ]]; then
        echo "FATAL: required file not found at $f" >&2
        exit 1
    fi
done

ALL="$(cat "$ALL_MD")"
AUDIT="$(cat "$AUDIT_MD")"
ORPHANS="$(cat "$ORPHANS_MD")"
TIDY="$(cat "$TIDY_MD")"

# Prose in these docs is hard-wrapped, so any assertion on a phrase longer than
# a few words has to run against a newline-flattened copy or it fails on the
# wrap point rather than on the content.
ALL_FLAT="$(tr '\n' ' ' < "$ALL_MD" | tr -s ' ')"
AUDIT_FLAT="$(tr '\n' ' ' < "$AUDIT_MD" | tr -s ' ')"

# ---------------------------------------------------------------------------
# Assertion helpers
# ---------------------------------------------------------------------------

ok() {   # <label>
    TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1))
    printf "  ${GREEN}PASS${NC}: %s\n" "$1"
}
no() {   # <label> <detail>
    TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
    printf "  ${RED}FAIL${NC}: %s\n" "$1"
    [[ -n "${2:-}" ]] && printf "        %s\n" "$2"
    return 0
}
skip() {  # <label> <reason>
    SKIP=$((SKIP + 1))
    printf "  ${YELLOW}SKIP${NC}: %s\n" "$1"
    [[ -n "${2:-}" ]] && printf "        %s\n" "$2"
    return 0
}
assert_eq() {  # <label> <expected> <actual>
    if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1" "expected [$2], got [$3]"; fi
}
assert_contains() {  # <label> <haystack> <needle>
    if [[ "$2" == *"$3"* ]]; then ok "$1"; else no "$1" "missing [$3]"; fi
}
assert_not_contains() {  # <label> <haystack> <needle>
    if [[ "$2" != *"$3"* ]]; then ok "$1"; else no "$1" "unexpected [$3] present"; fi
}
assert_matches() {  # <label> <haystack> <ere>
    if printf '%s\n' "$2" | grep -qE -- "$3"; then ok "$1"; else no "$1" "no match for /$3/"; fi
}

# ---------------------------------------------------------------------------
echo "1. The documented tracked-ness check classifies real files correctly"
# ---------------------------------------------------------------------------

# A faithful transcription of the one-liner all.md documents. If the doc's
# command changes, the drift assertion in section 2 fails and this function is
# the thing to update.
classify_orphan() {  # <repo> <path-relative-to-repo>
    git -C "$1" ls-files --error-unmatch -- "$2" >/dev/null 2>&1 \
        && echo tracked || echo untracked
}

FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/repo-orphans-stage.XXXXXX")"
cleanup() { rm -rf "$FIXTURE_ROOT"; }
trap cleanup EXIT

if ! command -v git >/dev/null 2>&1; then
    skip "tracked-ness fixtures" "git not available"
else
    FIX="$FIXTURE_ROOT/repo"
    mkdir -p "$FIX"
    git -C "$FIX" init --quiet
    git -C "$FIX" config user.email "test@example.invalid"
    git -C "$FIX" config user.name "Orphan Stage Test"

    printf 'build/\n' > "$FIX/.gitignore"
    printf 'export {}\n' > "$FIX/vite.config.d.ts"
    mkdir -p "$FIX/dir with spaces"
    printf 'x\n' > "$FIX/dir with spaces/generated.d.ts"
    git -C "$FIX" add .gitignore vite.config.d.ts "dir with spaces/generated.d.ts"
    git -C "$FIX" commit --quiet -m "scaffold"

    mkdir -p "$FIX/build"
    printf 'compiled\n' > "$FIX/build/out.js"          # untracked AND gitignored
    printf 'scratch\n' > "$FIX/notes.txt"              # untracked, not ignored
    printf 'staged\n' > "$FIX/staged-only.ts"
    git -C "$FIX" add staged-only.ts                   # in the index, never committed

    # The exact shape from the incident: a tracked, unreferenced generated file.
    assert_eq "a committed generated file classifies as tracked" \
        "tracked" "$(classify_orphan "$FIX" "vite.config.d.ts")"
    # Quoting matters — an orphan path with spaces must not be word-split into
    # two nonexistent pathspecs and silently reported untracked.
    assert_eq "a tracked path containing spaces classifies as tracked" \
        "tracked" "$(classify_orphan "$FIX" "dir with spaces/generated.d.ts")"
    assert_eq "a gitignored build output classifies as untracked" \
        "untracked" "$(classify_orphan "$FIX" "build/out.js")"
    assert_eq "an untracked, non-ignored file classifies as untracked" \
        "untracked" "$(classify_orphan "$FIX" "notes.txt")"
    # ls-files reads the INDEX, so a staged-but-never-committed file is already
    # tracked — removing it is still a repo change and must take the gated path.
    assert_eq "a staged-but-uncommitted file classifies as tracked" \
        "tracked" "$(classify_orphan "$FIX" "staged-only.ts")"
    assert_eq "a nonexistent path classifies as untracked (no crash)" \
        "untracked" "$(classify_orphan "$FIX" "does-not-exist.ts")"

    # The check must not be confused by a path that is BOTH tracked and matched
    # by a gitignore rule — git tracks it regardless, so it is a repo change.
    mkdir -p "$FIX/build"
    printf 'kept\n' > "$FIX/build/committed-anyway.js"
    git -C "$FIX" add --force build/committed-anyway.js
    git -C "$FIX" commit --quiet -m "force-add an ignored path"
    assert_eq "a tracked file that also matches a gitignore rule is tracked" \
        "tracked" "$(classify_orphan "$FIX" "build/committed-anyway.js")"
fi

# ---------------------------------------------------------------------------
echo ""
echo "2. Stage 1 claims orphaned files, and the claim lives inside stage 1"
# ---------------------------------------------------------------------------

STAGE1_LN="$(grep -nE '^### 1\. Audit' "$ALL_MD" | head -1 | cut -d: -f1)"
STAGE2_LN="$(grep -nE '^### 2\. ' "$ALL_MD" | head -1 | cut -d: -f1)"
STAGE5_LN="$(grep -nE '^### 5\. ' "$ALL_MD" | head -1 | cut -d: -f1)"
STAGE6_LN="$(grep -nE '^### 6\. ' "$ALL_MD" | head -1 | cut -d: -f1)"
ORPHAN_CLAIM_LN="$(grep -nE '^\*\*Orphaned files are actioned here' "$ALL_MD" | head -1 | cut -d: -f1)"

if [[ -n "$ORPHAN_CLAIM_LN" ]]; then
    ok "all.md states which stage acts on orphaned files"
else
    no "all.md states which stage acts on orphaned files" \
        "no '**Orphaned files are actioned here...' claim in all.md"
fi

if [[ -n "$STAGE1_LN" && -n "$STAGE2_LN" && -n "$ORPHAN_CLAIM_LN" ]]; then
    # The whole point is a STAGE assignment: prose that drifted out of stage 1
    # would answer "what happens to orphans" without answering "when".
    assert_eq "the claim sits after the stage 1 heading" "yes" \
        "$([[ "$STAGE1_LN" -lt "$ORPHAN_CLAIM_LN" ]] && echo yes || echo no)"
    assert_eq "the claim sits before stage 2" "yes" \
        "$([[ "$ORPHAN_CLAIM_LN" -lt "$STAGE2_LN" ]] && echo yes || echo no)"
else
    no "the orphan claim's position is checkable" \
        "1=$STAGE1_LN claim=$ORPHAN_CLAIM_LN 2=$STAGE2_LN"
fi

assert_contains "the claim is exclusive — no other stage owns orphans" "$ALL_FLAT" \
    "actioned here too, and nowhere else"
assert_contains "the finding classes that DO have a later home are named" "$ALL_FLAT" \
    "docs and links to Docs (stage 4), branch and worktree hygiene to Reset (stage 7)"
assert_contains "Tidy is named as the stage this deliberately is not" "$ALL_FLAT" \
    "Tidy (stage 5) is the stage it looks like it belongs to and deliberately is not"
assert_contains "the reason Tidy's SAFE tier cannot own this is stated" "$ALL_FLAT" \
    "regenerable or were never committed"
assert_contains "the consequence of leaving it unowned is stated" "$ALL_FLAT" \
    "would fall out of the run entirely"

# ---------------------------------------------------------------------------
echo ""
echo "3. Findings are split by tracked-ness; untracked ones route to Tidy"
# ---------------------------------------------------------------------------

assert_contains "the split is by tracked-ness" "$ALL_FLAT" "Split the findings by tracked-ness"
# Drift guard for section 1's transcription: the doc must document the exact
# check this suite exercises.
assert_contains "the documented check is git ls-files --error-unmatch" "$ALL" \
    'git ls-files --error-unmatch -- "$path"'
assert_contains "the check is quoted against paths with spaces" "$ALL" '-- "$path"'
assert_contains "untracked orphans are named" "$ALL" "- **Untracked orphans**"
assert_contains "untracked orphans are left for Tidy in stage 5" "$ALL_FLAT" \
    "leave them for Tidy in stage 5"
assert_contains "double-gating is named as the reason not to act on them here" "$ALL_FLAT" \
    "two different gates in one run"
assert_contains "tracked orphans are named" "$ALL" "- **Tracked orphans**"

# ---------------------------------------------------------------------------
echo ""
echo "4. Tracked-file removal stays per-file and behind an explicit yes"
# ---------------------------------------------------------------------------

assert_contains "removal is offered one file at a time, each with its own yes" "$ALL_FLAT" \
    "one file at a time, each behind"
assert_contains "the confirmation holds under the default (non---ask) form too" "$ALL_FLAT" \
    'including under the default (non-`--ask`) form'
# The load-bearing distinction from the issue: this must never become another
# auto-applied SAFE-tier deletion.
assert_contains "it is explicitly not folded into Tidy's auto-applied SAFE tier" "$ALL_FLAT" \
    "never folded into Tidy's auto-applied SAFE tier"
assert_contains "the irreversibility argument is stated" "$ALL_FLAT" \
    "recoverable only from history"
assert_contains "'nothing references it' is called evidence, not proof" "$ALL_FLAT" \
    "evidence rather than proof"
assert_contains "the false-positive shapes are named" "$ALL_FLAT" \
    "fixture opened by path at runtime"
assert_contains "the offer carries the finding's own evidence" "$ALL_FLAT" \
    "what was grepped for, how many references"
assert_contains "removal is staged as a repo change via git rm" "$ALL_FLAT" \
    'remove with `git rm`'
# audit.md's read-only posture must survive the addition, not be quietly voided.
assert_contains "audit's read-only posture is explicitly preserved" "$ALL_FLAT" \
    "does not loosen [[audit]]'s read-only posture"
assert_contains "the acting party is /repo:all's stage, after a yes" "$ALL_FLAT" \
    "only after the user says yes to that specific file"

# ---------------------------------------------------------------------------
echo ""
echo "5. Anything not removed is deferred into the summary, named individually"
# ---------------------------------------------------------------------------

assert_contains "not-removed orphans are deferred, not dropped" "$ALL_FLAT" \
    "**Anything not removed is deferred, not dropped.**"
assert_contains "declined orphans are carried into the final summary" "$ALL_FLAT" \
    "into the final summary as a deferred item"
assert_contains "deferral matches how scrub findings are already carried" "$ALL_FLAT" \
    "same way stage 3's scrub findings are"
assert_contains "never-offered orphans (skipped stage, scoped run) defer too" "$ALL_FLAT" \
    "never offered"

# The Final Summary template is the artifact the user actually reads.
SUMMARY_LN="$(grep -nE '^## Final Summary' "$ALL_MD" | head -1 | cut -d: -f1)"
if [[ -n "$SUMMARY_LN" ]]; then
    SUMMARY_BLOCK="$(tail -n +"$SUMMARY_LN" "$ALL_MD")"
    assert_matches "the summary's Audit line carries deferred tracked orphans" \
        "$SUMMARY_BLOCK" '^Audit: .*tracked orphans deferred'
    assert_matches "the deferred orphans are named, not just counted" \
        "$SUMMARY_BLOCK" 'tracked orphans deferred: .*\.ts'
    assert_contains "the left-behind list includes tracked orphans" \
        "$(printf '%s' "$SUMMARY_BLOCK" | tr '\n' ' ' | tr -s ' ')" \
        "tracked orphans left in place"
    assert_contains "naming beats counting, and the reason is stated" \
        "$(printf '%s' "$SUMMARY_BLOCK" | tr '\n' ' ' | tr -s ' ')" \
        "re-run the audit to find out which"
else
    no "the Final Summary section is checkable" "no '## Final Summary' heading in all.md"
fi

# ---------------------------------------------------------------------------
echo ""
echo "6. Tidy's stage does not acquire tracked-file removal"
# ---------------------------------------------------------------------------

if [[ -n "$STAGE5_LN" && -n "$STAGE6_LN" && "$STAGE5_LN" -lt "$STAGE6_LN" ]]; then
    STAGE5_BLOCK="$(sed -n "${STAGE5_LN},$((STAGE6_LN - 1))p" "$ALL_MD")"
    # If a later edit "simplifies" this by moving tracked orphans into Tidy, the
    # gate distinction the issue turns on is gone — catch that here.
    assert_not_contains "stage 5 does not claim tracked files" "$STAGE5_BLOCK" "tracked"
    assert_not_contains "stage 5 does not remove files with git rm" "$STAGE5_BLOCK" "git rm"
    assert_not_contains "stage 5 does not claim orphans" "$STAGE5_BLOCK" "orphan"
else
    no "stage 5's block is checkable" "5=$STAGE5_LN 6=$STAGE6_LN"
fi

# ---------------------------------------------------------------------------
echo ""
echo "7. The anchors all.md leans on still exist in the referenced commands"
# ---------------------------------------------------------------------------

# all.md delegates rather than restates, so its correctness depends on these
# continuing to hold. If one is reworded there, this names the dependent file.
assert_contains "audit.md still checks orphaned files" "$AUDIT" "### 2. Orphaned Files"
assert_contains "audit.md still declares itself read-only" "$AUDIT_FLAT" \
    "Does not make changes — presents findings for discussion"
assert_contains "orphans.md still never auto-acts" "$ORPHANS" "never auto-acts"
assert_contains "orphans.md is still report-and-wait" "$ORPHANS" "report-and-wait"
# The two tidy.md invariants that make "Tidy cannot own this" true rather than
# merely asserted.
assert_contains "tidy.md's SAFE tier still excludes tracked files" "$TIDY" \
    "Nothing in this category may be tracked by git"
assert_contains "tidy.md still reserves KEEP for tracked files" "$TIDY" \
    "not KEEP, which is"

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

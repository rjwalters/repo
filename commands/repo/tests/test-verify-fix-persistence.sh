#!/usr/bin/env bash
# Test suite for the verify-after-write contract documented in the /repo:*
# commands that edit tracked files — the check that stands between "the Edit
# call returned success" and "the fix is actually on disk when we report it".
#
# Usage: ./commands/repo/tests/test-verify-fix-persistence.sh
# Exit code 0 = all tests pass, 1 = failures detected.
#
# Structured like commands/repo/tests/test-branches-loss-check.sh: pure bash, no
# test framework, PASS/FAIL/TOTAL counters and a summary block. `pnpm test`
# delegates to this file via hooks/repo/tests/run.sh.
#
# WHY THIS FILE EXISTS (repo#89): a /repo:all run in a Loom-managed consumer repo
# applied three doc fixes, reported them as applied, and lost all three moments
# later — a concurrent sweep ran `check-main-clean.sh --quarantine`, which
# stashes the primary clone's working tree to get a clean checkout for its own
# worktrees. Nothing was destroyed (the stash is labelled), but the pass reported
# three fixes that were no longer on disk. The durable fix is verify-after-write,
# not daemon detection: detection is inherently racy, since a daemon can start
# right after the check.
#
# The contract under test:
#   1  after applying a fix, re-read it BEFORE counting it as applied
#   2  a fix found gone reports as "reverted after apply — needs re-run",
#      distinct from the applied count — never silently re-applied or re-counted
#   3  the check is UNCONDITIONAL — with no concurrent writer it always finds
#      the edit applied, so nothing user-visible changes
#   4  /repo:all re-verifies immediately before the consolidated summary prints,
#      and only the affected stage's line reflects a reversion
#
# Two sections: a fixture section that exercises verify_applied() (a faithful
# transcription of the documented check) against the real revert mechanisms —
# `git checkout --`, `git stash`, `git stash -u` — and a doc-drift section
# asserting the command files still say what this suite implements.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CMD_DIR="$REPO_ROOT/commands/repo"

# The four commands that edit tracked files by default and report a per-fix
# "applied" status. tidy.md and audit.md are deliberately NOT here — see the
# scope guard at the end of the doc-drift section.
APPLYING_COMMANDS=(docs readme gitignore links)
ALL_MD="$CMD_DIR/all.md"

PASS=0
FAIL=0
SKIP=0
TOTAL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

for c in "${APPLYING_COMMANDS[@]}"; do
    if [[ ! -f "$CMD_DIR/$c.md" ]]; then
        echo "FATAL: $c.md not found at $CMD_DIR/$c.md" >&2
        exit 1
    fi
done
if [[ ! -f "$ALL_MD" ]]; then
    echo "FATAL: all.md not found at $ALL_MD" >&2
    exit 1
fi

SCRATCH="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$SCRATCH"' EXIT

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
# A skipped assertion is neither pass nor fail: the environment cannot exercise
# it. Counted separately and surfaced in the summary so a silently-skipped suite
# is never mistaken for a full pass (repo#46).
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

# ---------------------------------------------------------------------------
# The check under test — a direct transcription of the documented step.
# ---------------------------------------------------------------------------

REPO=""

# verify_applied <path> <expected-substring> -> APPLIED | REVERTED
#   The primary, authoritative form: re-read the changed file and confirm the
#   edit's content is still there. Works for tracked edits, new files, and the
#   `git stash -u` case alike, because it asks about content on disk rather than
#   about git's opinion of the index.
verify_applied() {
    local path="$1" needle="$2"
    if [[ ! -f "$REPO/$path" ]]; then
        echo REVERTED; return       # a fix that created the file, stashed away
    fi
    if grep -qF -- "$needle" "$REPO/$path"; then
        echo APPLIED
    else
        echo REVERTED
    fi
}

# verify_dirty <path> -> DIRTY | CLEAN
#   The documented cheap pre-filter (`git status --porcelain -- <path>`).
#   Cheaper, but weaker: it only proves the path differs from HEAD, not that it
#   differs in the way this command intended. Pinned here so the docs' pre-filter
#   arm is covered, so the tracked-edit case can be shown to agree with the
#   content check, and so the partial-revert case below can show where it does
#   NOT agree (repo#95).
verify_dirty() {
    local path="$1" out
    out="$(git -C "$REPO" status --porcelain -- "$path" 2>/dev/null)"
    if [[ -n "$out" ]]; then echo DIRTY; else echo CLEAN; fi
}

# apply_fix <path> <line>  — stands in for an Edit call from a /repo:* command.
apply_fix() {
    printf '%s\n' "$2" >> "$REPO/$1"
}

# stage_report <fixed-count> <reverted-desc>
#   The reporting contract: a reverted edit must NOT feed the fixed count, and
#   must surface on its own line. Renders the line /repo:all's Final Summary
#   documents.
stage_report() {  # <stage> <applied-list> <reverted-list>
    local stage="$1" applied="$2" reverted="$3" n=0 line
    [[ -n "$applied" ]] && n=$(printf '%s\n' "$applied" | grep -c .)
    line="$stage: $n fixed"
    if [[ -n "$reverted" ]]; then
        line+=", $(printf '%s\n' "$reverted" | grep -c .) reverted after apply — needs re-run: $(printf '%s' "$reverted" | tr '\n' ',')"
    fi
    printf '%s\n' "$line"
}

# ---------------------------------------------------------------------------
# Fixture
# ---------------------------------------------------------------------------

build_fixture() {
    local root="$SCRATCH/fixture"
    mkdir -p "$root"
    git init -q -b main "$root/repo"
    REPO="$root/repo"
    git -C "$REPO" config user.email "test@example.invalid"
    git -C "$REPO" config user.name "Verify Persistence Test"

    printf '# Project\n\nA stale sentence.\n' > "$REPO/README.md"
    printf '# Changelog\n\n## 0.1.0\n' > "$REPO/CHANGELOG.md"
    printf 'node_modules/\n' > "$REPO/.gitignore"
    git -C "$REPO" add -A
    git -C "$REPO" commit -qm "M0: base docs"
}

echo "verify-after-write persistence test suite"
echo "========================================="
echo ""

build_fixture

# ---------------------------------------------------------------------------
echo "-- baseline: an untouched fix verifies as APPLIED --"
# ---------------------------------------------------------------------------
apply_fix README.md "Pulse adapters: alpha, beta, gamma."
assert_eq "fresh edit -> APPLIED" "APPLIED" "$(verify_applied README.md "Pulse adapters")"
assert_eq "fresh edit is dirty vs HEAD" "DIRTY" "$(verify_dirty README.md)"

# The check must be idempotent and side-effect free: running it does not alter
# the file, so an unconditional check costs a normal run nothing (criterion:
# behaviour unchanged with no concurrent writer).
BEFORE_HASH="$(git -C "$REPO" hash-object "$REPO/README.md")"
verify_applied README.md "Pulse adapters" >/dev/null
verify_dirty README.md >/dev/null
AFTER_HASH="$(git -C "$REPO" hash-object "$REPO/README.md")"
assert_eq "verifying does not modify the file" "$BEFORE_HASH" "$AFTER_HASH"
assert_eq "verifying twice is stable" "APPLIED" "$(verify_applied README.md "Pulse adapters")"

# ---------------------------------------------------------------------------
echo ""
echo "-- concurrent \`git checkout --\`: the fix is gone, and is detected --"
# ---------------------------------------------------------------------------
git -C "$REPO" checkout -q -- README.md   # the concurrent writer
assert_eq "reverted edit -> REVERTED" "REVERTED" "$(verify_applied README.md "Pulse adapters")"
assert_eq "reverted edit is clean vs HEAD" "CLEAN" "$(verify_dirty README.md)"
# The failure this suite exists to prevent: reporting it as applied anyway.
REPORT="$(stage_report Docs "" "README.md pulse adapters")"
assert_contains "reverted fix reports on its own line" "$REPORT" "reverted after apply — needs re-run"
assert_contains "reverted fix is not counted as fixed" "$REPORT" "0 fixed"

# ---------------------------------------------------------------------------
echo ""
echo "-- concurrent \`git stash\` (the loom-quarantine mechanism, repo#89) --"
# ---------------------------------------------------------------------------
apply_fix README.md "Pulse adapters: alpha, beta, gamma."
assert_eq "re-applied edit -> APPLIED" "APPLIED" "$(verify_applied README.md "Pulse adapters")"
git -C "$REPO" stash push -q -m "loom-quarantine: run=sweep-test issue=89" >/dev/null 2>&1
assert_eq "stashed edit -> REVERTED" "REVERTED" "$(verify_applied README.md "Pulse adapters")"
# Nothing was destroyed — which is exactly why the right report is "needs
# re-run" rather than "lost". Pin that the content is still recoverable.
STASH_LIST="$(git -C "$REPO" stash list)"
assert_contains "the quarantine stash is labelled, not silent" "$STASH_LIST" "loom-quarantine"
STASH_DIFF="$(git -C "$REPO" stash show -p 'stash@{0}' 2>/dev/null)"
assert_contains "stashed content is recoverable" "$STASH_DIFF" "Pulse adapters"

# ---------------------------------------------------------------------------
echo ""
echo "-- a fix that creates a new file: \`git stash -u\` also takes it --"
# ---------------------------------------------------------------------------
# /repo:readme can be asked to write a missing README; that file is untracked
# until committed, so only `git stash -u` (or a plain rm) can take it away. The
# content re-read catches it either way; `git status --porcelain` alone would
# report the *absence* as clean-and-tracked-nothing, so the content form is the
# one the docs make primary.
mkdir -p "$REPO/docs"
printf '# docs\n\nAdded by the readme stage.\n' > "$REPO/docs/README.md"
assert_eq "new-file fix -> APPLIED" "APPLIED" "$(verify_applied docs/README.md "Added by the readme stage")"
git -C "$REPO" stash push -q -u -m "loom-quarantine: run=sweep-test-2 issue=89" >/dev/null 2>&1
assert_eq "stashed new file -> REVERTED" "REVERTED" "$(verify_applied docs/README.md "Added by the readme stage")"

# ---------------------------------------------------------------------------
echo ""
echo "-- mixed stages: only the affected stage's line changes --"
# ---------------------------------------------------------------------------
# /repo:all edge case from the test plan: Docs loses an edit, Readme does not.
git -C "$REPO" stash clear
apply_fix README.md "Pulse adapters: alpha, beta, gamma."   # Docs stage fix
apply_fix CHANGELOG.md "## 0.2.0"                            # Readme stage fix
git -C "$REPO" checkout -q -- README.md                      # concurrent writer hits ONE file

DOCS_STATE="$(verify_applied README.md "Pulse adapters")"
README_STATE="$(verify_applied CHANGELOG.md "## 0.2.0")"
assert_eq "docs-stage edit detected reverted" "REVERTED" "$DOCS_STATE"
assert_eq "readme-stage edit still applied" "APPLIED" "$README_STATE"

DOCS_LINE="$(stage_report Docs "" "README.md pulse adapters")"
README_LINE="$(stage_report Readme "CHANGELOG.md 0.2.0 entry" "")"
assert_contains "affected stage reports the reversion" "$DOCS_LINE" "reverted after apply"
assert_not_contains "unaffected stage line is untouched" "$README_LINE" "reverted after apply"
assert_contains "unaffected stage still counts its fix" "$README_LINE" "1 fixed"

# ---------------------------------------------------------------------------
echo ""
echo "-- two edits, one file, partial revert: why \`git status\` alone lies --"
# ---------------------------------------------------------------------------
# repo#95: `git status --porcelain -- <path>` answers "does this path differ from
# HEAD?", not "is MY edit still there". When one command applies two fixes to the
# same file and a concurrent writer reverts only one region, the path is STILL
# dirty — so a git-status-only check would report both fixes as applied while one
# is gone on disk. Only the content re-read separates them. This is the scenario
# the caveat in each command file's "Verify after write" block warns about.
git -C "$REPO" checkout -q -- .
git -C "$REPO" clean -qfd
apply_fix README.md "Fix A: adapters are alpha, beta, gamma."
apply_fix README.md "Fix B: the daemon is started with loom start."
assert_eq "both edits verify APPLIED before the revert" "APPLIED/APPLIED" \
    "$(verify_applied README.md "Fix A:")/$(verify_applied README.md "Fix B:")"

# The concurrent writer reverts ONE region and leaves the other in place.
grep -vF -- "Fix A:" "$REPO/README.md" > "$SCRATCH/README.partial"
mv "$SCRATCH/README.partial" "$REPO/README.md"

# The weak form cannot tell the difference: the path is still dirty, so a
# git-status-only check concludes "still applied" for BOTH fixes.
assert_eq "partially-reverted path is still DIRTY vs HEAD" "DIRTY" \
    "$(verify_dirty README.md)"
# The primary form does tell the difference, per edit.
assert_eq "the reverted edit is caught by the content re-read" "REVERTED" \
    "$(verify_applied README.md "Fix A:")"
assert_eq "the surviving edit still verifies APPLIED" "APPLIED" \
    "$(verify_applied README.md "Fix B:")"

# The consequence: a git-status-only check would have counted 2 fixed.
PARTIAL_LINE="$(stage_report Docs "README.md fix B" "README.md fix A")"
assert_contains "only the surviving edit counts as fixed" \
    "$PARTIAL_LINE" "1 fixed"
assert_contains "the reverted edit reports needs-re-run" \
    "$PARTIAL_LINE" "reverted after apply — needs re-run"

# ---------------------------------------------------------------------------
echo ""
echo "-- no concurrent writer: the check is invisible --"
# ---------------------------------------------------------------------------
# Criterion: in a repo with nothing else writing, verify-after-write always
# finds "still applied" and the report is identical to the pre-fix behaviour.
git -C "$REPO" checkout -q -- .
git -C "$REPO" clean -qfd
apply_fix README.md "Quiet-repo fix."
apply_fix CHANGELOG.md "## 0.3.0"
QUIET_STATES="$(verify_applied README.md "Quiet-repo fix.")/$(verify_applied CHANGELOG.md "## 0.3.0")"
assert_eq "every edit verifies APPLIED with no concurrent writer" "APPLIED/APPLIED" "$QUIET_STATES"
QUIET_LINE="$(stage_report Docs "$(printf 'README.md\nCHANGELOG.md')" "")"
assert_eq "quiet-repo report is the plain fixed count" "Docs: 2 fixed" "$QUIET_LINE"

# ---------------------------------------------------------------------------
echo ""
echo "-- doc drift: the command files still specify what this suite implements --"
# ---------------------------------------------------------------------------
# Phrases are asserted against a whitespace-flattened copy of each file, since
# the requirement is prose that wraps across lines.
flatten() { tr '\n' ' ' < "$1" | tr -s ' '; }

for c in "${APPLYING_COMMANDS[@]}"; do
    MD="$(flatten "$CMD_DIR/$c.md")"
    assert_contains "$c.md has a verify-after-write step" \
        "$MD" '### Verify after write'
    assert_contains "$c.md verifies BEFORE counting a fix as applied" \
        "$MD" 'before counting it as applied'
    assert_contains "$c.md names a concrete re-check" \
        "$MD" 'git status --porcelain -- <path>'
    # repo#95: the content re-read is the authoritative form, and the git arms
    # are a pre-filter with a stated caveat — not an equivalent alternative.
    assert_contains "$c.md makes the content re-read the primary check" \
        "$MD" 're-read the changed region of the file and confirm your specific edit is present'
    assert_contains "$c.md caveats the git arm as HEAD-comparison only" \
        "$MD" 'only proves the path differs from HEAD'
    assert_contains "$c.md forbids the git arm as the sole check" \
        "$MD" 'must not be the sole check when the file may carry other uncommitted changes'
    assert_contains "$c.md makes the check unconditional (detection is racy)" \
        "$MD" 'This check is **unconditional**'
    assert_contains "$c.md explains why detect-then-skip is not the fix" \
        "$MD" 'racy'
    assert_contains "$c.md reports a lost fix as reverted, distinctly" \
        "$MD" 'reverted after apply — needs re-run'
    assert_contains "$c.md forbids silently re-applying / re-counting" \
        "$MD" 'Do not silently re-apply it, and do not count it in the fixed total'
    assert_contains "$c.md states the no-concurrent-writer case is unchanged" \
        "$MD" 'in a repo with no concurrent writer the check always finds the edit still applied'
done

ALL="$(flatten "$ALL_MD")"
assert_contains "all.md documents re-verify-before-print" \
    "$ALL" '### Re-verify before printing'
assert_contains "all.md ties re-verification to the summary print" \
    "$ALL" 'immediately before printing the consolidated summary, each stage re-verifies that the edits it applied are still present on disk'
assert_contains "all.md keeps reverted edits out of the fixed count" \
    "$ALL" "never folded into that stage's fixed count"
assert_contains "all.md shows the distinct reverted line" \
    "$ALL" 'reverted after apply — needs re-run'
assert_contains "all.md scopes the change to the affected stage" \
    "$ALL" "Only the affected stage's line changes"
assert_contains "all.md states the quiet-repo summary is unchanged" \
    "$ALL" 'In a repo with no concurrent writer the re-verification always finds every edit still applied'

# Scope guard (repo#89): tidy and audit are deliberately OUT of scope. tidy's
# SAFE tier deletes untracked/gitignored artifacts, which a stash-based
# quarantine cannot resurrect and therefore cannot silently revert; audit.md is
# read-only, and the gitignore fixes /repo:all's Audit stage offers are the same
# code path gitignore.md already covers. If either ever grows tracked-file edits,
# extend this suite rather than deleting these two assertions.
for c in tidy audit; do
    if [[ -f "$CMD_DIR/$c.md" ]]; then
        OUT_OF_SCOPE="$(flatten "$CMD_DIR/$c.md")"
        assert_not_contains "$c.md stays out of scope (no verify-after-write step)" \
            "$OUT_OF_SCOPE" '### Verify after write'
    else
        skip "$c.md stays out of scope (no verify-after-write step)" "$c.md not found"
    fi
done

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

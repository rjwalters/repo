#!/usr/bin/env bash
# Test suite for the Loom-managed-repo destination contract documented in the
# /repo:* commands that edit tracked files — the step that decides WHERE a fix
# lands before it is applied, so a sweep cannot take it away after the run.
#
# Usage: ./commands/repo/tests/test-loom-quarantine-destination.sh
# Exit code 0 = all tests pass, 1 = failures detected.
#
# Structured like commands/repo/tests/test-verify-fix-persistence.sh: pure bash,
# no test framework, PASS/FAIL/TOTAL counters and a summary block. `pnpm test`
# delegates to this file via hooks/repo/tests/run.sh.
#
# WHY THIS FILE EXISTS (repo#448): the verify-after-write contract that
# test-verify-fix-persistence.sh pins catches an edit reverted *during* a run.
# It structurally cannot catch the more likely failure in a Loom-managed repo,
# which happens *after* it: a /repo:all pass applied and re-verified 14 doc
# fixes in the primary checkout, printed its summary, and minutes later a sweep's
# `check-main-clean.sh --quarantine` stashed all 11 touched files away. The
# summary was true when it printed and false when the operator acted on it.
# The fix is a destination decision made BEFORE the first edit, plus a summary
# that names the destination rather than only a count.
#
# The contract under test:
#   1  detection is (.loom/ root AND (worktrees/ OR a running loom-daemon)),
#      and is OFF inside a managed worktree — that is not the policed clone
#   2  a repo with no .loom/ root is completely unaffected: no detection fires,
#      no new text appears
#   3  the destination ladder is worktree-commit -> clean-branch-commit ->
#      uncommitted-plus-warning, and the worktree arm uses
#      ./.loom/scripts/worktree.sh, never a bare `git worktree add`
#   4  the reported line names the destination, not just "N fixed"
#   5  quarantined fixes are recoverable from the labelled stash, not lost
#
# Two sections: a fixture section exercising a faithful transcription of the
# documented detection + report rendering (including a real `git stash push`
# quarantine against a real repo), and a doc-drift section asserting the command
# files still say what this suite implements.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CMD_DIR="$REPO_ROOT/commands/repo"

# The three commands repo#448 scopes: each applies fixes to the primary checkout
# by default and now has to decide where those fixes live first. readme.md is
# deliberately NOT here — see the scope note at the end of the doc-drift section.
DESTINATION_COMMANDS=(docs gitignore links)
ALL_MD="$CMD_DIR/all.md"

# Per-command noun in the one-line warning ("uncommitted <noun> fixes ...").
warning_noun() {
    case "$1" in
        docs)      echo "doc" ;;
        gitignore) echo "gitignore" ;;
        links)     echo "link" ;;
        *)         echo "" ;;
    esac
}

source "$(dirname "${BASH_SOURCE[0]}")/lib/assert.sh"

for c in "${DESTINATION_COMMANDS[@]}"; do
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
# The detection under test — a direct transcription of the documented snippet,
# with the `pgrep -f loom-daemon` arm passed in so the daemon case is testable
# without one running (and so a real daemon on the host cannot flip a result).
# ---------------------------------------------------------------------------

# detect_loom_managed <repo-root> <daemon-running: yes|no> -> yes | no
detect_loom_managed() {
    local root="$1" daemon="$2" loom_managed=no
    if [ -d "$root/.loom" ] && { [ -d "$root/.loom/worktrees" ] || [ "$daemon" = "yes" ]; }; then
        loom_managed=yes
    fi
    # Already inside a managed worktree? Not the primary checkout.
    [ -f "$root/.loom-managed" ] && loom_managed=no
    echo "$loom_managed"
}

# choose_destination <loom_managed> <issue-number|""> <tree-clean-at-start: yes|no>
#   -> worktree | branch-commit | uncommitted-warn | in-place
# The documented ladder, in order.
choose_destination() {
    local managed="$1" issue="$2" clean="$3"
    if [ "$managed" != "yes" ]; then echo "in-place"; return; fi
    if [ -n "$issue" ]; then echo "worktree"; return; fi
    if [ "$clean" = "yes" ]; then echo "branch-commit"; return; fi
    echo "uncommitted-warn"
}

# stage_line <stage> <count> <destination> <detail>
#   Renders the summary line shape each command file documents.
stage_line() {
    local stage="$1" n="$2" dest="$3" detail="$4"
    case "$dest" in
        worktree)         echo "$stage: $n fixed on feature/issue-$detail (worktree .loom/worktrees/issue-$detail, a1b2c3d)" ;;
        branch-commit)    echo "$stage: $n fixed, committed on $detail (a1b2c3d)" ;;
        uncommitted-warn) echo "$stage: $n fixed — uncommitted, at risk" ;;
        in-place)         echo "$stage: $n fixed ($detail)" ;;
    esac
}

WARNING_TAIL="in the primary checkout can be quarantined by a sweep — commit or stash them now."

echo "Loom-managed destination contract test suite"
echo "==========================================="
echo ""

# ---------------------------------------------------------------------------
echo "-- detection: which trees are the policed primary checkout --"
# ---------------------------------------------------------------------------
PLAIN="$SCRATCH/plain"; mkdir -p "$PLAIN"
assert_eq "no .loom/ root -> not Loom-managed" "no" "$(detect_loom_managed "$PLAIN" no)"
assert_eq "no .loom/ root, daemon running -> still not Loom-managed" \
    "no" "$(detect_loom_managed "$PLAIN" yes)"

LOOM_NO_WT="$SCRATCH/loom-no-worktrees"; mkdir -p "$LOOM_NO_WT/.loom"
assert_eq ".loom/ but no worktrees/ and no daemon -> not managed" \
    "no" "$(detect_loom_managed "$LOOM_NO_WT" no)"
assert_eq ".loom/ plus a running loom-daemon -> managed" \
    "yes" "$(detect_loom_managed "$LOOM_NO_WT" yes)"

LOOM_WT="$SCRATCH/loom-worktrees"; mkdir -p "$LOOM_WT/.loom/worktrees"
assert_eq ".loom/worktrees/ present, no daemon -> managed" \
    "yes" "$(detect_loom_managed "$LOOM_WT" no)"

# The carve-out: inside a managed worktree, quarantine polices somewhere else.
INSIDE_WT="$SCRATCH/inside-worktree"; mkdir -p "$INSIDE_WT/.loom/worktrees"
: > "$INSIDE_WT/.loom-managed"
assert_eq "inside a .loom-managed worktree -> detection off" \
    "no" "$(detect_loom_managed "$INSIDE_WT" yes)"

# ---------------------------------------------------------------------------
echo ""
echo "-- the destination ladder --"
# ---------------------------------------------------------------------------
assert_eq "managed + issue number -> dedicated worktree" \
    "worktree" "$(choose_destination yes 448 no)"
assert_eq "managed, no issue, clean tree -> commit on current branch" \
    "branch-commit" "$(choose_destination yes "" yes)"
assert_eq "managed, no issue, dirty tree -> uncommitted + warning" \
    "uncommitted-warn" "$(choose_destination yes "" no)"
assert_eq "not managed -> apply in place, unchanged" \
    "in-place" "$(choose_destination no "" no)"
assert_eq "not managed with an issue number -> still in place" \
    "in-place" "$(choose_destination no 448 yes)"

# ---------------------------------------------------------------------------
echo ""
echo "-- the report names the destination, not just the count --"
# ---------------------------------------------------------------------------
WT_LINE="$(stage_line Docs 2 worktree 448)"
assert_contains "worktree arm names the branch" "$WT_LINE" "feature/issue-448"
assert_contains "worktree arm names the worktree path" "$WT_LINE" ".loom/worktrees/issue-448"
BR_LINE="$(stage_line Docs 2 branch-commit main)"
assert_contains "branch arm names the branch it committed on" "$BR_LINE" "committed on main"
RISK_LINE="$(stage_line Docs 2 uncommitted-warn "")"
assert_contains "uncommitted arm says so explicitly" "$RISK_LINE" "uncommitted, at risk"
PLAIN_LINE="$(stage_line Docs 2 in-place "README table, CHANGELOG entry")"
assert_eq "non-Loom line is the plain fixed count" \
    "Docs: 2 fixed (README table, CHANGELOG entry)" "$PLAIN_LINE"
assert_not_contains "non-Loom line names no destination" "$PLAIN_LINE" "at risk"

# ---------------------------------------------------------------------------
echo ""
echo "-- a committed fix survives the quarantine that takes an uncommitted one --"
# ---------------------------------------------------------------------------
# The whole point of the ladder, against the real mechanism: the same
# `git stash push` a sweep's check-main-clean.sh --quarantine runs.
REPO="$SCRATCH/primary"
git init -q -b main "$REPO"
git -C "$REPO" config user.email "test@example.invalid"
git -C "$REPO" config user.name "Quarantine Destination Test"
printf '# Project\n\nA stale sentence.\n' > "$REPO/README.md"
printf '# Changelog\n\n## 0.1.0\n' > "$REPO/CHANGELOG.md"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "M0: base docs"

# Arm 2 of the ladder: tree was clean, so the fix is committed on the branch.
printf 'Committed fix: adapters are alpha, beta, gamma.\n' >> "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -qm "docs: fix adapter list"
# Arm 3: a fix left uncommitted, the shape this issue exists to stop.
printf 'Uncommitted fix: the daemon is started with loom start.\n' >> "$REPO/CHANGELOG.md"

git -C "$REPO" stash push -q -u -m "loom-quarantine: run=sweep-issue-448 issue=448" >/dev/null 2>&1

if grep -qF "Committed fix:" "$REPO/README.md"; then
    ok "committed fix survives the quarantine"
else
    no "committed fix survives the quarantine" "README.md lost its committed edit"
fi
if grep -qF "Uncommitted fix:" "$REPO/CHANGELOG.md"; then
    no "uncommitted fix is taken by the quarantine" "CHANGELOG.md still carries it"
else
    ok "uncommitted fix is taken by the quarantine"
fi

# ...and taken is not lost: the labelled stash is the recovery path the command
# files point the operator at.
STASH_LIST="$(git -C "$REPO" stash list)"
assert_contains "the quarantine stash is labelled" "$STASH_LIST" "loom-quarantine"
STASH_DIFF="$(git -C "$REPO" stash show -p 'stash@{0}' 2>/dev/null)"
assert_contains "the quarantined fix is recoverable from the stash" \
    "$STASH_DIFF" "Uncommitted fix:"

# ---------------------------------------------------------------------------
echo ""
echo "-- doc drift: the command files still specify what this suite implements --"
# ---------------------------------------------------------------------------
for c in "${DESTINATION_COMMANDS[@]}"; do
    MD="$(flatten "$CMD_DIR/$c.md")"
    assert_contains "$c.md has a Loom-managed destination step" \
        "$MD" '### Loom-managed repo: land fixes where a sweep cannot take them'
    assert_contains "$c.md names the quarantine mechanism" \
        "$MD" 'check-main-clean.sh --quarantine'
    assert_contains "$c.md names the stash label so the symptom is recognizable" \
        "$MD" 'loom-quarantine: run=<sweep-id> issue=<N>'
    assert_contains "$c.md quotes the guard message for the related symptom" \
        "$MD" 'resolves to the main repository checkout'
    assert_contains "$c.md says the quarantine is branch-blind" \
        "$MD" 'the quarantine is branch-blind'
    assert_contains "$c.md decides the destination before the first edit" \
        "$MD" 'Decide the destination before applying the first fix'
    assert_contains "$c.md ships the detection snippet" \
        "$MD" 'pgrep -f loom-daemon'
    assert_contains "$c.md exempts a managed worktree from the detection" \
        "$MD" '.loom-managed'
    assert_contains "$c.md leaves non-Loom repos unchanged" \
        "$MD" 'is the unchanged path: apply fixes in place, report them exactly as before'
    assert_contains "$c.md prefers a dedicated worktree first" \
        "$MD" './.loom/scripts/worktree.sh <issue-number>'
    assert_contains "$c.md forbids a bare git worktree add" \
        "$MD" 'never a bare `git worktree add`'
    assert_contains "$c.md offers the clean-tree commit as the second arm" \
        "$MD" 'the working tree was otherwise clean at the start of the run'
    assert_contains "$c.md forbids stashing the operator's unrelated edits" \
        "$MD" "Do not stash the operator's unrelated edits"
    assert_contains "$c.md prints the one-line quarantine warning" \
        "$MD" "uncommitted $(warning_noun "$c") fixes $WARNING_TAIL"
    assert_contains "$c.md names the destination in the report" \
        "$MD" 'Name the destination in the report, not just the count'
    assert_contains "$c.md has an at-risk report shape" \
        "$MD" 'uncommitted, at risk'
    assert_contains "$c.md points at the stash for recovery" \
        "$MD" 'git stash list | grep loom-quarantine'
done

ALL="$(flatten "$ALL_MD")"
assert_contains "all.md's summary names where the fixes live" \
    "$ALL" '### Where the fixes live (Loom-managed repos)'
assert_contains "all.md shows the committed-in-a-worktree line" \
    "$ALL" 'Docs: 2 fixed on feature/issue-448 (worktree .loom/worktrees/issue-448, a1b2c3d)'
assert_contains "all.md shows the committed-on-current-branch line" \
    "$ALL" 'Docs: 2 fixed, committed on main (a1b2c3d)'
assert_contains "all.md shows the at-risk line" \
    "$ALL" 'Docs: 2 fixed — uncommitted, at risk'
assert_contains "all.md keeps the non-Loom summary unchanged" \
    "$ALL" 'Not a Loom-managed repo'
assert_contains "all.md carries the one-line warning under the at-risk arm" \
    "$ALL" "uncommitted doc fixes $WARNING_TAIL"
assert_contains "all.md's Docs stage reports where the fixes landed" \
    "$ALL" 'Report where those fixes landed, not only that they were applied'
assert_contains "all.md extends the destination to stage 1's gitignore fixes" \
    "$ALL" 'when stage 1 applied gitignore rule fixes'
assert_contains "all.md stage 2 says a dirty Loom tree is actively rewritten" \
    "$ALL" 'it is a tree other processes actively rewrite'
assert_contains "all.md stage 2 keeps the exception narrow" \
    "$ALL" 'One narrow exception to "say nothing": a dirty tree in a Loom-managed repo'
assert_contains "all.md stage 2 does not change eligibility" \
    "$ALL" 'it changes nothing about eligibility'

# Scope note (repo#448): readme.md is deliberately out of scope here. It shares
# the verify-after-write contract (test-verify-fix-persistence.sh covers all
# four commands) but repo#448 scoped the destination decision to the three
# commands that apply fixes on their own account; /repo:readme runs under
# /repo:docs, which makes the decision for the whole Docs stage. If /repo:readme
# ever grows a standalone destination step, add it to DESTINATION_COMMANDS above
# rather than deleting this note.
README_MD="$CMD_DIR/readme.md"
if [[ -f "$README_MD" ]]; then
    README_FLAT="$(flatten "$README_MD")"
    assert_not_contains "readme.md stays out of scope (no destination step)" \
        "$README_FLAT" '### Loom-managed repo: land fixes where a sweep cannot take them'
else
    skip "readme.md stays out of scope (no destination step)" "readme.md not found"
fi

# ---------------------------------------------------------------------------
echo ""
echo "==========================================="
echo "  Total:  $TOTAL"
printf "  ${GREEN}Passed${NC}: %s\n" "$PASS"
printf "  ${RED}Failed${NC}: %s\n" "$FAIL"
printf "  ${YELLOW}Skipped${NC}: %s\n" "$SKIP"
echo "==========================================="

if [[ $FAIL -gt 0 ]]; then
    printf "\n${RED}TESTS FAILED${NC}\n"
    exit 1
fi
printf "\n${GREEN}ALL TESTS PASSED${NC}\n"
exit 0

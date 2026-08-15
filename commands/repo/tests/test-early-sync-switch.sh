#!/usr/bin/env bash
# Test suite for /repo:all's conditional early sync-and-switch — the check that
# stands between "the working branch is where the doc stages should be looking"
# and "the working branch is a stale checkout that will fight every edit".
#
# Usage: ./commands/repo/tests/test-early-sync-switch.sh
# Exit code 0 = all tests pass, 1 = failures detected.
#
# Structured like commands/repo/tests/test-verify-fix-persistence.sh: pure bash,
# no test framework, PASS/FAIL/SKIP/TOTAL counters and a summary block.
# `pnpm test` delegates to this file via hooks/repo/tests/run.sh.
#
# WHY THIS FILE EXISTS (repo#82): a /repo:all run in a consumer repo started on a
# PR branch that was fully pushed and 6 commits behind the default branch. With
# Reset ordered last, the Docs stage compared prose against that stale checkout:
# the real content drift lived in the default branch's newer copy of README.md,
# and editing the branch's copy would both pollute the open PR's diff and block
# the branch switch Reset performs at the end. Every content fix had to be
# deferred and re-done after Reset ran. The fix is to run only the *reversible*
# half of /repo:reset (fetch, checkout default, ff-only pull) early — before
# Docs — and only when the branch state proves nothing is lost by doing so.
#
# The contract under test:
#   1  eligibility is the conjunction of five conditions: on a non-default
#      branch, origin/HEAD resolves, clean working tree, HAS an upstream and is
#      0 commits ahead of it, and behind origin/<default> by >= 1
#   2  "never pushed" (no upstream) is NOT "fully pushed" — it is ineligible,
#      exactly like unpushed commits
#   3  being ahead of the DEFAULT branch is not disqualifying (a pushed PR
#      branch normally is); the unpushed test is against the branch's own
#      upstream, a different axis
#   4  when eligible, the sync-and-switch loses nothing: the branch ref and its
#      commits survive untouched
#   5  the pruning half (stash/branch/worktree review) still runs last
#   6  the two ways the switch can fail are NOT the same outcome: a refused
#      checkout (typically the default branch held by another worktree) leaves
#      HEAD where it was, while a failed `--ff-only` pull happens after the
#      checkout already landed and strands the run on a diverged default branch
#
# Two sections: a fixture section that exercises early_sync_eligible() (a
# faithful transcription of the documented check) against real git repositories
# with a real remote, and a doc-drift section asserting all.md and reset.md
# still say what this suite implements.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CMD_DIR="$REPO_ROOT/commands/repo"

ALL_MD="$CMD_DIR/all.md"
RESET_MD="$CMD_DIR/reset.md"

# Assertion helpers (ok/no/skip/assert_eq/assert_contains/assert_not_contains/
# assert_matches) plus the PASS/FAIL/SKIP/TOTAL counters and color vars are
# shared across the repo test suites — see lib/assert.sh (repo#307).
source "$(dirname "${BASH_SOURCE[0]}")/lib/assert.sh"

for f in "$ALL_MD" "$RESET_MD"; do
    if [[ ! -f "$f" ]]; then
        echo "FATAL: $(basename "$f") not found at $f" >&2
        exit 1
    fi
done

SCRATCH="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$SCRATCH"' EXIT

# ---------------------------------------------------------------------------
# The check under test — a direct transcription of the documented detection.
# ---------------------------------------------------------------------------

# early_sync_eligible <repo> -> ELIGIBLE | INELIGIBLE
#   Mirrors the bash block in all.md's "Sync early, if and only if nothing can
#   be lost" stage. Every guard is a separate early return so a failure message
#   points at one condition rather than at the conjunction.
early_sync_eligible() {
    local r="$1" current default ahead_of_upstream behind_default
    current=$(git -C "$r" symbolic-ref --short HEAD 2>/dev/null) || current=""
    # Fetch first, then resolve origin/HEAD from the refreshed local ref — the
    # documented order (repo#115). Resolving `default` first reads a stale or
    # missing ref that this very fetch could have supplied.
    git -C "$r" fetch origin --quiet 2>/dev/null
    default=$(git -C "$r" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')

    [ -n "$current" ] || { echo INELIGIBLE; return; }        # detached HEAD
    [ -n "$default" ] || { echo INELIGIBLE; return; }        # no origin/HEAD
    [ "$current" != "$default" ] || { echo INELIGIBLE; return; }
    [ -z "$(git -C "$r" status --porcelain)" ] || { echo INELIGIBLE; return; }

    # "Fully pushed" = HEAD has an upstream AND is not ahead of it.
    if git -C "$r" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
        ahead_of_upstream=$(git -C "$r" rev-list --count '@{u}..HEAD')
    else
        ahead_of_upstream=""   # no upstream at all => never pushed, not eligible
    fi
    behind_default=$(git -C "$r" rev-list --count "HEAD..origin/$default" 2>/dev/null || echo 0)

    if [ "$ahead_of_upstream" = "0" ] && [ "$behind_default" -gt 0 ]; then
        echo ELIGIBLE
    else
        echo INELIGIBLE
    fi
}

# diverged_on_default <repo> -> DIVERGED | NOT_DIVERGED
#   Mirrors the SECOND, independent detection all.md's stage 2 adds alongside
#   early_sync_eligible() — the case the first check's `current != default`
#   guard discards without inspecting further: already on the default branch,
#   with local commits it hasn't pushed AND commits upstream it doesn't have.
#   Mutually exclusive with ELIGIBLE: this one requires current == default.
diverged_on_default() {
    local r="$1" current default ahead_of_origin_default behind_origin_default
    current=$(git -C "$r" symbolic-ref --short HEAD 2>/dev/null) || current=""
    git -C "$r" fetch origin --quiet 2>/dev/null
    default=$(git -C "$r" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')

    [ -n "$current" ] || { echo NOT_DIVERGED; return; }
    [ -n "$default" ] || { echo NOT_DIVERGED; return; }
    [ "$current" = "$default" ] || { echo NOT_DIVERGED; return; }
    [ -z "$(git -C "$r" status --porcelain)" ] || { echo NOT_DIVERGED; return; }

    ahead_of_origin_default=$(git -C "$r" rev-list --count "origin/$default..HEAD")
    behind_origin_default=$(git -C "$r" rev-list --count "HEAD..origin/$default")
    if [ "$ahead_of_origin_default" -gt 0 ] && [ "$behind_origin_default" -gt 0 ]; then
        echo DIVERGED
    else
        echo NOT_DIVERGED
    fi
}

# behind_default <repo> -> N   (the count the eligibility check computes)
behind_default() {
    local r="$1" default
    default=$(git -C "$r" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
    git -C "$r" rev-list --count "HEAD..origin/$default" 2>/dev/null || echo 0
}

# ahead_of_default <repo> -> N   (the OTHER axis — never part of eligibility)
ahead_of_default() {
    local r="$1" default
    default=$(git -C "$r" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
    git -C "$r" rev-list --count "origin/$default..HEAD" 2>/dev/null || echo 0
}

# sync_and_switch <repo> -> OK | FAILED
#   The reversible half of /repo:reset (step 4), exactly as all.md stage 2 runs
#   it. Nothing here removes a branch, a worktree, or a stash.
sync_and_switch() {
    local r="$1" default
    default=$(git -C "$r" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
    git -C "$r" fetch --all --prune --quiet 2>/dev/null || { echo FAILED; return; }
    git -C "$r" checkout -q "$default" 2>/dev/null || { echo FAILED; return; }
    git -C "$r" pull --ff-only --quiet 2>/dev/null || { echo FAILED; return; }
    echo OK
}

# ---------------------------------------------------------------------------
# Fixture: a real bare "origin" plus per-case clones.
# ---------------------------------------------------------------------------

ORIGIN="$SCRATCH/origin.git"
SEED="$SCRATCH/seed"

git_quiet() { git -C "$1" "${@:2}" >/dev/null 2>&1; }

build_origin() {
    git init -q --bare -b main "$ORIGIN"
    git init -q -b main "$SEED"
    git -C "$SEED" config user.email "test@example.invalid"
    git -C "$SEED" config user.name "Early Sync Test"
    printf '# Project\n\nBase README.\n' > "$SEED/README.md"
    git_quiet "$SEED" add -A
    git_quiet "$SEED" commit -m "M0: base"
    git_quiet "$SEED" remote add origin "$ORIGIN"
    git_quiet "$SEED" push -u origin main
}

# advance_default <n>  — push n new commits to origin/main (the "default branch
# moved on while you sat on your PR branch" half of the motivating case).
advance_default() {
    local n="$1" i
    git_quiet "$SEED" checkout main
    git_quiet "$SEED" pull --ff-only
    for ((i = 0; i < n; i++)); do
        printf 'upstream line %s\n' "$RANDOM$i" >> "$SEED/README.md"
        git_quiet "$SEED" add -A
        git_quiet "$SEED" commit -m "upstream commit"
    done
    git_quiet "$SEED" push origin main
}

# new_clone <name> -> path   — a fresh clone, so each case is independent.
new_clone() {
    local path="$SCRATCH/$1"
    git clone -q "$ORIGIN" "$path" 2>/dev/null
    git -C "$path" config user.email "test@example.invalid"
    git -C "$path" config user.name "Early Sync Test"
    printf '%s' "$path"
}

echo "/repo:all early sync-and-switch test suite"
echo "========================================="
echo ""

build_origin

# ---------------------------------------------------------------------------
echo "-- the motivating case: pushed PR branch, default branch moved on --"
# ---------------------------------------------------------------------------
C="$(new_clone motivating)"
git_quiet "$C" checkout -b feature/x
printf 'branch-only work\n' >> "$C/README.md"
git_quiet "$C" add -A
git_quiet "$C" commit -m "PR commit"
git_quiet "$C" push -u origin feature/x
advance_default 6
git_quiet "$C" fetch origin

assert_eq "fully pushed + behind default -> ELIGIBLE" "ELIGIBLE" "$(early_sync_eligible "$C")"
assert_eq "behind-count is the real distance" "6" "$(behind_default "$C")"
# The diverged axis: a PR branch is normally AHEAD of the default branch too.
# That must not disqualify it, and must not break the behind computation.
assert_eq "branch is also ahead of default (diverged)" "1" "$(ahead_of_default "$C")"
assert_eq "diverged branch is still ELIGIBLE" "ELIGIBLE" "$(early_sync_eligible "$C")"

# Detection is read-only with respect to the working tree and HEAD: it fetches,
# but must not move HEAD or touch files, so running it costs an ineligible run
# nothing.
HEAD_BEFORE="$(git -C "$C" rev-parse HEAD)"
STATUS_BEFORE="$(git -C "$C" status --porcelain)"
early_sync_eligible "$C" >/dev/null
assert_eq "detection does not move HEAD" "$HEAD_BEFORE" "$(git -C "$C" rev-parse HEAD)"
assert_eq "detection does not dirty the tree" "$STATUS_BEFORE" "$(git -C "$C" status --porcelain)"
assert_eq "detection is stable when repeated" "ELIGIBLE" "$(early_sync_eligible "$C")"

# ---------------------------------------------------------------------------
echo ""
echo "-- the switch itself loses nothing --"
# ---------------------------------------------------------------------------
BRANCH_SHA_BEFORE="$(git -C "$C" rev-parse feature/x)"
assert_eq "sync-and-switch succeeds" "OK" "$(sync_and_switch "$C")"
assert_eq "lands on the default branch" "main" "$(git -C "$C" symbolic-ref --short HEAD)"
assert_eq "default branch is up to date with origin" "0" "$(git -C "$C" rev-list --count 'HEAD..@{u}')"
assert_eq "working tree still clean" "" "$(git -C "$C" status --porcelain)"
assert_eq "the branch ref survives untouched" "$BRANCH_SHA_BEFORE" "$(git -C "$C" rev-parse feature/x)"
assert_eq "the branch still matches its upstream" "$BRANCH_SHA_BEFORE" "$(git -C "$C" rev-parse origin/feature/x)"
BRANCH_LOG="$(git -C "$C" log --oneline feature/x)"
assert_contains "the branch's own commit is still reachable" "$BRANCH_LOG" "PR commit"
# And the point of the whole exercise: the doc stages now read the fresh copy.
FRESH_README="$(cat "$C/README.md")"
assert_contains "checked-out docs are the default branch's newer copy" "$FRESH_README" "upstream line"
assert_not_contains "stale branch-only content is gone from the checkout" "$FRESH_README" "branch-only work"
# Nothing was pruned: the pruning half has not run.
assert_eq "no branch was deleted by the sync half" "1" \
    "$(git -C "$C" for-each-ref --format='%(refname:short)' refs/heads/feature | grep -c .)"

# ---------------------------------------------------------------------------
echo ""
echo "-- worktree collision: the default branch is checked out elsewhere --"
# ---------------------------------------------------------------------------
# The ordinary shape of a Loom-managed repo (repo#115): a worktree per issue,
# with the default branch checked out in one of them. `git checkout <default>`
# then refuses with exit 128 and HEAD does not move — a safe no-op, but the one
# environment this feature was built for, so it must be named rather than
# reported as a generic failure.
C="$(new_clone worktree-collision)"
git_quiet "$C" checkout -b feature/z
git_quiet "$C" push -u origin feature/z
advance_default 2
git_quiet "$C" fetch origin
assert_eq "the collision case is otherwise ELIGIBLE" "ELIGIBLE" "$(early_sync_eligible "$C")"

COLLIDE_WT="$SCRATCH/collide-main"
git_quiet "$C" worktree add "$COLLIDE_WT" main
HEAD_BEFORE="$(git -C "$C" rev-parse HEAD)"
COLLIDE_ERR="$(git -C "$C" checkout main 2>&1 >/dev/null)"
COLLIDE_RC=$?
assert_eq "checkout refuses while another worktree holds the branch" "128" "$COLLIDE_RC"
assert_contains "git names the colliding worktree in its error" \
    "$COLLIDE_ERR" "already used by worktree at"
assert_eq "the refused checkout leaves HEAD exactly where it was" \
    "$HEAD_BEFORE" "$(git -C "$C" rev-parse HEAD)"
assert_eq "still on the working branch" "feature/z" "$(git -C "$C" symbolic-ref --short HEAD)"
assert_eq "the sync half reports failure, not a silent success" "FAILED" "$(sync_and_switch "$C")"
assert_eq "and the failed sync half still moved nothing" \
    "$HEAD_BEFORE" "$(git -C "$C" rev-parse HEAD)"
assert_eq "the tree is still clean after the refused switch" "" "$(git -C "$C" status --porcelain)"
git_quiet "$C" worktree remove --force "$COLLIDE_WT"

# ---------------------------------------------------------------------------
echo ""
echo "-- regression guard: unpushed WIP keeps the old order --"
# ---------------------------------------------------------------------------
C="$(new_clone unpushed-commit)"
git_quiet "$C" checkout -b feature/wip
printf 'pushed work\n' >> "$C/README.md"
git_quiet "$C" add -A
git_quiet "$C" commit -m "pushed commit"
git_quiet "$C" push -u origin feature/wip
printf 'unpushed work\n' >> "$C/README.md"
git_quiet "$C" add -A
git_quiet "$C" commit -m "unpushed commit"
advance_default 2
git_quiet "$C" fetch origin
assert_eq "1 commit ahead of upstream -> INELIGIBLE" "INELIGIBLE" "$(early_sync_eligible "$C")"
assert_eq "behind default is still >0 (only the ahead test excluded it)" "2" "$(behind_default "$C")"
assert_eq "the unpushed commit is untouched" "1" "$(git -C "$C" rev-list --count '@{u}..HEAD')"
assert_eq "still on the working branch" "feature/wip" "$(git -C "$C" symbolic-ref --short HEAD)"

# ---------------------------------------------------------------------------
echo ""
echo "-- 'never pushed' is not 'fully pushed' --"
# ---------------------------------------------------------------------------
C="$(new_clone never-pushed)"
git_quiet "$C" checkout -b feature/local-only
printf 'local only\n' >> "$C/README.md"
git_quiet "$C" add -A
git_quiet "$C" commit -m "local commit"
advance_default 1
git_quiet "$C" fetch origin
HAS_UPSTREAM="$(git -C "$C" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || echo NONE)"
assert_eq "the branch genuinely has no upstream" "NONE" "$HAS_UPSTREAM"
assert_eq "no upstream -> INELIGIBLE (not treated as fully pushed)" "INELIGIBLE" "$(early_sync_eligible "$C")"
# This is the shape an over-eager switch would strand: the commit exists only
# here, so the run must stay on this branch.
assert_eq "the local-only commit exists nowhere else" "1" \
    "$(git -C "$C" rev-list --count 'origin/main..HEAD')"
assert_eq "still on the never-pushed branch" "feature/local-only" \
    "$(git -C "$C" symbolic-ref --short HEAD)"

# ---------------------------------------------------------------------------
echo ""
echo "-- a dirty tree falls back to the current behaviour --"
# ---------------------------------------------------------------------------
C="$(new_clone dirty-tracked)"
git_quiet "$C" checkout -b feature/dirty
git_quiet "$C" push -u origin feature/dirty
advance_default 3
git_quiet "$C" fetch origin
assert_eq "clean precondition -> ELIGIBLE" "ELIGIBLE" "$(early_sync_eligible "$C")"
printf 'uncommitted edit\n' >> "$C/README.md"
assert_eq "modified tracked file -> INELIGIBLE" "INELIGIBLE" "$(early_sync_eligible "$C")"
git_quiet "$C" checkout -- README.md
printf 'scratch\n' > "$C/notes.txt"
assert_eq "untracked file -> INELIGIBLE" "INELIGIBLE" "$(early_sync_eligible "$C")"
rm -f "$C/notes.txt"
assert_eq "cleaning up restores eligibility" "ELIGIBLE" "$(early_sync_eligible "$C")"

# ---------------------------------------------------------------------------
echo ""
echo "-- already on the default branch: no spurious switch --"
# ---------------------------------------------------------------------------
C="$(new_clone on-default)"
advance_default 2
git_quiet "$C" fetch origin
assert_eq "on default and behind it -> INELIGIBLE" "INELIGIBLE" "$(early_sync_eligible "$C")"
assert_eq "still on default, nothing attempted" "main" "$(git -C "$C" symbolic-ref --short HEAD)"
# Behind-only, no local commits: this is the adjacent-but-distinct case the
# new detection must NOT flag. Not diverged — merely stale.
assert_eq "on default and merely behind -> NOT_DIVERGED (not the new case)" \
    "NOT_DIVERGED" "$(diverged_on_default "$C")"

# ---------------------------------------------------------------------------
echo ""
echo "-- on the default branch AND diverged: the shape this issue exists for --"
# ---------------------------------------------------------------------------
# repo#273: already on the default branch, with N unpushed local commits AND M
# commits that landed on origin/default mid-session (other agents, in the
# motivating live run). early_sync_eligible() no-ops here (current == default
# fails its first condition) — that's the silent no-op this test guards
# against. diverged_on_default() must surface it as its own, distinct outcome.
C="$(new_clone diverged-on-default)"
printf 'local unpushed change 1\n' >> "$C/README.md"
git_quiet "$C" add -A
git_quiet "$C" commit -m "local commit 1 (unpushed)"
printf 'local unpushed change 2\n' >> "$C/README.md"
git_quiet "$C" add -A
git_quiet "$C" commit -m "local commit 2 (unpushed)"
advance_default 3
git_quiet "$C" fetch origin

assert_eq "still on the default branch" "main" "$(git -C "$C" symbolic-ref --short HEAD)"
assert_eq "on-default-and-diverged -> INELIGIBLE (current == default excludes it)" \
    "INELIGIBLE" "$(early_sync_eligible "$C")"
assert_eq "the clone is ahead of origin/main by its unpushed commits" "2" \
    "$(git -C "$C" rev-list --count 'origin/main..HEAD')"
assert_eq "the clone is behind origin/main by the upstream commits" "3" \
    "$(git -C "$C" rev-list --count 'HEAD..origin/main')"
assert_eq "on-default-and-diverged -> DIVERGED, distinct from the plain no-op" \
    "DIVERGED" "$(diverged_on_default "$C")"
# Read-only, same as early_sync_eligible: detecting it must not move HEAD.
HEAD_BEFORE="$(git -C "$C" rev-parse HEAD)"
diverged_on_default "$C" >/dev/null
assert_eq "detecting divergence does not move HEAD" "$HEAD_BEFORE" "$(git -C "$C" rev-parse HEAD)"

# Not the same as the fully-pushed-and-behind ELIGIBLE case either: that one
# requires current != default, so a clone that reaches it can never also
# report DIVERGED.
ELIGIBLE_C="$(new_clone eligible-is-not-diverged)"
git_quiet "$ELIGIBLE_C" checkout -b feature/not-diverged
git_quiet "$ELIGIBLE_C" push -u origin feature/not-diverged
advance_default 2
git_quiet "$ELIGIBLE_C" fetch origin
assert_eq "sanity: this fixture is the fully-pushed ELIGIBLE shape" "ELIGIBLE" \
    "$(early_sync_eligible "$ELIGIBLE_C")"
assert_eq "the motivating ELIGIBLE clone (on a feature branch) is NOT diverged-on-default" \
    "NOT_DIVERGED" "$(diverged_on_default "$ELIGIBLE_C")"

# A dirty tree defers the divergence detection exactly like eligibility, for
# the same reason: nothing here should reason about a state mid-edit.
printf 'uncommitted edit\n' >> "$C/README.md"
assert_eq "a dirty tree suppresses the divergence detection" "NOT_DIVERGED" "$(diverged_on_default "$C")"
git_quiet "$C" checkout -- README.md
assert_eq "cleaning up restores the DIVERGED detection" "DIVERGED" "$(diverged_on_default "$C")"

# ---------------------------------------------------------------------------
echo ""
echo "-- nothing to gain: pushed branch that is not behind --"
# ---------------------------------------------------------------------------
C="$(new_clone not-behind)"
git_quiet "$C" checkout -b feature/current
git_quiet "$C" push -u origin feature/current
git_quiet "$C" fetch origin
assert_eq "behind-count is zero" "0" "$(behind_default "$C")"
assert_eq "not behind default -> INELIGIBLE" "INELIGIBLE" "$(early_sync_eligible "$C")"

# ---------------------------------------------------------------------------
echo ""
echo "-- degenerate HEAD states do not crash the check --"
# ---------------------------------------------------------------------------
C="$(new_clone detached)"
advance_default 1
git_quiet "$C" fetch origin
git_quiet "$C" checkout --detach HEAD
DETACHED_RESULT="$(early_sync_eligible "$C")"
DETACHED_STATUS=$?
assert_eq "detached HEAD -> INELIGIBLE" "INELIGIBLE" "$DETACHED_RESULT"
assert_eq "detached HEAD does not error out" "0" "$DETACHED_STATUS"

C="$(new_clone no-origin-head)"
git_quiet "$C" checkout -b feature/y
git_quiet "$C" push -u origin feature/y
advance_default 1
git_quiet "$C" fetch origin
assert_eq "with origin/HEAD present -> ELIGIBLE" "ELIGIBLE" "$(early_sync_eligible "$C")"
# Unreachable remote AND no origin/HEAD: there is no defensible switch target,
# so the run must leave the stage order alone rather than guess one. (The remote
# is pointed at a missing path so the check's own `git fetch` cannot restore
# origin/HEAD, which a modern git otherwise does automatically.)
git_quiet "$C" remote set-url origin "$SCRATCH/gone.git"
git -C "$C" update-ref -d refs/remotes/origin/HEAD 2>/dev/null
NO_HEAD_RESULT="$(early_sync_eligible "$C")"
NO_HEAD_STATUS=$?
assert_eq "unresolvable origin/HEAD -> INELIGIBLE" "INELIGIBLE" "$NO_HEAD_RESULT"
assert_eq "unresolvable origin/HEAD does not error out" "0" "$NO_HEAD_STATUS"
assert_eq "still on the working branch after the degraded check" "feature/y" \
    "$(git -C "$C" symbolic-ref --short HEAD)"

# A repo with no remote at all is the same conclusion by a different route.
NOREMOTE="$SCRATCH/no-remote"
git init -q -b main "$NOREMOTE"
git -C "$NOREMOTE" config user.email "test@example.invalid"
git -C "$NOREMOTE" config user.name "Early Sync Test"
printf 'solo\n' > "$NOREMOTE/README.md"
git_quiet "$NOREMOTE" add -A
git_quiet "$NOREMOTE" commit -m "solo commit"
assert_eq "no remote at all -> INELIGIBLE" "INELIGIBLE" "$(early_sync_eligible "$NOREMOTE")"

# ---------------------------------------------------------------------------
echo ""
echo "-- doc drift: the command files still specify what this suite implements --"
# ---------------------------------------------------------------------------
# Phrases are asserted against a whitespace-flattened copy of each file, since
# the requirement is prose that wraps across lines.
flatten() { tr '\n' ' ' < "$1" | tr -s ' '; }

ALL="$(flatten "$ALL_MD")"

assert_contains "all.md has the conditional early-sync stage" \
    "$ALL" '### 2. Sync early, if and only if nothing can be lost'
assert_contains "all.md names the reversible/pruning split" \
    "$ALL" '**Sync-and-switch** (reversible)'
assert_contains "all.md keeps the pruning half gated and last" \
    "$ALL" '**Pruning** (gated)'
assert_contains "all.md documents the upstream ahead-count test" \
    "$ALL" "ahead_of_upstream=\$(git rev-list --count '@{u}..HEAD')"
assert_contains "all.md treats a never-pushed branch as ineligible" \
    "$ALL" 'no upstream at all => never pushed, not eligible'
assert_contains "all.md spells out the no-upstream rule in prose" \
    "$ALL" 'never pushed** has no upstream and is **not** eligible'
assert_contains "all.md requires a clean working tree" \
    "$ALL" 'Working tree clean (`git status --porcelain` empty)'
assert_contains "all.md requires the branch to be behind the default" \
    "$ALL" 'behind `origin/<default>` by at least one commit'
assert_contains "all.md excludes an already-default checkout" \
    "$ALL" "it isn't already the default"
assert_contains "all.md states ahead-of-default is not disqualifying" \
    "$ALL" 'Being ahead of the *default branch* is **not** disqualifying'
assert_contains "all.md runs only step 4 early" \
    "$ALL" 'run only the sync-and-switch half now'
assert_contains "all.md reports the early switch on its own line" \
    "$ALL" 'switched before Docs'
assert_contains "all.md honours --ask before switching" \
    "$ALL" 'report the finding and get a yes before switching'
# The two failure modes are NOT interchangeable (repo#115): a failed checkout
# leaves HEAD where it was, a failed --ff-only pull happens after the switch
# already landed. Each claim gets its own assertion so neither can be quietly
# collapsed back into the other.
assert_contains "all.md falls back safely when the CHECKOUT fails" \
    "$ALL" 'change nothing, report why, and continue with the stage order unchanged'
assert_contains "all.md names the worktree-collision cause of that failed checkout" \
    "$ALL" "already used by worktree at"
assert_contains "all.md says a failed PULL leaves the run on the diverged default" \
    "$ALL" 'the run is now sitting on that diverged local default branch'
assert_contains "all.md warns the later stages read that diverged copy" \
    "$ALL" 'Docs, Tidy, and Update tools will read that copy'
assert_not_contains "all.md no longer folds the pull failure into 'change nothing'" \
    "$ALL" 'If the checkout or the `--ff-only` pull fails'
assert_contains "all.md makes the ineligible path a silent no-op" \
    "$ALL" 'this stage is a no-op'
assert_contains "all.md keeps pruning in the last stage" \
    "$ALL" '**pruning half always runs here**'
assert_contains "all.md forbids double-reporting the switch" \
    "$ALL" "don't report the switch twice"
assert_contains "all.md keeps pruning output in the summary's Reset line" \
    "$ALL" 'the `Reset:` line still carries the pruning half'
assert_contains "all.md shows a composed Reset summary line" \
    "$ALL" 'synced early (feature/x'

# Stage ordering is the whole point: the sync stage must be documented BEFORE
# the Docs stage, and the pruning Reset stage must remain the last one.
# Located by stage NAME, not by stage number: inserting a stage renumbers every
# one after it, and this test is about relative order, not the digits. Pinning
# the numbers made an ordering test fail on an unrelated stage insertion
# (repo#174's Scrub stage) while the ordering it guards was still intact.
heading_line() {  # <file> <stage-name>
    grep -nE "^### [0-9]+\. $2" "$1" | head -1 | cut -d: -f1
}
SYNC_LN="$(heading_line "$ALL_MD" 'Sync early')"
DOCS_LN="$(heading_line "$ALL_MD" 'Docs')"
TIDY_LN="$(heading_line "$ALL_MD" 'Tidy')"
TOOLS_LN="$(heading_line "$ALL_MD" 'Update tools')"
RESET_LN="$(heading_line "$ALL_MD" 'Reset')"
if [[ -n "$SYNC_LN" && -n "$DOCS_LN" && -n "$TIDY_LN" && -n "$TOOLS_LN" && -n "$RESET_LN" ]]; then
    assert_eq "sync stage is documented before Docs" "yes" \
        "$([[ "$SYNC_LN" -lt "$DOCS_LN" ]] && echo yes || echo no)"
    assert_eq "Docs/Tidy/Update-tools follow the sync stage in order" "yes" \
        "$([[ "$DOCS_LN" -lt "$TIDY_LN" && "$TIDY_LN" -lt "$TOOLS_LN" ]] && echo yes || echo no)"
    assert_eq "the Reset (pruning) stage is still last" "yes" \
        "$([[ "$TOOLS_LN" -lt "$RESET_LN" ]] && echo yes || echo no)"
else
    no "all five ordered stage headings are present in all.md" \
        "sync=$SYNC_LN docs=$DOCS_LN tidy=$TIDY_LN tools=$TOOLS_LN reset=$RESET_LN"
fi

# Stage numbers must still be contiguous from 1 and in ascending order — the
# renumbering half of an insertion is exactly what gets forgotten.
STAGE_NUMS="$(grep -oE '^### [0-9]+\.' "$ALL_MD" | grep -oE '[0-9]+' | tr '\n' ' ')"
EXPECTED_NUMS=""
_n=1
for _ in $STAGE_NUMS; do EXPECTED_NUMS+="$_n "; _n=$((_n + 1)); done
assert_eq "all.md stage headings are numbered contiguously from 1" \
    "$EXPECTED_NUMS" "$STAGE_NUMS"

# Composition guard (repo#82 + repo#89): stage reordering and verify-after-write
# are orthogonal mechanisms — reordering prevents editing a stale checkout,
# verify-after-write protects an edit already applied. Neither supersedes the
# other, so the re-verify-before-print step must survive this reordering. Its
# full contract is asserted by test-verify-fix-persistence.sh; this is the
# cross-check that the reorder did not quietly drop it.
assert_contains "all.md still documents re-verify-before-print" \
    "$ALL" '### Re-verify before printing'

# Fetch ordering (repo#115): `default` is resolved from the LOCAL
# refs/remotes/origin/HEAD, so the eligibility block's own fetch has to run
# first or a stale/unset origin/HEAD cannot be refreshed in time and the stage
# no-ops on its first opportunity to run. Asserted by line position, since the
# bug is purely the order of two adjacent lines.
line_of() {  # <file> <literal>
    grep -n -F -m1 -- "$2" "$1" | cut -d: -f1
}
FETCH_LN="$(line_of "$ALL_MD" 'git fetch origin --quiet')"
DEFAULT_LN="$(line_of "$ALL_MD" 'default=$(git symbolic-ref --short refs/remotes/origin/HEAD')"
if [[ -n "$FETCH_LN" && -n "$DEFAULT_LN" ]]; then
    assert_eq "all.md fetches before resolving origin/HEAD" "yes" \
        "$([[ "$FETCH_LN" -lt "$DEFAULT_LN" ]] && echo yes || echo no)"
else
    no "all.md's eligibility block still fetches and resolves origin/HEAD" \
        "fetch=$FETCH_LN default=$DEFAULT_LN"
fi
assert_contains "all.md documents the unset-origin/HEAD escape hatch" \
    "$ALL" 'git remote set-head origin --auto'

# repo#273: the second, independent detection for the on-default-and-diverged
# case, so the next reader doesn't have to rediscover why the first check
# "did nothing" there.
assert_contains "all.md documents the diverged_on_default detection" \
    "$ALL" 'diverged_on_default=yes'
assert_contains "all.md names the second detection as independent, not a change to eligible" \
    "$ALL" 'A second, independent detection'
assert_contains "all.md's eligibility table gains a row for the diverged-on-default shape" \
    "$ALL" 'Already on the default branch, and diverged from `origin/<default>`'
assert_contains "all.md reports the divergence before Docs runs, even without --ask" \
    "$ALL" 'Report it before Docs runs, even under the default (non-`--ask`) form'
assert_contains "all.md's diverged-on-default report names the invisible upstream commits" \
    "$ALL" "later stages won't see"
assert_contains "all.md's --ask resolution for diverged-on-default reuses reset.md's own wording" \
    "$ALL" 'report the divergence (`git log --oneline @{u}..HEAD` and `HEAD..@{u}`) and ask how to proceed. Do not rebase or force anything on your own.'

RESET="$(flatten "$RESET_MD")"
assert_contains "reset.md names the two halves" \
    "$RESET" '## Two halves'
assert_contains "reset.md maps the reversible half to steps 1 and 4" \
    "$RESET" '**Sync-and-switch** (reversible — steps 1 and 4)'
assert_contains "reset.md maps the pruning half to steps 2 and 3" \
    "$RESET" '**Pruning** (gated — steps 2 and 3)'
assert_contains "reset.md keeps standalone behaviour unchanged" \
    "$RESET" 'Run standalone, `/repo:reset` always runs all four steps in order'
assert_contains "reset.md points at /repo:all's early use of the first half" \
    "$RESET" 'may run the **sync-and-switch half early**'
assert_contains "reset.md names the worktree-collision checkout refusal" \
    "$RESET" "already used by worktree at"
assert_contains "reset.md says a failed --ff-only leaves the run on the default branch" \
    "$RESET" 'the checkout already landed'

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

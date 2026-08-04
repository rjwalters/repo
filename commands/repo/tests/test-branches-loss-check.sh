#!/usr/bin/env bash
# Test suite for the permanent-loss check documented in commands/repo/branches.md
# step 5 — the guard that stands between `/repo:branches --prune` (and
# `/repo:reset --prune`, which delegates to it) and permanently deleted work.
#
# Usage: ./commands/repo/tests/test-branches-loss-check.sh
# Exit code 0 = all tests pass, 1 = failures detected.
#
# Structured like hooks/repo/tests/test-guard-destructive.sh and
# test-session-start-handoff.sh: pure bash, no test framework, PASS/FAIL/TOTAL
# counters and a summary block. `pnpm test` delegates to this file via
# hooks/repo/tests/run.sh.
#
# WHY THIS FILE EXISTS (repo#39): branches.md is prose an agent reads, not code
# any harness executes, so nothing in this repo could catch a regression in the
# loss check. But the check is a small set of self-contained git invocations,
# independent of the surrounding prose — so they can be run directly against
# scratch-repo fixtures. loss_check() below is a faithful transcription of
# branches.md step 5; the doc-drift block at the end asserts the file still says
# what this suite implements.
#
# The contract under test:
#   5a  git log --oneline <branch> --not <default> --remotes   (ONE --not)
#   5b  content containment + forge merge state, NOT SHA ancestry. Four arms,
#       tried in order: merge-tree / diff --quiet / git cherry / merged-PR
#   5c  any error or ambiguity classifies KEEP, never SAFE
#
# Every verdict also carries the TAG naming the arm that produced it (repo#97),
# because a report that says only "SAFE TO DELETE" cannot distinguish "landed as
# a squash commit" from "had no unique commits at all" from work kept because it
# exists nowhere else. The doc-drift block at the end pins the tag vocabulary in
# branches.md and reset.md against the tags this file emits.
#
# NOTE on the forge arm: branches.md keeps `gh pr list --head ... --state merged`
# as the containment probe and adds the REST `gh api .../pulls?state=all&head=...`
# form for the number/date the tag needs. Converting the remaining GraphQL-backed
# `gh pr list` read paths is repo#103's scope, deliberately NOT duplicated here.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BRANCHES_MD="$REPO_ROOT/commands/repo/branches.md"
RESET_MD="$REPO_ROOT/commands/repo/reset.md"

PASS=0
FAIL=0
SKIP=0
TOTAL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

if [[ ! -f "$BRANCHES_MD" ]]; then
    echo "FATAL: branches.md not found at $BRANCHES_MD" >&2
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
# it (e.g. this git predates `merge-tree --write-tree`). It is counted separately
# and surfaced in the summary so a silently-skipped suite is never mistaken for a
# full pass (repo#46). SKIP does NOT feed TOTAL/PASS/FAIL — run.sh folds only the
# pass/fail counts, and reports the skip count as a breakdown annotation.
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
# The only verdict that can destroy work is SAFE. UNSAFE and KEEP are both
# "do not delete", so most assertions care about that boundary, not which of
# the two non-deleting verdicts came back.
assert_not_safe() {  # <label> <actual>
    if [[ "$2" != "SAFE" ]]; then ok "$1"; else no "$1" "got SAFE — this branch would be deleted"; fi
}

# ---------------------------------------------------------------------------
# The check under test — a direct transcription of branches.md step 5.
# ---------------------------------------------------------------------------

DEFAULT="main"
REPO=""

# Stands in for the forge lookup — `gh pr list --head <branch> --state merged`
# for the count, plus the REST `gh api .../pulls?state=all&head=...` form for the
# number and merge date the report tag needs. Echoes "<count> <number> <date>".
# PR_LOOKUP_MODE: none -> no merged PR | merged -> one merged PR | fail ->
# non-zero exit (gh missing / unauthenticated / rate-limited / offline).
PR_LOOKUP_MODE="none"
pr_merged_lookup() {  # <branch>
    case "$PR_LOOKUP_MODE" in
        merged) echo "1 150 2026-06-28" ;;
        fail)   return 7 ;;
        *)      echo "0  " ;;
    esac
}

# classify <branch> -> "<verdict>|<tag>"
#   SAFE   : work is preserved elsewhere; branch may be deleted under --prune
#   UNSAFE : branch holds commits whose content exists nowhere else
#   KEEP   : ambiguous or errored (5c) — must be treated exactly like UNSAFE
# The tag is the branches.md step-4 report label naming the check that fired.
classify() {
    local branch="$1" unique mt tree lookup n num date cherry
    local n_commits

    # -- 5a: ancestry. ONE --not, both exclusions after it.
    if ! unique=$(git -C "$REPO" log --oneline "$branch" --not "$DEFAULT" --remotes 2>/dev/null); then
        echo "KEEP|unverifiable: 5a ancestry lookup failed"; return   # 5c
    fi
    if [[ -z "$unique" ]]; then
        echo "SAFE|no unique commits"; return
    fi
    n_commits=$(printf '%s\n' "$unique" | grep -c .)

    # -- 5b arm 1: tree containment (merge-tree), not SHA ancestry.
    if mt=$(git -C "$REPO" merge-tree --write-tree "$DEFAULT" "$branch" 2>/dev/null); then
        if ! tree=$(git -C "$REPO" rev-parse "$DEFAULT^{tree}" 2>/dev/null); then
            echo "KEEP|unverifiable: cannot resolve $DEFAULT^{tree}"; return   # 5c
        fi
        if [[ "$mt" == "$tree" ]]; then
            # merging the branch would change nothing
            echo "SAFE|landed (squash), content-verified (merge-tree)"; return
        fi
    # -- 5b arm 2: exact tree match (the git < 2.38 / conflicted-merge fallback).
    elif git -C "$REPO" diff --quiet "$DEFAULT" "$branch" 2>/dev/null; then
        echo "SAFE|landed, identical tree"; return
    fi

    # -- 5b arm 3: patch-id equivalence. Proven only when the output is non-empty
    #    and EVERY line is '-'. One '+' means a patch that is not in <default>.
    if cherry=$(git -C "$REPO" cherry "$DEFAULT" "$branch" 2>/dev/null); then
        if [[ -n "$cherry" ]] && ! printf '%s\n' "$cherry" | grep -q '^+'; then
            echo "SAFE|landed (squash), patch-id equivalent (git cherry)"; return
        fi
    fi

    # -- 5b arm 4: forge merge state.
    if lookup=$(pr_merged_lookup "$branch" 2>/dev/null); then
        read -r n num date <<<"$lookup"
        if [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 )); then
            echo "SAFE|landed (squash), merged PR #${num} (${date})"; return
        fi
    else
        # 5c: forge lookup unavailable -> KEEP
        echo "KEEP|unverifiable: forge lookup failed"; return
    fi

    echo "UNSAFE|unique work: ${n_commits} commits found nowhere else"
}

# loss_check <branch> -> SAFE | UNSAFE | KEEP   (verdict only)
loss_check() { classify "$1" | cut -d'|' -f1; }

# loss_tag <branch> -> the report tag classify assigned
loss_tag() { classify "$1" | cut -d'|' -f2-; }

# safe_to_delete_set -> newline-separated branches loss_check calls SAFE
safe_to_delete_set() {
    local b
    while read -r b; do
        [[ -z "$b" || "$b" == "$DEFAULT" ]] && continue
        [[ "$(loss_check "$b")" == "SAFE" ]] && echo "$b"
    done < <(git -C "$REPO" for-each-ref --format='%(refname:short)' refs/heads/)
    return 0
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

build_fixtures() {
    local root="$SCRATCH/fixture"
    mkdir -p "$root"
    git init -q --bare "$root/origin.git"
    git init -q -b main "$root/repo"
    REPO="$root/repo"
    git -C "$REPO" config user.email "test@example.invalid"
    git -C "$REPO" config user.name "Loss Check Test"
    git -C "$REPO" remote add origin "$root/origin.git"

    echo base > "$REPO/base.txt"
    git -C "$REPO" add -A && git -C "$REPO" commit -qm "M0: base"
    git -C "$REPO" push -q origin main

    # (1) SQUASH-MERGED branch. Its two commits are replayed into main as ONE
    #     new commit, so neither original SHA is an ancestor of main. This is
    #     the fixture a `git branch --merged`-based check gets wrong.
    git -C "$REPO" checkout -q -b feature/squashed
    echo one > "$REPO/f.txt"
    git -C "$REPO" add -A && git -C "$REPO" commit -qm "B1: add f"
    echo two >> "$REPO/f.txt"
    git -C "$REPO" add -A && git -C "$REPO" commit -qm "B2: extend f"
    git -C "$REPO" checkout -q main
    git -C "$REPO" merge --squash -q feature/squashed >/dev/null
    git -C "$REPO" commit -qm "squash: add f (#1)"
    git -C "$REPO" push -q origin main

    # (2) UNPUSHED branch: content genuinely absent from main and from every
    #     remote. Nothing merged, nothing squashed, nothing cherry-picked.
    git -C "$REPO" checkout -q -b feature/unpushed main
    echo irreplaceable > "$REPO/u.txt"
    git -C "$REPO" add -A && git -C "$REPO" commit -qm "U1: genuinely unpushed work"

    # (3) PUSHED but unmerged: unique to main, but preserved on the remote.
    git -C "$REPO" checkout -q -b feature/pushed main
    echo pushed > "$REPO/p.txt"
    git -C "$REPO" add -A && git -C "$REPO" commit -qm "P1: pushed, not merged"
    git -C "$REPO" push -q origin feature/pushed

    # (4) MERGED PR whose content main has since moved past: squash-merged, then
    #     main edited the same file. merge-tree conflicts and diff differs, so
    #     only the forge lookup can establish containment — the case that proves
    #     the 5c failure direction.
    #     It is deliberately MULTI-commit: a squash collapses its two patches into
    #     one, so no individual patch-id survives into main and `git cherry`
    #     (5b arm 3) correctly reports '+' and falls through to the forge arm.
    #     A single-commit version would be cleared by patch-id and would stop
    #     exercising the forge-only path — fixture 5 covers that case instead.
    git -C "$REPO" checkout -q -b feature/pr-merged main
    echo v1 > "$REPO/c.txt"
    git -C "$REPO" add -A && git -C "$REPO" commit -qm "C1: add c=v1"
    echo v1b > "$REPO/c.txt"
    git -C "$REPO" add -A && git -C "$REPO" commit -qm "C2: c=v1b"
    git -C "$REPO" checkout -q main
    git -C "$REPO" merge --squash -q feature/pr-merged >/dev/null
    git -C "$REPO" commit -qm "squash: add c (#2)"
    echo v2 > "$REPO/c.txt"
    git -C "$REPO" add -A && git -C "$REPO" commit -qm "main: c=v2"
    git -C "$REPO" push -q origin main
    git -C "$REPO" checkout -q main

    # (5) SINGLE-commit squash-merge that main has since moved past (repo#97).
    #     The live failure this issue was filed from: every branch in it carried
    #     one commit, was squash-landed, and main had advanced. merge-tree
    #     conflicts (add/add on s.txt) and diff differs, so arms 1-2 cannot clear
    #     it — but the squash commit's patch IS the branch commit's patch, so
    #     `git cherry` clears it with no forge access at all.
    git -C "$REPO" checkout -q -b feature/cherry-landed main
    echo s1 > "$REPO/s.txt"
    git -C "$REPO" add -A && git -C "$REPO" commit -qm "S1: add s=s1"
    git -C "$REPO" checkout -q main
    git -C "$REPO" merge --squash -q feature/cherry-landed >/dev/null
    git -C "$REPO" commit -qm "squash: add s (#3)"
    echo s2 > "$REPO/s.txt"
    git -C "$REPO" add -A && git -C "$REPO" commit -qm "main: s=s2"
    git -C "$REPO" push -q origin main
    git -C "$REPO" checkout -q main

    # (6) Finally, a commit made to main and NOT pushed — the `abae8dc` analogue
    #     from repo#39. Local main is now one commit ahead of origin/main, which
    #     is the ordinary state right after any local merge. The malformed idiom
    #     leaks THIS commit into every branch's output; the fixed one does not.
    #     It must stay unpushed: had it been pushed, `--remotes` would mask the
    #     leak and the malformed form would look correct — that accidental
    #     masking is exactly the "right answer for the wrong reason" failure
    #     mode this suite exists to pin down.
    echo mainonly > "$REPO/m.txt"
    git -C "$REPO" add -A && git -C "$REPO" commit -qm "MAINONLY: committed only to main"
    MAINONLY_SHA=$(git -C "$REPO" rev-parse --short HEAD)

    # (7) IDENTICAL-TREE branch: same content as main's current tip but a
    #     distinct SHA (an amended commit, same tree + same parent). Its tree
    #     equals main's, so even the degraded `git diff --quiet` fallback can
    #     prove containment — this is the legitimate "old git still classifies
    #     SAFE" path exercised by the degraded-mode section below (repo#46).
    #     Built last so main's tree is fixed from here on; leaving main checked
    #     out keeps every later assertion operating from main.
    git -C "$REPO" checkout -q -b feature/identical
    git -C "$REPO" commit -q --amend --allow-empty -m "identical: main's tree, distinct SHA"
    git -C "$REPO" checkout -q main
}

echo "branches.md permanent-loss check test suite"
echo "==========================================="
echo ""

build_fixtures

# ---------------------------------------------------------------------------
# Capability probe + merge-tree shim (repo#46)
# ---------------------------------------------------------------------------
# 5b's primary containment check uses `git merge-tree --write-tree`, which only
# exists on git >= 2.38. Probe the capability once — on the fixture repo, not by
# parsing `git --version` (a vendor version string can distort that) — so the
# assertions that need a REAL merge-tree result skip cleanly on older git instead
# of failing with a confusing empty-string-vs-tree-hash mismatch. The documented
# fallback (`git diff --quiet` -> merged-PR lookup) is then exercised explicitly
# under a PATH shim below, on every git version.
HAS_MERGE_TREE=0
if git -C "$REPO" merge-tree --write-tree HEAD HEAD >/dev/null 2>&1; then
    HAS_MERGE_TREE=1
fi

# A `git` shim that simulates git < 2.38: it fails only on `merge-tree` and execs
# the real git for everything else. Used by mt_unsupported_loss_check to force
# the degraded fallback chain regardless of the host git version.
SHIM_DIR="$SCRATCH/nomergetree-bin"
mkdir -p "$SHIM_DIR"
REAL_GIT="$(command -v git)"
cat > "$SHIM_DIR/git" <<SHIM
#!/usr/bin/env bash
for arg in "\$@"; do
    if [ "\$arg" = "merge-tree" ]; then
        echo "git: 'merge-tree --write-tree' unsupported (simulated git < 2.38)" >&2
        exit 129
    fi
done
exec "$REAL_GIT" "\$@"
SHIM
chmod +x "$SHIM_DIR/git"

# loss_check run against a git that lacks `merge-tree --write-tree`. The PATH
# override lives in a subshell, so the real merge-tree is untouched afterward —
# later real-git assertions must not see the shim (guards the "shim leak" case).
mt_unsupported_loss_check() {  # <branch>
    ( PATH="$SHIM_DIR:$PATH"; loss_check "$1" )
}

# ---------------------------------------------------------------------------
echo "-- the bug: \`--not\` is a toggle (repo#39) --"
# ---------------------------------------------------------------------------
MALFORMED=$(git -C "$REPO" log --oneline feature/squashed --not --remotes --not main 2>&1)
FIXED=$(git -C "$REPO" log --oneline feature/squashed --not main --remotes 2>&1)

assert_contains "malformed form leaks a main-only commit" "$MALFORMED" "MAINONLY"
assert_not_contains "fixed form excludes main-only commits" "$FIXED" "MAINONLY"
assert_contains "fixed form still surfaces branch-only commits" "$FIXED" "B2: extend f"
# The leaked commit really is main-only — it was never on the branch.
CONTAINS=$(git -C "$REPO" branch --contains "$MAINONLY_SHA" --format='%(refname:short)' | tr '\n' ' ')
assert_eq "leaked commit exists only on main" "main " "$CONTAINS"

# ---------------------------------------------------------------------------
echo ""
echo "-- the squash-merge trap: --merged must NOT be used alone --"
# ---------------------------------------------------------------------------
MERGED_LIST=$(git -C "$REPO" branch --merged main --format='%(refname:short)' | tr '\n' ' ')
assert_not_contains "git branch --merged omits the squash-merged branch" \
    "$MERGED_LIST" "feature/squashed"
# 5a alone therefore cannot clear it: the original SHAs are not ancestors of main.
SQ_5A=$(git -C "$REPO" log --oneline feature/squashed --not main --remotes)
if [[ -n "$SQ_5A" ]]; then
    ok "5a alone reports the squash-merged branch as having unique SHAs"
else
    no "5a alone reports the squash-merged branch as having unique SHAs" "5a was empty"
fi
# ...but its content IS contained in main, which is what 5b measures. This direct
# probe needs a real merge-tree result, so it skips (not fails) on git < 2.38.
if [[ "$HAS_MERGE_TREE" == 1 ]]; then
    MT=$(git -C "$REPO" merge-tree --write-tree main feature/squashed 2>/dev/null)
    assert_eq "5b: merging the squash-merged branch changes nothing" \
        "$(git -C "$REPO" rev-parse 'main^{tree}')" "$MT"
else
    skip "5b: merging the squash-merged branch changes nothing" \
        "git merge-tree --write-tree unsupported (git < 2.38)"
fi

# ---------------------------------------------------------------------------
echo ""
echo "-- fixture 1: squash-merged branch classifies SAFE --"
# ---------------------------------------------------------------------------
PR_LOOKUP_MODE="none"   # no forge help at all — content containment must carry it
# main has advanced past the squash-merge (later fixtures added files), so only
# merge-tree can prove containment here; without it the degraded path correctly
# refuses SAFE. That degraded direction is pinned in the fallback section below.
if [[ "$HAS_MERGE_TREE" == 1 ]]; then
    assert_eq "squash-merged -> SAFE (without any PR lookup)" "SAFE" "$(loss_check feature/squashed)"
    assert_eq "squash-merged tag names the merge-tree arm" \
        "landed (squash), content-verified (merge-tree)" "$(loss_tag feature/squashed)"
else
    skip "squash-merged -> SAFE (without any PR lookup)" \
        "content containment needs merge-tree; degraded path covered by the fallback section"
    skip "squash-merged tag names the merge-tree arm" "needs merge-tree (git < 2.38)"
fi

# ---------------------------------------------------------------------------
echo ""
echo "-- fixture 2: genuinely unpushed branch classifies UNSAFE --"
# ---------------------------------------------------------------------------
PR_LOOKUP_MODE="none"
assert_eq "unpushed work -> UNSAFE" "UNSAFE" "$(loss_check feature/unpushed)"
# Not rescued by a bogus merged-PR answer being absent, and not by --prune.
SAFE_SET="$(safe_to_delete_set | tr '\n' ' ')"
assert_not_contains "unpushed branch is never offered for deletion" "$SAFE_SET" "feature/unpushed"
if [[ "$HAS_MERGE_TREE" == 1 ]]; then
    assert_contains "squash-merged branch IS offered for deletion" "$SAFE_SET" "feature/squashed"
else
    skip "squash-merged branch IS offered for deletion" \
        "needs merge-tree to prove containment after main advanced (git < 2.38)"
fi

# ---------------------------------------------------------------------------
echo ""
echo "-- fixture 3: pushed-but-unmerged branch is covered by --remotes --"
# ---------------------------------------------------------------------------
assert_eq "pushed branch -> SAFE (preserved on the remote)" "SAFE" "$(loss_check feature/pushed)"
# Delete the remote copy and the same branch must flip to UNSAFE.
git -C "$REPO" push -q origin --delete feature/pushed
git -C "$REPO" fetch -q --prune origin
assert_eq "pushed branch -> UNSAFE once the remote copy is gone" \
    "UNSAFE" "$(loss_check feature/pushed)"

# ---------------------------------------------------------------------------
echo ""
echo "-- fixture 5: single-commit squash landed, main advanced (repo#97) --"
# ---------------------------------------------------------------------------
# The exact shape of the live failure: one commit, squash-merged, main since
# advanced past the file. `git branch -d` refuses it, `git branch --merged`
# omits it, merge-tree conflicts, `git diff` differs — yet the work is fully
# landed. Only patch-id equivalence (5b arm 3) can say so without the forge.
PR_LOOKUP_MODE="none"
CHERRY_OUT=$(git -C "$REPO" cherry main feature/cherry-landed)
assert_contains "git cherry marks the squash-landed commit as '-'" "$CHERRY_OUT" "-"
assert_not_contains "git cherry finds no unmatched patch on that branch" "$CHERRY_OUT" "+"
MERGED_LIST=$(git -C "$REPO" branch --merged main --format='%(refname:short)' | tr '\n' ' ')
assert_not_contains "git branch --merged still omits it (reachability is wrong here)" \
    "$MERGED_LIST" "feature/cherry-landed"
assert_eq "single-commit squash-landed -> SAFE with no forge access" \
    "SAFE" "$(loss_check feature/cherry-landed)"
assert_eq "its tag names the patch-id arm, not merge-tree" \
    "landed (squash), patch-id equivalent (git cherry)" "$(loss_tag feature/cherry-landed)"
# A branch of several commits squashed into one does NOT patch-id match, and the
# check must not pretend otherwise: this is the documented limit of arm 3.
MULTI_CHERRY=$(git -C "$REPO" cherry main feature/pr-merged)
assert_contains "multi-commit squash is NOT cleared by patch-id" "$MULTI_CHERRY" "+"
# And genuinely unique work is never cleared by patch-id either.
UNIQ_CHERRY=$(git -C "$REPO" cherry main feature/unpushed)
assert_contains "unpushed work is NOT cleared by patch-id" "$UNIQ_CHERRY" "+"

# ---------------------------------------------------------------------------
echo ""
echo "-- 5c: ambiguity and errors classify KEEP, never SAFE --"
# ---------------------------------------------------------------------------
# feature/pr-merged: content NOT contained (main moved past it), so only the
# forge lookup can clear it.
PR_LOOKUP_MODE="merged"
assert_eq "merged PR clears a branch main has moved past" "SAFE" "$(loss_check feature/pr-merged)"
assert_eq "its tag carries the PR number and merge date" \
    "landed (squash), merged PR #150 (2026-06-28)" "$(loss_tag feature/pr-merged)"
PR_LOOKUP_MODE="fail"
assert_eq "forge lookup unavailable -> KEEP (not SAFE)" "KEEP" "$(loss_check feature/pr-merged)"
assert_eq "its tag says unverifiable, not landed" \
    "unverifiable: forge lookup failed" "$(loss_tag feature/pr-merged)"
PR_LOOKUP_MODE="none"
assert_eq "no merged PR found -> UNSAFE" "UNSAFE" "$(loss_check feature/pr-merged)"
assert_contains "its tag says unique work, distinct from any landed tag" \
    "$(loss_tag feature/pr-merged)" "unique work:"

# A failing forge lookup must never rescue, nor condemn-to-SAFE, anything.
PR_LOOKUP_MODE="fail"
if [[ "$HAS_MERGE_TREE" == 1 ]]; then
    assert_eq "forge failure leaves squash-merged branch SAFE on content alone" \
        "SAFE" "$(loss_check feature/squashed)"
else
    skip "forge failure leaves squash-merged branch SAFE on content alone" \
        "content containment needs merge-tree (git < 2.38)"
fi
assert_not_safe "forge failure keeps unpushed branch out of SAFE" \
    "$(loss_check feature/unpushed)"
SAFE_SET="$(safe_to_delete_set | tr '\n' ' ')"
assert_not_contains "degraded mode: pr-merged branch not offered for deletion" \
    "$SAFE_SET" "feature/pr-merged"
assert_not_contains "degraded mode: unpushed branch not offered for deletion" \
    "$SAFE_SET" "feature/unpushed"

# 5a itself erroring (unknown ref) must classify KEEP.
PR_LOOKUP_MODE="merged"
assert_eq "unknown ref -> KEEP even with a merged-PR answer available" \
    "KEEP" "$(loss_check no/such/branch)"
PR_LOOKUP_MODE="none"

# ---------------------------------------------------------------------------
echo ""
echo "-- degraded path: git < 2.38 has no \`merge-tree --write-tree\` (repo#46) --"
# ---------------------------------------------------------------------------
# The documented fallback chain (branches.md:161) is `merge-tree` -> `git diff
# --quiet` -> merged-PR lookup. On a modern git the merge-tree arm always wins, so
# the fallback arms have zero natural coverage. Force them by running loss_check
# under a git that fails on merge-tree, and pin the failure DIRECTION: the
# degraded path must never classify SAFE unless containment is otherwise proven
# (identical trees or a merged PR). "Degrades to SAFE" is precisely the
# silent-data-loss failure repo#39 was filed to prevent — this is the coverage it
# left untested. Runs on every git version; the shim forces the fallback.

# (a) Identical trees: `git diff --quiet` exits 0 — the legitimate degraded
#     success path (exit 0 is documented proof of containment).
PR_LOOKUP_MODE="none"
assert_eq "fallback: identical-tree branch -> SAFE via \`git diff --quiet\`" \
    "SAFE" "$(mt_unsupported_loss_check feature/identical)"
assert_eq "fallback: identical-tree tag names the tree arm, not a squash arm" \
    "landed, identical tree" \
    "$( PATH="$SHIM_DIR:$PATH"; loss_tag feature/identical )"

# (a2) Patch-id equivalence needs no merge-tree at all, so the single-commit
#      squash-landed branch is still cleared — and still labelled as landed —
#      on a git that predates `merge-tree --write-tree` (repo#97).
assert_eq "fallback: single-commit squash-landed -> SAFE via patch-id" \
    "SAFE" "$(mt_unsupported_loss_check feature/cherry-landed)"
assert_eq "fallback: patch-id tag survives the degraded path" \
    "landed (squash), patch-id equivalent (git cherry)" \
    "$( PATH="$SHIM_DIR:$PATH"; loss_tag feature/cherry-landed )"

# (b) main advanced past a squash-merge, no forge help: diff differs, PR lookup
#     finds nothing -> UNSAFE. The primary (merge-tree) path calls this SAFE;
#     degraded correctly will not, because it cannot prove containment.
PR_LOOKUP_MODE="none"
assert_eq "fallback: squash-merged (main advanced), no PR -> UNSAFE" \
    "UNSAFE" "$(mt_unsupported_loss_check feature/squashed)"
assert_not_safe "fallback: squash-merged branch never degrades to SAFE" \
    "$(mt_unsupported_loss_check feature/squashed)"

# (c) Same, but the forge lookup itself fails (5c) -> KEEP, never SAFE.
PR_LOOKUP_MODE="fail"
assert_eq "fallback: squash-merged (main advanced), forge down -> KEEP" \
    "KEEP" "$(mt_unsupported_loss_check feature/squashed)"

# (d) A merged PR still rescues a branch without merge-tree — the forge arm is
#     independent of the containment probe.
PR_LOOKUP_MODE="merged"
assert_eq "fallback: merged-PR lookup clears the branch without merge-tree" \
    "SAFE" "$(mt_unsupported_loss_check feature/pr-merged)"
PR_LOOKUP_MODE="none"

# Shim hygiene: the PATH override was confined to subshells, so a REAL merge-tree
# (when the host has one) must still resolve here — no leak into later cases.
if [[ "$HAS_MERGE_TREE" == 1 ]]; then
    if git -C "$REPO" merge-tree --write-tree main feature/squashed >/dev/null 2>&1; then
        ok "merge-tree shim did not leak into the real environment"
    else
        no "merge-tree shim did not leak into the real environment" \
            "real merge-tree unavailable after the shim subshells"
    fi
fi

# ---------------------------------------------------------------------------
echo ""
echo "-- report tags: every verdict names the check that fired (repo#97) --"
# ---------------------------------------------------------------------------
# The operator-facing half of the fix: a bare "SAFE TO DELETE" cannot be audited
# after the fact. Each verdict must carry a tag, "landed" tags must be visibly
# distinct from "unique work", and every tag this suite emits must appear in the
# vocabulary table branches.md publishes (asserted in the doc-drift block below).
PR_LOOKUP_MODE="merged"
UNTAGGED=""
for b in feature/squashed feature/unpushed feature/pushed feature/pr-merged \
         feature/cherry-landed feature/identical; do
    t="$(loss_tag "$b")"
    [[ -z "$t" ]] && UNTAGGED+="$b "
done
if [[ -z "$UNTAGGED" ]]; then
    ok "every classified branch carries a report tag"
else
    no "every classified branch carries a report tag" "untagged: $UNTAGGED"
fi

# A landed branch and a unique-work branch must not read the same.
LANDED_TAG="$(loss_tag feature/cherry-landed)"
PR_LOOKUP_MODE="none"
UNIQUE_TAG="$(loss_tag feature/unpushed)"
assert_contains "landed branches are tagged 'landed'" "$LANDED_TAG" "landed"
assert_not_contains "a landed tag never reads as unique work" "$LANDED_TAG" "unique work"
assert_contains "unique work is tagged 'unique work'" "$UNIQUE_TAG" "unique work"
assert_not_contains "a unique-work tag never reads as landed" "$UNIQUE_TAG" "landed"

# ---------------------------------------------------------------------------
echo ""
echo "-- doc drift: branches.md still specifies what this suite implements --"
# ---------------------------------------------------------------------------
# Every `git log` invocation in the file must use EXACTLY ONE `--not`. A second
# one silently re-includes the default branch (repo#39).
BAD_LINES=""
while IFS= read -r line; do
    n=$(printf '%s\n' "$line" | grep -o -- '--not' | grep -c . || true)
    [[ "$n" -gt 1 ]] && BAD_LINES+="$line"$'\n'
done < <(grep -E '^git log ' "$BRANCHES_MD" || true)
if [[ -z "$BAD_LINES" ]]; then
    ok "no 'git log' command in branches.md uses a second --not"
else
    no "no 'git log' command in branches.md uses a second --not" "offending: ${BAD_LINES//$'\n'/ | }"
fi

MD="$(cat "$BRANCHES_MD")"
assert_contains "branches.md documents the corrected 5a idiom" \
    "$MD" 'git log --oneline <branch> --not <default> --remotes'
assert_contains "branches.md documents a content-containment check" \
    "$MD" 'git merge-tree --write-tree <default> <branch>'
assert_contains "branches.md documents the merged-PR fallback" \
    "$MD" 'gh pr list --head <branch> --state merged'
assert_contains "branches.md warns against --merged alone" \
    "$MD" 'Do NOT "simplify" 5b to `git branch --merged <default>`'
assert_contains "branches.md explains why --not must not be doubled" \
    "$MD" '`--not` is a **toggle**'
assert_contains "branches.md fixes the failure direction to KEEP" \
    "$MD" 'UNKNOWN / KEEP'
assert_contains "branches.md states errors are never SAFE" \
    "$MD" '**Never SAFE.**'

# repo#97: patch-id arm, the REST form for new forge calls, and the -d/-D warning.
assert_contains "branches.md documents the patch-id (git cherry) arm" \
    "$MD" 'git cherry <default> <branch>'
assert_contains "branches.md documents the patch-id limit for multi-commit squashes" \
    "$MD" 'matches none of them individually'
assert_contains "branches.md gives the REST form for new forge calls" \
    "$MD" 'gh api "repos/{owner}/{repo}/pulls?state=all&head={owner}:<branch>"'
assert_contains "branches.md warns that -d is not the classifier" \
    "$MD" '`git branch -d` is not the classifier'
assert_contains "branches.md warns that -D is not the fix for a -d refusal" \
    "$MD" '`-D` is not the fix'
assert_contains "branches.md restricts -D to branches step 5 tagged landed" \
    "$MD" 'Escalate to `-D` only for a branch step 5 tagged `landed (...)`'
assert_contains "branches.md refuses the git branch --merged offline fallback" \
    "$MD" 'Do **not** fall back to'

# The tag vocabulary this suite emits must be published in branches.md, or the
# report and the check have drifted apart.
for tag in 'no unique commits' \
           'landed (squash), content-verified (merge-tree)' \
           'landed, identical tree' \
           'landed (squash), patch-id equivalent (git cherry)' \
           'landed (squash), merged PR #N (<date>)' \
           'unique work: N commits found nowhere else' \
           'unverifiable: <reason>'; do
    assert_contains "branches.md publishes the tag: $tag" "$MD" "$tag"
done

# reset.md delegates to branches.md rather than duplicating the idiom; if it
# ever grows its own copy, this suite must be extended to cover it too.
if [[ -f "$RESET_MD" ]]; then
    RESET="$(cat "$RESET_MD")"
    assert_contains "reset.md still delegates to the permanent-loss check" \
        "$RESET" "permanent-loss check"
    if grep -qE '^git log .*--not' "$RESET_MD"; then
        no "reset.md does not duplicate the loss-check idiom" "reset.md grew its own copy"
    else
        ok "reset.md does not duplicate the loss-check idiom"
    fi
    # repo#97: reset.md's final report must carry the tag through, so its branch
    # summary is not a bare "N deleted" that hides which rule applied.
    assert_contains "reset.md carries the per-branch tag into its report" \
        "$RESET" "landed (squash)"
    assert_contains "reset.md's report distinguishes kept unique work" \
        "$RESET" "unique work:"
    assert_contains "reset.md warns against reaching for -D" \
        "$RESET" 'Never reach for `-D`'
fi

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

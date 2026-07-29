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
#   5b  content containment (merge-tree / diff / merged-PR), NOT SHA ancestry
#   5c  any error or ambiguity classifies KEEP, never SAFE

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

# Stands in for `gh pr list --head <branch> --state merged --json number --jq length`.
# PR_LOOKUP_MODE: none -> "0" | merged -> "1" | fail -> non-zero exit (gh
# missing / unauthenticated / rate-limited / offline).
PR_LOOKUP_MODE="none"
pr_merged_count() {  # <branch>
    case "$PR_LOOKUP_MODE" in
        merged) echo 1 ;;
        fail)   return 7 ;;
        *)      echo 0 ;;
    esac
}

# loss_check <branch> -> SAFE | UNSAFE | KEEP
#   SAFE   : work is preserved elsewhere; branch may be deleted under --prune
#   UNSAFE : branch holds commits whose content exists nowhere else
#   KEEP   : ambiguous or errored (5c) — must be treated exactly like UNSAFE
loss_check() {
    local branch="$1" unique mt tree n

    # -- 5a: ancestry. ONE --not, both exclusions after it.
    if ! unique=$(git -C "$REPO" log --oneline "$branch" --not "$DEFAULT" --remotes 2>/dev/null); then
        echo KEEP; return          # 5c: errored -> KEEP, never SAFE
    fi
    if [[ -z "$unique" ]]; then
        echo SAFE; return
    fi

    # -- 5b: content containment, not SHA ancestry.
    if mt=$(git -C "$REPO" merge-tree --write-tree "$DEFAULT" "$branch" 2>/dev/null); then
        if ! tree=$(git -C "$REPO" rev-parse "$DEFAULT^{tree}" 2>/dev/null); then
            echo KEEP; return      # 5c
        fi
        if [[ "$mt" == "$tree" ]]; then
            echo SAFE; return      # merging the branch would change nothing
        fi
    elif git -C "$REPO" diff --quiet "$DEFAULT" "$branch" 2>/dev/null; then
        echo SAFE; return          # fallback: identical trees
    fi

    if n=$(pr_merged_count "$branch" 2>/dev/null); then
        if [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 )); then
            echo SAFE; return
        fi
    else
        echo KEEP; return          # 5c: forge lookup unavailable -> KEEP
    fi

    echo UNSAFE
}

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
    git -C "$REPO" checkout -q -b feature/pr-merged main
    echo v1 > "$REPO/c.txt"
    git -C "$REPO" add -A && git -C "$REPO" commit -qm "C1: add c=v1"
    git -C "$REPO" checkout -q main
    git -C "$REPO" merge --squash -q feature/pr-merged >/dev/null
    git -C "$REPO" commit -qm "squash: add c (#2)"
    echo v2 > "$REPO/c.txt"
    git -C "$REPO" add -A && git -C "$REPO" commit -qm "main: c=v2"
    git -C "$REPO" push -q origin main
    git -C "$REPO" checkout -q main

    # (5) Finally, a commit made to main and NOT pushed — the `abae8dc` analogue
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

    # (6) IDENTICAL-TREE branch: same content as main's current tip but a
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
else
    skip "squash-merged -> SAFE (without any PR lookup)" \
        "content containment needs merge-tree; degraded path covered by the fallback section"
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
echo "-- 5c: ambiguity and errors classify KEEP, never SAFE --"
# ---------------------------------------------------------------------------
# feature/pr-merged: content NOT contained (main moved past it), so only the
# forge lookup can clear it.
PR_LOOKUP_MODE="merged"
assert_eq "merged PR clears a branch main has moved past" "SAFE" "$(loss_check feature/pr-merged)"
PR_LOOKUP_MODE="fail"
assert_eq "forge lookup unavailable -> KEEP (not SAFE)" "KEEP" "$(loss_check feature/pr-merged)"
PR_LOOKUP_MODE="none"
assert_eq "no merged PR found -> UNSAFE" "UNSAFE" "$(loss_check feature/pr-merged)"

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

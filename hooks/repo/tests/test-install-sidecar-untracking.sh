#!/usr/bin/env bash
# Regression suite for install.sh's tracked-`.install-local.json` detection.
#
# Usage: ./hooks/repo/tests/test-install-sidecar-untracking.sh
# Exit code 0 = all tests pass, 1 = failures detected.
#
# Structured like test-install-claude-md-markers.sh next door: pure bash, no
# test framework, PASS/FAIL counters and a summary block, scratch git repos the
# real install.sh is driven against.
#
# The bug under test (repo#96): the sidecar is machine-local and gitignored, but
# gitignoring a path never untracks one that is ALREADY tracked (pre-split
# installs, or a repo that accidentally committed it). Whoever later notices the
# file showing as modified and "fixes" it with `git rm --cached` produces a
# commit whose tree says the file no longer exists — so every OTHER checkout
# that pulls that commit has its working-tree copy DELETED, silently destroying
# the source pointer /repo:update-tools and /repo:followups read. Before this
# change install.sh had no tracked-path detection at all, so that untracking
# happened outside the installer with no warning about the consequence.
#
# The contract asserted below:
#   - tracked sidecar  -> `git rm --cached` staged in the same install run, the
#     working-tree file survives with FRESH content, and the output explains the
#     pull-deletes-the-sidecar consequence plus the re-run-the-installer remedy
#   - untracked sidecar (the common case) -> byte-for-byte unchanged behavior:
#     no index mutation, no new warning lines
#   - the detection is not gated on --dev, and it coexists with the .gitignore
#     append in a repo that has no .gitignore yet

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
SIDECAR=".claude/skills/repo/.install-local.json"

PASS=0
FAIL=0
TOTAL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

if [[ ! -f "$INSTALL_SH" ]]; then
    echo "FATAL: install.sh not found at $INSTALL_SH" >&2
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
    [[ -n "${2:-}" ]] && printf "%s\n" "$2" | sed 's/^/        /'
    return 0
}
assert_eq() {  # <label> <expected> <actual>
    if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1" "expected [$2], got [$3]"; fi
}
assert_contains() {  # <label> <haystack> <needle>
    if [[ "$2" == *"$3"* ]]; then ok "$1"; else no "$1" "missing [$3]"; fi
}
assert_not_contains() {  # <label> <haystack> <needle>
    if [[ "$2" != *"$3"* ]]; then ok "$1"; else no "$1" "unexpectedly present: [$3]"; fi
}

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

# git in a scratch repo must not depend on (or be blocked by) the developer's
# global identity / signing configuration.
g() {  # <repo> <git args...>
    local r="$1"; shift
    git -C "$r" \
        -c user.email=test@example.com \
        -c user.name='Repo Skills Test' \
        -c commit.gpgsign=false \
        "$@"
}

new_target() {  # <name> -> prints the target path
    local t="$SCRATCH/$1"
    mkdir -p "$t"
    git init -q "$t" 2>/dev/null
    # A repo with at least one commit behaves like a real consumer repo (HEAD
    # resolves), which the tracked-sidecar fixtures below depend on.
    printf '%s\n' '# scratch' > "$t/README.md"
    g "$t" add README.md
    g "$t" commit -q -m "initial"
    printf '%s' "$t"
}

# Commit a sidecar into the target, simulating a pre-split / accidentally
# committed `.install-local.json` sitting in the tree at upgrade time.
track_sidecar() {  # <target>
    mkdir -p "$1/.claude/skills/repo"
    printf '%s\n' '{"source":"/old/stale/path","installed_at":"2020-01-01T00:00:00Z"}' \
        > "$1/$SIDECAR"
    g "$1" add -f "$SIDECAR"
    g "$1" commit -q -m "accidentally commit the machine-local sidecar"
}

# Is the path currently tracked in the index?
is_tracked() {  # <target> -> "yes" | "no"
    if git -C "$1" ls-files --error-unmatch "$SIDECAR" >/dev/null 2>&1; then
        echo yes
    else
        echo no
    fi
}

# Staged status letter for the sidecar (D = staged deletion from the index),
# or "none" when the path has no staged change.
staged_status() {  # <target>
    local s
    s="$(g "$1" diff --cached --name-status -- "$SIDECAR" | awk 'NR==1{print $1}')"
    printf '%s' "${s:-none}"
}

# ===========================================================================
echo "install.sh tracked-sidecar untracking suite"
echo "==========================================="

# ---------------------------------------------------------------------------
echo ""
echo "-- tracked sidecar: install stages the untracking and explains it (repo#96) --"

T1="$(new_target tracked-sidecar)"
track_sidecar "$T1"
assert_eq "tracked: fixture really is tracked before install" "yes" "$(is_tracked "$T1")"

OUT1="$(bash "$INSTALL_SH" -y "$T1" 2>&1)"; RC1=$?

assert_eq "tracked: install exits 0" "0" "$RC1"
assert_eq "tracked: sidecar is no longer in the index" "no" "$(is_tracked "$T1")"
assert_eq "tracked: untracking is STAGED (index deletion, vs HEAD)" "D" "$(staged_status "$T1")"

# --cached must never touch the working tree: the file the installer just wrote
# has to survive locally, with FRESH content, not the stale committed content.
if [[ -f "$T1/$SIDECAR" ]]; then
    ok "tracked: working-tree sidecar still exists"
else
    no "tracked: working-tree sidecar still exists" "file was deleted by git rm"
fi
BODY1="$(cat "$T1/$SIDECAR" 2>/dev/null)"
assert_contains     "tracked: sidecar content is freshly written (source)" "$BODY1" "\"source\": \"$REPO_ROOT\""
assert_contains     "tracked: sidecar content is freshly written (installed_at)" "$BODY1" '"installed_at"'
assert_not_contains "tracked: stale committed content is gone" "$BODY1" "/old/stale/path"

assert_contains "tracked: warns the sidecar was already tracked" \
                "$OUT1" "$SIDECAR was already tracked in git"
assert_contains "tracked: names the staging mechanism"          "$OUT1" "git rm --cached"
assert_contains "tracked: explains the pull-deletes consequence" \
                "$OUT1" "will DELETE the"
assert_contains "tracked: says which checkouts are affected"    "$OUT1" "every OTHER checkout that pulls the"
assert_contains "tracked: gives the re-create hint"             "$OUT1" "re-run this installer"
assert_contains "tracked: still wrote the sidecar"              "$OUT1" "Wrote .install-local.json"

# The gitignore-append path is independent of the untracking and must also run
# in the same pass (this fixture starts with no .gitignore at all).
if [[ -f "$T1/.gitignore" ]] && grep -qxF "$SIDECAR" "$T1/.gitignore"; then
    ok "tracked: .gitignore was created with the sidecar entry"
else
    no "tracked: .gitignore was created with the sidecar entry" \
       "$(cat "$T1/.gitignore" 2>/dev/null || echo '<no .gitignore>')"
fi

# Idempotence: a second run finds nothing tracked, so it must say nothing new.
OUT1B="$(bash "$INSTALL_SH" -y "$T1" 2>&1)"
assert_not_contains "tracked: re-install does not re-warn" "$OUT1B" "was already tracked in git"
assert_eq "tracked: re-install leaves the sidecar untracked" "no" "$(is_tracked "$T1")"

# ---------------------------------------------------------------------------
echo ""
echo "-- untracked sidecar (common case): behavior unchanged --"

T2="$(new_target untracked-sidecar)"
OUT2="$(bash "$INSTALL_SH" -y "$T2" 2>&1)"; RC2=$?

assert_eq "untracked: install exits 0" "0" "$RC2"
assert_eq "untracked: sidecar is not tracked" "no" "$(is_tracked "$T2")"
assert_eq "untracked: nothing staged for the sidecar" "none" "$(staged_status "$T2")"
assert_eq "untracked: index has no staged changes at all" "" "$(g "$T2" diff --cached --name-only)"
assert_not_contains "untracked: no tracked-sidecar warning" "$OUT2" "was already tracked in git"
assert_not_contains "untracked: no rm --cached mention"     "$OUT2" "git rm --cached"
assert_not_contains "untracked: no pull-deletes warning"    "$OUT2" "will DELETE the"
assert_contains     "untracked: sidecar was still written"  "$OUT2" "Wrote .install-local.json"

if [[ -f "$T2/$SIDECAR" ]]; then
    ok "untracked: sidecar exists in the working tree"
else
    no "untracked: sidecar exists in the working tree" "file missing"
fi

# ---------------------------------------------------------------------------
echo ""
echo "-- edge: tracked sidecar under --dev (detection is not \$DEV-gated) --"

T3="$(new_target tracked-dev)"
track_sidecar "$T3"
OUT3="$(bash "$INSTALL_SH" -y --dev "$T3" 2>&1)"; RC3=$?

assert_eq "dev: install exits 0" "0" "$RC3"
assert_eq "dev: sidecar untracked despite --dev" "no" "$(is_tracked "$T3")"
assert_eq "dev: untracking is staged"            "D"  "$(staged_status "$T3")"
assert_contains "dev: warning still printed" "$OUT3" "was already tracked in git"
if [[ -f "$T3/$SIDECAR" ]]; then
    ok "dev: working-tree sidecar survives"
else
    no "dev: working-tree sidecar survives" "file was deleted"
fi

# ---------------------------------------------------------------------------
echo ""
echo "-- edge: sidecar tracked AND already listed in .gitignore --"

# git keeps tracking a file regardless of .gitignore once it is in the index,
# and `check-ignore` consults the index — so a TRACKED path reports as "not
# ignored" (exit 1) even with an exact .gitignore line for it. Tracked-ness and
# ignored-ness are orthogonal and check-ignore answers neither question here;
# only `ls-files --error-unmatch` does. This fixture pins that: it is exactly
# the state where the pre-existing check-ignore gate sees nothing to do.
T4="$(new_target tracked-and-ignored)"
printf '%s\n' "$SIDECAR" > "$T4/.gitignore"
g "$T4" add .gitignore
g "$T4" commit -q -m "gitignore the sidecar"
track_sidecar "$T4"
assert_eq "tracked+ignored: .gitignore lists the sidecar exactly once" \
          "1" "$(grep -cxF "$SIDECAR" "$T4/.gitignore")"
assert_eq "tracked+ignored: check-ignore says NOT ignored while tracked" \
          "1" "$(git -C "$T4" check-ignore -q "$SIDECAR"; echo $?)"
assert_eq "tracked+ignored: ls-files is what detects it" "yes" "$(is_tracked "$T4")"

OUT4="$(bash "$INSTALL_SH" -y "$T4" 2>&1)"; RC4=$?
assert_eq "tracked+ignored: install exits 0" "0" "$RC4"
assert_eq "tracked+ignored: sidecar untracked" "no" "$(is_tracked "$T4")"
assert_contains "tracked+ignored: warning printed" "$OUT4" "was already tracked in git"
assert_eq "tracked+ignored: check-ignore now says ignored" \
          "0" "$(git -C "$T4" check-ignore -q "$SIDECAR"; echo $?)"
assert_eq "tracked+ignored: .gitignore not duplicated" \
          "1" "$(grep -cxF "$SIDECAR" "$T4/.gitignore")"

# ---------------------------------------------------------------------------
echo ""
echo "-- multi-checkout simulation: the consequence the warning describes --"

# Document (and pin) the git behavior this issue is about: committing the staged
# untracking and pulling it elsewhere DELETES that checkout's working-tree copy,
# and re-running the installer there is the correct remedy.
T5="$(new_target multi-checkout-origin)"
track_sidecar "$T5"
bash "$INSTALL_SH" -y "$T5" >/dev/null 2>&1
g "$T5" commit -q -m "untrack the machine-local sidecar"

CLONE="$SCRATCH/multi-checkout-clone"
git clone -q "$T5" "$CLONE" 2>/dev/null
# The clone is made AFTER the untracking commit, so re-point it at the parent of
# that commit to model a checkout that predates it, then pull the commit in.
g "$CLONE" checkout -q HEAD~1
if [[ -f "$CLONE/$SIDECAR" ]]; then
    ok "multi-checkout: pre-untracking checkout has the sidecar"
else
    no "multi-checkout: pre-untracking checkout has the sidecar" "file missing"
fi
g "$CLONE" checkout -q "$(g "$T5" rev-parse HEAD)"
if [[ ! -f "$CLONE/$SIDECAR" ]]; then
    ok "multi-checkout: pulling the untracking commit DELETES the sidecar there"
else
    no "multi-checkout: pulling the untracking commit DELETES the sidecar there" \
       "file unexpectedly survived"
fi

# The remedy the warning advertises must actually work.
OUT5="$(bash "$INSTALL_SH" -y "$CLONE" 2>&1)"; RC5=$?
assert_eq "multi-checkout: re-running the installer exits 0" "0" "$RC5"
if [[ -f "$CLONE/$SIDECAR" ]]; then
    ok "multi-checkout: re-running the installer regenerates the sidecar"
else
    no "multi-checkout: re-running the installer regenerates the sidecar" "file missing"
fi
assert_eq "multi-checkout: regenerated sidecar is untracked" "no" "$(is_tracked "$CLONE")"
assert_not_contains "multi-checkout: no tracked-sidecar warning on the remedy run" \
                    "$OUT5" "was already tracked in git"

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

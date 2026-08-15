#!/usr/bin/env bash
# test-managed-worktree-lib.sh — Tests for lib/managed-worktree.sh (issue #304)
#
# worktree.sh, pr-worktree.sh, and docs-worktree.sh each independently
# hand-rolled their own "create a Loom-managed worktree" sequence (concurrency
# lock, .loom-managed sentinel write, .mcp.json symlink + info/exclude
# bookkeeping). pr-worktree.sh and docs-worktree.sh were missing the
# concurrency lock entirely — confirmed by grep before this extraction — which
# left them exposed to the exact `git worktree add` / `.git/config.lock` race
# issue #3380 fixed only in worktree.sh. This suite exercises the shared
# implementation directly (unit-level), while test-worktree-concurrency.sh /
# test-worktree-nested-symlinks.sh / test-worktree-sentinel*.sh continue to
# exercise it indirectly through worktree.sh, and test-pr-worktree-isolation.sh
# / test-docs-worktree.sh through the two smaller scripts.
#
# Coverage:
#   1. loom_wt_write_sentinel: header/footer + optional metadata/footer lines.
#   2. loom_wt_append_exclude: idempotent (no duplicate lines on repeat calls).
#   3. loom_wt_symlink_mcp_json: symlinks + records the exclude entry; no-ops
#      when the main .mcp.json is missing or the worktree already has one.
#   4. loom_wt_acquire_lock / loom_wt_release_lock: mutual exclusion across
#      TWO DISTINCT shell processes (simulating two different caller scripts),
#      and a documented timeout with WORKTREE_LOCK_HOLDER_PID set.
#   5. All three caller scripts (worktree.sh, pr-worktree.sh, docs-worktree.sh)
#      source this exact file — a stale copy-pasted lock implementation could
#      not silently reappear without this test catching the missing `source`.
#
# Hermetic: mktemp -d sandboxes only, no forge/network calls.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$SCRIPTS_DIR/lib/managed-worktree.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass() { TESTS_RUN=$((TESTS_RUN + 1)); TESTS_PASSED=$((TESTS_PASSED + 1)); echo -e "  ${GREEN}PASS${NC}: $1"; }
fail() { TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1)); echo -e "  ${RED}FAIL${NC}: $1"; }

assert_grep() {
    local pattern="$1" file="$2" msg="$3"
    if [[ -f "$file" ]] && grep -qxF "$pattern" "$file"; then pass "$msg"; else fail "$msg (missing line '$pattern' in $file)"; fi
}

if [[ ! -f "$LIB" ]]; then
    echo "FAIL: lib/managed-worktree.sh missing at $LIB"
    exit 1
fi

TMP=$(mktemp -d /tmp/loom-managed-wt-lib.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# --- Test 0: all three caller scripts source this exact file --------------
echo "Test 0: worktree.sh / pr-worktree.sh / docs-worktree.sh all source the shared lib"
for caller in worktree.sh pr-worktree.sh docs-worktree.sh; do
    if grep -q 'lib/managed-worktree\.sh' "$SCRIPTS_DIR/$caller" 2>/dev/null; then
        pass "$caller sources lib/managed-worktree.sh"
    else
        fail "$caller does not source lib/managed-worktree.sh"
    fi
done

# shellcheck source=../lib/managed-worktree.sh
source "$LIB"

# --- Test 1: loom_wt_write_sentinel ----------------------------------------
echo ""
echo "Test 1: loom_wt_write_sentinel"
WT1="$TMP/wt1"
mkdir -p "$WT1"
loom_wt_write_sentinel "$WT1" "unit-test.sh"
assert_grep "# Loom-managed worktree marker" "$WT1/.loom-managed" \
    "no-metadata call writes the header"
assert_grep "# Created by .loom/scripts/unit-test.sh" "$WT1/.loom-managed" \
    "no-metadata call records the calling script"
assert_grep "# to clean it up automatically." "$WT1/.loom-managed" \
    "no-metadata call writes the standard footer"

WT2="$TMP/wt2"
mkdir -p "$WT2"
loom_wt_write_sentinel "$WT2" "unit-test.sh" "# Issue: 42" "# Extra footer note"
assert_grep "# Issue: 42" "$WT2/.loom-managed" \
    "metadata line is written between header and standard footer"
assert_grep "# Extra footer note" "$WT2/.loom-managed" \
    "caller-supplied footer is appended after the standard footer"

# The write is a plain overwrite — must be idempotent / self-healing.
rm -f "$WT2/.loom-managed"
loom_wt_write_sentinel "$WT2" "unit-test.sh" "# Issue: 42"
if [[ -f "$WT2/.loom-managed" ]]; then
    pass "re-invoking after deletion restores the sentinel (self-heals, #3548)"
else
    fail "sentinel not restored on re-invoke"
fi

# --- Test 2: loom_wt_append_exclude idempotency -----------------------------
echo ""
echo "Test 2: loom_wt_append_exclude"
WT3="$TMP/wt3"
git init -q -b main "$WT3"
loom_wt_append_exclude "$WT3" "some/generated/path"
loom_wt_append_exclude "$WT3" "some/generated/path"
loom_wt_append_exclude "$WT3" "some/generated/path"
EXCLUDE_FILE="$(git -C "$WT3" rev-parse --git-path info/exclude 2>/dev/null)"
[[ "$EXCLUDE_FILE" == /* ]] || EXCLUDE_FILE="$WT3/$EXCLUDE_FILE"
COUNT=$(grep -cxF "some/generated/path" "$EXCLUDE_FILE" 2>/dev/null || echo 0)
if [[ "$COUNT" == "1" ]]; then
    pass "repeated appends of the same entry are idempotent (no duplication)"
else
    fail "expected exactly 1 occurrence, got $COUNT"
fi

# --- Test 3: loom_wt_symlink_mcp_json ---------------------------------------
echo ""
echo "Test 3: loom_wt_symlink_mcp_json"
MAIN_WS="$TMP/main-ws"
mkdir -p "$MAIN_WS"
WT4="$TMP/wt4"
git init -q -b main "$WT4"

# No main .mcp.json -> silent no-op, returns 0.
if loom_wt_symlink_mcp_json "$MAIN_WS" "$WT4"; then
    pass "missing main .mcp.json -> returns 0 (silent no-op)"
else
    fail "missing main .mcp.json should not be a failure"
fi
if [[ -e "$WT4/.mcp.json" ]]; then
    fail "a .mcp.json symlink was created despite no main .mcp.json existing"
else
    pass "no .mcp.json symlink created when the main workspace has none"
fi

echo '{"mcpServers":{}}' > "$MAIN_WS/.mcp.json"
loom_wt_symlink_mcp_json "$MAIN_WS" "$WT4"
if [[ -L "$WT4/.mcp.json" ]]; then
    pass ".mcp.json symlinked from the main workspace"
else
    fail ".mcp.json was not symlinked"
fi
EXCLUDE_FILE4="$(git -C "$WT4" rev-parse --git-path info/exclude 2>/dev/null)"
[[ "$EXCLUDE_FILE4" == /* ]] || EXCLUDE_FILE4="$WT4/$EXCLUDE_FILE4"
assert_grep ".mcp.json" "$EXCLUDE_FILE4" \
    "the .mcp.json symlink is recorded in info/exclude"

# Re-invoke: worktree already has .mcp.json -> silent no-op, no duplicate exclude line.
loom_wt_symlink_mcp_json "$MAIN_WS" "$WT4"
COUNT4=$(grep -cxF ".mcp.json" "$EXCLUDE_FILE4" 2>/dev/null || echo 0)
if [[ "$COUNT4" == "1" ]]; then
    pass "re-invoking with an existing worktree .mcp.json is idempotent"
else
    fail "expected exactly 1 exclude entry after re-invoke, got $COUNT4"
fi

# --- Test 4: loom_wt_acquire_lock / loom_wt_release_lock across processes ---
echo ""
echo "Test 4: loom_wt_acquire_lock / loom_wt_release_lock (cross-process mutual exclusion)"
LOCK_REPO="$TMP/lock-repo"
git init -q -b main "$LOCK_REPO"

# 4a. Two DISTINCT shell processes (simulating two different caller scripts,
# e.g. worktree.sh and pr-worktree.sh) contending for the same lock: the
# second must wait for the first to release rather than both proceeding.
(
    cd "$LOCK_REPO" || exit 1
    # shellcheck source=../lib/managed-worktree.sh
    source "$LIB"
    loom_wt_acquire_lock "42" "worktree.sh" "false" || exit 1
    sleep 2
    loom_wt_release_lock
) &
HOLDER_PID=$!
sleep 0.5

START_TS=$(date +%s)
(
    cd "$LOCK_REPO" || exit 1
    # shellcheck source=../lib/managed-worktree.sh
    source "$LIB"
    LOOM_WORKTREE_LOCK_POLL_INTERVAL=1 loom_wt_acquire_lock "pr-99" "pr-worktree.sh" "false"
)
SECOND_RC=$?
END_TS=$(date +%s)
wait "$HOLDER_PID" 2>/dev/null || true

ELAPSED=$((END_TS - START_TS))
if [[ "$SECOND_RC" -eq 0 && "$ELAPSED" -ge 1 ]]; then
    pass "a second caller (different owner/script) waits for the first holder's release (waited ${ELAPSED}s)"
else
    fail "expected the second caller to wait >=1s and then succeed (rc=$SECOND_RC, elapsed=${ELAPSED}s)"
fi
loom_wt_release_lock

# 4b. Timeout path sets WORKTREE_LOCK_HOLDER_PID and returns non-zero.
mkdir -p "$LOCK_REPO/.loom/locks/worktree-add"
cat > "$LOCK_REPO/.loom/locks/worktree-add/owner.json" <<EOF
{
  "owner": "docs-guide",
  "owner_pid": $$,
  "script": "docs-worktree.sh",
  "acquired_at": "1970-01-01T00:00:00Z"
}
EOF
(
    cd "$LOCK_REPO" || exit 1
    if LOOM_WORKTREE_LOCK_TIMEOUT=1 LOOM_WORKTREE_LOCK_POLL_INTERVAL=1 \
        loom_wt_acquire_lock "601" "worktree.sh" "false"; then
        echo "RC=0"
    else
        echo "RC=1 HOLDER=$WORKTREE_LOCK_HOLDER_PID"
    fi
) > "$TMP/timeout-out.txt" 2>&1
if grep -q "RC=1 HOLDER=$$" "$TMP/timeout-out.txt"; then
    pass "timeout path returns non-zero and sets WORKTREE_LOCK_HOLDER_PID to the live holder"
else
    fail "unexpected timeout-path output: $(cat "$TMP/timeout-out.txt")"
fi
rm -rf "$LOCK_REPO/.loom/locks/worktree-add"

# --- Summary ---
echo ""
echo "Tests run: $TESTS_RUN, Passed: $TESTS_PASSED, Failed: $TESTS_FAILED"
[[ $TESTS_FAILED -eq 0 ]] || exit 1

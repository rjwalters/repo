#!/usr/bin/env bash
# test-random-file-gitignore.sh - Regression tests for random-file.sh's
# gitignore/exclusion filtering on the `find` fallback path (issue #379).
#
# Two bugs previously let gitignored/excluded paths leak through when `fd`
# is not on PATH:
#
#   1. apply_exclusions() classified any DEFAULT_EXCLUDES entry containing a
#      literal "." (e.g. ".git", ".loom/worktrees") as a file pattern instead
#      of a directory name, so it was end-anchored and never matched files
#      *inside* those directories.
#   2. gitignore_to_regex()'s directory-only branch (patterns ending in "/")
#      hardcoded a leading "/" instead of anchoring with "(^|/)" like every
#      other branch, so a directory-only .gitignore entry never matched when
#      that directory was the first path segment of a relative path.
#
# This suite builds a scratch git repo with exactly this shape (a nested
# ".git"-style path, a ".loom/worktrees/..." scratch copy, a ".claude/"
# gitignored dev-mode dir, and a gitignored "hooks/logs/" dir) and asserts
# random-file.sh -- run with `fd` hidden from PATH, forcing the `find`
# fallback -- never returns a path under any of them, across many runs
# (RANDOM-based selection means a single run isn't a reliable check).
#
# Usage:
#   bash .loom/scripts/tests/test-random-file-gitignore.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RANDOM_FILE_SH="$SCRIPT_DIR/../random-file.sh"

if [[ ! -f "$RANDOM_FILE_SH" ]]; then
    echo "SKIP: $RANDOM_FILE_SH not found (not an installed Loom repo)" >&2
    exit 0
fi

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
TESTS_RUN=0; TESTS_PASSED=0; TESTS_FAILED=0

pass() { TESTS_RUN=$((TESTS_RUN + 1)); TESTS_PASSED=$((TESTS_PASSED + 1)); echo -e "  ${GREEN}PASS${NC}: $1"; }
fail() { TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1)); echo -e "  ${RED}FAIL${NC}: $1"; }

FIXTURE_ROOT="$(mktemp -d)"
EMPTY_BIN="$(mktemp -d)"

cleanup() {
    rm -rf "$FIXTURE_ROOT" "$EMPTY_BIN"
}
trap cleanup EXIT

# --- Build a scratch git repo shaped like the leakage report in #379 ---
mkdir -p \
    "$FIXTURE_ROOT/src" \
    "$FIXTURE_ROOT/.loom/scripts" \
    "$FIXTURE_ROOT/.loom/worktrees/pr-361/.loom/scripts" \
    "$FIXTURE_ROOT/.claude/worktrees/agent-abc/.loom/scripts" \
    "$FIXTURE_ROOT/hooks/logs" \
    "$FIXTURE_ROOT/node_modules/pkg"

git -C "$FIXTURE_ROOT" init -q
git -C "$FIXTURE_ROOT" config user.email "test@example.com"
git -C "$FIXTURE_ROOT" config user.name "Test"

cat > "$FIXTURE_ROOT/.gitignore" <<'EOF'
node_modules
.claude/
hooks/logs/
.loom/worktrees/
EOF

echo "console.log(1)"   > "$FIXTURE_ROOT/src/index.ts"
echo "readme"            > "$FIXTURE_ROOT/README.md"
echo "build gate"        > "$FIXTURE_ROOT/.loom/scripts/build-gate.sh"
echo "leak candidate 1"  > "$FIXTURE_ROOT/.loom/worktrees/pr-361/.loom/scripts/build-gate.sh"
echo "leak candidate 2"  > "$FIXTURE_ROOT/.claude/worktrees/agent-abc/.loom/scripts/build-gate.sh"
echo "log leak"          > "$FIXTURE_ROOT/hooks/logs/foo.log"
echo "dep"                > "$FIXTURE_ROOT/node_modules/pkg/index.js"

git -C "$FIXTURE_ROOT" add src README.md .gitignore .loom/scripts
git -C "$FIXTURE_ROOT" commit -q -m "init"

# Install the script under test into the fixture's own .loom/scripts/ so
# WORKSPACE_ROOT (computed from $SCRIPT_DIR/../..) resolves to $FIXTURE_ROOT.
cp "$RANDOM_FILE_SH" "$FIXTURE_ROOT/.loom/scripts/random-file.sh"
chmod +x "$FIXTURE_ROOT/.loom/scripts/random-file.sh"

# Force the `find` fallback path: an empty PATH dir first means `fd` is
# never found by `command -v fd`.
FORCED_PATH="$EMPTY_BIN:/usr/bin:/bin"

run_once() {
    (cd "$FIXTURE_ROOT" && PATH="$FORCED_PATH" ./.loom/scripts/random-file.sh 2>&1)
}

# --- Case 1: no leaked path across many runs (RANDOM-based selection) ---
echo "Case 1: no gitignored/excluded path leaks across 60 find-fallback runs"
LEAK_COUNT=0
RUN_FAILURES=0
for _ in $(seq 1 60); do
    out="$(run_once)"
    if [[ -z "$out" ]]; then
        RUN_FAILURES=$((RUN_FAILURES + 1))
        continue
    fi
    rel="${out#"$FIXTURE_ROOT"/}"
    case "$rel" in
        .git/*|*/.git/*|.loom/worktrees/*|.claude/worktrees/*|hooks/logs/*|node_modules/*|*/node_modules/*)
            LEAK_COUNT=$((LEAK_COUNT + 1))
            echo "    leaked: $rel" >&2
            ;;
    esac
done

if [[ "$RUN_FAILURES" -gt 0 ]]; then
    fail "Case 1: script ran without error ($RUN_FAILURES/60 runs produced no output)"
elif [[ "$LEAK_COUNT" -eq 0 ]]; then
    pass "Case 1: 0/60 runs leaked a gitignored/excluded path"
else
    fail "Case 1: $LEAK_COUNT/60 runs leaked a gitignored/excluded path"
fi

# --- Case 2: legitimate tracked files are still reachable ---
echo "Case 2: legitimate tracked files still appear across repeated runs"
FOUND_SRC=0
FOUND_README=0
FOUND_BUILD_GATE=0
for _ in $(seq 1 60); do
    out="$(run_once)"
    rel="${out#"$FIXTURE_ROOT"/}"
    case "$rel" in
        src/index.ts) FOUND_SRC=1 ;;
        README.md) FOUND_README=1 ;;
        .loom/scripts/build-gate.sh) FOUND_BUILD_GATE=1 ;;
    esac
done

if [[ "$FOUND_SRC" -eq 1 && "$FOUND_README" -eq 1 && "$FOUND_BUILD_GATE" -eq 1 ]]; then
    pass "Case 2: src/index.ts, README.md, and .loom/scripts/build-gate.sh all remained reachable"
else
    fail "Case 2: some legitimate tracked file never appeared (src=$FOUND_SRC readme=$FOUND_README build_gate=$FOUND_BUILD_GATE)"
fi

# --- Summary ---
echo ""
echo "  Total: $TESTS_RUN  Passed: $TESTS_PASSED  Failed: $TESTS_FAILED"

[[ "$TESTS_FAILED" -eq 0 ]]

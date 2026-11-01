#!/usr/bin/env bash
# Test suite for /repo:deps CI value `none` (repo#731): a repo with no
# workflows needs an evidence bar for bot-PR merges.
#
# Usage: ./commands/repo/tests/test-deps-no-ci.sh
# Exit code 0 = all tests pass, 1 = failures detected.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
DEPS_MD="$REPO_ROOT/commands/repo/deps.md"
ALL_MD="$REPO_ROOT/commands/repo/all.md"

source "$(dirname "${BASH_SOURCE[0]}")/lib/assert.sh"

for f in "$DEPS_MD" "$ALL_MD"; do
    [[ -f "$f" ]] || { echo "FATAL: required file not found at $f" >&2; exit 1; }
done

DEPS_FLAT="$(flatten "$DEPS_MD")"
ALL_FLAT="$(flatten "$ALL_MD")"

echo "1. Step 8 defines CI value none, distinct from pending"
assert_contains "four CI values named" "$DEPS_FLAT" \
    'takes four values: `green`, `red`, `pending`, and **`none`**'
assert_contains "none = no workflows" "$DEPS_FLAT" "the repo has **no workflows**"
assert_contains "none is distinct from pending" "$DEPS_FLAT" "It is **distinct from \`pending\`**"
assert_contains "uncovered ecosystem is not none" "$DEPS_FLAT" "is **not** \`none\`"

echo ""
echo "2. Local-check substitute and CI-column format"
assert_contains "temporary worktree" "$DEPS_FLAT" "temporary worktree"
assert_contains "cargo command" "$DEPS_FLAT" '`cargo check`'
assert_contains "uv command" "$DEPS_FLAT" '`uv sync --locked && python -m compileall .`'
assert_contains "npm command" "$DEPS_FLAT" '`npm ci && npm run build`'
assert_contains "ok format" "$DEPS_FLAT" 'none; local <command> ok'
assert_contains "failed format" "$DEPS_FLAT" 'none; local <command> failed'

echo ""
echo "3. Step 9 never merges a none PR on title alone"
assert_contains "never on title alone" "$DEPS_FLAT" "never merged on its title alone"
assert_contains "majors keep own confirmation" "$DEPS_FLAT" "majors still get their own separate confirmation"
assert_contains "recommends adding CI" "$DEPS_FLAT" "recommends adding CI"

echo ""
echo "4. /repo:all Deps: line carries no CI"
assert_contains "no CI caveat" "$ALL_FLAT" '**`no CI` caveat**'
assert_matches "example line" "$(cat "$ALL_MD")" '^Deps:.*no CI —'

echo ""
echo "========================================="
echo "  Total:  $TOTAL"
printf "  ${GREEN}Passed${NC}: %s\n" "$PASS"
printf "  ${RED}Failed${NC}: %s\n" "$FAIL"
echo "========================================="
[[ $FAIL -gt 0 ]] && { printf "\n${RED}TESTS FAILED${NC}\n"; exit 1; }
printf "\n${GREEN}ALL TESTS PASSED${NC}\n"

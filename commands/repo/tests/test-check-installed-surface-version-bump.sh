#!/usr/bin/env bash
# Test suite for scripts/check-installed-surface-version-bump.sh — the CI gate
# that fails a PR touching this repo's installed surface (commands/, skills/,
# hooks/, lib/, install.sh, uninstall.sh, scripts/repo/) without either
# bumping VERSION or declaring the `<!-- loom:no-surface-change -->` marker
# (#387, #416).
#
# Structured like .loom/scripts/tests/test-check-defaults-version-bump.sh
# (the vendored upstream sibling this wrapper mirrors the contract of): a
# throwaway scratch git repo fixture, exercised against every branch of the
# gate's decision tree. `pnpm test` delegates to this file via
# hooks/repo/tests/run.sh.
#
# Usage: ./commands/repo/tests/test-check-installed-surface-version-bump.sh
# Exit code 0 = all tests pass, 1 = failures detected.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/check-installed-surface-version-bump.sh"

# Assertion helpers (ok/no/skip/assert_eq/assert_contains/assert_not_contains/
# assert_matches) plus the PASS/FAIL/SKIP/TOTAL counters and color vars are
# shared across the repo test suites — see lib/assert.sh (repo#307).
source "$(dirname "${BASH_SOURCE[0]}")/lib/assert.sh"

if [[ ! -x "$SCRIPT" ]]; then
    echo "FATAL: check-installed-surface-version-bump.sh missing or not executable at $SCRIPT" >&2
    exit 1
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/test-installed-surface-version-bump.XXXXXX")"
trap 'rm -rf "$WORKDIR" 2>/dev/null || true' EXIT

export GIT_AUTHOR_NAME="test" GIT_AUTHOR_EMAIL="test@example.com"
export GIT_COMMITTER_NAME="test" GIT_COMMITTER_EMAIL="test@example.com"

REPO="$WORKDIR/repo"

# Fresh repo with a base commit carrying commands/foo.md and VERSION=1.0.0,
# tagged "base". Callers add more commits on top and diff against "base".
make_fixture() {
    rm -rf "$REPO"
    git init --quiet "$REPO"
    git -C "$REPO" checkout -q -b main
    mkdir -p "$REPO/commands/repo"
    echo "hello" > "$REPO/commands/repo/foo.md"
    echo "1.0.0" > "$REPO/VERSION"
    echo "unrelated" > "$REPO/README.md"
    git -C "$REPO" add -A
    git -C "$REPO" commit -q -m "base"
    git -C "$REPO" tag base
}

echo "check-installed-surface-version-bump.sh test suite"
echo "===================================================="
echo ""

# ---------------------------------------------------------------------------
echo "-- case 1: no watched-surface change passes --"
# ---------------------------------------------------------------------------
make_fixture
echo "more" >> "$REPO/README.md"
git -C "$REPO" commit -q -am "readme only"
OUT="$(cd "$REPO" && "$SCRIPT" --base base 2>&1)"
STATUS=$?
assert_eq "no watched change exits 0" "0" "$STATUS"
assert_contains "no watched change prints OK" "$OUT" "OK"

# ---------------------------------------------------------------------------
echo ""
echo "-- case 2: watched-surface change + VERSION bump passes --"
# ---------------------------------------------------------------------------
make_fixture
echo "changed" >> "$REPO/commands/repo/foo.md"
echo "1.0.1" > "$REPO/VERSION"
git -C "$REPO" commit -q -am "bump"
OUT="$(cd "$REPO" && "$SCRIPT" --base base 2>&1)"
STATUS=$?
assert_eq "watched change + VERSION bump exits 0" "0" "$STATUS"

# ---------------------------------------------------------------------------
echo ""
echo "-- case 3: watched-surface change without a VERSION bump fails --"
# ---------------------------------------------------------------------------
make_fixture
echo "changed" >> "$REPO/commands/repo/foo.md"
git -C "$REPO" commit -q -am "command change, no bump"
ERR_OUT="$(cd "$REPO" && "$SCRIPT" --base base 2>&1 >/dev/null)"
RC=0
( cd "$REPO" && "$SCRIPT" --base base >/dev/null 2>&1 ) || RC=$?
assert_eq "unbumped watched change exits 1" "1" "$RC"
assert_contains "failure output lists the changed file" "$ERR_OUT" "commands/repo/foo.md"
assert_contains "failure output suggests the version bump remediation" "$ERR_OUT" "version.sh bump patch"
assert_contains "failure output mentions the no-surface-change marker escape hatch" "$ERR_OUT" "loom:no-surface-change"

# ---------------------------------------------------------------------------
echo ""
echo "-- case 4: skills/, hooks/, lib/, install.sh, uninstall.sh, scripts/repo/ are all watched --"
# ---------------------------------------------------------------------------
for path in "skills/repo/SKILL.md" "hooks/repo/guard.sh" "lib/foo.sh" "install.sh" "uninstall.sh" "scripts/repo/repo-remote.sh"; do
    make_fixture
    mkdir -p "$REPO/$(dirname "$path")"
    echo "changed" >> "$REPO/$path"
    git -C "$REPO" add -A
    git -C "$REPO" commit -q -m "touch $path, no bump"
    RC=0
    ERR_OUT="$(cd "$REPO" && "$SCRIPT" --base base 2>&1)" || RC=$?
    assert_eq "unbumped $path change exits 1" "1" "$RC"
    assert_contains "failure output lists $path" "$ERR_OUT" "$path"
done

# ---------------------------------------------------------------------------
echo ""
echo "-- case 5: scripts/repo/*.sh change without a VERSION bump fails (#416) --"
# ---------------------------------------------------------------------------
make_fixture
mkdir -p "$REPO/scripts/repo"
echo "changed" >> "$REPO/scripts/repo/resync-installed.sh"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "scripts/repo change, no bump"
RC=0
ERR_OUT="$(cd "$REPO" && "$SCRIPT" --base base 2>&1)" || RC=$?
assert_eq "unbumped scripts/repo/*.sh change exits 1" "1" "$RC"
assert_contains "failure output lists scripts/repo/resync-installed.sh" "$ERR_OUT" "scripts/repo/resync-installed.sh"

# ---------------------------------------------------------------------------
echo ""
echo "-- case 6: scripts/repo/*.sh change + VERSION bump passes --"
# ---------------------------------------------------------------------------
make_fixture
mkdir -p "$REPO/scripts/repo"
echo "changed" >> "$REPO/scripts/repo/resync-installed.sh"
echo "1.0.1" > "$REPO/VERSION"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "scripts/repo change + bump"
OUT="$(cd "$REPO" && "$SCRIPT" --base base 2>&1)"
STATUS=$?
assert_eq "scripts/repo/*.sh change + VERSION bump exits 0" "0" "$STATUS"

# ---------------------------------------------------------------------------
echo ""
echo "-- case 7: scripts/repo/*.sh change + no-surface-change marker passes --"
# ---------------------------------------------------------------------------
make_fixture
mkdir -p "$REPO/scripts/repo"
echo "changed" >> "$REPO/scripts/repo/resync-installed.sh"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "scripts/repo change

<!-- loom:no-surface-change -->"
OUT="$(cd "$REPO" && "$SCRIPT" --base base 2>&1)"
STATUS=$?
assert_eq "scripts/repo/*.sh change + marker exits 0" "0" "$STATUS"

# ---------------------------------------------------------------------------
echo ""
echo "-- case 8: watched-surface change + PR_BODY marker passes --"
# ---------------------------------------------------------------------------
make_fixture
echo "changed" >> "$REPO/commands/repo/foo.md"
git -C "$REPO" commit -q -am "doc typo fix"
OUT="$(cd "$REPO" && PR_BODY='fixes a typo

<!-- loom:no-surface-change -->' "$SCRIPT" --base base 2>&1)"
STATUS=$?
assert_eq "PR_BODY marker exits 0" "0" "$STATUS"

# ---------------------------------------------------------------------------
echo ""
echo "-- case 9: watched-surface change + commit-message marker passes --"
# ---------------------------------------------------------------------------
make_fixture
echo "changed" >> "$REPO/commands/repo/foo.md"
git -C "$REPO" commit -q -am "doc typo fix

<!-- loom:no-surface-change -->"
OUT="$(cd "$REPO" && "$SCRIPT" --base base 2>&1)"
STATUS=$?
assert_eq "commit-message marker exits 0" "0" "$STATUS"

# ---------------------------------------------------------------------------
echo ""
echo "-- case 10: a change under scripts/ but outside scripts/repo/ never requires a bump --"
# ---------------------------------------------------------------------------
make_fixture
mkdir -p "$REPO/scripts"
echo "changed" >> "$REPO/scripts/version.sh"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "unwatched scripts/ change"
OUT="$(cd "$REPO" && "$SCRIPT" --base base 2>&1)"
STATUS=$?
assert_eq "unwatched scripts/ (outside scripts/repo/) change exits 0" "0" "$STATUS"

# ---------------------------------------------------------------------------
echo ""
echo "-- case 11: usage / arg-handling --"
# ---------------------------------------------------------------------------
make_fixture
RC=0
( cd "$REPO" && "$SCRIPT" >/dev/null 2>&1 ) || RC=$?
assert_eq "missing --base exits 2" "2" "$RC"

RC=0
( cd "$REPO" && "$SCRIPT" --base does-not-exist >/dev/null 2>&1 ) || RC=$?
assert_eq "unknown --base ref exits 2" "2" "$RC"

HELP_OUT="$("$SCRIPT" --help 2>&1)"
STATUS=$?
assert_eq "--help exit code is 0" "0" "$STATUS"
assert_contains "--help mentions Usage" "$HELP_OUT" "Usage"

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

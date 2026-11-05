#!/usr/bin/env bash
# Test suite for the CHANGELOG-heading-per-VERSION contract (#769):
#   * scripts/check-changelog-version.sh fails when VERSION has no matching
#     CHANGELOG.md heading (and is a no-op without CHANGELOG.md).
#   * scripts/version.sh bump/set cuts `## Unreleased` into `## <new> (date)`.
#
# Usage: ./commands/repo/tests/test-changelog-version-heading.sh
# Exit code 0 = all tests pass, 1 = failures detected.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CHECK="$REPO_ROOT/scripts/check-changelog-version.sh"
VERSION_SH="$REPO_ROOT/scripts/version.sh"

source "$(dirname "${BASH_SOURCE[0]}")/lib/assert.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-fixture.sh"
git_fixture_scrub_env

for f in "$CHECK" "$VERSION_SH"; do
    [[ -f "$f" ]] || { echo "FATAL: $f not found" >&2; exit 1; }
done

SCRATCH="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$SCRATCH" 2>/dev/null || true' EXIT
export GIT_AUTHOR_NAME="test" GIT_AUTHOR_EMAIL="test@example.com"
export GIT_COMMITTER_NAME="test" GIT_COMMITTER_EMAIL="test@example.com"

# build <name> <version> [changelog-text]: fixture repo with copies of both scripts.
build() {
    local root="$SCRATCH/$1"
    rm -rf "$root"
    mkdir -p "$root/scripts"
    cp "$CHECK" "$root/scripts/check-changelog-version.sh"
    cp "$VERSION_SH" "$root/scripts/version.sh"
    chmod +x "$root/scripts/"*.sh
    printf '%s\n' "$2" > "$root/VERSION"
    printf "{\n  \"name\": \"fixture\",\n  \"version\": \"%s\"\n}\n" "$2" > "$root/package.json"
    [[ $# -ge 3 ]] && printf '%s' "$3" > "$root/CHANGELOG.md"
    git_fixture_init "$root"
    git -C "$root" checkout -q -b main
    git -C "$root" add -A
    git -C "$root" commit -q -m base
    REPO="$root"
}

# run_vs <args...>: run the fixture's version.sh from inside the fixture repo.
run_vs() { ( cd "$REPO" && ./scripts/version.sh "$@" >/dev/null 2>&1 ); }

echo "changelog heading per VERSION test suite"
echo "========================================="

echo "-- check: matching heading passes --"
build c1 1.2.3 $'# Changelog\n\n## Unreleased\n\n## 1.2.3 (2026-01-01)\n\n- x\n'
OUT="$("$REPO/scripts/check-changelog-version.sh" 2>&1)"; RC=$?
assert_eq "heading present exits 0" "0" "$RC"
assert_contains "reports ok" "$OUT" "ok:"

echo "-- check: bracketed Keep-a-Changelog heading passes --"
build c2 1.2.3 $'# Changelog\n\n## [1.2.3] - 2026-01-01\n'
"$REPO/scripts/check-changelog-version.sh" >/dev/null 2>&1; RC=$?
assert_eq "bracketed heading exits 0" "0" "$RC"

echo "-- check: missing heading fails --"
build c3 1.2.3 $'# Changelog\n\n## Unreleased\n\n- x\n\n## 1.2.2 (2026-01-01)\n'
OUT="$("$REPO/scripts/check-changelog-version.sh" 2>&1)"; RC=$?
assert_eq "missing heading exits 1" "1" "$RC"
assert_contains "names the version" "$OUT" "MISSING"

echo "-- check: 1.2.3 must not match 1.2.30 or 1X2X3 --"
build c4 1.2.3 $'# Changelog\n\n## 1.2.30 (2026-01-01)\n\n## 1X2X3 (2026-01-01)\n'
"$REPO/scripts/check-changelog-version.sh" >/dev/null 2>&1; RC=$?
assert_eq "near-miss headings do not satisfy the check" "1" "$RC"

echo "-- check: absent CHANGELOG.md is a no-op --"
build c5 1.2.3
"$REPO/scripts/check-changelog-version.sh" >/dev/null 2>&1; RC=$?
assert_eq "no CHANGELOG.md exits 0" "0" "$RC"

echo "-- version.sh bump cuts the heading --"
build b1 1.2.3 $'# Changelog\n\n## Unreleased\n\n- **thing (#1).** done\n\n## 1.2.3 (2026-01-01)\n\n- old\n'
run_vs bump patch; RC=$?
assert_eq "bump exits 0" "0" "$RC"
assert_matches "new heading cut with a date" "$(cat "$REPO/CHANGELOG.md")" '^## 1\.2\.4 \([0-9]{4}-[0-9]{2}-[0-9]{2}\)$'
FIRST_H2="$(grep -m1 '^## ' "$REPO/CHANGELOG.md")"
assert_eq "Unreleased stays the first heading" "## Unreleased" "$FIRST_H2"
LINE_BULLET="$(grep -n 'thing (#1)' "$REPO/CHANGELOG.md" | cut -d: -f1)"
LINE_NEW="$(grep -n '^## 1\.2\.4 ' "$REPO/CHANGELOG.md" | cut -d: -f1)"
LINE_OLD="$(grep -n '^## 1\.2\.3 ' "$REPO/CHANGELOG.md" | cut -d: -f1)"
if [[ "$LINE_NEW" -lt "$LINE_BULLET" && "$LINE_BULLET" -lt "$LINE_OLD" ]]; then
    ok "entry now sits under the new version heading"
else
    no "entry now sits under the new version heading (new=$LINE_NEW bullet=$LINE_BULLET old=$LINE_OLD)"
fi
"$REPO/scripts/check-changelog-version.sh" >/dev/null 2>&1; RC=$?
assert_eq "check passes after bump" "0" "$RC"
assert_contains "CHANGELOG.md is part of the bump commit" "$(git -C "$REPO" show --stat --format= HEAD)" "CHANGELOG.md"

echo "-- version.sh set is idempotent when the heading already exists --"
build b2 1.2.3 $'# Changelog\n\n## Unreleased\n\n## 1.3.0 (2026-01-01)\n\n- hand cut\n'
run_vs set 1.3.0; RC=$?
assert_eq "set exits 0" "0" "$RC"
assert_eq "no duplicate heading" "1" "$(grep -c '^## 1\.3\.0 ' "$REPO/CHANGELOG.md")"

echo "-- version.sh bump without an Unreleased heading leaves CHANGELOG alone --"
build b3 1.2.3 $'# Changelog\n\n## 1.2.3 (2026-01-01)\n'
run_vs bump patch; RC=$?
assert_eq "bump exits 0" "0" "$RC"
assert_eq "CHANGELOG unchanged" $'# Changelog\n\n## 1.2.3 (2026-01-01)' "$(cat "$REPO/CHANGELOG.md")"

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

#!/usr/bin/env bash
# Test suite for scripts/version.sh — this repo's single source of truth for
# VERSION, exercised via a scratch git fixture (#387).
#
# scripts/version.sh resolves its own root from $0's location
# ("$(dirname "$0")/..") rather than cwd, so each case copies the real script
# into a throwaway scratch repo at the same scripts/version.sh relative path
# and invokes the COPY — never the real repo's VERSION/package.json.
#
# Structured like commands/repo/tests/test-check-label-descriptions.sh: pure
# bash, no test framework, PASS/FAIL/TOTAL counters via lib/assert.sh, and a
# scratch-git fixture harness. `pnpm test` delegates to this file via
# hooks/repo/tests/run.sh.
#
# Usage: ./commands/repo/tests/test-version-script.sh
# Exit code 0 = all tests pass, 1 = failures detected.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SOURCE_SCRIPT="$REPO_ROOT/scripts/version.sh"

# Assertion helpers (ok/no/skip/assert_eq/assert_contains/assert_not_contains/
# assert_matches) plus the PASS/FAIL/SKIP/TOTAL counters and color vars are
# shared across the repo test suites — see lib/assert.sh (repo#307).
source "$(dirname "${BASH_SOURCE[0]}")/lib/assert.sh"

if [[ ! -f "$SOURCE_SCRIPT" ]]; then
    echo "FATAL: version.sh not found at $SOURCE_SCRIPT" >&2
    exit 1
fi

SCRATCH="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$SCRATCH" 2>/dev/null || true' EXIT

export GIT_AUTHOR_NAME="test" GIT_AUTHOR_EMAIL="test@example.com"
export GIT_COMMITTER_NAME="test" GIT_COMMITTER_EMAIL="test@example.com"

# build_repo <name> <version> [with-package-json] -> sets REPO and VS
# (the copied scripts/version.sh inside REPO).
build_repo() {
    local root="$SCRATCH/$1" ver="$2" with_pkg="${3:-yes}"
    rm -rf "$root"
    mkdir -p "$root/scripts"
    cp "$SOURCE_SCRIPT" "$root/scripts/version.sh"
    chmod +x "$root/scripts/version.sh"
    printf '%s\n' "$ver" > "$root/VERSION"
    if [[ "$with_pkg" == "yes" ]]; then
        printf '{\n  "name": "fixture",\n  "version": "%s"\n}\n' "$ver" > "$root/package.json"
    fi
    git -C "$root" init --quiet
    git -C "$root" checkout -q -b main
    git -C "$root" add -A
    git -C "$root" commit -q -m "base"
    REPO="$root"
    VS="$root/scripts/version.sh"
}

echo "version.sh test suite"
echo "======================"
echo ""

# ---------------------------------------------------------------------------
echo "-- case 1: print (default / explicit) --"
# ---------------------------------------------------------------------------
build_repo "case1" "1.2.3"
OUT="$(cd "$REPO" && "$VS")"
assert_eq "no-arg print reports the version" "1.2.3" "$OUT"
OUT="$(cd "$REPO" && "$VS" print)"
assert_eq "explicit print reports the version" "1.2.3" "$OUT"

# ---------------------------------------------------------------------------
echo ""
echo "-- case 2: check --"
# ---------------------------------------------------------------------------
build_repo "case2-ok" "1.2.3"
OUT="$(cd "$REPO" && "$VS" check 2>&1)"
STATUS=$?
assert_eq "matching VERSION/package.json passes (exit 0)" "0" "$STATUS"
assert_contains "check reports ok with the version" "$OUT" "ok: 1.2.3"

build_repo "case2-drift" "1.2.3"
printf '{\n  "name": "fixture",\n  "version": "9.9.9"\n}\n' > "$REPO/package.json"
RC=0
OUT="$(cd "$REPO" && "$VS" check 2>&1)" || RC=$?
assert_eq "mismatched package.json fails (exit 1)" "1" "$RC"
assert_contains "drift output names both versions" "$OUT" "VERSION=1.2.3"
assert_contains "drift output names both versions (package.json side)" "$OUT" "package.json=9.9.9"

build_repo "case2-no-field" "1.2.3"
printf '{\n  "name": "fixture"\n}\n' > "$REPO/package.json"
RC=0
OUT="$(cd "$REPO" && "$VS" check 2>&1)" || RC=$?
assert_eq "package.json missing a version field fails (exit 1)" "1" "$RC"
assert_contains "no-field output flags the absent field, not silent agreement" "$OUT" "no version field"

# ---------------------------------------------------------------------------
echo ""
echo "-- case 3: bump --"
# ---------------------------------------------------------------------------
build_repo "case3-patch" "1.2.3"
OUT="$(cd "$REPO" && "$VS" bump patch)"
assert_eq "bump patch prints the new version" "1.2.4" "$OUT"
assert_eq "bump patch writes VERSION" "1.2.4" "$(cat "$REPO/VERSION")"
assert_contains "bump patch syncs package.json" "$(cat "$REPO/package.json")" '"version": "1.2.4"'
assert_contains "bump patch commits with the expected message" \
    "$(git -C "$REPO" log -1 --format=%s)" "chore: bump version to 1.2.4"

build_repo "case3-minor" "1.2.3"
OUT="$(cd "$REPO" && "$VS" bump minor)"
assert_eq "bump minor resets patch" "1.3.0" "$OUT"

build_repo "case3-major" "1.2.3"
OUT="$(cd "$REPO" && "$VS" bump major)"
assert_eq "bump major resets minor and patch" "2.0.0" "$OUT"

build_repo "case3-tag" "1.2.3"
(cd "$REPO" && "$VS" bump patch --tag >/dev/null)
TAGS="$(git -C "$REPO" tag -l)"
assert_contains "bump --tag creates an annotated tag" "$TAGS" "v1.2.4"

build_repo "case3-badlevel" "1.2.3"
RC=0
(cd "$REPO" && "$VS" bump bogus >/dev/null 2>&1) || RC=$?
assert_eq "bump with an invalid level exits 2" "2" "$RC"

# ---------------------------------------------------------------------------
echo ""
echo "-- case 4: set --"
# ---------------------------------------------------------------------------
build_repo "case4-set" "1.2.3"
OUT="$(cd "$REPO" && "$VS" set 5.0.0)"
assert_eq "set prints the new version" "5.0.0" "$OUT"
assert_eq "set writes VERSION" "5.0.0" "$(cat "$REPO/VERSION")"
assert_contains "set syncs package.json" "$(cat "$REPO/package.json")" '"version": "5.0.0"'
assert_contains "set commits with the expected message" \
    "$(git -C "$REPO" log -1 --format=%s)" "chore: set version to 5.0.0"

build_repo "case4-set-tag" "1.2.3"
(cd "$REPO" && "$VS" set 5.0.0 --tag >/dev/null)
TAGS="$(git -C "$REPO" tag -l)"
assert_contains "set --tag creates an annotated tag" "$TAGS" "v5.0.0"

build_repo "case4-set-invalid" "1.2.3"
RC=0
(cd "$REPO" && "$VS" set not-a-version >/dev/null 2>&1) || RC=$?
assert_eq "set with a malformed version exits 2" "2" "$RC"
BEFORE="$(cat "$REPO/VERSION")"
assert_eq "a rejected set leaves VERSION unchanged" "1.2.3" "$BEFORE"

build_repo "case4-set-missing-arg" "1.2.3"
RC=0
(cd "$REPO" && "$VS" set >/dev/null 2>&1) || RC=$?
assert_eq "set with no argument exits 2" "2" "$RC"

# ---------------------------------------------------------------------------
echo ""
echo "-- case 5: no package.json is a no-op for check, not an error --"
# ---------------------------------------------------------------------------
# This repo always ships a root package.json (mirrored by bump/set), so this
# case only pins `check`'s documented behavior when there is nothing to
# compare against — it does not exercise bump/set in a package.json-less
# tree, which is not a configuration this repo actually has.
build_repo "case5" "1.2.3" "no"
OUT="$(cd "$REPO" && "$VS" check 2>&1)"
STATUS=$?
assert_eq "check passes with no package.json to compare against" "0" "$STATUS"

# ---------------------------------------------------------------------------
echo ""
echo "-- case 6: unknown subcommand usage --"
# ---------------------------------------------------------------------------
build_repo "case6" "1.2.3"
RC=0
(cd "$REPO" && "$VS" bogus-command >/dev/null 2>&1) || RC=$?
assert_eq "an unknown subcommand exits 2" "2" "$RC"

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

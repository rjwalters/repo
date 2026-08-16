#!/usr/bin/env bash
# Shared PASS/FAIL/SKIP assertion helpers for the repo test suites.
#
# WHY THIS FILE EXISTS (repo#307): `ok()`, `no()`, `skip()`, `assert_eq()`,
# `assert_contains()`, `assert_not_contains()`, and `assert_matches()` were
# byte-for-byte (or near-identical) copy-pasted at the top of 22 separate test
# files under commands/repo/tests/ and hooks/repo/tests/ — ~400 duplicated
# lines. This is the union of every variant that existed across those 22
# copies (some also defined `skip()` and/or `assert_matches()`; this file
# defines all of them so every caller gets the full set regardless of which
# subset its old inline copy used).
#
# This is a **sourced helpers file**, not a test framework: no discovery, no
# hooks, no assertion DSL beyond what already existed inline. Each caller
# still runs as an independent subprocess (`./test-foo.sh` or `bash
# test-foo.sh`) exactly as before — only the ~15-30 lines of boilerplate at
# the top of each file are replaced by one `source` line.
#
# Sourcing contract: define the PASS/FAIL/SKIP/TOTAL counters and the
# RED/GREEN/YELLOW/NC color vars (initializing them, not just declaring
# functions that reference them) so callers can delete their own copies
# outright. Callers MUST source this file with a path resolved from their own
# `${BASH_SOURCE[0]}` (not cwd-relative), since each test file is invoked as
# an independent subprocess and cwd varies by caller (`pnpm test` vs a
# standalone `./test-foo.sh` invocation from any directory).
#
# Usage (from commands/repo/tests/):
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/assert.sh"
# Usage (from hooks/repo/tests/):
#   source "$(dirname "${BASH_SOURCE[0]}")/../../../commands/repo/tests/lib/assert.sh"

PASS=0
FAIL=0
SKIP=0
TOTAL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

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
# A skipped assertion is neither pass nor fail: the environment cannot exercise
# it. Counted separately and surfaced in the summary so a silently-skipped suite
# is never mistaken for a full pass (repo#46).
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
assert_matches() {  # <label> <haystack> <ere>
    if printf '%s\n' "$2" | grep -qE -- "$3"; then ok "$1"; else no "$1" "no match for /$3/"; fi
}
# flatten() (repo#363): whitespace-flatten a file for doc-drift assertions
# against prose that wraps across lines. Was byte-for-byte duplicated in
# test-tidy-keep-tiers.sh, test-verify-fix-persistence.sh, and
# test-early-sync-switch.sh.
flatten() { tr '\n' ' ' < "$1" | tr -s ' '; }

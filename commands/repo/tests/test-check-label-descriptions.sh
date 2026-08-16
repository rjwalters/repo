#!/usr/bin/env bash
# Test suite for .loom/scripts/check-label-descriptions.sh — the lint that
# fails when a label description in .github/labels.yml exceeds GitHub's
# 100-character limit (originally written for #4335).
#
# Usage: ./commands/repo/tests/test-check-label-descriptions.sh
# Exit code 0 = all tests pass, 1 = failures detected.
#
# Structured like commands/repo/tests/test-release-version-citation-check.sh:
# pure bash, no test framework, PASS/FAIL/SKIP/TOTAL counters via lib/assert.sh,
# and a scratch-git fixture harness. `pnpm test` delegates to this file via
# hooks/repo/tests/run.sh.
#
# WHY THIS FILE EXISTS (repo#356): check-label-descriptions.sh is a real,
# working check against this repo's live .github/labels.yml — unlike its two
# siblings (check-cas-recheck-consistency.sh, check-phantom-labels.sh), which
# are structural no-ops here because they guard a defaults/ tree this repo
# does not have — but nothing in this repo invoked it, so a future hand-edit
# to labels.yml that pushed a description over the limit would 422 on
# `gh label sync` with no earlier automated signal. This suite is the
# regression coverage that lets hooks/repo/tests/run.sh wire the checker in
# with confidence the gate can actually fail, not just that it currently
# passes.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CHECK="$REPO_ROOT/.loom/scripts/check-label-descriptions.sh"

# Assertion helpers (ok/no/skip/assert_eq/assert_contains/assert_not_contains/
# assert_matches) plus the PASS/FAIL/SKIP/TOTAL counters and color vars are
# shared across the repo test suites — see lib/assert.sh (repo#307).
source "$(dirname "${BASH_SOURCE[0]}")/lib/assert.sh"

if [[ ! -f "$CHECK" ]]; then
    echo "FATAL: check-label-descriptions.sh not found at $CHECK" >&2
    exit 1
fi

SCRATCH="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$SCRATCH"' EXIT

build_repo() {   # <name> -> sets REPO to a fresh scratch git repo dir
    local root="$SCRATCH/$1"
    mkdir -p "$root"
    REPO="$root"
}

echo "check-label-descriptions.sh test suite"
echo "======================================="
echo ""

# ---------------------------------------------------------------------------
echo "-- case 1: current repo state passes --"
# ---------------------------------------------------------------------------
# The live .github/labels.yml is expected to be within the 100-character
# limit today (verified by the Curator directly executing the script against
# origin/main). This pins that expectation so a future drift is caught here,
# not just at `gh label sync` time.
OUT="$("$CHECK" "$REPO_ROOT" 2>&1)"
STATUS=$?
assert_eq "current .github/labels.yml passes (exit 0)" "0" "$STATUS"
assert_contains "current run reports OK" "$OUT" "OK — all label descriptions are within"

# ---------------------------------------------------------------------------
echo ""
echo "-- case 2: a description under the limit passes --"
# ---------------------------------------------------------------------------
build_repo "case2"
mkdir -p "$REPO/.github"
cat > "$REPO/.github/labels.yml" <<'EOF'
- name: "loom:issue"
  color: "3B82F6"
  description: "Approved for work."
EOF
OUT="$("$CHECK" "$REPO" 2>&1)"
STATUS=$?
assert_eq "an in-limit description passes (exit 0)" "0" "$STATUS"

# ---------------------------------------------------------------------------
echo ""
echo "-- case 3: a description over the limit fails --"
# ---------------------------------------------------------------------------
build_repo "case3"
mkdir -p "$REPO/.github"
LONG_DESC="This description is deliberately far too long to fit inside GitHub's one hundred character limit for label descriptions, guaranteed."
cat > "$REPO/.github/labels.yml" <<EOF
- name: "loom:overlong"
  color: "3B82F6"
  description: "${LONG_DESC}"
EOF
OUT="$("$CHECK" "$REPO" 2>&1)"
STATUS=$?
assert_eq "an over-limit description fails (exit 1)" "1" "$STATUS"
assert_contains "the offending label is named on output" "$OUT" "loom:overlong"
assert_contains "output reports OVER LIMIT" "$OUT" "OVER LIMIT"

# ---------------------------------------------------------------------------
echo ""
echo "-- case 4: a compliant label alongside an over-limit one still fails --"
# ---------------------------------------------------------------------------
build_repo "case4"
mkdir -p "$REPO/.github"
cat > "$REPO/.github/labels.yml" <<EOF
- name: "loom:ok"
  color: "10B981"
  description: "Short and within the limit."
- name: "loom:overlong"
  color: "3B82F6"
  description: "${LONG_DESC}"
EOF
OUT="$("$CHECK" "$REPO" 2>&1)"
STATUS=$?
assert_eq "mixed compliant + over-limit still fails (exit 1)" "1" "$STATUS"
assert_contains "only the offending label is named" "$OUT" "loom:overlong"
assert_not_contains "the compliant label is not flagged" "$OUT" "loom:ok\n  at"

# ---------------------------------------------------------------------------
echo ""
echo "-- case 5: no labels.yml anywhere -> clean no-op --"
# ---------------------------------------------------------------------------
build_repo "case5"
OUT="$("$CHECK" "$REPO" 2>&1)"
STATUS=$?
assert_eq "absent labels.yml is a clean no-op (exit 0)" "0" "$STATUS"
assert_contains "no-op message names the missing target" "$OUT" "nothing to check"

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

#!/usr/bin/env bash
# Test suite for /repo:deps step 1's three-state security-updates read (repo#479).
#
# Usage: ./commands/repo/tests/test-deps-security-updates-paused.sh
# Exit code 0 = all tests pass, 1 = failures detected.
#
# Structured like commands/repo/tests/test-followups-scrub-step.sh: pure bash,
# no test framework, PASS/FAIL/SKIP/TOTAL counters and a summary block.
# `pnpm test` delegates to this file via hooks/repo/tests/run.sh.
#
# WHY THIS FILE EXISTS (repo#479): `GET /repos/:owner/:repo/automated-security-fixes`
# answers with TWO booleans — `{"enabled": bool, "paused": bool}` — and they
# encode three distinct states, not two. Until #479, deps.md read the endpoint
# as `--jq '.enabled'`, which discards `paused` entirely: a repo sitting at
# `{"enabled":true,"paused":true}` (GitHub pauses Dependabot itself on an idle
# repo; nobody changed a setting) was reported identically to one actively
# raising fix PRs, even though no fix PRs are arriving in the paused case.
# The ways this can silently rot back:
#
#   - Someone re-narrows the read to `--jq '.enabled'` "for readability",
#     which drops `paused` at the source — no amount of downstream reporting
#     prose can recover a field that was never fetched.
#   - The three states get collapsed back to two in the report, so `paused`
#     renders as either `enabled` (hiding that fix PRs have stopped) or
#     `disabled` (hiding that the flag is still on, and mis-prescribing the
#     step-5 enable write, which is a no-op against an already-enabled flag).
#   - The paused state gets folded into UNKNOWN. UNKNOWN is reserved for an
#     actual 403 and nothing else — see the regression section below.
#
# The contract under test:
#   1  deps.md still exists and step 1 still reports config and the security
#      flag as two distinct items
#   2  the endpoint is read in FULL — `.enabled`-only is gone, and both
#      fields are named
#   3  step 1 documents three states (enabled / paused / disabled), with the
#      literal payload shapes, plus 403 -> UNKNOWN as a fourth answer
#   4  the report surface can express `paused` distinctly from `enabled` and
#      `disabled`
#   5  the paused state carries its own next action (the step-5 enable write
#      is NOT the remedy)
#   6  REGRESSION (PR #344, must not be undone by #479): "object absent" and
#      "no permission to see it" stay distinct states, UNKNOWN stays reserved
#      for an actual 403, and an absent `security_and_analysis` object is
#      still never treated as evidence of missing admin

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
DEPS_MD="$REPO_ROOT/commands/repo/deps.md"

# Assertion helpers (ok/no/skip/assert_eq/assert_contains/assert_not_contains/
# assert_matches) plus the PASS/FAIL/SKIP/TOTAL counters and color vars are
# shared across the repo test suites — see lib/assert.sh (repo#307).
source "$(dirname "${BASH_SOURCE[0]}")/lib/assert.sh"

if [[ ! -f "$DEPS_MD" ]]; then
    echo "FATAL: required file not found at $DEPS_MD" >&2
    exit 1
fi

DEPS="$(cat "$DEPS_MD")"
# Prose in deps.md wraps at ~80 columns, so a sentence-level assertion has to
# run against a whitespace-flattened copy (lib/assert.sh's flatten(), repo#363).
# Code blocks and report tables are asserted against the RAW text instead —
# there, the line break IS the structure under test.
DEPS_FLAT="$(flatten "$DEPS_MD")"

# Step 1's own body, isolated: every assertion about the security-updates read
# must hold IN STEP 1, not merely somewhere in a 900-line file.
STEP1_LN="$(grep -nE '^### 1\. Report config and the security flag' "$DEPS_MD" | head -1 | cut -d: -f1)"
STEP2_LN="$(grep -nE '^### 2\. Detect the ecosystems' "$DEPS_MD" | head -1 | cut -d: -f1)"
if [[ -n "$STEP1_LN" && -n "$STEP2_LN" && "$STEP1_LN" -lt "$STEP2_LN" ]]; then
    STEP1="$(sed -n "${STEP1_LN},${STEP2_LN}p" "$DEPS_MD")"
    STEP1_FLAT="$(printf '%s\n' "$STEP1" | tr '\n' ' ' | tr -s ' ')"
else
    STEP1=""
    STEP1_FLAT=""
fi

# ---------------------------------------------------------------------------
echo "1. Command surface — step 1 still reports the two items separately"
# ---------------------------------------------------------------------------

assert_matches "deps.md declares name: deps" "$DEPS" '^name: "deps"'
if [[ -n "$STEP1" ]]; then
    ok "step 1 ('Report config and the security flag') is locatable"
else
    no "step 1 ('Report config and the security flag') is locatable" \
        "step1=$STEP1_LN step2=$STEP2_LN — heading renamed or reordered?"
fi
assert_contains "version updates and security updates stay distinct items" "$STEP1_FLAT" \
    "entirely independent"

# ---------------------------------------------------------------------------
echo ""
echo "2. The endpoint is read in full, not --jq '.enabled'"
# ---------------------------------------------------------------------------

# The root cause: a narrowed read cannot be recovered downstream.
assert_not_contains "the read is no longer narrowed to .enabled" "$DEPS_FLAT" \
    "automated-security-fixes --jq '.enabled'"
assert_matches "step 1 reads the whole automated-security-fixes object" "$STEP1" \
    '^gh api repos/OWNER/REPO/automated-security-fixes$'
assert_contains "both response fields are named at the read site" "$STEP1_FLAT" \
    '{"enabled": bool, "paused": bool}'
assert_contains "narrowing the read back to .enabled is explicitly warned against" "$STEP1_FLAT" \
    "never \`--jq '.enabled'\` alone"
# The alerts read next to it is a different endpoint and must survive untouched.
assert_contains "the vulnerability-alerts read is unchanged" "$STEP1_FLAT" \
    "gh api repos/OWNER/REPO/vulnerability-alerts -i"

# ---------------------------------------------------------------------------
echo ""
echo "3. Three states are documented, with their literal payload shapes"
# ---------------------------------------------------------------------------

assert_contains "the enabled payload shape is shown" "$STEP1_FLAT" \
    '`{"enabled": true, "paused": false}`'
assert_contains "the paused payload shape is shown" "$STEP1_FLAT" \
    '`{"enabled": true, "paused": true}`'
assert_contains "the disabled payload shape is shown" "$STEP1_FLAT" \
    '`{"enabled": false'
assert_contains "the three states are named as three, not two" "$STEP1_FLAT" \
    "**three** states"
# 403 stays a fourth answer, not one of the three.
assert_contains "403 is still mapped to UNKNOWN (needs admin)" "$STEP1_FLAT" \
    "UNKNOWN (needs admin)"
# Why paused exists at all: it is drifted-into, not configured.
assert_contains "paused is described as GitHub's own doing, not a setting" "$STEP1_FLAT" \
    "GitHub sets \`paused\` itself"

# ---------------------------------------------------------------------------
echo ""
echo "4. The report can express paused distinctly from enabled and disabled"
# ---------------------------------------------------------------------------

assert_matches "the report shows a paused rendering of the security-updates row" "$STEP1" \
    '\| security updates \(repo flag\).*\| paused —'
assert_matches "the report still shows an enabled rendering" "$STEP1" \
    '\| security updates \(repo flag\).*\| enabled —'
assert_matches "the report still shows a disabled rendering" "$STEP1" \
    '\| security updates \(repo flag\).*\| disabled —'
assert_matches "the report still shows an UNKNOWN rendering" "$STEP1" \
    '\| security updates \(repo flag\).*\| UNKNOWN \(needs admin\)'
assert_contains "collapsing paused into enabled is explicitly forbidden" "$STEP1_FLAT" \
    "never collapse \`paused\` into \`enabled\`"

# ---------------------------------------------------------------------------
echo ""
echo "5. Paused carries its own next action — the step-5 write is not it"
# ---------------------------------------------------------------------------

assert_contains "paused is stated to produce no fix PRs right now" "$STEP1_FLAT" \
    "no fix PRs are being raised"
assert_contains "the enable write is named a no-op against a paused repo" "$STEP1_FLAT" \
    "no-op"
assert_contains "step 5 defers to step 1 rather than offering the no-op write" "$DEPS_FLAT" \
    "already \`enabled\` but \`paused\`"

# ---------------------------------------------------------------------------
echo ""
echo "6. REGRESSION (PR #344) — absence is not inaccessibility"
# ---------------------------------------------------------------------------

# #479 must not walk back #344. These are that fix's load-bearing sentences.
assert_contains "the two states stay named as different states" "$DEPS_FLAT" \
    '"object absent" and "no permission to see it" are different states'
assert_contains "only a 403 is evidence of a permission gap" "$DEPS_FLAT" \
    'only `automated-security-fixes`'
assert_contains "the private-repo-without-GHAS case is still named" "$DEPS_FLAT" \
    "even a token with full admin sees it absent"
assert_contains "UNKNOWN is still reserved for an actual permission failure" "$DEPS_FLAT" \
    "Reserve **UNKNOWN (needs admin)** for an actual permission failure"
assert_contains "inferring UNKNOWN from an absent object is still forbidden" "$DEPS_FLAT" \
    "do **not** infer UNKNOWN from an absent"
assert_contains "the flags are still read from dedicated endpoints" "$DEPS_FLAT" \
    "Read both flags from their dedicated endpoints, never from"

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

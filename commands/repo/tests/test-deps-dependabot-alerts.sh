#!/usr/bin/env bash
# Test suite for /repo:deps step 1's open-Dependabot-alert read (repo#551).
#
# Usage: ./commands/repo/tests/test-deps-dependabot-alerts.sh
# Exit code 0 = all tests pass, 1 = failures detected.
#
# Structured like commands/repo/tests/test-deps-security-updates-paused.sh:
# pure bash, no test framework, PASS/FAIL/SKIP/TOTAL counters and a summary
# block. `pnpm test` delegates to this file via hooks/repo/tests/run.sh.
#
# WHY THIS FILE EXISTS (repo#551): a `/repo:all` run's stage 6 reported
# `dependabot.yml` present, security updates ON, 4 open Dependabot PRs (0
# majors, 0 stale) — which reads as clean — and the very next `git push`
# printed GitHub's banner for 2 open vulnerabilities on the default branch (1
# high, 1 moderate), both transitive dev dependencies with patched versions
# available. The check read the repo-level security-updates *flag* and the PR
# list, and never the open *alerts*. Those are three different questions:
#
#   - `vulnerability-alerts`       → is detection turned on?
#   - `automated-security-fixes`   → would a fix PR be raised?
#   - `dependabot/alerts?state=open` → is anything vulnerable RIGHT NOW?
#
# An alert whose fix sits behind a lockfile pin or a dependency override
# produces NO PR, so it is invisible to both flags and to the PR list. The ways
# this can silently rot back:
#
#   - The alerts read gets dropped again, or narrowed to a bare count, losing
#     the severity/package/fixed_in fields the report needs (no downstream
#     prose can recover a field that was never fetched).
#   - A failed read (403) collapses into `0 open`, which is the original bug in
#     its most dangerous form: a confident zero where there is no evidence.
#   - The uncovered-alert cross-reference against the open bot PRs disappears,
#     so alerts that need manual action are left indistinguishable from ones a
#     bot is already fixing.
#   - /repo:all's `Deps:` summary line stops carrying the counts, putting the
#     clean-looking summary back exactly as #551 found it.
#
# The contract under test:
#   1  step 1 is still locatable and still reads the alerts ENDPOINT (state=open),
#      distinct from both existing flag reads
#   2  the read keeps the fields the report consumes: severity, package,
#      ecosystem, fixed_in — asserted by RUNNING the documented jq against
#      fixture payloads (alerts present / none present), not just grepping prose
#   3  a failed read is UNKNOWN, never 0 — `0 open` is reserved for a successful
#      read of an empty set, and the 403 ambiguity (token vs. alerts-disabled)
#      is disambiguated against the alerts flag
#   4  alerts with no corresponding open bot PR are listed individually with
#      package / ecosystem / severity / fixed_in, and coverage is decided from
#      the PR diff against `fixed_in` — asserted by RUNNING the documented
#      files-API pipeline against fixture payloads
#   5  the report surface carries an always-printed alerts row with all four
#      renderings, and /repo:all's `Deps:` line carries the counts
#   6  REGRESSION (repo#479/#344, must not be undone by #551): the three-state
#      security-updates read and UNKNOWN-reserved-for-403 rules survive

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
DEPS_MD="$REPO_ROOT/commands/repo/deps.md"
ALL_MD="$REPO_ROOT/commands/repo/all.md"

# Assertion helpers (ok/no/skip/assert_eq/assert_contains/assert_not_contains/
# assert_matches) plus the PASS/FAIL/SKIP/TOTAL counters and color vars are
# shared across the repo test suites — see lib/assert.sh (repo#307).
source "$(dirname "${BASH_SOURCE[0]}")/lib/assert.sh"

for f in "$DEPS_MD" "$ALL_MD"; do
    if [[ ! -f "$f" ]]; then
        echo "FATAL: required file not found at $f" >&2
        exit 1
    fi
done

DEPS="$(cat "$DEPS_MD")"
ALL="$(cat "$ALL_MD")"
# Prose in these files wraps at ~80 columns, so sentence-level assertions have
# to run against a whitespace-flattened copy (lib/assert.sh's flatten(),
# repo#363). Code blocks and report tables are asserted against the RAW text
# instead — there, the line break IS the structure under test.
DEPS_FLAT="$(flatten "$DEPS_MD")"
ALL_FLAT="$(flatten "$ALL_MD")"

# Step 1's own body, isolated: every assertion about the alerts read must hold
# IN STEP 1, not merely somewhere in a 1200-line file.
STEP1_LN="$(grep -nE '^### 1\. Report config and the security flag' "$DEPS_MD" | head -1 | cut -d: -f1)"
STEP2_LN="$(grep -nE '^### 2\. Detect the ecosystems' "$DEPS_MD" | head -1 | cut -d: -f1)"
if [[ -n "$STEP1_LN" && -n "$STEP2_LN" && "$STEP1_LN" -lt "$STEP2_LN" ]]; then
    STEP1="$(sed -n "${STEP1_LN},${STEP2_LN}p" "$DEPS_MD")"
    STEP1_FLAT="$(printf '%s\n' "$STEP1" | tr '\n' ' ' | tr -s ' ')"
else
    STEP1=""
    STEP1_FLAT=""
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/deps-alerts-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

# ---------------------------------------------------------------------------
echo "1. Step 1 reads the open-alerts endpoint, distinct from both flags"
# ---------------------------------------------------------------------------

assert_matches "deps.md declares name: deps" "$DEPS" '^name: "deps"'
if [[ -n "$STEP1" ]]; then
    ok "step 1 ('Report config and the security flag') is locatable"
else
    no "step 1 ('Report config and the security flag') is locatable" \
        "step1=$STEP1_LN step2=$STEP2_LN — heading renamed or reordered?"
fi

assert_matches "step 1 reads repos/OWNER/REPO/dependabot/alerts" "$STEP1" \
    'gh api repos/OWNER/REPO/dependabot/alerts'
assert_matches "the read is scoped to open alerts" "$STEP1" \
    'dependabot/alerts.*state=open'
assert_matches "the read is paginated (one page silently drops alerts)" "$STEP1" \
    'dependabot/alerts --paginate'
# The whole point of #551: this is a THIRD question, not a restatement of
# either flag. Both flag reads must survive beside it.
assert_contains "the automated-security-fixes flag read survives" "$STEP1_FLAT" \
    "gh api repos/OWNER/REPO/automated-security-fixes"
assert_contains "the vulnerability-alerts flag read survives" "$STEP1_FLAT" \
    "gh api repos/OWNER/REPO/vulnerability-alerts -i"
assert_contains "the flag-vs-open-alerts distinction is stated" "$STEP1_FLAT" \
    "**Open alerts are a count of findings, not a fourth flag.**"
assert_contains "an ON flag is not evidence that nothing is open" "$STEP1_FLAT" \
    "A flag being ON says nothing about whether anything is currently vulnerable"
assert_contains "the no-PR-for-this-alert case is named as the cause" "$STEP1_FLAT" \
    "lockfile pin"

# ---------------------------------------------------------------------------
echo ""
echo "2. The documented jq actually yields the fields the report consumes"
# ---------------------------------------------------------------------------

# Transcribe the filter straight out of deps.md — a test that hardcodes its own
# copy would keep passing after someone narrows the doc's read.
ALERT_JQ="$(grep -A1 'gh api repos/OWNER/REPO/dependabot/alerts' "$DEPS_MD" \
    | grep -- '--jq' | head -1 | sed -E "s/^[[:space:]]*--jq[[:space:]]*'//; s/'[[:space:]]*\$//")"

if ! command -v jq >/dev/null 2>&1; then
    skip "fixture run of the documented alerts jq" "jq not installed"
elif [[ -z "$ALERT_JQ" ]]; then
    no "the alerts read carries a --jq projection" \
        "no --jq line found after the dependabot/alerts read in $DEPS_MD"
else
    ok "the alerts read carries a --jq projection (extracted from deps.md)"

    # Two open alerts, shaped like the real payload: one high with a manifest
    # fix available, one medium (GitHub's UI calls this "moderate") whose fix is
    # lockfile-only. This is the #551 repro shape.
    cat >"$WORKDIR/alerts-present.json" <<'JSON'
[
  {
    "number": 7,
    "state": "open",
    "security_advisory": {"severity": "high", "ghsa_id": "GHSA-xxxx-yyyy-zzzz"},
    "security_vulnerability": {"first_patched_version": {"identifier": "4.17.21"}},
    "dependency": {
      "package": {"ecosystem": "npm", "name": "lodash"},
      "manifest_path": "package-lock.json",
      "scope": "development"
    }
  },
  {
    "number": 8,
    "state": "open",
    "security_advisory": {"severity": "medium", "ghsa_id": "GHSA-aaaa-bbbb-cccc"},
    "security_vulnerability": {"first_patched_version": {"identifier": "3.1.1"}},
    "dependency": {
      "package": {"ecosystem": "npm", "name": "tar-fs"},
      "manifest_path": "pnpm-lock.yaml",
      "scope": "development"
    }
  }
]
JSON
    printf '%s\n' "[]" >"$WORKDIR/alerts-empty.json"

    PRESENT_OUT="$(jq -c "$ALERT_JQ" "$WORKDIR/alerts-present.json" 2>"$WORKDIR/jq.err")"
    if [[ -n "$PRESENT_OUT" ]]; then
        ok "alerts present: the documented filter emits one object per open alert"
    else
        no "alerts present: the documented filter emits one object per open alert" \
            "jq produced no output; stderr: $(tr '\n' ' ' <"$WORKDIR/jq.err")"
    fi
    assert_eq "alerts present: two alerts in, two records out" \
        "2" "$(printf '%s\n' "$PRESENT_OUT" | grep -c . || true)"

    # Severity must survive the projection, or the by-severity counts the first
    # acceptance criterion asks for cannot be produced at all.
    assert_eq "severity survives the projection (high)" "1" \
        "$(printf '%s\n' "$PRESENT_OUT" | jq -s '[.[] | select(.severity == "high")] | length')"
    assert_eq "severity survives the projection (medium)" "1" \
        "$(printf '%s\n' "$PRESENT_OUT" | jq -s '[.[] | select(.severity == "medium")] | length')"
    # Grouping by severity — what the report's "(1 high, 1 medium)" is built from.
    assert_eq "the projection supports grouping by severity" "high=1 medium=1" \
        "$(printf '%s\n' "$PRESENT_OUT" | jq -sr '[group_by(.severity)[] | "\(.[0].severity)=\(length)"] | sort | join(" ")')"
    # Package / ecosystem / fixed_in are what the manual-action listing prints.
    assert_eq "package name survives the projection" "lodash tar-fs" \
        "$(printf '%s\n' "$PRESENT_OUT" | jq -sr '[.[].package] | sort | join(" ")')"
    assert_eq "ecosystem survives the projection" "npm" \
        "$(printf '%s\n' "$PRESENT_OUT" | jq -sr '[.[].ecosystem] | unique | join(" ")')"
    assert_eq "fixed-in version survives the projection" "3.1.1 4.17.21" \
        "$(printf '%s\n' "$PRESENT_OUT" | jq -sr '[.[].fixed_in] | sort | join(" ")')"

    # No alerts present: an empty read is the ONLY thing that earns "0 open".
    EMPTY_OUT="$(jq -c "$ALERT_JQ" "$WORKDIR/alerts-empty.json" 2>/dev/null)"
    assert_eq "alerts absent: an empty alert set yields no records (→ 0 open)" \
        "0" "$(printf '%s' "$EMPTY_OUT" | grep -c . || true)"
fi

# ---------------------------------------------------------------------------
echo ""
echo "3. A failed read is UNKNOWN, never 0"
# ---------------------------------------------------------------------------

assert_contains "403 maps to UNKNOWN, naming the missing read scope" "$STEP1_FLAT" \
    "UNKNOWN (needs security_events read)"
assert_contains "collapsing a failed read into zero is explicitly forbidden" "$STEP1_FLAT" \
    "Never report \`0 open\` for a read that failed"
assert_contains "zero is reserved for a successful read of an empty set" "$STEP1_FLAT" \
    "the only way to earn a zero"
# A 403 is ambiguous on this endpoint (no security_events read vs. alerts
# detection off); both answers are non-zero, and the disambiguation is the
# alerts flag already read beside it.
assert_contains "the 403 ambiguity is disambiguated against the alerts flag" "$STEP1_FLAT" \
    "alerts enabled → the \`403\` is about the token"
assert_contains "alerts-disabled is reported as n/a, not as a zero count" "$STEP1_FLAT" \
    "n/a — alerts disabled"
assert_matches "step 1's own read site warns that 403 is UNKNOWN, not 0" "$STEP1" \
    '403 .* UNKNOWN, never 0'
# Safety Rule 2 is where this generalizes beyond step 1.
assert_contains "Safety Rule 2 covers the open-alert read" "$DEPS_FLAT" \
    "UNKNOWN (not \`0 open\`) when it can't read \`/dependabot/alerts\`"
assert_contains "flag state is not evidence that nothing is vulnerable" "$DEPS_FLAT" \
    "Never present flag state or an empty bot-PR list as evidence"

# ---------------------------------------------------------------------------
echo ""
echo "4. Alerts with no open fix PR are cross-referenced and listed"
# ---------------------------------------------------------------------------

assert_contains "the cross-reference reuses step 7's author-filtered PR list" "$STEP1_FLAT" \
    'gh pr list --author "app/dependabot" --state open'
assert_contains "coverage requires reaching at least the fixed-in version" "$STEP1_FLAT" \
    "bumps that package to at least its \`fixed_in\` version"
assert_contains "a below-fixed_in bump is explicitly not coverage" "$STEP1_FLAT" \
    "lands *below* \`fixed_in\` is not coverage"
assert_contains "the leftover set is named as needing human action" "$STEP1_FLAT" \
    "needs a human action"
assert_matches "the manual-action listing block exists" "$STEP1" \
    '^ALERTS NEEDING MANUAL ACTION$'
assert_matches "the listing names package, ecosystem, severity and fixed-in" "$STEP1" \
    '\| Package +\| Ecosystem +\| Severity +\| Fixed in +\|'
assert_matches "the listing shows a worked uncovered row" "$STEP1" \
    '\| lodash +\| npm +\|.*\| 4\.17\.21 +\|'
assert_contains "the block is omitted when nothing is uncovered" "$STEP1_FLAT" \
    "only when the leftover set is non-empty"
assert_contains "--check stays report-only for alert remediation" "$STEP1_FLAT" \
    "do not open a PR, edit a manifest, or refresh a lockfile"

# Run the documented coverage probe: does an open PR's diff actually bump the
# alerting package? Matching on the PR TITLE is the trap (a grouped PR names
# none of its packages), so the doc matches on the files API's patch text.
FILES_JQ="$(grep -A2 'pulls/<N>/files' "$DEPS_MD" | grep -- '--jq' | head -1 \
    | sed -E "s/^[[:space:]]*--jq[[:space:]]*'//; s/'[[:space:]]*\\\\?[[:space:]]*\$//")"

if ! command -v jq >/dev/null 2>&1; then
    skip "fixture run of the documented coverage probe" "jq not installed"
elif [[ -z "$FILES_JQ" ]]; then
    no "the coverage probe carries a --jq projection" \
        "no --jq line found after the pulls/<N>/files read in $DEPS_MD"
else
    ok "the coverage probe carries a --jq projection (extracted from deps.md)"

    # An open Dependabot PR that bumps tar-fs in the lockfile only — its title
    # would be "bump the npm group with 3 updates", naming no package at all.
    cat >"$WORKDIR/pr-files.json" <<'JSON'
[
  {
    "filename": "pnpm-lock.yaml",
    "patch": "@@ -1,4 +1,4 @@\n-      tar-fs: 3.0.4\n+      tar-fs: 3.1.1\n"
  },
  {
    "filename": "README.md",
    "patch": "@@ -1 +1 @@\n-lodash is great\n+lodash is still great\n"
  }
]
JSON

    PATCHES="$(jq -r "$FILES_JQ" "$WORKDIR/pr-files.json" 2>"$WORKDIR/jq2.err")"
    if printf '%s\n' "$PATCHES" | grep -qi 'tar-fs'; then
        ok "covered alert: the probe finds the lockfile-only bump of tar-fs"
    else
        no "covered alert: the probe finds the lockfile-only bump of tar-fs" \
            "probe output: $(printf '%s' "$PATCHES" | tr '\n' ' ' | head -c 200); stderr: $(tr '\n' ' ' <"$WORKDIR/jq2.err")"
    fi
    if printf '%s\n' "$PATCHES" | grep -qi 'lodash'; then
        no "uncovered alert: lodash is NOT matched from a non-manifest file" \
            "the probe matched README.md text — the filename filter is too wide, so an unfixed alert would be reported as covered"
    else
        ok "uncovered alert: lodash is NOT matched from a non-manifest file"
    fi
    # The fixed-in comparison is what turns a match into coverage: this PR
    # reaches 3.1.1, which is exactly tar-fs's first patched version.
    if printf '%s\n' "$PATCHES" | grep -q '3\.1\.1'; then
        ok "the probe surfaces the proposed version for the fixed-in comparison"
    else
        no "the probe surfaces the proposed version for the fixed-in comparison" \
            "no version visible in the emitted patch text"
    fi
fi

# ---------------------------------------------------------------------------
echo ""
echo "5. The report row and /repo:all's Deps: line carry the counts"
# ---------------------------------------------------------------------------

assert_matches "the DEPENDABOT table has an open-alerts row" "$STEP1" \
    '\| open Dependabot alerts +\|'
assert_contains "the row is a count, never folded into the alerts flag" "$STEP1_FLAT" \
    "never fold it into \`vulnerability alerts (repo flag)\`"
assert_contains "the row is printed even at zero" "$STEP1_FLAT" \
    "never omit it when the count is zero"
assert_matches "row rendering: zero" "$STEP1" \
    '\| open Dependabot alerts +\| 0 open'
assert_matches "row rendering: counts by severity plus the uncovered call-out" "$STEP1" \
    '\| open Dependabot alerts +\| 2 open \(1 high, 1 medium\) — 1 with no open fix PR'
assert_matches "row rendering: UNKNOWN" "$STEP1" \
    '\| open Dependabot alerts +\| UNKNOWN \(needs security_events read\)'
assert_matches "row rendering: alerts disabled" "$STEP1" \
    '\| open Dependabot alerts +\| n/a — alerts disabled'
assert_contains "deps.md requires the caller's summary to carry the counts" "$STEP1_FLAT" \
    "Carry the alert counts into the caller's summary"

# /repo:all stage 6 + Final Summary.
assert_contains "all.md stage 6 reports open alerts by severity" "$ALL_FLAT" \
    "**open Dependabot alerts by severity**"
assert_contains "all.md distinguishes the flag from the open-alert count" "$ALL_FLAT" \
    "means detection is enabled, not that nothing is detected"
assert_contains "all.md names the endpoint stage 6 depends on" "$ALL_FLAT" \
    "dependabot/alerts?state=open"
assert_contains "all.md requires UNKNOWN rather than 0 open" "$ALL_FLAT" \
    "reports \`UNKNOWN\` (never \`0 open\`)"
assert_contains "all.md carries the no-open-fix-PR count into the summary" "$ALL_FLAT" \
    "no open fix PR"
assert_matches "the example Deps: line includes the alert counts" "$ALL" \
    '^Deps: +.*open alerts \(1 high, 1 medium'
assert_matches "Deps: rendering for zero open alerts" "$ALL" \
    '^Deps: +.*0 open alerts'
assert_matches "Deps: rendering for an unreadable alerts endpoint" "$ALL" \
    '^Deps: +.*open alerts UNKNOWN'
assert_matches "Deps: rendering when alerts detection is off" "$ALL" \
    '^Deps: +.*open alerts n/a \(alerts disabled\)'
assert_contains "the alerts clause is never dropped from the Deps: line" "$ALL_FLAT" \
    "an absent clause is indistinguishable from"
assert_contains "UNKNOWN is never rendered as zero in the summary" "$ALL_FLAT" \
    "\`UNKNOWN\` is never rendered as \`0\`"

# The Renovate path skips step 1 entirely, so it has to pick the read up itself.
assert_contains "the Renovate path also probes the open-alert read" "$DEPS_FLAT" \
    "including the open-alert read"
# --all-repos stays out of scope, explicitly rather than by omission (repo#551).
assert_contains "--all-repos' exclusion of alert counts is explicit" "$DEPS_FLAT" \
    "deliberately not a survey column"
assert_contains "a survey row is not evidence of no open vulnerabilities" "$DEPS_FLAT" \
    "a survey row is not evidence that a repo has no open vulnerabilities"

# ---------------------------------------------------------------------------
echo ""
echo "6. REGRESSION (repo#479, #344) — the flag reads keep their contracts"
# ---------------------------------------------------------------------------

assert_not_contains "the security-updates read is still not narrowed to .enabled" "$DEPS_FLAT" \
    "automated-security-fixes --jq '.enabled'"
assert_contains "the three security-updates states survive" "$DEPS_FLAT" \
    "**three** states"
assert_contains "paused is still never collapsed into enabled" "$DEPS_FLAT" \
    "never collapse \`paused\` into \`enabled\`"
assert_contains "UNKNOWN is still reserved for an actual permission failure" "$DEPS_FLAT" \
    "Reserve **UNKNOWN (needs admin)** for an actual permission failure"
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

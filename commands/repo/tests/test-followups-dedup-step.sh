#!/usr/bin/env bash
# Test suite for /repo:followups' dedup match-type contract (repo#515).
#
# Usage: ./commands/repo/tests/test-followups-dedup-step.sh
# Exit code 0 = all tests pass, 1 = failures detected.
#
# Structured like commands/repo/tests/test-followups-scrub-step.sh: pure bash,
# no test framework, PASS/FAIL/SKIP/TOTAL counters and a summary block. `pnpm
# test` delegates to this file via hooks/repo/tests/run.sh. Hermetic — it reads
# commands/repo/followups.md from the working tree and makes no network calls.
#
# WHY THIS FILE EXISTS (repo#515): step 3's dedup search deliberately returns
# pull requests as well as issues (repo#102, repo#121 — that decision stands and
# this file does not narrow it). The design relies on the match TYPE being
# visible, and until #515 nothing enforced that. In a live run a session wrote
# its own `--jq` that printed only `#number title`, dropped the one field that
# disclosed the type, proposed the row as "#<pr> duplicates #<issue>", and ran
# `gh issue close <pr>` — closing an approved, in-flight PR that implemented the
# very issue it was reported as duplicating. gh prints "✓ Closed issue …" for a
# closed pull request, so nothing downstream caught it either.
#
# The fix is prose, so the ways it can silently rot are the ways prose rots:
#
#   - The canonical query loses its type expression again — trimmed back to
#     `"#\(.number) \(.title) \(.html_url)"` as "simpler", or narrowed with
#     `+is:issue` (which would "fix" the ambiguity by discarding the strongest
#     dedup signal there is, undoing repo#102/#121 rather than implementing
#     #515).
#   - The step-4 Dedup cells drift back to a bare `near #N`, or the PR row gets
#     re-labelled "duplicate" — the exact word whose attachment to a PR number
#     produced the incident.
#   - The "this command never closes/edits/relabels an existing item" rule is
#     softened into a preference, or the type re-check before touching a number
#     is dropped because step 3 "already classified it".
#
# The contract under test:
#   1  followups.md still exists, is user-invocable, and still has a step 3
#   2  step 3's canonical query emits the match type inline, keeps html_url,
#      and is documented as MUST — the type-less form is named invalid
#   3  PRs remain in dedup scope (repo#102/#121), un-narrowed by +is:issue
#   4  classification is always typed: `near #N (issue)` / `in flight: #N (PR)`,
#      and a PR match is never called a duplicate
#   5  step 4's example table renders a PR match as `in flight`, an issue match
#      as `(issue)`, and the Dedup prose requires the type on every cell
#   6  an existing number's type is re-derived from the forge before use, and
#      `closingIssuesReferences` means implementation, not duplicate
#   7  the command never closes/edits/relabels an existing issue or PR — it
#      files, or it reports — recorded as a safety rule, with rules 1-8 intact

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CMD_DIR="$REPO_ROOT/commands/repo"

FOLLOWUPS_MD="$CMD_DIR/followups.md"

# Assertion helpers (ok/no/skip/assert_eq/assert_contains/assert_not_contains/
# assert_matches/flatten) plus the PASS/FAIL/SKIP/TOTAL counters and color vars
# are shared across the repo test suites — see lib/assert.sh (repo#307).
source "$(dirname "${BASH_SOURCE[0]}")/lib/assert.sh"

if [[ ! -f "$FOLLOWUPS_MD" ]]; then
    echo "FATAL: required file not found at $FOLLOWUPS_MD" >&2
    exit 1
fi

FOLLOWUPS="$(cat "$FOLLOWUPS_MD")"
# Wrapped prose is asserted against the whitespace-flattened form so a reflow
# does not turn a green assertion red.
FLAT="$(flatten "$FOLLOWUPS_MD")"

# ---------------------------------------------------------------------------
echo "1. Command surface and step 3"
# ---------------------------------------------------------------------------

assert_matches "followups.md declares name: followups" "$FOLLOWUPS" '^name: "followups"'
assert_matches "followups.md is user-invocable" "$FOLLOWUPS" '^user-invocable: true'

DEDUP_LN="$(grep -nE '^### 3\. ' "$FOLLOWUPS_MD" | head -1 | cut -d: -f1)"
SCRUB_LN="$(grep -nE '^### 3b\.' "$FOLLOWUPS_MD" | head -1 | cut -d: -f1)"
CONFIRM_LN="$(grep -nE '^### 4\. ' "$FOLLOWUPS_MD" | head -1 | cut -d: -f1)"

if [[ -n "$DEDUP_LN" && -n "$SCRUB_LN" && -n "$CONFIRM_LN" ]]; then
    ok "step 3 (dedup), 3b (scrub) and 4 (confirm) headings all exist"
    STEP3="$(sed -n "${DEDUP_LN},$((SCRUB_LN - 1))p" "$FOLLOWUPS_MD")"
else
    no "step 3 (dedup), 3b (scrub) and 4 (confirm) headings all exist" \
        "3=$DEDUP_LN 3b=$SCRUB_LN 4=$CONFIRM_LN"
    STEP3=""
fi

# ---------------------------------------------------------------------------
echo ""
echo "2. The canonical dedup query emits the match type"
# ---------------------------------------------------------------------------

# The load-bearing expression. Asserted inside step 3's own section, not just
# anywhere in the file, so a stray mention elsewhere cannot satisfy it.
TYPE_EXPR='if .pull_request then "PR" else "issue" end'
assert_contains "step 3's query carries the type expression" "$STEP3" "$TYPE_EXPR"
assert_contains "the type is rendered as a bracketed [PR]/[issue] tag" "$STEP3" \
    '[\(if .pull_request then "PR" else "issue" end)]'
# The type is ADDITIVE to html_url (repo#121), not a replacement for it.
assert_contains "the query still emits html_url alongside the type" "$STEP3" \
    '\(.title) \(.html_url)"'
assert_contains "the query still emits the number" "$STEP3" '"#\(.number)'

# Drift guard: the exact pre-#515 type-less jq form must not come back.
assert_not_contains "the type-less pre-#515 query form is gone" "$FOLLOWUPS" \
    '"#\(.number) \(.title) \(.html_url)"'

# The requirement must be stated as a MUST on any hand-written replacement —
# the incident came from a session writing its own --jq, not from the canonical
# one being wrong.
assert_contains "carrying the type is stated as a MUST" "$FLAT" \
    "A dedup query MUST carry the match type, not only the URL."
assert_contains "a hand-written --jq must emit the type too" "$FLAT" \
    "it **must** emit the type as well as \`html_url\`"
assert_contains "the type-less query is named invalid, not merely discouraged" "$FLAT" \
    "is not a valid dedup query for this step"
assert_contains "the incident is cited, not just asserted" "$FLAT" "repo#515"
assert_contains "the pull_request field is explained as the type signal" "$FLAT" \
    "present only on pull requests"

# ---------------------------------------------------------------------------
echo ""
echo "3. PRs stay in dedup scope (repo#102 / repo#121, unchanged by #515)"
# ---------------------------------------------------------------------------

assert_contains "PRs are still deliberately in scope" "$FOLLOWUPS" \
    "**Pull requests are deliberately in scope.**"
assert_contains "an open PR is still named the stronger dedup signal" "$FLAT" \
    "a candidate is a **stronger** dedup signal than an open issue"

# The wrong fix for #515 would be narrowing the search instead of typing the
# output. Pin the actual query line: it must not carry is:issue.
QUERY_LINE="$(grep -F 'search/issues?q=repo:<slug>' "$FOLLOWUPS_MD" | head -1)"
if [[ -n "$QUERY_LINE" ]]; then
    ok "the canonical search query line is present"
    assert_not_contains "the search is NOT narrowed with is:issue" "$QUERY_LINE" "is:issue"
    assert_contains "the search is still restricted to open items" "$QUERY_LINE" "state:open"
else
    no "the canonical search query line is present" "no search/issues?q=repo:<slug> line"
fi

# ---------------------------------------------------------------------------
echo ""
echo "4. Classification always states the type; a PR match is 'in flight'"
# ---------------------------------------------------------------------------

assert_contains "no type-less classification is allowed" "$FLAT" \
    "there is no type-less near-match"
assert_contains "an issue match is reported as near #N (issue)" "$FLAT" \
    '`near #N (issue)`'
assert_contains "a PR match is reported as in flight: #N (PR)" "$FLAT" \
    '`in flight: #N (PR)`'
assert_contains "a PR match is classified in flight" "$FOLLOWUPS" \
    "**Near-match on a pull request**"
assert_contains "a PR match is explicitly never a duplicate" "$FLAT" \
    'never as a "duplicate"'
assert_contains "the word duplicate is barred from PR numbers entirely" "$FLAT" \
    "never with the word *duplicate* attached to a PR number at all"

# Drift guard: the pre-#515 untyped/duplicate-flavored cell wordings.
assert_not_contains "the old untyped (PR, flag) cell wording is gone" "$FOLLOWUPS" \
    "(PR, flag)"
assert_not_contains "the old untyped (issue, flag) cell wording is gone" "$FOLLOWUPS" \
    "(issue, flag)"

# ---------------------------------------------------------------------------
echo ""
echo "5. Step 4's example table and Dedup prose render the type"
# ---------------------------------------------------------------------------

assert_matches "the example table's PR row renders as in flight" "$FOLLOWUPS" \
    '\| in flight: #99 \(PR\) +\|'
assert_matches "the example table's issue row names the type" "$FOLLOWUPS" \
    '\| near #217 \(issue\) +\|'
assert_matches "a NEW row is still shown for contrast" "$FOLLOWUPS" '\| NEW +\|'
assert_contains "the Dedup prose requires the type on every match cell" "$FLAT" \
    "**A match cell always states the type**"
assert_contains "a bare near #N cell is explicitly rejected" "$FLAT" \
    "never a bare \`near #N\`"
assert_contains "the incident is named as the cost of a type-less cell" "$FLAT" \
    "propose closing an approved PR as a duplicate issue"

# ---------------------------------------------------------------------------
echo ""
echo "6. An existing number's type is verified before it is used"
# ---------------------------------------------------------------------------

assert_contains "the forge type check is documented verbatim" "$FOLLOWUPS" \
    "--jq '.pull_request != null'"
assert_contains "the type check names the REST issues endpoint" "$FOLLOWUPS" \
    'gh api "repos/<slug>/issues/<n>"'
assert_contains "the check is required before a number is written into a row" "$FLAT" \
    "Verify the type before you write a number into a row."
assert_contains "gh issue view is named as NOT a type check" "$FLAT" \
    "\`gh issue view <n>\` is **not** a type check"
assert_contains "gh issue close/comment are named as silent on PR numbers" "$FLAT" \
    "both act on a PR number without"
assert_contains "the misleading gh success message is recorded" "$FOLLOWUPS" \
    "Closed issue"
# The type is re-checked at the point of the write too, not only at classify
# time — the incident's close happened well after classification.
assert_contains "the type is re-checked immediately before commenting" "$FLAT" \
    "Re-check the type immediately before posting"

assert_contains "closingIssuesReferences is named" "$FOLLOWUPS" "closingIssuesReferences"
assert_contains "an implementation is explicitly not a duplicate" "$FLAT" \
    "**An implementation is not a duplicate.**"
assert_contains "the implementing PR is reported in flight, not duplicate" "$FLAT" \
    "never as a duplicate of the thing it implements"

# ---------------------------------------------------------------------------
echo ""
echo "7. The command files or reports — it never acts on an existing item"
# ---------------------------------------------------------------------------

assert_contains "safety rule 9 bars acting on an existing item" "$FOLLOWUPS" \
    "9. **Never act on an existing issue or pull request**"
assert_contains "safety rule 10 requires typed classification" "$FOLLOWUPS" \
    "10. **Classify every match by type, and verify the type before using a"
assert_contains "the files-or-reports posture is stated" "$FLAT" \
    "It never closes, edits, relabels, reopens, or assigns an existing item"
assert_contains "the only two writes are enumerated" "$FLAT" \
    "**Those two POSTs are the only writes this command makes.**"
assert_contains "approving the table is not consent to close anything" "$FLAT" \
    "approving the table never authorizes one"
assert_contains "closing a duplicated issue is left to the user, outside this command" "$FLAT" \
    "closing that issue is the user's call, made outside this command"
assert_contains "gh issue close is named as out of vocabulary" "$FLAT" \
    "\`gh issue close\` has no place in this command at any step"
assert_contains "no flag or approval phrasing unlocks a state change" "$FLAT" \
    "there is no flag, mode, or approval phrasing that unlocks one"

# The pre-existing rules must survive the insertion — a renumbering that
# silently drops one is the classic edit failure here.
for rule in "1. **Never file without confirmation**" "2. **Dedup before filing**" \
            "3. **Never guess a target repo**" "4. **\`--dry-run\` files nothing**" \
            "5. **Reach the forge over REST**" \
            "6. **Scrub before proposing, not before filing**" \
            "7. **Warn, never block, on a confidential source filing to a public target**" \
            "8. **Hold, don't warn, when the source repo opts into block mode**"; do
    assert_contains "pre-existing safety rule intact: $rule" "$FOLLOWUPS" "$rule"
done

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

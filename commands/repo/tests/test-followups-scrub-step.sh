#!/usr/bin/env bash
# Test suite for /repo:followups' pre-filing anti-PII scrub step (repo#265).
#
# Usage: ./commands/repo/tests/test-followups-scrub-step.sh
# Exit code 0 = all tests pass, 1 = failures detected.
#
# Structured like commands/repo/tests/test-scrub-contract.sh: pure bash, no test
# framework, PASS/FAIL/SKIP/TOTAL counters and a summary block. `pnpm test`
# delegates to this file via hooks/repo/tests/run.sh.
#
# WHY THIS FILE EXISTS (repo#265): /repo:followups mines a PRIVATE working
# session and files the result into OTHER repos, usually public ones. Until
# #265 the command said nothing about that boundary, and in a live run
# (2026-08-11) the drafted upstream bodies carried the consumer org/repo name,
# exact fleet sizes, and per-session operational counts — caught only because
# the operator read them before approving. The step added by #265 is prose, so
# the ways it can silently rot are the ways prose rots:
#
#   - The step gets moved after the confirmation table, turning a mechanism
#     into a review checklist. Filing is the point of no return (issue bodies
#     are removable-by-deletion, PR comments permanent), so the ordering
#     dedup -> scrub -> confirm -> file is load-bearing, not stylistic.
#   - Someone "helpfully" inlines scrub.md's detection classes here. Two copies
#     of a class list drift, and the copy in the consuming command is the one
#     nobody updates — the step must CROSS-REFERENCE scrub.md, not restate it.
#   - The visibility column gets dropped from the step-4 table as noise. It is
#     what records which bar each row was held to, and an unresolvable
#     visibility must fail closed (treated as public), not open.
#   - The file:line citation guidance gets replaced by an example that quotes
#     the sensitive value it is teaching readers not to quote.
#
# The contract under test:
#   1  followups.md still exists, is user-invocable, and points at the step
#   2  a scrub step exists and sits between dedup (3) and confirm (4)
#   3  it cross-references scrub.md's detection classes instead of restating
#      them, and names the session-specific classes scrub.md does not cover
#   4  scope is cross-repo candidates; --here is documented as out of scope
#   5  step 4's table carries a visibility column, unknown fails closed
#   6  file:line citation is named the preferred style for public targets, and
#      the "avoid" example is the quoted one
#   7  a safety rule records the constraint
#   8  scrub.md still provides what followups.md now depends on
#
# repo#272 extends this file with the source-confidentiality warning (step
# 3c): the source repo's own CLAUDE.md can declare itself confidential /
# pre-disclosure, and that combines with 3b's already-resolved target `Vis`
# to produce a distinct, louder — but still purely advisory — warning in step
# 4. Two more ways this can rot, on top of the ones above:
#
#   - Step 3c gets built as a hard block instead of advisory, which breaks
#     the "confirm, never auto-apply" posture the rest of the command holds.
#   - The new warning replaces the `Vis` column instead of adding to it, or
#     an ambiguous/missing CLAUDE.md silently suppresses the warning instead
#     of failing closed (warn when in doubt; the sole exception is a CLAUDE.md
#     that does not exist at all — no file, no signal).
#
#   9  a source-confidentiality sub-step (3c) exists, sits after 3b and
#      before 4, is advisory-only, fails closed on ambiguity (not on a
#      missing file), and step 4's warning is additive to 3b's `Vis` column

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CMD_DIR="$REPO_ROOT/commands/repo"

FOLLOWUPS_MD="$CMD_DIR/followups.md"
SCRUB_MD="$CMD_DIR/scrub.md"

PASS=0
FAIL=0
SKIP=0
TOTAL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

for f in "$FOLLOWUPS_MD" "$SCRUB_MD"; do
    if [[ ! -f "$f" ]]; then
        echo "FATAL: required file not found at $f" >&2
        exit 1
    fi
done

FOLLOWUPS="$(cat "$FOLLOWUPS_MD")"
SCRUB="$(cat "$SCRUB_MD")"

# ---------------------------------------------------------------------------
# Assertion helpers
# ---------------------------------------------------------------------------

ok() {   # <label>
    TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1))
    printf "  ${GREEN}PASS${NC}: %s\n" "$1"
}
no() {   # <label> <detail>
    TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
    printf "  ${RED}FAIL${NC}: %s\n" "$1"
    [[ -n "${2:-}" ]] && printf "        %s\n" "$2"
    return 0
}
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

# ---------------------------------------------------------------------------
echo "1. Command surface"
# ---------------------------------------------------------------------------

assert_matches "followups.md declares name: followups" "$FOLLOWUPS" '^name: "followups"'
assert_matches "followups.md is user-invocable" "$FOLLOWUPS" '^user-invocable: true'
assert_contains "the header names the private->public boundary crossing" "$FOLLOWUPS" \
    "visibility boundary crossing"
assert_contains "the header points forward at the scrub step" "$FOLLOWUPS" "see step 3b"

# ---------------------------------------------------------------------------
echo ""
echo "2. The scrub step runs BEFORE the confirmation table, after dedup"
# ---------------------------------------------------------------------------

SCRUB_STEP_LN="$(grep -nE '^### 3b\.' "$FOLLOWUPS_MD" | head -1 | cut -d: -f1)"
DEDUP_LN="$(grep -nE '^### 3\. ' "$FOLLOWUPS_MD" | head -1 | cut -d: -f1)"
CONFIRM_LN="$(grep -nE '^### 4\. ' "$FOLLOWUPS_MD" | head -1 | cut -d: -f1)"
FILE_LN="$(grep -nE '^### 5\. ' "$FOLLOWUPS_MD" | head -1 | cut -d: -f1)"

if [[ -n "$SCRUB_STEP_LN" ]]; then
    ok "a scrub step heading exists (### 3b.)"
else
    no "a scrub step heading exists (### 3b.)" "no '### 3b.' heading in followups.md"
fi

if [[ -n "$SCRUB_STEP_LN" && -n "$DEDUP_LN" && -n "$CONFIRM_LN" && -n "$FILE_LN" ]]; then
    assert_eq "the scrub step follows dedup (step 3)" "yes" \
        "$([[ "$DEDUP_LN" -lt "$SCRUB_STEP_LN" ]] && echo yes || echo no)"
    # The core ordering property: scrubbing after the table would make the
    # operator's read the mechanism instead of the backstop.
    assert_eq "the scrub step precedes the confirmation table (step 4)" "yes" \
        "$([[ "$SCRUB_STEP_LN" -lt "$CONFIRM_LN" ]] && echo yes || echo no)"
    assert_eq "the scrub step precedes filing (step 5)" "yes" \
        "$([[ "$SCRUB_STEP_LN" -lt "$FILE_LN" ]] && echo yes || echo no)"
else
    no "step ordering is checkable" \
        "3b=$SCRUB_STEP_LN 3=$DEDUP_LN 4=$CONFIRM_LN 5=$FILE_LN"
fi

assert_contains "the step title says the scrub happens before proposing" "$FOLLOWUPS" \
    "before they are proposed"
assert_contains "irreversibility is stated as the reason it runs here" "$FOLLOWUPS" \
    "removable-by-deletion"
assert_contains "PR comments are named as permanent" "$FOLLOWUPS" '`permanent`'
assert_contains "the live incident is cited, not just asserted" "$FOLLOWUPS" "2026-08-11"

# ---------------------------------------------------------------------------
echo ""
echo "3. Cross-references scrub.md's classes; never restates them"
# ---------------------------------------------------------------------------

assert_contains "the step links to [[scrub]]" "$FOLLOWUPS" "[[scrub]]"
assert_contains "it points at scrub.md's Detection classes table" "$FOLLOWUPS" \
    "**Detection classes** table"
assert_contains "restating the classes is explicitly forbidden" "$FOLLOWUPS" \
    "do not restate them here"
assert_contains "the affiliated-entity allowlist source is named" "$FOLLOWUPS" \
    '`.repo/scrub.toml`'
# The class names appear as a one-line index into scrub.md's table — a pointer,
# which is the cross-reference itself. The RULES behind them must not follow.
for class in "credentials" "cloud resource IDs" "identity" "affiliated entities" \
             "network topology"; do
    assert_contains "the step indexes scrub.md's class: $class" "$FOLLOWUPS" "$class"
done
assert_contains "keeping a second copy of the classes is named as the failure" "$FOLLOWUPS" \
    "two copies drift"

# The anti-drift property: scrub.md's per-class triage RULES must not be
# duplicated here. A copy in the consuming command is the copy nobody updates.
# (The class NAMES appear as a one-line pointer, which is the cross-reference
# itself; the rules behind them must not.)
for rule in "nearby-word context" "ip-172-31-74-176" "*.noreply.github.com" \
            "Alias expansion" "Substantive vs incidental"; do
    assert_not_contains "followups.md does not duplicate scrub.md's rule: $rule" \
        "$FOLLOWUPS" "$rule"
done

# The three classes that only exist in draft text, which scrub.md cannot cover.
assert_contains "session-specific class: consumer identity" "$FOLLOWUPS" "Consumer identity"
assert_contains "session-specific class: environment fingerprint" "$FOLLOWUPS" \
    "Environment fingerprint"
assert_contains "session-specific class: session identifiers" "$FOLLOWUPS" \
    "Session identifiers"
assert_contains "consumer org/repo slug is named" "$FOLLOWUPS" "org/repo slug"
assert_contains "machine paths are named" "$FOLLOWUPS" "machine paths"
assert_contains "fingerprinting counts are named" "$FOLLOWUPS" "per-session operational counts"
assert_contains "the consumer repo gets a generic replacement" "$FOLLOWUPS" \
    '"a consumer repo"'

# ---------------------------------------------------------------------------
echo ""
echo "4. Scope — cross-repo candidates only; --here is out of scope"
# ---------------------------------------------------------------------------

assert_contains "scope is candidates targeting another repo" "$FOLLOWUPS" \
    "**Scope: every candidate whose target repo is not this repo.**"
assert_contains "--here skips the step entirely" "$FOLLOWUPS" "**skips this step"
assert_contains "the reason --here is exempt is stated" "$FOLLOWUPS" "crosses no"
assert_contains "--repo <tool> is still in scope" "$FOLLOWUPS" "is still cross-repo and is in scope"
assert_contains "a named UNKNOWN target is pulled into scope" "$FOLLOWUPS" \
    "once the user names a slug"

# ---------------------------------------------------------------------------
echo ""
echo "5. Step 4's table carries visibility; unknown fails closed"
# ---------------------------------------------------------------------------

assert_contains "the confirmation table has a visibility column" "$FOLLOWUPS" "| Vis "
assert_matches "a table row carries a resolved visibility value" "$FOLLOWUPS" \
    '\| public +\|'
assert_matches "the UNKNOWN-target row shows unknown visibility" "$FOLLOWUPS" \
    '\| unknown \|'
assert_contains "visibility is resolved from the forge, not guessed" "$FOLLOWUPS" \
    "gh repo view <slug> --json visibility"
assert_contains "the column is explained under the table" "$FOLLOWUPS" \
    "The \`Vis\` column is step 3b's resolved visibility"
assert_contains "public targets get the full bar" "$FOLLOWUPS" "world-readable and permanent"
assert_contains "private is a lower bar, not an exemption" "$FOLLOWUPS" \
    "not an exemption"
# Fail-closed is the property worth pinning: an unresolvable visibility must
# never default to the private (looser) bar.
assert_contains "unknown visibility is treated as public" "$FOLLOWUPS" \
    "treated as **public**"
assert_contains "fail-closed is stated in those words" "$FOLLOWUPS" "Fail"
assert_contains "an unscrubbable candidate is held, not dropped or filed" "$FOLLOWUPS" \
    "HOLD"

# ---------------------------------------------------------------------------
echo ""
echo "6. file:line citation is the preferred style for public targets"
# ---------------------------------------------------------------------------

assert_contains "citation guidance names the preferred style" "$FOLLOWUPS" \
    "point at the value, never quote"
assert_matches "the prefer/avoid example pair is present" "$FOLLOWUPS" '^Prefer: '
assert_matches "the avoid arm shows the quoted form it rejects" "$FOLLOWUPS" '^Avoid: '
assert_matches "the preferred arm cites a path:line" "$FOLLOWUPS" 'Prefer:.*[a-z]+\.sh:[0-9]+'
assert_contains "the citation must be openable by the receiving maintainer" "$FOLLOWUPS" \
    "maintainer can open"
assert_contains "a consumer-only path is described by role, not path" "$FOLLOWUPS" \
    "**role**"
assert_contains "the posture is attributed to scrub, not invented here" "$FOLLOWUPS" \
    "same posture [[scrub]] takes"

# ---------------------------------------------------------------------------
echo ""
echo "7. A safety rule records the constraint"
# ---------------------------------------------------------------------------

assert_contains "safety rule 6 covers the scrub" "$FOLLOWUPS" \
    "6. **Scrub before proposing, not before filing**"
assert_contains "the operator is named as backstop, not mechanism" "$FOLLOWUPS" \
    "backstop, never the mechanism"
# The pre-existing rules must survive the insertion — a renumbering that
# silently drops one is the classic edit failure here.
for rule in "1. **Never file without confirmation**" "2. **Dedup before filing**" \
            "3. **Never guess a target repo**" "4. **\`--dry-run\` files nothing**" \
            "5. **Reach the forge over REST**"; do
    assert_contains "pre-existing safety rule intact: $rule" "$FOLLOWUPS" "$rule"
done

# ---------------------------------------------------------------------------
echo ""
echo "8. scrub.md still provides what followups.md now depends on"
# ---------------------------------------------------------------------------

# followups.md delegates rather than restates, so its correctness depends on
# these anchors continuing to exist in scrub.md. If one is renamed there, this
# names the dependent file to update.
assert_contains "scrub.md still has a Detection classes section" "$SCRUB" \
    "## Detection classes"
for class in "Credentials" "Cloud resource IDs" "Identity" "Affiliated entities" \
             "Network topology"; do
    assert_contains "scrub.md still documents class: $class" "$SCRUB" "$class"
done
assert_contains "scrub.md still classes issue bodies removable-by-deletion" "$SCRUB" \
    "removable-by-deletion"
assert_contains "scrub.md still reads .repo/scrub.toml" "$SCRUB" '`.repo/scrub.toml`'

# ---------------------------------------------------------------------------
echo ""
echo "9. Source-repo confidentiality warning (step 3c, repo#272)"
# ---------------------------------------------------------------------------

SOURCE_STEP_LN="$(grep -nE '^### 3c\.' "$FOLLOWUPS_MD" | head -1 | cut -d: -f1)"

if [[ -n "$SOURCE_STEP_LN" ]]; then
    ok "a source-confidentiality step heading exists (### 3c.)"
else
    no "a source-confidentiality step heading exists (### 3c.)" \
        "no '### 3c.' heading in followups.md"
fi

if [[ -n "$SOURCE_STEP_LN" && -n "$SCRUB_STEP_LN" && -n "$CONFIRM_LN" ]]; then
    assert_eq "step 3c follows step 3b" "yes" \
        "$([[ "$SCRUB_STEP_LN" -lt "$SOURCE_STEP_LN" ]] && echo yes || echo no)"
    assert_eq "step 3c precedes the confirmation table (step 4)" "yes" \
        "$([[ "$SOURCE_STEP_LN" -lt "$CONFIRM_LN" ]] && echo yes || echo no)"
else
    no "step 3c ordering is checkable" "3c=$SOURCE_STEP_LN 3b=$SCRUB_STEP_LN 4=$CONFIRM_LN"
fi

# The confidentiality phrases named in the issue must all be present.
for phrase in "confidential" "do not disclose" "before a provisional is filed" \
              "pre-disclosure"; do
    assert_contains "step 3c names the confidentiality phrase: $phrase" "$FOLLOWUPS" "$phrase"
done

assert_contains "step 3c reads the source repo's own CLAUDE.md" "$FOLLOWUPS" \
    "this repo's root \`CLAUDE.md\`"
assert_contains "step 3c honors a structured opt-in in .repo/scrub.toml" "$FOLLOWUPS" \
    "structured opt-in in \`.repo/scrub.toml\`"

# Fail-closed on ambiguity, but NOT on an absent file — these are opposite
# outcomes and a single grep can't tell them apart, so pin both directions.
assert_contains "step 3c fails closed on ambiguous matches (warn when in doubt)" \
    "$FOLLOWUPS" "When in doubt, warn"
assert_contains "a missing CLAUDE.md is the one case that does NOT warn" "$FOLLOWUPS" \
    "missing** \`CLAUDE.md\`"

# The warning must be additive to Vis, not a replacement — and advisory-only,
# matching the rest of the command's confirm-first posture.
assert_contains "the step-4 warning is additive to the Vis column, not a replacement" \
    "$FOLLOWUPS" "additive to the \`Vis\` column, not"
assert_contains "the warning text appears above the confirmation table" "$FOLLOWUPS" \
    "SOURCE REPO LOOKS CONFIDENTIAL"
assert_contains "the warning is explicitly advisory-only" "$FOLLOWUPS" \
    "**purely advisory**"
assert_contains "the warning never blocks filing" "$FOLLOWUPS" \
    "it never blocks filing and never auto-redacts"

# It must cross-reference 3b's Vis resolution rather than re-deriving target
# visibility from scratch — same anti-duplication property as step 3b's own
# reuse of scrub.md's classes.
assert_contains "step 3c/4 reuses 3b's resolved Vis rather than re-deriving it" \
    "$FOLLOWUPS" "3b's already-resolved"

assert_contains "safety rule 7 covers the source-confidentiality warning" "$FOLLOWUPS" \
    "7. **Warn, never block, on a confidential source filing to a public target**"

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

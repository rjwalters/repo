#!/usr/bin/env bash
# Test suite for /repo:links' precision rules — the two fixes that stand between
# "a useful cross-reference checker" and "30 findings, 0 real".
#
# Usage: ./commands/repo/tests/test-links-precision.sh
# Exit code 0 = all tests pass, 1 = failures detected.
#
# Structured like commands/repo/tests/test-scrub-contract.sh: pure bash, no test
# framework, PASS/FAIL/SKIP/TOTAL counters and a summary block. `pnpm test`
# delegates to this file via hooks/repo/tests/run.sh.
#
# WHY THIS FILE EXISTS (repo#190): a /repo:all run against a healthy 603-file
# repo reported 30 broken internal links, and every single one was a false
# positive. Two causes, neither of which the command's rules addressed:
#
#   1. Inline code spans were scanned as links, so the checker flagged the
#      sentences in links.md and audit.md that DESCRIBE what it looks for.
#   2. Links were resolved only against the containing file's directory. 28 of
#      the 30 were in .loom/CLAUDE.md, which writes root-relative paths — the
#      correct convention there, since a CLAUDE.md is loaded into an agent's
#      context and its paths read from the repo root.
#
# The second one is the dangerous half: links.md calls CLAUDE.md references
# CRITICAL severity, so the highest-severity class in the checker was the class
# most likely to be wrong.
#
# The cost is not the wasted minute. A check that returns 100% noise on a
# healthy repo teaches people to skim past its output, which is expensive the
# first time it is right — so "precision is itself a finding" is part of the
# contract, not a nicety.
#
# The contract under test:
#   1  fenced blocks and inline code spans are stripped before scanning
#   2  links resolve against BOTH the file's directory and the repo root, and a
#      finding requires failing both
#   3  CLAUDE.md's root-relative convention is named as correct, not a defect
#   4  vendored/installer-managed files are reported but never edited in place
#   5  a high false-positive rate is surfaced as its own finding
#   6  the two real-world false positives no longer match the documented scan

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CMD_DIR="$REPO_ROOT/commands/repo"

LINKS_MD="$CMD_DIR/links.md"
AUDIT_MD="$CMD_DIR/audit.md"

PASS=0
FAIL=0
SKIP=0
TOTAL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

if [[ ! -f "$LINKS_MD" ]]; then
    echo "FATAL: links.md not found at $LINKS_MD" >&2
    exit 1
fi

LINKS="$(cat "$LINKS_MD")"

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

# ---------------------------------------------------------------------------
echo "1. Code spans are stripped before scanning"
# ---------------------------------------------------------------------------

assert_contains "links.md requires stripping code before scanning" "$LINKS" \
    "Strip code before scanning"
assert_contains "fenced blocks are stripped" "$LINKS" '```.*?```'
assert_contains "inline spans are stripped" "$LINKS" '`[^`]*`'
assert_contains "the self-flagging failure is named" "$LINKS" \
    "flags the sentences in this very file"

# ---------------------------------------------------------------------------
echo ""
echo "2. Two-base resolution"
# ---------------------------------------------------------------------------

assert_contains "both bases documented" "$LINKS" \
    "Resolve against two bases"
assert_contains "a finding requires failing both" "$LINKS" \
    "missing under **both**"
assert_contains "the repo root is one of the bases" "$LINKS" "the repo root"
assert_contains "the resolving base is stated when non-obvious" "$LINKS" \
    "base resolved it when the answer"
assert_contains "the 28-finding incident is recorded" "$LINKS" \
    "28 wrong findings"

# ---------------------------------------------------------------------------
echo ""
echo "3. CLAUDE.md root-relative is correct, not a defect"
# ---------------------------------------------------------------------------

assert_contains "CLAUDE.md paths are read from the repo root" "$LINKS" \
    "loaded into an agent's context and its paths are read from the repo"
assert_contains "critical severity is tied to the resolution risk" "$LINKS" \
    "the one most likely to be wrong"
assert_contains "nested CLAUDE.md also uses two bases" "$LINKS" \
    "against that directory **and** the repo"

# ---------------------------------------------------------------------------
echo ""
echo "4. Vendored files reported, never edited"
# ---------------------------------------------------------------------------

assert_contains "vendored/installer-managed section exists" "$LINKS" \
    "Vendored and installer-managed files"
assert_contains "never edited in place" "$LINKS" "reported but never edited in"
assert_contains "the next install overwrites the edit" "$LINKS" \
    "install overwrites the edit"
assert_contains "the upstream owner is named in the report" "$LINKS" \
    "name the upstream repo that owns the file"

# ---------------------------------------------------------------------------
echo ""
echo "5. Precision is itself a finding"
# ---------------------------------------------------------------------------

assert_contains "precision section exists" "$LINKS" "Precision is itself a finding"
assert_contains "a noisy run is reported on its own line" "$LINKS" \
    "0 actionable"
assert_contains "the cost of noise is stated" "$LINKS" \
    "teaches people to skim past its output"

# ---------------------------------------------------------------------------
echo ""
echo "6. The two real false positives no longer match the documented scan"
# ---------------------------------------------------------------------------

# Reproduce the documented strip on the actual files that produced the two
# code-span false positives in repo#190, then confirm no bare `[text](path)`
# link survives on those lines. This is the regression itself, not a proxy.
strip_code() {  # <file> -> file text with fenced blocks and inline spans removed
    perl -0777 -pe 's/```.*?```//gs; s/`[^`]*`//g' "$1" 2>/dev/null
}

if ! command -v perl >/dev/null 2>&1; then
    skip "code-span stripping clears the links.md false positive" "perl not available"
    skip "code-span stripping clears the audit.md false positive" "perl not available"
else
    LINKS_STRIPPED="$(strip_code "$LINKS_MD")"
    # The literal that tripped the checker: `[text](path)` inside backticks.
    assert_eq "stripping clears the links.md '[text](path)' code span" "0" \
        "$(printf '%s\n' "$LINKS_STRIPPED" | grep -cF '[text](path)')"

    if [[ -f "$AUDIT_MD" ]]; then
        AUDIT_STRIPPED="$(strip_code "$AUDIT_MD")"
        assert_eq "stripping clears the audit.md '[text](path)' code span" "0" \
            "$(printf '%s\n' "$AUDIT_STRIPPED" | grep -cF '[text](path)')"
        # And confirm the span really is there pre-strip, or the test proves nothing.
        assert_eq "audit.md does carry the span pre-strip (test is meaningful)" "1" \
            "$(grep -cF '`[text](path)`' "$AUDIT_MD")"
    else
        skip "stripping clears the audit.md '[text](path)' code span" "audit.md not found"
        skip "audit.md does carry the span pre-strip (test is meaningful)" "audit.md not found"
    fi
fi

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

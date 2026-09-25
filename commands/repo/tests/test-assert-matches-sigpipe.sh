#!/usr/bin/env bash
# Regression test for repo#466: assert_matches() in lib/assert.sh used to pipe
# `printf '%s\n' "$haystack" | grep -qE -- "$pattern"` under `set -o
# pipefail`. `grep -q` exits (and closes its stdin) as soon as it finds the
# first match; if `printf` is still writing when that happens it can receive
# SIGPIPE (exit 141), and under `pipefail` that nonzero exit wins the
# pipeline's reported status even though `grep` itself found a genuine match
# — so `assert_matches` intermittently reported FAIL for a pattern that
# actually matched. The race rate scales with haystack size and host pipe
# buffer behavior (see the issue's own reproduction notes).
#
# This test loops the real assert_matches() many times against a haystack
# large enough to have triggered the pre-fix race (a multi-KB, multi-line
# string, well past a small pipe buffer, with the target pattern near the end
# so grep must read most of the input before it can match), asserting 0
# failures across the run. It also pins the two correctness edge cases the
# fix must not break: a genuine non-match must still report FAIL, and a
# haystack too small to ever race must still behave correctly.
#
# Usage: ./commands/repo/tests/test-assert-matches-sigpipe.sh
# Exit code 0 = all tests pass, 1 = failures detected.

set -uo pipefail

# Assertion helpers (ok/no/skip/assert_eq/assert_contains/assert_not_contains/
# assert_matches) plus the PASS/FAIL/SKIP/TOTAL counters and color vars are
# shared across the repo test suites — see lib/assert.sh (repo#307).
source "$(dirname "${BASH_SOURCE[0]}")/lib/assert.sh"

echo "-- flake-detection loop: assert_matches() against a large haystack --"

# Build a haystack large enough to reproduce the pre-fix SIGPIPE race: many
# lines, several KB, with the target pattern near the END so grep has to read
# most of the input before it can match (this is what let `grep -q` close its
# stdin mid-write in the pre-fix pipe). Mirrors the issue's own reproduction
# against a large `followups.md`.
build_haystack() {
    local i
    for i in $(seq 1 2000); do
        printf 'line %04d: filler content to widen the haystack past a pipe buffer\n' "$i"
    done
    printf 'name: "followups"\n'
    for i in $(seq 2001 2100); do
        printf 'line %04d: more filler after the target pattern\n' "$i"
    done
}
HAYSTACK="$(build_haystack)"

ITERATIONS=300
flake_before=$FAIL
for i in $(seq 1 "$ITERATIONS"); do
    # Call the real assert_matches() directly (no subshell): its ok()/no()
    # calls mutate the shared PASS/FAIL/TOTAL counters, which is exactly what
    # lets the delta below detect a flaky FAIL. Redirecting this single
    # command's stdout does not fork a subshell in bash, so the counter
    # mutation is still visible after the loop. Output is silenced only to
    # avoid 300 lines of "PASS: iteration N" noise.
    assert_matches "iteration $i" "$HAYSTACK" '^name: "followups"' >/dev/null
done
flake_fails=$((FAIL - flake_before))

assert_eq "assert_matches() reports 0 flaky failures across $ITERATIONS iterations" "0" "$flake_fails"

echo ""
echo "-- correctness edge cases (fix must not paper over real mismatches) --"

# Run each probe assertion in an isolated subshell so its ok()/no() call does
# not itself contribute a PASS/FAIL count to *this* suite's totals (a
# subshell's variable mutations do not escape to the parent shell) — this
# suite's own PASS/FAIL is decided by whether assert_matches printed the
# label we expected, not by whatever assert_matches itself decided.
probe() {  # <haystack> <ere>
    ( assert_matches "probe" "$1" "$2" )
}

result="$(probe "$HAYSTACK" '^this pattern does not appear anywhere$')"
if [[ "$result" == *FAIL* ]]; then
    ok "large haystack: genuine non-match still reports FAIL"
else
    no "large haystack: genuine non-match still reports FAIL" "expected FAIL, got: $result"
fi

result="$(probe "$HAYSTACK" '^name: "followups"')"
if [[ "$result" == *PASS* ]]; then
    ok "large haystack: genuine match still reports PASS"
else
    no "large haystack: genuine match still reports PASS" "expected PASS, got: $result"
fi

result="$(probe "small haystack" '^small')"
if [[ "$result" == *PASS* ]]; then
    ok "small haystack (below any race threshold): genuine match reports PASS"
else
    no "small haystack (below any race threshold): genuine match reports PASS" "expected PASS, got: $result"
fi

result="$(probe "small haystack" '^nomatch')"
if [[ "$result" == *FAIL* ]]; then
    ok "small haystack (below any race threshold): genuine non-match reports FAIL"
else
    no "small haystack (below any race threshold): genuine non-match reports FAIL" "expected FAIL, got: $result"
fi

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

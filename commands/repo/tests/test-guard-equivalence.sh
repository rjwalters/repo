#!/usr/bin/env bash
# Guard equivalence harness (repo#193) — compares the canonical guard against
# Loom's vendored copy over a shared corpus and asserts the canonical guard is
# never WEAKER.
#
# Usage: ./commands/repo/tests/test-guard-equivalence.sh
# Exit code 0 = all cases pass (or the suite skipped cleanly), 1 = failures.
#
# WHY THIS FILE EXISTS
#
# rjwalters/loom#5660: the vendored copy drifted ~2,200 lines ahead of its
# upstream while its own header said not to hand-edit it. That drift was
# invisible for as long as it existed because nothing compared the two.
#
# repo#188 then paid the cost of measuring the difference once, by hand. The
# measurement changed the conclusion: counting functions and grep hits said
# four capability gaps; comparing verdicts said two. `systemctl` and fastpath
# tiering diverged on ZERO cases and were correctly not ported, avoiding ~700
# lines of churn and a Loom-specific allowlist in a tool-agnostic guard. The
# two real gaps had different causes than their symptoms suggested.
#
# That harness then died with the session. This is it, made permanent.
#
# THE RULE: NEVER WEAKER, NOT EQUAL
#
# Loom's dispatcher swaps this guard in for its own on a single capability
# marker (`worktree-write-confinement`), so shipping something more permissive
# silently downgrades protection fleet-wide, while shipping something stricter
# does not. Exact equality is the wrong invariant — it fails when this guard
# fixes a bug the vendored copy still has, which is precisely what happened in
# repo#188 (the symlinked-ancestor write-confinement bypass). So:
#
#   equal verdicts        -> pass
#   canonical STRICTER    -> pass, and REPORTED BY NAME so it stays visible
#   canonical WEAKER      -> fail
#
# Strictness order: deny > ask > allow.
#
# KNOWN DELIBERATE DIVERGENCES are declared in one place (below) with their
# rationale, so they read as decisions rather than drift.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

CANONICAL="$REPO_ROOT/hooks/repo/guard-destructive.sh"
VENDORED="$REPO_ROOT/.loom/hooks/guard-destructive-generic.sh"
CASES="$SCRIPT_DIR/guard-equivalence-cases.txt"

PASS=0
FAIL=0
SKIP=0
TOTAL=0
STRICTER=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# Known deliberate divergences — canonical is intentionally stricter here.
# Keyed by exact command string. Anything NOT listed that comes back stricter
# is still a pass, but is reported as an undeclared divergence so it gets
# either fixed or declared.
# ---------------------------------------------------------------------------
# Each entry was MEASURED, not assumed — an entry here that no longer diverges
# is dead weight, and one that diverges without an entry is reported as
# undeclared. Do not add speculative rows.
declare -a DECLARED_DIVERGENCES=(
    "aws iam delete-role --role-name admin|canonical hard-denies IAM deletion; vendored asks. Documented in README.md and skills/repo/SKILL.md as the deliberate divergence that makes a Loom-managed repo stricter after the capability probe flips (repo#188)."
    "az group delete --name rg1 --yes|canonical hard-denies Azure resource-group deletion; vendored asks. Same posture as the IAM row: cloud teardown is deny-by-default here, and a repo whose job IS managing cloud infra opts out via guards.cloudCli:false rather than by weakening the default."
    "gcloud compute instances delete vm1|canonical hard-denies GCP instance deletion; vendored asks. Same rationale as the az row."
)

declared_reason() {  # <command> -> reason, or empty
    local cmd="$1" entry
    for entry in "${DECLARED_DIVERGENCES[@]}"; do
        if [[ "${entry%%|*}" == "$cmd" ]]; then
            printf '%s' "${entry#*|}"
            return 0
        fi
    done
    printf ''
}

# ---------------------------------------------------------------------------
# Preconditions — skip cleanly, never fail, when the vendored copy is absent.
# A non-Loom-managed checkout of this repo has nothing to compare against.
# The skip is COUNTED and printed so it can never be mistaken for a pass.
# ---------------------------------------------------------------------------
if [[ ! -f "$CANONICAL" ]]; then
    echo "FATAL: canonical guard not found at $CANONICAL" >&2
    exit 1
fi
if [[ ! -f "$CASES" ]]; then
    echo "FATAL: case corpus not found at $CASES" >&2
    exit 1
fi
if [[ ! -r "$VENDORED" ]]; then
    echo "guard-equivalence harness"
    echo "========================="
    printf "  ${YELLOW}SKIP${NC}: vendored guard not present at %s\n" "$VENDORED"
    echo "        (not a Loom-managed checkout — nothing to compare against)"
    echo ""
    echo "========================="
    echo "  Total:  0"
    printf "  ${GREEN}Passed${NC}: 0\n"
    printf "  ${RED}Failed${NC}: 0\n"
    printf "  ${YELLOW}Skipped${NC}: 1\n"
    echo "========================="
    printf "\n${GREEN}SUITE SKIPPED (no vendored guard)${NC}\n"
    exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "FATAL: jq is required" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Scratch repo — every case runs from here, so verdicts never depend on the
# developer's cwd or on an ambient worktree.
#
# NOTE: both guards must be invoked at their real in-tree paths. A guard copied
# to /tmp and run from there fails open and reports `allow` for everything,
# which silently turns this whole suite green (learned the hard way in repo#192
# review). Never "helpfully" copy the guards somewhere neutral.
# ---------------------------------------------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
git -C "$WORK" init -q 2>/dev/null
git -C "$WORK" -c user.email=t@example.com -c user.name=t \
    commit -q --allow-empty -m init 2>/dev/null

decide() {  # <guard> <command> -> deny|ask|allow
    local guard="$1" cmd="$2" input out dec
    input=$(jq -n --arg c "$cmd" --arg w "$WORK" '{tool_input:{command:$c}, cwd:$w}')
    out=$(printf '%s' "$input" | bash "$guard" 2>/dev/null)
    if [[ -z "$out" ]]; then
        printf 'allow'
        return
    fi
    dec=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null)
    printf '%s' "${dec:-allow}"
}

rank() {  # <verdict> -> integer, higher = stricter
    case "$1" in
        deny)  printf '2' ;;
        ask)   printf '1' ;;
        allow) printf '0' ;;
        *)     printf '-1' ;;
    esac
}

echo "guard-equivalence harness"
echo "========================="
echo "canonical: $CANONICAL"
echo "vendored:  $VENDORED"
echo ""

declare -a UNDECLARED=()

while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    TOTAL=$((TOTAL + 1))

    dec_c=$(decide "$CANONICAL" "$line")
    dec_v=$(decide "$VENDORED" "$line")
    r_c=$(rank "$dec_c")
    r_v=$(rank "$dec_v")

    short="${line:0:64}"

    if [[ "$dec_c" == "$dec_v" ]]; then
        PASS=$((PASS + 1))
        printf "  ${GREEN}ok${NC}    %-7s %s\n" "$dec_c" "$short"
    elif [[ "$r_c" -gt "$r_v" ]]; then
        PASS=$((PASS + 1))
        STRICTER=$((STRICTER + 1))
        reason="$(declared_reason "$line")"
        if [[ -n "$reason" ]]; then
            printf "  ${BLUE}ok${NC}    ${BLUE}STRICTER${NC} canonical=%-5s vendored=%-5s %s\n" \
                "$dec_c" "$dec_v" "$short"
            printf "        declared: %s\n" "$reason"
        else
            printf "  ${BLUE}ok${NC}    ${BLUE}STRICTER${NC} canonical=%-5s vendored=%-5s %s\n" \
                "$dec_c" "$dec_v" "$short"
            printf "        ${YELLOW}undeclared divergence${NC} — fix it, or add it to DECLARED_DIVERGENCES with a rationale\n"
            UNDECLARED+=("$line ($dec_c vs $dec_v)")
        fi
    else
        FAIL=$((FAIL + 1))
        printf "  ${RED}FAIL${NC}  canonical WEAKER: canonical=%-5s vendored=%-5s %s\n" \
            "$dec_c" "$dec_v" "$short"
    fi
done < "$CASES"

echo ""
echo "========================="
echo "  Total:  $TOTAL"
printf "  ${GREEN}Passed${NC}: %s\n" "$PASS"
printf "  ${RED}Failed${NC}: %s\n" "$FAIL"
printf "  ${YELLOW}Skipped${NC}: %s\n" "$SKIP"
printf "  ${BLUE}Stricter${NC}: %s (canonical ahead of the vendored copy)\n" "$STRICTER"
echo "========================="

if [[ ${#UNDECLARED[@]} -gt 0 ]]; then
    printf "\n${YELLOW}Undeclared stricter divergences (%s):${NC}\n" "${#UNDECLARED[@]}"
    printf '  %s\n' "${UNDECLARED[@]}"
    echo "  These pass (stricter is allowed) but should be declared or fixed."
fi

if [[ $FAIL -gt 0 ]]; then
    printf "\n${RED}TESTS FAILED${NC} — the canonical guard is more permissive than the vendored copy.\n"
    printf "This is the direction that downgrades protection fleet-wide once Loom's\n"
    printf "capability probe swaps this guard in. Fix before merging.\n"
    exit 1
fi
printf "\n${GREEN}ALL TESTS PASSED${NC}\n"
exit 0

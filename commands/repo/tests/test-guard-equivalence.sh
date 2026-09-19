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
#   equal verdicts             -> pass
#   canonical STRICTER         -> pass, and REPORTED BY NAME so it stays visible
#   canonical WEAKER, declared -> pass, and REPORTED, with the rationale
#   canonical WEAKER otherwise -> fail
#
# Strictness order: deny > ask > allow.
#
# The declared-weaker case is not a loophole, it is the recognition that a
# weaker VERDICT is not the same as a weaker GUARD. The vendored copy denies
# `echo <destructive-string>` — but echo prints its argument, it does not run
# it, so that deny prevents nothing and blocks ordinary work (documenting a
# destructive command, filing an issue about one, running this repo's own guard
# tests). Being correct there means being more permissive there. Both lists are
# short, every row states its reasoning, and an UNDECLARED divergence in either
# direction is surfaced — stricter as a warning, weaker as a hard failure.
#
# TWO FIXTURE CWDs (repo#438)
#
# Until repo#438 every case ran from ONE cwd: a flat scratch git repo with no
# sibling worktree. `worktree-write-confinement` only engages when an ALTERNATE
# Loom-managed worktree exists alongside the acting checkout, so that
# precondition was never met — every write-confinement verdict collapsed to
# `allow` in both guards, and divergences in the one capability the dispatcher
# swap is keyed on were invisible BY CONSTRUCTION rather than merely absent.
#
# So there are now two fixtures, and a corpus row opts into the second with a
# `wt:` line prefix (see guard-equivalence-cases.txt):
#
#   default   -> $WORK,   a flat scratch repo (unchanged, still the default)
#   `wt:` row -> $WTC_WT, a Loom-managed worktree whose main checkout is a real
#                git repo with a .loom/worktrees/issue-1 sibling carrying
#                `.loom-managed` (the make_wt_confinement_repo() shape from
#                hooks/repo/tests/test-guard-destructive.sh)
#
# `{{MAIN}}` and `{{WT}}` in a `wt:` row expand to those two absolute paths,
# since both are mktemp paths not knowable when the corpus is written.
#
# A BROKEN fixture would re-create exactly the blindness this fixes — every
# `wt:` row would quietly read `allow == allow` and pass. So the fixture is
# canaried (see WTC_CANARY below): if a plain redirect into the main checkout
# from the worktree cwd does not deny in BOTH guards, the suite FAILS instead
# of reporting a green run over a dead fixture.

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
WEAKER_DECLARED=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# Known deliberate divergences — canonical is intentionally stricter here.
# Keyed by the exact corpus LINE, verbatim: for a `wt:` row that means the
# `wt:` prefix and the unexpanded `{{MAIN}}`/`{{WT}}` placeholders are part of
# the key (the expanded paths are mktemp temporaries, different every run, so
# they could never be a stable key). Anything NOT listed that comes back
# stricter is still a pass, but is reported as an undeclared divergence so it
# gets either fixed or declared.
# ---------------------------------------------------------------------------
# Each entry was MEASURED, not assumed — an entry here that no longer diverges
# is dead weight, and one that diverges without an entry is reported as
# undeclared. Do not add speculative rows.
declare -a DECLARED_DIVERGENCES=(
    "aws iam delete-role --role-name admin|canonical hard-denies IAM deletion; vendored asks. Documented in README.md and skills/repo/SKILL.md as the deliberate divergence that makes a Loom-managed repo stricter after the capability probe flips (repo#188)."
    "az group delete --name rg1 --yes|canonical hard-denies Azure resource-group deletion; vendored asks. Same posture as the IAM row: cloud teardown is deny-by-default here, and a repo whose job IS managing cloud infra opts out via guards.cloudCli:false rather than by weakening the default."
    "gcloud compute instances delete vm1|canonical hard-denies GCP instance deletion; vendored asks. Same rationale as the az row."
    "rm -rf \"/\"|repo#197: canonical dequotes inert spans AFTER sink-aware redaction, so quoting an operative argument no longer defeats the literal catastrophic patterns. The vendored copy still allows this; it is the same command to the shell as the bare form."
    "rm -rf '/'|repo#197: single-quoted form of the row above; same fix, same rationale."
    "git push --force origin \"main\"|repo#197: quoting the branch name downgraded a hard deny to a mere ask in both guards. Canonical now denies; the vendored copy still asks."
    "git push -f origin 'main'|repo#197: -f short-flag, single-quoted branch. Same fix and rationale as the --force row above."
    "rg --pre 'rm -rf /' . | head -3|repo#311: ripgrep's --pre names an external preprocessor program that rg EXECUTES, so an rg carrying it is vetoed out of query-sink treatment and its pattern stays visible to the catastrophic scan. The vendored copy has no query sinks at all and allows this shape outright."
    "grep 'rm -rf /' f.txt | sh|repo#311: the pattern is piped into a shell that WOULD execute it, so command_has_shell_segment() skips the redaction entirely and canonical denies. The vendored copy allows it; this is the safety floor that makes the query sinks safe, and it is measurably stricter here."
    "rg -m \"use --pre for preprocessing\" 'rm -rf /' . | head -3|repo#434: the --pre veto token sits inside a -m value that strip_literal_text() blanks, so the veto only fires because the data-sink pass now reads the RAW command. Canonical denies; the vendored copy has no query sinks at all and allows every rg shape outright (same posture as the plain rg --pre row above). The sed and awk rows of this trio match the vendored copy exactly and need no entry."
    "wt:echo hi > \"{{MAIN}}/o-\$(echo x|tr -d x).json\"|repo#438: a write target carrying a command substitution, issued from a Loom-managed worktree into its own main checkout. Canonical resolves the target past the substitution and denies under worktree-write-confinement; the vendored copy still allows it — a live worktree-isolation bypass, and the first divergence in this capability the harness has ever been able to see (measured deny vs allow, 2026-09-19)."
    "wt:echo \"\$(id|tee {{MAIN}}/evil.sh)\"|repo#438: a tee into the main checkout smuggled inside a command substitution, which the shell EXECUTES. repo#437 stopped qsplit() splitting the outer stream at a separator inside \$( ), so canonical now sees the inner segment and denies; the vendored copy still allows it. Measured deny vs allow, 2026-09-19."
    "wt:echo \"\$(id && cp /tmp/s {{MAIN}}/e.sh)\"|repo#438: same shape as the tee row, with the write idiom after a && separator rather than a pipe, confirming the fix is separator-general and not pipe-specific. Canonical denies, vendored allows. Measured 2026-09-19."
)

# ---------------------------------------------------------------------------
# Deliberately WEAKER than the vendored copy.
#
# "Weaker verdict" and "less safe" are not the same thing. The entries here are
# cases where the vendored guard produces a FALSE POSITIVE and this guard is
# correct to allow: a string handed to echo/printf as data is printed, not
# executed, so denying it blocks ordinary work (documenting a destructive
# command, filing an issue about one, running this repo's own guard tests) while
# preventing nothing. That is repo#53.
#
# The safety property is preserved by construction: the redaction that makes
# these allow is skipped entirely when a shell segment is present, so
# `echo '<payload>' | sh` — where the data IS executed — still hard-denies. It
# is also never applied to spans carrying $( or a backtick.
#
# This list is deliberately SHORT and every row states why the permissiveness is
# correct. An undeclared weaker verdict is still a hard failure; adding a row
# here to silence one is the wrong move unless the vendored guard is genuinely
# wrong about it.
#
# Rows are MEASURED, never speculative (same discipline as DECLARED_DIVERGENCES
# above). repo#311 added query sinks for jq/grep/egrep/fgrep/rg/inert-sed/awk
# and corpus cases for all of them, but only the two rows below actually came
# back weaker than the vendored copy — the vendored guard already allows the
# jq/grep/egrep/fgrep/rg shapes, so declaring those too would be dead weight.
# ---------------------------------------------------------------------------
declare -a DECLARED_WEAKER=(
    "printf '%s\\n' \"rm -rf /\"|repo#53: printf prints its argument, it does not execute it. The vendored guard denies this, which blocks documenting a destructive command. Redaction is skipped when a shell segment is present, so a piped-to-shell payload still denies."
    "echo 'git push --force origin main'|repo#53: same as the printf row — echo of a string is not execution of it."
    "sed -n 's|rm -rf /|X|p' log.jsonl|repo#311: an inert sed (no -i, no w/W write command, no e execute command) only PRINTS what it matches — the pattern is data, not a command. The vendored guard denies it, which blocks auditing a log for the literal text of a catastrophic pattern. The acting sub-forms (sed -i, s///w, e) are vetoed out of sink treatment and still deny in both guards (see the corpus rows below this one)."
    "awk '\$0 ~ \"git push --force origin main\" {print}' log.jsonl|repo#311: same as the sed row — awk program text is matched and printed, never executed. system(…) and pipe-to-command (print | \"cmd\") are vetoed out of sink treatment and still deny in both guards."
)

# Both lookups match on the "<command>|" PREFIX rather than on `${entry%%|*}`
# (repo#311). `%%|*` truncates at the FIRST pipe, so any corpus case that
# contains a `|` — `grep '<pattern>' f | sh`, a jq filter, an awk pipe-to-
# command — could never be declared at all: its key silently became the text
# before its first pipe, the declaration never matched, and a hard FAIL was
# reported with the row sitting right there in the array. The prefix test is
# exact for the `<command>|<reason>` row format and behaves identically for
# every pipe-free row. Only the trailing `*` is a glob: the "$cmd|" half is
# quoted, so a command containing `*`/`?`/`[` is compared literally.
declared_reason() {  # <command> -> reason, or empty
    local cmd="$1" entry
    for entry in "${DECLARED_DIVERGENCES[@]}"; do
        if [[ "$entry" == "$cmd|"* ]]; then
            printf '%s' "${entry#"$cmd|"}"
            return 0
        fi
    done
    printf ''
}

declared_weaker_reason() {  # <command> -> reason, or empty
    local cmd="$1" entry
    for entry in "${DECLARED_WEAKER[@]}"; do
        if [[ "$entry" == "$cmd|"* ]]; then
            printf '%s' "${entry#"$cmd|"}"
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
# Scratch repo — the DEFAULT cwd for every case, so verdicts never depend on
# the developer's cwd or on an ambient worktree. A `wt:` row opts into the
# worktree fixture built immediately below instead (repo#438).
#
# NOTE: both guards must be invoked at their real in-tree paths. A guard copied
# to /tmp and run from there fails open and reports `allow` for everything,
# which silently turns this whole suite green (learned the hard way in repo#192
# review). Never "helpfully" copy the guards somewhere neutral.
# ---------------------------------------------------------------------------
WORK="$(mktemp -d)"
WTC_MAIN=""
# shellcheck disable=SC2317 # invoked indirectly, by the EXIT trap below
cleanup() {
    [[ -n "$WTC_MAIN" && -d "$WTC_MAIN" ]] && rm -rf "$WTC_MAIN"
    rm -rf "$WORK"
}
trap cleanup EXIT
git -C "$WORK" init -q 2>/dev/null
git -C "$WORK" -c user.email=t@example.com -c user.name=t \
    commit -q --allow-empty -m init 2>/dev/null

# ---------------------------------------------------------------------------
# Second fixture (repo#438): a main checkout with a Loom-managed worktree
# sibling, so `worktree-write-confinement` can actually engage.
#
# Mirrors make_wt_confinement_repo() in hooks/repo/tests/test-guard-destructive.sh:
# a real git repo, plus `.loom/worktrees/issue-1` added with `git worktree add`
# and carrying the `.loom-managed` sentinel worktree.sh writes. Both halves
# matter — the sentinel alone is not enough, the alternate worktree must be
# registered with git for the guard to see a main root to confine writes to.
#
# WTC_READY gates the `wt:` corpus rows. If the fixture cannot be built (no
# `git worktree` support, a read-only TMPDIR), those rows are SKIPPED and
# counted, never silently run against a cwd that makes them all pass.
# ---------------------------------------------------------------------------
WTC_READY=0
WTC_WT=""
WTC_MAIN="$(mktemp -d)"
if git -C "$WTC_MAIN" init -q 2>/dev/null &&
    git -C "$WTC_MAIN" -c user.email=t@example.com -c user.name=t \
        commit -q --allow-empty -m init 2>/dev/null &&
    mkdir -p "$WTC_MAIN/.loom/worktrees" 2>/dev/null; then
    WTC_WT="$WTC_MAIN/.loom/worktrees/issue-1"
    if git -C "$WTC_MAIN" worktree add -q -b "eqv-$(basename "$WTC_MAIN")" \
        "$WTC_WT" >/dev/null 2>&1 && touch "$WTC_WT/.loom-managed" 2>/dev/null; then
        WTC_READY=1
    fi
fi

decide() {  # <guard> <command> [cwd] -> deny|ask|allow
    local guard="$1" cmd="$2" cwd="${3:-$WORK}" input out dec
    input=$(jq -n --arg c "$cmd" --arg w "$cwd" '{tool_input:{command:$c}, cwd:$w}')
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

expand_wt() {  # <corpus line, minus the wt: prefix> -> command with paths filled in
    local cmd="$1"
    cmd="${cmd//\{\{MAIN\}\}/$WTC_MAIN}"
    cmd="${cmd//\{\{WT\}\}/$WTC_WT}"
    printf '%s' "$cmd"
}

echo "guard-equivalence harness"
echo "========================="
echo "canonical: $CANONICAL"
echo "vendored:  $VENDORED"
if [[ "$WTC_READY" -eq 1 ]]; then
    echo "wt cwd:    $WTC_WT (main checkout: $WTC_MAIN)"
else
    printf "wt cwd:    ${YELLOW}unavailable${NC} — 'wt:' cases will be skipped\n"
fi
echo ""

# ---------------------------------------------------------------------------
# Fixture canary (repo#438). A fixture that LOOKS built but does not actually
# engage worktree-write-confinement would make every `wt:` row read
# `allow == allow` and pass — the exact silent blindness repo#438 exists to
# remove. So assert the precondition directly, against both guards, on the
# most basic confinement shape there is. This is a property of the FIXTURE,
# not a corpus case: it must deny in both, and a weaker verdict from either is
# a broken harness rather than a declarable divergence.
# ---------------------------------------------------------------------------
if [[ "$WTC_READY" -eq 1 ]]; then
    TOTAL=$((TOTAL + 1))
    canary_cmd="echo x > $WTC_MAIN/canary.sh"
    canary_c=$(decide "$CANONICAL" "$canary_cmd" "$WTC_WT")
    canary_v=$(decide "$VENDORED" "$canary_cmd" "$WTC_WT")
    if [[ "$canary_c" == "deny" && "$canary_v" == "deny" ]]; then
        PASS=$((PASS + 1))
        printf "  ${GREEN}ok${NC}    %-7s [fixture canary] plain redirect into main checkout denies in both\n" "deny"
    else
        FAIL=$((FAIL + 1))
        printf "  ${RED}FAIL${NC}  [fixture canary] worktree-write-confinement is NOT engaging: canonical=%s vendored=%s\n" \
            "$canary_c" "$canary_v"
        printf "        Every 'wt:' case below is therefore meaningless — fix the fixture, do not declare the rows.\n"
    fi
fi

declare -a UNDECLARED=()

while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    TOTAL=$((TOTAL + 1))

    cwd="$WORK"
    cmd="$line"
    if [[ "$line" == wt:* ]]; then
        if [[ "$WTC_READY" -ne 1 ]]; then
            SKIP=$((SKIP + 1))
            printf "  ${YELLOW}SKIP${NC}  %-7s %s\n" "no-wt-fixture" "${line:0:64}"
            continue
        fi
        cmd="$(expand_wt "${line#wt:}")"
        cwd="$WTC_WT"
    fi

    dec_c=$(decide "$CANONICAL" "$cmd" "$cwd")
    dec_v=$(decide "$VENDORED" "$cmd" "$cwd")
    r_c=$(rank "$dec_c")
    r_v=$(rank "$dec_v")

    # Declarations and the printed label both key on the RAW corpus line, so
    # they stay stable across runs even though $WTC_MAIN is a fresh mktemp
    # path every time.
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
        wreason="$(declared_weaker_reason "$line")"
        if [[ -n "$wreason" ]]; then
            PASS=$((PASS + 1))
            WEAKER_DECLARED=$((WEAKER_DECLARED + 1))
            printf "  ${YELLOW}ok${NC}    ${YELLOW}WEAKER (declared)${NC} canonical=%-5s vendored=%-5s %s\n" \
                "$dec_c" "$dec_v" "$short"
            printf "        %s\n" "$wreason"
        else
            FAIL=$((FAIL + 1))
            printf "  ${RED}FAIL${NC}  canonical WEAKER: canonical=%-5s vendored=%-5s %s\n" \
                "$dec_c" "$dec_v" "$short"
        fi
    fi
done < "$CASES"

echo ""
echo "========================="
echo "  Total:  $TOTAL"
printf "  ${GREEN}Passed${NC}: %s\n" "$PASS"
printf "  ${RED}Failed${NC}: %s\n" "$FAIL"
printf "  ${YELLOW}Skipped${NC}: %s\n" "$SKIP"
printf "  ${BLUE}Stricter${NC}: %s (canonical ahead of the vendored copy)\n" "$STRICTER"
printf "  ${YELLOW}Weaker (declared)${NC}: %s (vendored false positives this guard deliberately allows)\n" "$WEAKER_DECLARED"
echo "========================="

if [[ ${#UNDECLARED[@]} -gt 0 ]]; then
    printf "\n${YELLOW}Undeclared stricter divergences (%s):${NC}\n" "${#UNDECLARED[@]}"
    printf '  %s\n' "${UNDECLARED[@]}"
    echo "  These pass (stricter is allowed) but should be declared or fixed."
fi

if [[ $FAIL -gt 0 ]]; then
    printf "\n${RED}TESTS FAILED${NC} — either the canonical guard is more permissive than the\n"
    printf "vendored copy on a case above, or the fixture canary did not engage (repo#438).\n"
    printf "The first is the direction that downgrades protection fleet-wide once Loom's\n"
    printf "capability probe swaps this guard in. The second means the 'wt:' cases measured\n"
    printf "nothing at all, which is how this blind spot went unnoticed in the first place.\n"
    printf "Fix before merging.\n"
    exit 1
fi
printf "\n${GREEN}ALL TESTS PASSED${NC}\n"
exit 0

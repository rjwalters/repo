#!/usr/bin/env bash
# Test suite pinning commands/repo/sudo.md's guard note — both the DOCUMENTED
# claims and the guard BEHAVIOUR those claims describe (repo#249).
#
# Usage: ./commands/repo/tests/test-sudo-rm-guard-contract.sh
# Exit code 0 = all tests pass, 1 = failures detected.
#
# Structured like commands/repo/tests/test-scrub-contract.sh and
# test-skill-commands-table.sh: pure bash, no test framework, PASS/FAIL/SKIP/
# TOTAL counters and a summary block. `pnpm test` delegates to this file via
# hooks/repo/tests/run.sh.
#
# WHY THIS FILE EXISTS (repo#249): repo#244 changed the rm-scope guard,
# sudo.md was not updated, and nothing noticed — that one-way drift is what
# repo#245 reported. repo#248 fixed the doc AND pinned the guard (two
# assert_deny cases in hooks/repo/tests/test-guard-destructive.sh), but pinned
# only the behaviour side. Until this file existed, the entire guard note could
# be deleted from sudo.md and the suite stayed green: the same drift, in the
# opposite direction. The repo already treats this class as worth a dedicated
# suite — test-readme-layout-block.sh (repo#211/#212) and
# test-skill-commands-table.sh (repo#246) both exist because a hand-maintained
# artifact drifted from reality with nothing checking it, and sudo.md's guard
# note is the same shape: hand-written prose asserting specific facts about
# guard behaviour.
#
# WHAT IS PINNED:
#   1  the guard note blocks exist and parse (a deleted note is loud, not silent)
#   2  both rule tags are named in the doc AND exist in guard-destructive.sh
#   3  the rm guard's trigger is config-only and defaults to `repo` — so the
#      write guard's zero-managed-worktree carve-out is not reintroduced here
#   4  a fully-resolved literal $DROPIN does not escape either (it just changes
#      which rule fires)
#   5  the per-call-site consequences and the operator remedy (a LITERAL path)
#   6  behaviour: the four rm shapes read out of sudo.md's own fences, the
#      literal out-of-repo target, both multi-line if-blocks as they really
#      appear, the write/rm asymmetry at zero managed worktrees, and the
#      rmScope=off opt-out
#
# REFLOW-PROOFING: every prose assertion runs against a FLATTENED copy of the
# note — blockquote markers stripped, lines folded to one, whitespace squeezed.
# The note is a hard-wrapped `>` blockquote, so a claim like "in this file, are
# denied inside a Loom-managed repo session" spans a line break in the source
# and a naive line-based grep would miss it. This matters in both directions:
# it is why section 1 asserts a deliberately break-spanning needle as a
# self-check on the flattener, and it is why re-wrapping the note cannot fail
# this suite. (Discovered the hard way during repo#249: a `sed`-based fault
# injection silently did not apply because the target phrase wrapped, and the
# suite stayed green for the wrong reason — a FALSE NEGATIVE, the worst
# possible outcome for a drift check.) The tolerance boundary is deliberate:
# re-wrapping at WORD boundaries cannot fail this suite, but a wrap that splits
# a backticked token (`worktree-write-confinement-\nunresolved-var`) does fail —
# that is not a reflow, it changes the rendered code span.
#
# SCOPE DECISION: this suite deliberately does NOT verify any `line ~NNN`
# citation in the note. repo#250 raised exactly that drift risk and repo#255
# resolved it by REMOVING the citations in favour of step/role references
# ("step 3's `--remove`", "this step's rollback") — which is what the prose
# assertions below key on. If a future edit reintroduces line numbers, pinning
# them is a separate concern from this suite's claims.
#
# Verified by fault injection in BOTH directions before landing (repo#246's
# rule: a check must be proven to fail, not trusted because it passes). Each row
# was applied to a scratch copy of commands/ + hooks/, run, then reverted:
#
#   doc side   flip the WRAPPED "defaults to `repo`" claim to `off`      1 fail
#   doc side   delete the whole step 5 guard note blockquote            28 fails
#   doc side   rewrite the uninstall remedy to the `"$DROPIN"` form      1 fail
#   doc side   add a fifth `rm` to a fence ("all four" claim)            2 fails
#   doc side   drop the `rm-scope-outside-repo` tag name from the note   1 fail
#   guard side rm_scope_repo_enabled() forced false (guard narrowed)     9 fails
#   guard side rename the rm-scope-unresolved-var tag in the guard       7 fails
#   control    re-wrap the WHOLE note to 95 cols (pure reflow)           0 fails
#
# The last row is the point of the flattening: a pure reflow must NOT go red.
# The "uninstall remedy" row is why both remedy sites are asserted separately —
# a single "appears somewhere" check stayed green through that injection.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SUDO_MD="$REPO_ROOT/commands/repo/sudo.md"
GUARD="$REPO_ROOT/hooks/repo/guard-destructive.sh"

PASS=0
FAIL=0
# Every case here is unconditional — nothing in this suite is environment- or
# version-gated — so SKIP stays 0. The column is kept because run.sh's delegated
# -suite plumbing parses the shared `Skipped:` summary line when present.
SKIP=0
TOTAL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

for f in "$SUDO_MD" "$GUARD"; do
    if [[ ! -f "$f" ]]; then
        echo "FATAL: required file not found at $f" >&2
        exit 1
    fi
done
if ! command -v jq >/dev/null 2>&1; then
    echo "FATAL: jq is required to run these tests" >&2
    exit 1
fi

# --- Ambient guard-env neutralization ---------------------------------------
# Same hazard as hooks/repo/tests/test-guard-destructive.sh's preamble (repo#134):
# a dispatched agent's shell exports LOOM_FORCE_SCOPE / LOOM_GUARD_DECISION_LOG
# (and friends) into every child process, which silently redefines what "default"
# means for the behaviour cases below — the ones that assert the guard's
# factory-default rmScope=repo posture. Neutralize BOTH the REPO_* name and its
# legacy LOOM_* alias before any case runs; cases that need a non-default value
# set it explicitly and locally via `env VAR=val` in guard_run.
for _guard_env_var in \
    REPO_GUARD_READONLY_FASTPATH LOOM_GUARD_READONLY_FASTPATH \
    REPO_GUARD_SQL LOOM_GUARD_SQL \
    REPO_GUARD_CLOUD LOOM_GUARD_CLOUD \
    REPO_GUARD_REVERSIBLE_GH LOOM_GUARD_REVERSIBLE_GH \
    REPO_GUARD_DECISION_LOG LOOM_GUARD_DECISION_LOG \
    REPO_GUARD_DECISION_LOG_FILE LOOM_GUARD_DECISION_LOG_FILE \
    REPO_RM_SCOPE LOOM_RM_SCOPE \
    REPO_FORCE_SCOPE LOOM_FORCE_SCOPE \
    REPO_DEFAULT_BRANCH LOOM_DEFAULT_BRANCH \
    LOOM_WORKTREE_ROOT; do
    unset "$_guard_env_var"
done
unset _guard_env_var

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

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
assert_contains() {  # <label> <haystack> <needle>
    if [[ "$2" == *"$3"* ]]; then ok "$1"; else no "$1" "missing [$3]"; fi
}
assert_guard_defines() {  # <label> <ere>  -- grep the guard source file directly
    # Greps the FILE, not a `printf "$GUARD_SRC" | grep -q` pipeline: under
    # `set -o pipefail`, grep -q's early exit on a 5000-line haystack makes
    # printf die on SIGPIPE (141), so the pipeline reports failure even on a
    # match. That produced four bogus failures while developing this file.
    if grep -qE -- "$2" "$GUARD"; then
        ok "$1"
    else
        no "$1" "no match for /$2/ in hooks/repo/guard-destructive.sh"
    fi
}
assert_eq() {  # <label> <expected> <actual>
    if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1" "expected [$2], got [$3]"; fi
}

# flatten <text> -> one line: leading blockquote markers stripped, lines folded,
# runs of whitespace squeezed to a single space. This is what makes every prose
# assertion below reflow-proof (see REFLOW-PROOFING in the header).
flatten() {
    printf '%s\n' "$1" \
        | sed -e 's/^[[:space:]]*>[[:space:]]\{0,1\}//' \
        | tr '\n' ' ' \
        | tr -s '[:space:]' ' '
}

# guard_run <cwd> <command> [ENV=VAL ...]
# Drives the REAL hook with a Claude Code PreToolUse payload and sets:
#   GUARD_DECISION  deny|ask|allow   (no output at all == allow)
#   GUARD_TAG       the rule tag from the guard's own decision log, or ""
# The decision log is the only place the tag is exposed (deny() logs it but does
# not put it in the JSON), so it is enabled per-invocation against a private
# scratch file — never the repo's default log path.
GUARD_DECISION=""
GUARD_TAG=""
guard_run() {
    local cwd="$1" cmd="$2"; shift 2
    local logf="$SCRATCH/decision.log"
    rm -f "$logf"
    local out
    out=$(jq -n --arg cmd "$cmd" --arg cwd "$cwd" \
            '{tool_name:"Bash", tool_input:{command:$cmd}, cwd:$cwd}' \
          | env "$@" REPO_GUARD_DECISION_LOG=1 REPO_GUARD_DECISION_LOG_FILE="$logf" \
                bash "$GUARD" 2>/dev/null) || true
    if [[ -z "$out" ]]; then
        GUARD_DECISION="allow"
    else
        GUARD_DECISION=$(printf '%s' "$out" \
            | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null) || GUARD_DECISION="allow"
        [[ -n "$GUARD_DECISION" ]] || GUARD_DECISION="allow"
    fi
    GUARD_TAG=""
    if [[ -f "$logf" ]]; then
        GUARD_TAG=$(jq -r 'select(.decision == "deny" or .decision == "ask") | .pattern' "$logf" 2>/dev/null | tail -1)
    fi
}

# assert_decision <label> <expected> <cwd> <command> [ENV=VAL ...]
assert_decision() {
    local label="$1" expected="$2" cwd="$3" cmd="$4"; shift 4
    guard_run "$cwd" "$cmd" "$@"
    if [[ "$GUARD_DECISION" == "$expected" ]]; then
        ok "$label"
    else
        no "$label" "got $GUARD_DECISION, want $expected"
    fi
}

# assert_deny_tag <label> <expected-tag> <cwd> <command> [ENV=VAL ...]
assert_deny_tag() {
    local label="$1" tag="$2" cwd="$3" cmd="$4"; shift 4
    guard_run "$cwd" "$cmd" "$@"
    if [[ "$GUARD_DECISION" == "deny" && "$GUARD_TAG" == "$tag" ]]; then
        ok "$label"
    else
        no "$label" "got ${GUARD_DECISION}/${GUARD_TAG:-<no tag>}, want deny/$tag"
    fi
}

# ---------------------------------------------------------------------------
echo "1. The guard note blocks exist and flatten correctly"
# ---------------------------------------------------------------------------
# Everything downstream reads these two blocks. If either goes missing the
# assertions must go RED — never vacuously pass against an empty haystack, which
# is exactly the "deleted note, green suite" failure this file exists for.

# Step 5's consolidated guard note: the blockquote opening with "Guard note —
# these two writes", up to the first line that leaves the blockquote.
NOTE_RAW="$(awk '
    /^>[[:space:]]*\*\*Guard note — these two writes/ { f = 1 }
    f { if ($0 !~ /^>/) exit; print }
' "$SUDO_MD")"
# Step 3's short pointer note.
STEP3_RAW="$(awk '
    /^>[[:space:]]*\*\*Guard note\*\*:/ { f = 1 }
    f { if ($0 !~ /^>/) exit; print }
' "$SUDO_MD")"

NOTE="$(flatten "$NOTE_RAW")"
STEP3="$(flatten "$STEP3_RAW")"

if [[ -n "$NOTE_RAW" ]]; then
    ok "step 5 carries a consolidated guard note blockquote"
else
    no "step 5 carries a consolidated guard note blockquote" \
        "no '> **Guard note — these two writes' blockquote in $SUDO_MD"
fi
if [[ -n "$STEP3_RAW" ]]; then
    ok "step 3 (--remove) carries its own guard note blockquote"
else
    no "step 3 (--remove) carries its own guard note blockquote" \
        "no '> **Guard note**:' blockquote in $SUDO_MD"
fi

# Self-check on the flattener itself: this needle spans a hard line break in the
# source AND crosses a blockquote marker, so it can only match after flattening.
# If flatten() ever stops stripping/folding, this fails and every prose
# assertion below is known to be untrustworthy rather than silently weakened.
assert_contains "flattened note joins across a hard-wrapped line + '>' marker" \
    "$NOTE" "in this file, are denied inside a Loom-managed repo session"

# ---------------------------------------------------------------------------
echo ""
echo "2. Both rule tags are named in the doc AND exist in the guard"
# ---------------------------------------------------------------------------
# The tags are the doc's most checkable claim: they name specific deny sites in
# guard-destructive.sh. Asserting them in BOTH places is what makes this a
# cross-check rather than a restatement of the prose.

assert_contains "note names the rm-scope-unresolved-var tag" \
    "$NOTE" 'tag `rm-scope-unresolved-var`'
assert_contains "note names the rm-scope-outside-repo rule" \
    "$NOTE" '`rm-scope-outside-repo`'
assert_contains "note names the write guard's worktree-write-confinement-unresolved-var tag" \
    "$NOTE" 'tag `worktree-write-confinement-unresolved-var`'
assert_contains "note attributes both tags to hooks/repo/guard-destructive.sh" \
    "$NOTE" '`hooks/repo/guard-destructive.sh`'

assert_guard_defines "guard-destructive.sh really denies with rm-scope-unresolved-var" \
    'deny .*"rm-scope-unresolved-var"'
assert_guard_defines "guard-destructive.sh really denies with rm-scope-outside-repo" \
    'deny .*"rm-scope-outside-repo"'
assert_guard_defines "guard-destructive.sh really denies with worktree-write-confinement-unresolved-var" \
    'deny .*"worktree-write-confinement-unresolved-var"'

# ---------------------------------------------------------------------------
echo ""
echo "3. The rm guard's trigger is config-only and defaults to repo"
# ---------------------------------------------------------------------------
# This is the claim that most needs pinning. The write guard has a real
# zero-managed-worktree carve-out; the rm guard does not. A future edit that
# "tidies" the note by extending the carve-out to both guards would tell an
# operator the rm denials go away outside a Loom checkout — they don't.

assert_contains "note names rm_scope_repo_enabled() as the trigger" \
    "$NOTE" '`rm_scope_repo_enabled()`'
assert_contains "note states the rm trigger checks config only" \
    "$NOTE" 'checks **config only**'
assert_contains "note names the guards.rmScope config knob" \
    "$NOTE" '`guards.rmScope`'
assert_contains "note names the LOOM_RM_SCOPE env knob" \
    "$NOTE" '`LOOM_RM_SCOPE`'
assert_contains "note names the REPO_RM_SCOPE env knob" \
    "$NOTE" '`REPO_RM_SCOPE`'
assert_contains "note states the rm trigger defaults to repo" \
    "$NOTE" 'defaults to `repo`'
assert_contains "note states the zero-managed-worktree escape hatch does NOT apply to rm" \
    "$NOTE" 'zero-managed-worktree escape hatch above does NOT apply to it'
assert_contains "note states a host session avoids the write denials but not the rm denials" \
    "$NOTE" 'avoids the write denials above but does **not** avoid these `rm` denials'
# The contrast side: the write guard's trigger IS worktree-conditional, and the
# note says so. Without this, "config only" reads as a claim about both guards.
assert_contains "note states the write deny is keyed to any managed worktree existing" \
    "$NOTE" 'keyed to whether **any** managed worktree exists in the repository'
assert_contains "note states the write guard fails open with zero managed worktrees" \
    "$NOTE" 'With zero managed worktrees the write guard fails open'

assert_guard_defines "guard-destructive.sh really defines rm_scope_repo_enabled()" \
    '^rm_scope_repo_enabled\(\)'

# ---------------------------------------------------------------------------
echo ""
echo "4. A resolved literal \$DROPIN does not escape — it changes which rule fires"
# ---------------------------------------------------------------------------
# The tempting "fix" for these denials is to make the guard resolve $DROPIN.
# The note explains why that is not a fix; if the explanation is dropped, the
# next reader re-derives the wrong conclusion.

assert_contains "note gives the resolved literal path" \
    "$NOTE" '`/etc/sudoers.d/<user>-nopasswd`'
assert_contains "note states the resolved path is outside the repo under any resolution" \
    "$NOTE" 'outside the repo under *any* resolution and would still be denied'
assert_contains "note states resolution only changes which rule fires" \
    "$NOTE" 'only changes which rule fires, not the outcome'
assert_contains "note rejects an /etc/sudoers.d allowlist entry as the remedy" \
    "$NOTE" 'would require an `/etc/sudoers.d` allowlist entry'

# ---------------------------------------------------------------------------
echo ""
echo "5. Per-call-site consequences and the operator remedy"
# ---------------------------------------------------------------------------
# The consequences are the operator-visible half: --remove silently cannot
# finish, and a failed rollback strands a live sudoers drop-in. Both must stay
# stated, and the remedy must use a LITERAL path (a remedy spelled "$DROPIN"
# would be denied by the same guard it is meant to route around).

assert_contains "note states --remove cannot complete automatically" \
    "$NOTE" '`--remove` cannot complete automatically'
assert_contains "note states a denied rollback leaves the drop-in installed" \
    "$NOTE" 'the drop-in stays installed'
assert_contains "note flags the rollback as the serious case" \
    "$NOTE" 'the serious case'
assert_contains "note characterises the \$TMP cleanup denials as low-stakes" \
    "$NOTE" 'low-stakes'
# BOTH remedy sites are asserted separately, on purpose: a single "does the
# literal path appear anywhere" check stays green when one of the two remedies
# is rewritten to `sudo rm -f "$DROPIN"` (verified by fault injection — that is
# exactly what happened on the first attempt).
assert_contains "uninstall remedy uses a literal path, not \$DROPIN" \
    "$NOTE" 'run `sudo rm -f /etc/sudoers.d/<user>-nopasswd`, then `sudo visudo -c` to confirm the removal'
assert_contains "rollback remedy uses a literal path, not \$DROPIN" \
    "$NOTE" 'then `sudo rm -f /etc/sudoers.d/<user>-nopasswd` by hand to remove the stranded file'
assert_contains "note forbids disabling the guards to push the delete through" \
    "$NOTE" 'disabling `guards.worktreeIsolation` / `guards.rmScope`'
assert_contains "note forbids hardcoding a predictable temp path" \
    "$NOTE" 'Do not "fix" the write side by hardcoding a predictable temp path'

# Step 3's note must both state the denial and point at step 5 — a bare "see
# below" (or a broken anchor) is how the consolidated note gets orphaned.
assert_contains "step 3 note states the denial under default guards.rmScope=repo" \
    "$STEP3" 'default `guards.rmScope=repo`'
assert_contains "step 3 note cross-references step 5's consolidated note" \
    "$STEP3" '(#5-confirm-then-write--validate--roll-back)'

# ---------------------------------------------------------------------------
echo ""
echo "6. Behaviour: the four rm calls read out of sudo.md's own fences"
# ---------------------------------------------------------------------------
# Read the rm invocations from the document rather than restating them, so
# adding a fifth rm (or rewording one) is caught instead of silently uncovered.
# The count is itself the check on the note's "all four `rm` calls" claim.

FENCES="$(awk '
    /^[[:space:]]*```bash[[:space:]]*$/ { f = 1; next }
    /^[[:space:]]*```[[:space:]]*$/     { f = 0; next }
    f { print }
' "$SUDO_MD")"

RM_LINES=()
while IFS= read -r _line; do
    [[ -n "$_line" ]] && RM_LINES+=("$_line")
done < <(printf '%s\n' "$FENCES" | sed -e 's/^[[:space:]]*//' | grep -E '^(sudo[[:space:]]+)?rm[[:space:]]')

assert_eq "sudo.md's bash fences contain exactly 4 rm calls (the note's claim)" \
    "4" "${#RM_LINES[@]}"

if [[ ${#RM_LINES[@]} -eq 0 ]]; then
    no "each documented rm call is denied by the real guard" \
        "no rm invocations extracted from sudo.md's bash fences — extraction is stale"
else
    for _rm in "${RM_LINES[@]}"; do
        assert_deny_tag "documented rm denies (rm-scope-unresolved-var): $_rm" \
            "rm-scope-unresolved-var" "$REPO_ROOT" "$_rm"
    done
fi

# ---------------------------------------------------------------------------
echo ""
echo "7. Behaviour: literal target, multi-line forms, asymmetry, opt-out"
# ---------------------------------------------------------------------------

# 7a. The fully-resolved literal target the note says would "still be denied,
# just by the ordinary out-of-repo rule". Asserting the TAG is what proves the
# note's claim about WHICH rule fires, not merely that something denied.
assert_deny_tag "literal /etc/sudoers.d/<user>-nopasswd denies (rm-scope-outside-repo)" \
    "rm-scope-outside-repo" "$REPO_ROOT" 'sudo rm -f /etc/sudoers.d/alice-nopasswd'

# 7b. The rollback as it REALLY appears — a multi-line if-block, not the bare
# one-liner. Same-command resolution does not rescue it: the surrounding
# `sudo visudo -c` does not make $DROPIN resolvable. test-guard-destructive.sh's
# repo#248 pair covers the one-line shapes only, so this is the form that would
# be missed if the guard's multi-line segmentation regressed.
ROLLBACK_BLOCK="$(awk '
    /^if ! sudo visudo -c; then$/ { f = 1 }
    f { print; if ($0 ~ /^fi$/) exit }
' "$SUDO_MD")"
if [[ -n "$ROLLBACK_BLOCK" ]]; then
    assert_deny_tag "multi-line post-install rollback block denies (rm-scope-unresolved-var)" \
        "rm-scope-unresolved-var" "$REPO_ROOT" "$ROLLBACK_BLOCK"
else
    no "multi-line post-install rollback block denies (rm-scope-unresolved-var)" \
        "could not extract the 'if ! sudo visudo -c; then ... fi' block from $SUDO_MD"
fi

VALIDATE_BLOCK="$(awk '
    /^if ! sudo visudo -cf "\$TMP"; then$/ { f = 1 }
    f { print; if ($0 ~ /^fi$/) exit }
' "$SUDO_MD")"
if [[ -n "$VALIDATE_BLOCK" ]]; then
    assert_deny_tag "multi-line validation-failure cleanup block denies (rm-scope-unresolved-var)" \
        "rm-scope-unresolved-var" "$REPO_ROOT" "$VALIDATE_BLOCK"
else
    no "multi-line validation-failure cleanup block denies (rm-scope-unresolved-var)" \
        "could not extract the 'if ! sudo visudo -cf \"\$TMP\"; then ... fi' block from $SUDO_MD"
fi

# 7c. The write/rm ASYMMETRY, which is the whole point of section 3's prose.
# A scratch git repo with ZERO managed worktrees: the write guard fails open,
# the rm guard still fails closed. If these two ever agree, the note is wrong.
NOWT_REPO="$SCRATCH/no-worktrees"
mkdir -p "$NOWT_REPO"
git -C "$NOWT_REPO" init -q

assert_decision "zero managed worktrees: sudo cp \"\$TMP\" \"\$DROPIN\" runs (write fails open)" \
    "allow" "$NOWT_REPO" 'sudo cp "$TMP" "$DROPIN"'
assert_decision "zero managed worktrees: { ... } > \"\$TMP\" runs (write fails open)" \
    "allow" "$NOWT_REPO" '{ echo "# header"; } > "$TMP"'
assert_decision "zero managed worktrees: sudo rm -f \"\$DROPIN\" STILL denied (config-only trigger)" \
    "deny" "$NOWT_REPO" 'sudo rm -f "$DROPIN"'
assert_decision "zero managed worktrees: rm -f \"\$TMP\" STILL denied (config-only trigger)" \
    "deny" "$NOWT_REPO" 'rm -f "$TMP"'

# The other side of the asymmetry: with a managed worktree present the write
# guard does fire, exactly as the note says. Without this case, "fails open" and
# "keyed to whether any managed worktree exists" are both untested.
WT_REPO="$SCRATCH/with-worktree"
mkdir -p "$WT_REPO/.loom/worktrees/issue-1"
git -C "$WT_REPO" init -q
: > "$WT_REPO/.loom/worktrees/issue-1/.loom-managed"

assert_decision "managed worktree present: sudo cp \"\$TMP\" \"\$DROPIN\" denied (write fails closed)" \
    "deny" "$WT_REPO" 'sudo cp "$TMP" "$DROPIN"'
assert_decision "managed worktree present: { ... } > \"\$TMP\" denied (write fails closed)" \
    "deny" "$WT_REPO" '{ echo "# header"; } > "$TMP"'

# 7d. The documented opt-out, via BOTH surfaces the note names. rmScope=off must
# restore permissive behaviour byte-for-byte — the note tells operators this
# escape hatch is theirs to pull, so it has to keep working.
OFF_REPO="$SCRATCH/rmscope-off"
mkdir -p "$OFF_REPO/.claude/skills/repo"
git -C "$OFF_REPO" init -q
printf '{"guards":{"rmScope":"off"}}\n' > "$OFF_REPO/.claude/skills/repo/config.json"

assert_decision "guards.rmScope=off (config): sudo rm -f \"\$DROPIN\" allowed" \
    "allow" "$OFF_REPO" 'sudo rm -f "$DROPIN"'
assert_decision "guards.rmScope=off (config): literal /etc/sudoers.d target allowed" \
    "allow" "$OFF_REPO" 'sudo rm -f /etc/sudoers.d/alice-nopasswd'
assert_decision "REPO_RM_SCOPE=off (env): sudo rm -f \"\$DROPIN\" allowed" \
    "allow" "$NOWT_REPO" 'sudo rm -f "$DROPIN"' REPO_RM_SCOPE=off
assert_decision "LOOM_RM_SCOPE=off (legacy env): rm -f \"\$TMP\" allowed" \
    "allow" "$NOWT_REPO" 'rm -f "$TMP"' LOOM_RM_SCOPE=off

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

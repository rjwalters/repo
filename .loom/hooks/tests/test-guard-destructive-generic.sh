#!/usr/bin/env bash
# Test suite for .loom/hooks/guard-destructive-generic.sh's echo/printf
# data-sink redaction (issue #305, porting the upstream #53 fix).
#
# Usage: ./.loom/hooks/tests/test-guard-destructive-generic.sh
#
# guard-destructive-generic.sh is a VENDORED fallback copy of Repo Skills'
# canonical hooks/repo/guard-destructive.sh (see that file's own header:
# "DO NOT hand-edit generic pattern behavior here — send fixes upstream").
# Before #305 it had NO dedicated test file at all in .loom/hooks/tests/
# (only test-guard-background-subagents.sh, test-guard-loom-workspace.sh,
# test-guard-worktree-paths.sh, test-methodology-inject.sh, and
# test-skill-router.sh existed here). #305 ported strip_datasink_literals()
# and command_has_shell_segment() from the canonical guard's #53 fix — since
# Loom's dispatcher (.loom/hooks/guard-destructive.sh) cannot yet select the
# canonical guard in a repo like this one (probe (c), #5916, is permanently
# inert), every session that falls back to THIS file needs the #53 fix too.
#
# This suite is DELIBERATELY narrow in scope: it covers only the ported
# echo/printf data-sink redaction and its safety floor (mirroring the
# relevant cases from hooks/repo/tests/test-guard-destructive.sh's own
# "Data-sink (echo/printf) quoted-literal false positive (#53)" section), not
# a full port of that suite's ~1400+ cases. Broader regression coverage for
# this vendored file already exists indirectly via
# hooks/repo/tests/test-guard-destructive.sh's own
# "equivalence: ..." assertions, which run the SAME write-target fixtures
# through both the canonical guard and this vendored copy and fail if this
# copy is ever WEAKER.
#
# Covered here:
#   (a) the exact `rm -rf /` inside quoted echo JSON data -> allow (the #305
#       repro: a guard self-test payload piped into a guard script)
#   (b) a real, un-quoted-as-data destructive command -> still denied
#   (c) `echo '<payload>' | sh` (data piped into a shell that would execute
#       it) -> still denied (the command_has_shell_segment() gate)
#   (d) a quoted redirect target after echo/printf -> still confined
#       correctly by Bash-tool write confinement (the `redir` flag /
#       repo#197 case — the redaction must never blind write-target
#       extraction to a real destination path)
#   ...plus a handful of closely-related safety-floor cases (command
#   substitution / backtick smuggling, bash -c / sh -c not being data sinks,
#   a real command in a separate pipeline segment, and the ask-tier mirror).
#
# The hook under test is the canonical source at .loom/hooks/ (there is no
# defaults/ mirror for this file — it is the Repo-Skills-vendored fallback
# guard itself, see its own header comment), copied into an isolated temp
# git tree so write-confinement's real-filesystem worktree checks
# (.loom-managed sentinel, git worktree) resolve there instead of against
# this actual repo checkout. Exit 0 = all pass, 1 = fail.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SRC_HOOK="$REPO_ROOT/.loom/hooks/guard-destructive-generic.sh"

PASS=0
FAIL=0
TOTAL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
git -C "$TMPROOT" init -q
git -C "$TMPROOT" -c user.email=test@example.com -c user.name=test \
    commit -q --allow-empty -m init
mkdir -p "$TMPROOT/.loom/hooks"
cp "$SRC_HOOK" "$TMPROOT/.loom/hooks/guard-destructive-generic.sh"
chmod +x "$TMPROOT/.loom/hooks/guard-destructive-generic.sh"
HOOK="$TMPROOT/.loom/hooks/guard-destructive-generic.sh"

pass() { PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1)); printf "${GREEN}PASS${NC} %s\n" "$1"; }
fail() { FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1)); printf "${RED}FAIL${NC} %s\n" "$1"; }

# Build the real PreToolUse JSON shape Claude Code hands a Bash PreToolUse
# hook (matches hooks/repo/tests/test-guard-destructive.sh's make_input()).
make_input() {
    local cmd="$1" cwd="${2:-$TMPROOT}"
    jq -n --arg cmd "$cmd" --arg cwd "$cwd" '{
        tool_name: "Bash",
        tool_input: { command: $cmd },
        cwd: $cwd
    }'
}

run_hook() {
    local cmd="$1" cwd="${2:-$TMPROOT}"
    local exit_code=0 output
    output=$(make_input "$cmd" "$cwd" | "$HOOK" 2>&1) || exit_code=$?
    printf '%s|%s' "$exit_code" "$output"
}

assert_allow() {
    local desc="$1" cmd="$2" cwd="${3:-$TMPROOT}"
    local result code out
    result=$(run_hook "$cmd" "$cwd")
    code="${result%%|*}"; out="${result#*|}"
    if [[ "$code" == "0" ]] && ! echo "$out" | jq -e '.hookSpecificOutput.permissionDecision' >/dev/null 2>&1; then
        pass "$desc"
    else
        fail "$desc (expected allow: exit 0 + no decision, got exit=$code output=$out)"
    fi
}

assert_deny() {
    local desc="$1" cmd="$2" cwd="${3:-$TMPROOT}"
    local result out
    result=$(run_hook "$cmd" "$cwd")
    out="${result#*|}"
    if echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
        pass "$desc"
    else
        fail "$desc (expected deny, got: $out)"
    fi
}

echo ""
echo "=== guard-destructive-generic.sh: echo/printf data-sink redaction (#305, ports #53) ==="
echo ""

# Danger phrase assembled at runtime so this file's own Bash-tool invocation
# is never itself flagged by the guard governing THIS session (mirrors
# hooks/repo/tests/test-guard-destructive.sh's _DS_DANGER convention).
_DS_DANGER="rm -r""f /"

# (a) The confirmed #305 repro: a JSON self-test payload piped into a guard
# script. The dangerous command appears ONLY as single-quoted JSON DATA to
# echo, and the pipe target is not a shell, so it must be ALLOWED.
assert_allow "(a) #305/#53: echo JSON self-test payload piped into a guard script is allowed" \
    "$(printf 'echo %s%s%s | .loom/hooks/guard-destructive-generic.sh' \
        "'" '{"tool_name":"Bash","tool_input":{"command":"'"$_DS_DANGER"'"}}' "'")"

assert_allow "(a) #53: single-quoted danger as a plain echo argument is allowed" \
    "echo '$_DS_DANGER'"

assert_allow "(a) #53: double-quoted danger as a plain echo argument is allowed" \
    "echo \"$_DS_DANGER\""

assert_allow "(a) #53: printf is a data sink too" \
    "printf '%s' '$_DS_DANGER'"

# Ask-tier mirror: an ask-phrase quoted as echo data must not false-ask.
assert_allow "(a) #53 ask-tier: echo mentioning 'kubectl delete' does not false-ask" \
    "echo 'to clean up, run kubectl delete deployment foo'"

# (b) SAFETY FLOOR: a real, un-quoted-as-data destructive command must still
# deny — the redaction must never widen a deny into an allow.
assert_deny "(b) safety: a bare dangerous command still denies" \
    "$_DS_DANGER"

assert_deny "(b) safety: echo \"\$(<danger>)\" command substitution still denies" \
    "echo \"\$($_DS_DANGER)\""

assert_deny "(b) safety: echo with backtick substitution still denies" \
    "echo \"\`$_DS_DANGER\`\""

assert_deny "(b) safety: bash -c '<danger>' still denies (not a data sink)" \
    "bash -c '$_DS_DANGER'"

assert_deny "(b) safety: sh -c '<danger>' still denies (not a data sink)" \
    "sh -c '$_DS_DANGER'"

assert_deny "(b) safety: echo 'ok' | tee f ; <danger> still denies (separate segment)" \
    "echo 'ok' | tee f ; $_DS_DANGER"

# (c) Data PIPED into a shell that would execute it must still deny: the
# command_has_shell_segment() gate skips the redaction so the raw scan sees it.
assert_deny "(c) safety: echo '<danger>' | sh still denies (piped to shell)" \
    "echo '$_DS_DANGER' | sh"

assert_deny "(c) safety: echo '<danger>' | bash still denies (piped to shell)" \
    "echo '$_DS_DANGER' | bash"

assert_deny "(c) safety: printf '<danger>' | sh still denies (piped to shell)" \
    "printf '%s' '$_DS_DANGER' | sh"

echo ""
echo "=== (d) write confinement / repo#197: quoted redirect target after echo/printf ==="
echo ""

# The `redir` flag inside strip_datasink_literals() must keep a quoted
# redirect TARGET visible after echo/printf, even though the preceding quoted
# echo/printf ARGUMENT is redacted — otherwise Bash-tool write confinement
# goes blind to a real destination path and a write into the main checkout
# from a builder worktree silently falls through from deny to allow.
#
# Fixture: a throwaway git repo with a REAL linked worktree at the default
# worktree.sh layout (<repo>/.loom/worktrees/issue-N) carrying the
# `.loom-managed` sentinel, mirroring
# hooks/repo/tests/test-guard-destructive.sh's make_wt_confinement_repo().
make_wt_confinement_repo() {
    local main wt branch
    main=$(mktemp -d 2>/dev/null)
    git -C "$main" init -q >/dev/null 2>&1
    git -C "$main" -c user.email=test@example.com -c user.name=test \
        commit -q --allow-empty -m init >/dev/null 2>&1
    mkdir -p "$main/.loom/worktrees"
    wt="$main/.loom/worktrees/issue-1"
    branch="wtc-$(basename "$main")"
    git -C "$main" worktree add -q -b "$branch" "$wt" >/dev/null 2>&1
    touch "$wt/.loom-managed"
    printf '%s %s' "$main" "$wt"
}

# shellcheck disable=SC2046 # main/wt are mktemp paths, never contain IFS chars
read -r WTC_MAIN WTC_WT <<< "$(make_wt_confinement_repo)"

assert_deny "(d) repo#197: quoted echo arg + quoted redirect target into main checkout still denies" \
    "echo \"hi\" > \"$WTC_MAIN/evil.sh\"" "$WTC_WT"

assert_deny "(d) repo#197: quoted printf arg + quoted redirect target into main checkout still denies" \
    "printf '%s' \"hi\" > \"$WTC_MAIN/evil.sh\"" "$WTC_WT"

# Control: the identical write, but landing inside the acting worktree
# itself, is allowed — the redir gate does not widen denial beyond real
# out-of-tree writes.
assert_allow "(d) repo#197: quoted echo arg + quoted redirect target inside the worktree itself is allowed" \
    "echo \"hi\" > \"$WTC_WT/scratch.txt\"" "$WTC_WT"

git -C "$WTC_MAIN" worktree remove --force "$WTC_WT" >/dev/null 2>&1 || true
rm -rf "$WTC_MAIN"

echo ""
echo "=== (e) heredoc-wrapped --body values quoting an example command (Loom issue #317) ==="
echo ""

# This repo's own recommended commit-message/PR-comment convention is
# `--body "$(cat <<'EOF' ... EOF)"` -- a QUOTED-delimiter heredoc, so no
# expansion happens inside the body. Because the whole value necessarily
# contains a literal `$(`, strip_literal_text()'s pre-existing `$(`-floor used
# to leave it completely un-redacted, re-exposing any documented
# dangerous-command example inside the heredoc body to the raw
# catastrophic/ASK scans. mask_flag_cat_heredocs() masks ONLY the body of this
# one provably-inert shape before the flag-value redaction runs.

# Danger phrases assembled at runtime so this file's own Bash-tool invocation
# is never itself flagged by the guard governing this session.
_HD_DANGER="rm -r""f /"
_HD_PB=main
_HD_FORCE="git push --force origin $_HD_PB"

# The exact issue #317 repro: a `gh pr comment` --body built with the quoted-
# delimiter heredoc idiom, whose body merely documents/quotes a dangerous
# command as fixture/example text.
assert_allow "(e) #317: gh pr comment --body heredoc quoting a dangerous-rm example is allowed" \
    "$(printf 'gh pr comment 315 --body "$(cat <<'"'"'EOF'"'"'\nfixture asserts %s is denied\nEOF\n)"' "$_HD_DANGER")"

assert_allow "(e) #317: gh pr comment --body heredoc quoting a force-push example is allowed" \
    "$(printf 'gh pr comment 315 --body "$(cat <<'"'"'EOF'"'"'\ndo not run %s\nEOF\n)"' "$_HD_FORCE")"

# The `<<-` (dash) form, and a git commit -m using the same convention.
assert_allow "(e) #317: git commit -m heredoc (<<- dash form) quoting a danger example is allowed" \
    "$(printf 'git commit -m "$(cat <<-'"'"'EOF'"'"'\n\tfixture asserts %s is denied\n\tEOF\n)"' "$_HD_DANGER")"

# --- SAFETY FLOOR: a --body value whose $(...) is NOT a quoted-delimiter
# heredoc `cat` -- real command-substitution smuggling -- must still
# hard-deny, UNMODIFIED.
assert_deny "(e) #317 safety: --body \"text \$(danger) more\" (non-heredoc \$(...)) still denies" \
    "gh issue comment 1 --body \"text \$($_HD_DANGER) more\""

# --- SAFETY FLOOR: a heredoc body that ITSELF carries a real $(...)/backtick
# substitution must still hard-deny -- proves the fix does not widen the
# exclusion past the provably-inert heredoc-cat shape (per shell semantics a
# single-quoted heredoc delimiter does NOT expand $()/backticks in the body,
# so this nested payload never actually executes -- but the guard still
# denies it as a deliberately conservative floor).
assert_deny "(e) #317 safety: heredoc body nesting a real \$(danger) substitution still denies" \
    "$(printf 'gh pr comment 315 --body "$(cat <<'"'"'EOF'"'"'\n$(%s)\nEOF\n)"' "$_HD_DANGER")"

assert_deny "(e) #317 safety: heredoc body nesting a backtick substitution still denies" \
    "$(printf 'gh pr comment 315 --body "$(cat <<'"'"'EOF'"'"'\n\`%s\`\nEOF\n)"' "$_HD_DANGER")"

# --- SAFETY FLOOR: an UNQUOTED heredoc delimiter really is expanded by the
# shell, so it must NOT be treated as inert -- pre-existing behavior,
# unchanged by this fix.
assert_deny "(e) #317 safety: unquoted heredoc delimiter (\$(cat <<EOF ... EOF)) still denies" \
    "$(printf 'gh pr comment 315 --body "$(cat <<EOF\n%s\nEOF\n)"' "$_HD_DANGER")"

# --- SAFETY FLOOR: a real command chained after the heredoc but still INSIDE
# the $(...) substitution genuinely executes, so it must not be masked away.
assert_deny "(e) #317 safety: a real command chained after the heredoc inside \$(...) still denies" \
    "$(printf 'gh pr comment 315 --body "$(cat <<'"'"'EOF'"'"'\nharmless prose\nEOF\n%s\n)"' "$_HD_DANGER")"

echo ""
echo "=== $PASS/$TOTAL passed ==="
[[ "$FAIL" -eq 0 ]]

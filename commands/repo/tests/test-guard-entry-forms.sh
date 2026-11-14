#!/usr/bin/env bash
# Quoted vs unquoted guard-destructive.sh entry handling (repo#798).
#
# Usage: ./commands/repo/tests/test-guard-entry-forms.sh
# Exit code 0 = all tests pass, 1 = failures detected.
#
# install.sh's deferral heal (unwire_own_guard) and uninstall.sh's
# remove_settings_hook_entry used to match our settings.json entry by exact
# string equality, so the quoted form of the command (the path wrapped in
# escaped quotes) was left behind pointing at a deleted script. Both forms must
# be removed, other hooks in the same matcher kept, and a re-run be a no-op.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$SCRIPT_DIR/lib/assert.sh"
source "$SCRIPT_DIR/lib/git-fixture.sh"
git_fixture_scrub_env

SCRATCH="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$SCRATCH"' EXIT
FAKE_HOME="$SCRATCH/home"; mkdir -p "$FAKE_HOME"

OURS='${CLAUDE_PROJECT_DIR}/.claude/skills/repo/hooks/guard-destructive.sh'
OTHER='${CLAUDE_PROJECT_DIR}/.loom/hooks/guard-destructive.sh'
UNRELATED='${CLAUDE_PROJECT_DIR}/tools/other-hook.sh'

# fixture <dir> <our-command-string> [with-other-guard: yes|no]
fixture() {
    local t="$1" ours="$2" other="${3:-yes}"
    mkdir -p "$t"; git_fixture_init "$t"
    HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" -y --no-codex "$t" >/dev/null 2>&1 </dev/null
    mkdir -p "$t/.claude"
    if [[ "$other" == yes ]]; then
        jq -n --arg o "$ours" --arg l "$OTHER" --arg u "$UNRELATED" '
          {hooks:{PreToolUse:[{matcher:"Bash",hooks:[
            {type:"command",command:$l},{type:"command",command:$o},{type:"command",command:$u}]}]}}' \
          >"$t/.claude/settings.json"
    else
        jq -n --arg o "$ours" '{hooks:{PreToolUse:[{matcher:"Bash",hooks:[{type:"command",command:$o}]}]}}' \
          >"$t/.claude/settings.json"
    fi
}

cmds() { jq -r '[.hooks.PreToolUse[]?.hooks[]?.command] | join("\n")' "$1/.claude/settings.json"; }

for form in unquoted quoted; do
    if [[ "$form" == quoted ]]; then C="\"$OURS\""; else C="$OURS"; fi
    echo ""; echo "-- $form entry --"

    # install.sh deferral heal: another guard is wired, ours must go.
    T="$SCRATCH/inst-$form"; fixture "$T" "$C" yes
    HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" -y --no-codex "$T" >/dev/null 2>&1 </dev/null
    OUT="$(cmds "$T")"
    assert_not_contains "install heal removes the $form entry" "$OUT" "skills/repo/hooks/guard-destructive.sh"
    assert_contains "install heal keeps the other guard" "$OUT" "$OTHER"
    assert_contains "install heal keeps unrelated hooks" "$OUT" "$UNRELATED"
    BEFORE="$(cksum <"$T/.claude/settings.json")"
    HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" -y --no-codex "$T" >/dev/null 2>&1 </dev/null
    assert_eq "install re-run is a no-op on settings.json ($form)" "$BEFORE" "$(cksum <"$T/.claude/settings.json")"

    # Our entry alone: not mistaken for "another guard", not duplicated.
    T="$SCRATCH/solo-$form"; fixture "$T" "$C" no
    HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" -y --no-codex "$T" >/dev/null 2>&1 </dev/null
    N="$(jq '[.hooks.PreToolUse[]?.hooks[]?] | length' "$T/.claude/settings.json")"
    assert_eq "install keeps exactly one guard entry when only ours is wired ($form)" "1" "$N"

    # uninstall.sh
    T="$SCRATCH/uninst-$form"; fixture "$T" "$C" yes
    ( cd "$T" && HOME="$FAKE_HOME" bash "$REPO_ROOT/uninstall.sh" -y "$T" >/dev/null 2>&1 </dev/null )
    OUT="$(cmds "$T")"
    assert_not_contains "uninstall removes the $form entry" "$OUT" "skills/repo/hooks/guard-destructive.sh"
    assert_contains "uninstall keeps the other guard" "$OUT" "$OTHER"
    assert_contains "uninstall keeps unrelated hooks" "$OUT" "$UNRELATED"
done

echo ""
echo "  Total:  $TOTAL"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
[[ $FAIL -gt 0 ]] && exit 1
exit 0

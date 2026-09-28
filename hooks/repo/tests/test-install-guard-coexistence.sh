#!/usr/bin/env bash
# Regression suite for install.sh's guard-hook coexistence branch (repo#490).
#
# Usage: ./hooks/repo/tests/test-install-guard-coexistence.sh
# Exit code 0 = all tests pass, 1 = failures detected.
#
# Structured like test-install-sidecar-untracking.sh next door: pure bash, no
# test framework, PASS/FAIL counters and a summary block, scratch git repos the
# real install.sh is driven against.
#
# THE BUG UNDER TEST (repo#490): when install.sh finds a destructive-command
# guard already wired in the target's .claude/settings.json (e.g. from a Loom
# install), merge_settings_hook correctly defers and adds no second PreToolUse
# entry — but before this fix, hooks/repo/guard-destructive.sh (~6,700 lines)
# was copied into .claude/skills/repo/hooks/ regardless, where nothing would
# ever run it. There was also no recorded install-time decision, so
# resync-installed.sh independently re-planned the same file on every run with
# no coexistence check at all.
#
# The contract asserted below:
#   - another guard already wired -> the file is NOT copied, install-metadata.json
#     records guardHookInstalled:false, and settings.json still defers (no
#     duplicate PreToolUse entry)
#   - no existing guard -> unchanged happy path: the file IS copied, chmod'd,
#     wired, and install-metadata.json records guardHookInstalled:true
#   - a REPEAT install of an already-fully-wired target does not mistake its own
#     prior wiring for "another" guard and stop maintaining itself
#   - resync-installed.sh respects the recorded decision: it does not re-add a
#     hand-deleted (or never-installed) guard-destructive.sh once
#     guardHookInstalled is false, but keeps refreshing one recorded as true

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
RESYNC_SH="$REPO_ROOT/scripts/repo/resync-installed.sh"
GUARD_DEST=".claude/skills/repo/hooks/guard-destructive.sh"
META=".claude/skills/repo/install-metadata.json"
SETTINGS=".claude/settings.json"

# Assertion helpers (ok/no/skip/assert_eq/assert_contains/assert_not_contains/
# assert_matches) plus the PASS/FAIL/SKIP/TOTAL counters and color vars are
# shared across the repo test suites — see commands/repo/tests/lib/assert.sh
# (repo#307).
source "$(dirname "${BASH_SOURCE[0]}")/../../../commands/repo/tests/lib/assert.sh"

if [[ ! -f "$INSTALL_SH" ]]; then
    echo "FATAL: install.sh not found at $INSTALL_SH" >&2
    exit 1
fi

SCRATCH="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$SCRATCH"' EXIT

new_target() {  # <name> -> prints the target path
    local t="$SCRATCH/$1"
    mkdir -p "$t"
    git init -q "$t" 2>/dev/null
    printf "%s" "$t"
}

# Seed a target's .claude/settings.json with a PreToolUse->Bash hook whose
# command matches guard-destructive.sh but is NOT this installer's own path —
# simulating an existing Loom install (or any other tool) that already wired a
# guard before Repo Skills' install.sh runs.
seed_foreign_guard() {  # <target>
    mkdir -p "$1/.claude"
    cat >"$1/$SETTINGS" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "${CLAUDE_PROJECT_DIR}/.loom/hooks/guard-destructive.sh" }
        ]
      }
    ]
  }
}
EOF
}

# ===========================================================================
echo "install.sh guard-hook coexistence suite (repo#490)"
echo "===================================================="

# ---------------------------------------------------------------------------
echo ""
echo "-- another guard already wired: skip the copy entirely --"

T1="$(new_target foreign-guard)"
seed_foreign_guard "$T1"
OUT1="$(bash "$INSTALL_SH" -y "$T1" 2>&1)"; RC1=$?

assert_eq "install exits 0" "0" "$RC1"
if [[ ! -e "$T1/$GUARD_DEST" ]]; then
    ok "guard-destructive.sh is NOT copied when another guard is already wired"
else
    no "guard-destructive.sh is NOT copied when another guard is already wired" \
       "file exists at $T1/$GUARD_DEST"
fi
assert_contains "install-metadata.json records guardHookInstalled:false" \
    "$(cat "$T1/$META" 2>/dev/null)" '"guardHookInstalled": false'
assert_contains "install still reports deferring" \
    "$OUT1" "deferring to it"
assert_not_contains "install does not claim it installed the guard script" \
    "$OUT1" "Installed .claude/skills/repo/hooks/guard-destructive.sh"

# The foreign guard's own entry must be untouched — install.sh adds no second
# PreToolUse entry (the pre-existing coexistence contract, now shared with the
# copy decision via existing_guard_wired()).
SETTINGS_BODY1="$(cat "$T1/$SETTINGS")"
FOREIGN_COUNT="$(printf '%s' "$SETTINGS_BODY1" | grep -c 'guard-destructive\.sh')"
assert_eq "settings.json still has exactly one guard command (no duplicate added)" \
    "1" "$FOREIGN_COUNT"
assert_contains "the foreign guard's own command is preserved verbatim" \
    "$SETTINGS_BODY1" '.loom/hooks/guard-destructive.sh'

# ---------------------------------------------------------------------------
echo ""
echo "-- no existing guard: unchanged happy path --"

T2="$(new_target no-guard)"
OUT2="$(bash "$INSTALL_SH" -y "$T2" 2>&1)"; RC2=$?

assert_eq "install exits 0" "0" "$RC2"
if [[ -f "$T2/$GUARD_DEST" ]]; then
    ok "guard-destructive.sh IS copied when nothing else is wired"
else
    no "guard-destructive.sh IS copied when nothing else is wired" "file missing"
fi
if [[ -x "$T2/$GUARD_DEST" ]]; then
    ok "the copied guard script is executable"
else
    no "the copied guard script is executable"
fi
assert_contains "install-metadata.json records guardHookInstalled:true" \
    "$(cat "$T2/$META" 2>/dev/null)" '"guardHookInstalled": true'
assert_contains "install reports the guard as installed" \
    "$OUT2" "Installed .claude/skills/repo/hooks/guard-destructive.sh"
assert_contains "the guard is wired into settings.json" \
    "$(cat "$T2/$SETTINGS" 2>/dev/null)" 'guard-destructive.sh'

# ---------------------------------------------------------------------------
echo ""
echo "-- a REPEAT install of a self-wired target does not defer to itself --"

# T2 is already fully installed from the previous block: its own hook is now
# wired. A second run must not mistake that prior self-wiring for "another"
# guard (the existing_guard_wired() `.command != $c` filter under test).
OUT2B="$(bash "$INSTALL_SH" -y "$T2" 2>&1)"; RC2B=$?
assert_eq "re-install exits 0" "0" "$RC2B"
assert_contains "re-install still reports the guard as installed" \
    "$OUT2B" "Installed .claude/skills/repo/hooks/guard-destructive.sh"
assert_not_contains "re-install does not claim it deferred to itself" \
    "$OUT2B" "deferring to it"
assert_contains "re-install keeps recording guardHookInstalled:true" \
    "$(cat "$T2/$META" 2>/dev/null)" '"guardHookInstalled": true'
if [[ -f "$T2/$GUARD_DEST" ]]; then
    ok "the guard script still exists after a re-install"
else
    no "the guard script still exists after a re-install"
fi

# ---------------------------------------------------------------------------
echo ""
echo "-- resync-installed.sh respects a recorded deferral (repo#490) --"

if [[ ! -f "$RESYNC_SH" ]]; then
    skip "resync respects guardHookInstalled:false" "resync-installed.sh not found at $RESYNC_SH"
    skip "resync keeps refreshing guardHookInstalled:true" "resync-installed.sh not found at $RESYNC_SH"
else
    # T1 deferred at install time (guardHookInstalled:false). A dry-run resync
    # must not propose adding the file back.
    RESYNC_OUT1="$(cd "$T1" && bash "$RESYNC_SH" --dry-run --source "$REPO_ROOT" 2>&1)"
    assert_not_contains "dry-run resync does not propose adding guard-destructive.sh back" \
        "$RESYNC_OUT1" "guard-destructive.sh"
    bash "$RESYNC_SH" --target "$T1" --source "$REPO_ROOT" >/dev/null 2>&1
    if [[ ! -e "$T1/$GUARD_DEST" ]]; then
        ok "apply resync still does not create guard-destructive.sh"
    else
        no "apply resync still does not create guard-destructive.sh" \
           "file exists at $T1/$GUARD_DEST"
    fi

    # T2 installed normally (guardHookInstalled:true). Hand-delete the guard
    # script to simulate drift, and confirm resync still refreshes it — the
    # deferral must be selective, not a blanket "never touch this file".
    rm -f "$T2/$GUARD_DEST"
    bash "$RESYNC_SH" --target "$T2" --source "$REPO_ROOT" >/dev/null 2>&1
    if [[ -f "$T2/$GUARD_DEST" ]]; then
        ok "resync keeps refreshing a guard recorded as installed (guardHookInstalled:true)"
    else
        no "resync keeps refreshing a guard recorded as installed (guardHookInstalled:true)" \
           "file was not restored"
    fi
fi

# ---------------------------------------------------------------------------
echo ""
echo "========================================="
echo "  Total:  $TOTAL"
printf "  ${GREEN}Passed${NC}: %s\n" "$PASS"
printf "  ${RED}Failed${NC}: %s\n" "$FAIL"
echo "  Skipped: $SKIP"
echo "========================================="

if [[ $FAIL -gt 0 ]]; then
    printf "\n${RED}TESTS FAILED${NC}\n"
    exit 1
fi
printf "\n${GREEN}ALL TESTS PASSED${NC}\n"
exit 0

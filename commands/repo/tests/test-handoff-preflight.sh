#!/usr/bin/env bash
# Test suite for /repo:handoff's step-0 reader preflight (repo#493).
#
# Usage: ./commands/repo/tests/test-handoff-preflight.sh
# Exit code 0 = all tests pass, 1 = failures detected.
#
# Structured like commands/repo/tests/test-followups-scrub-step.sh: pure bash,
# no test framework, PASS/FAIL/SKIP/TOTAL counters and a summary block.
# `pnpm test` delegates to this file via hooks/repo/tests/run.sh.
#
# WHY THIS FILE EXISTS (repo#493): /repo:handoff writes .claude/handoff.md; a
# SEPARATE artifact reads it — hooks/repo/session-start-handoff.sh, which
# install.sh copies to .claude/skills/repo/hooks/ and wires into
# .claude/settings.json. Until #493 handoff.md merely ASSERTED the reader
# existed ("installed by Repo Skills") and never checked. Where it did not,
# the note was written, the restart block printed, and the next session never
# told — a silent loss at the exact moment the operator has stopped watching,
# because they quit the CLI on this command's own instructions.
#
# The step is prose, so the ways it can silently rot are the ways prose rots:
#
#   - The preflight gets moved after followups or reset, turning a gate into a
#     postmortem. Filing and pruning are the expensive, partly-irreversible
#     stages; learning the note has no reader must happen BEFORE them, which
#     is why it is step 0 and not step 3.5.
#   - The script-existence check gets dropped as redundant with the wiring
#     check. It is the opposite of redundant: consumers commonly TRACK
#     .claude/settings.json while GITIGNORING .claude/skills/, so a clone can
#     receive correct-looking wiring with no script behind it. That is the
#     case a settings.json-only check cannot see, and the case observed in
#     rjwalters/loom.
#   - The two checks get collapsed into one "hook is broken" message. They
#     have different repairs; a merged message sends the operator to the
#     wrong one.
#   - The jq predicate drifts from install.sh's merge_settings_sessionstart_hook,
#     so writer and installer disagree on what "wired" means.
#   - A partial wiring (startup but not resume) gets treated as acceptable.
#     install.sh treats it as incomplete and completes it; so must this.
#   - --force loses its obligation to tell the truth in the restart block,
#     leaving an operator with a note they believe will be announced.
#
# The contract under test:
#   1  handoff.md still exists, is user-invocable, and documents --force
#   2  a preflight step exists, is numbered 0, and precedes followups (1)
#      and reset (2)
#   3  it checks the script's existence AND executability
#   4  it checks the settings.json wiring for BOTH startup and resume, and
#      names a partial wiring a failure
#   5  it cross-references install.sh's merge_settings_sessionstart_hook so
#      the predicates cannot drift
#   6  it records WHY the script check cannot be replaced by the wiring check
#      (tracked settings.json + gitignored skills dir)
#   7  failures are reported per-half with distinct repairs
#   8  --force proceeds but must correct the step-5 restart block
#   9  the gitignore check and the REPO_HANDOFF_SIBLING_ROOT advisory are
#      present, and the advisory does not block
#  10  the artifacts handoff.md depends on still exist and still say what it
#      relies on (the hook, its two matchers, install.sh's wiring function)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$(dirname "${BASH_SOURCE[0]}")/lib/assert.sh"

HANDOFF="$REPO_ROOT/commands/repo/handoff.md"
HOOK="$REPO_ROOT/hooks/repo/session-start-handoff.sh"
INSTALL="$REPO_ROOT/install.sh"

echo "=== /repo:handoff step-0 reader preflight (repo#493) ==="
echo

# ---------------------------------------------------------------------------
# 1. The command still exists and advertises the new flag
# ---------------------------------------------------------------------------
echo "-- 1. command surface --"
if [[ ! -f "$HANDOFF" ]]; then
    no "handoff.md exists" "not found at $HANDOFF"
    echo; echo "Passed: $PASS"; echo "Failed: $FAIL"; exit 1
fi
ok "handoff.md exists"
BODY="$(cat "$HANDOFF")"

assert_contains "handoff.md is user-invocable" "$BODY" "user-invocable: true"
assert_contains "usage documents --force" "$BODY" "/repo:handoff --force"

# ---------------------------------------------------------------------------
# 2. Ordering: preflight is step 0, ahead of followups and reset
# ---------------------------------------------------------------------------
echo
echo "-- 2. ordering is load-bearing --"
assert_matches "a step 0 preflight heading exists" "$BODY" '^### 0\. Preflight'

line_of() {  # <ere> -> first matching line number, or empty
    grep -nE -- "$1" "$HANDOFF" 2>/dev/null | head -1 | cut -d: -f1
}
L_PRE="$(line_of '^### 0\. Preflight')"
L_FOLLOW="$(line_of '^### 1\. File follow-ups')"
L_RESET="$(line_of '^### 2\. Reset to baseline')"
L_NOTE="$(line_of '^### 4\. Write the handoff note')"

if [[ -n "$L_PRE" && -n "$L_FOLLOW" && "$L_PRE" -lt "$L_FOLLOW" ]]; then
    ok "preflight precedes followups (step 1)"
else
    no "preflight precedes followups (step 1)" "preflight@${L_PRE:-none} followups@${L_FOLLOW:-none}"
fi
if [[ -n "$L_PRE" && -n "$L_RESET" && "$L_PRE" -lt "$L_RESET" ]]; then
    ok "preflight precedes reset (step 2)"
else
    no "preflight precedes reset (step 2)" "preflight@${L_PRE:-none} reset@${L_RESET:-none}"
fi
if [[ -n "$L_PRE" && -n "$L_NOTE" && "$L_PRE" -lt "$L_NOTE" ]]; then
    ok "preflight precedes writing the note (step 4)"
else
    no "preflight precedes writing the note (step 4)" "preflight@${L_PRE:-none} note@${L_NOTE:-none}"
fi

# Everything below is scoped to the step-0 section so a stray mention
# elsewhere in the document cannot satisfy these assertions.
PRE_SECTION="$(awk '/^### 0\. Preflight/{f=1} /^### 1\. File follow-ups/{f=0} f' "$HANDOFF")"
if [[ -n "$PRE_SECTION" ]]; then
    ok "step-0 section body is extractable"
else
    no "step-0 section body is extractable" "awk range produced nothing"
fi

# ---------------------------------------------------------------------------
# 3. Half 1 — the script itself
# ---------------------------------------------------------------------------
echo
echo "-- 3. half 1: the hook script --"
assert_contains "names the installed script path" "$PRE_SECTION" \
    ".claude/skills/repo/hooks/session-start-handoff.sh"
assert_matches "checks executability, not mere existence" "$PRE_SECTION" \
    'test -x|-x \.claude/skills'

# ---------------------------------------------------------------------------
# 4. Half 2 — the settings.json wiring, both matchers
# ---------------------------------------------------------------------------
echo
echo "-- 4. half 2: the SessionStart wiring --"
assert_contains "reads .claude/settings.json" "$PRE_SECTION" ".claude/settings.json"
assert_contains "checks hooks.SessionStart" "$PRE_SECTION" "SessionStart"
assert_contains "covers the startup matcher" "$PRE_SECTION" '"startup"'
assert_contains "covers the resume matcher" "$PRE_SECTION" '"resume"'
assert_matches "a partial wiring is a failure, not a pass" "$PRE_SECTION" \
    '[Pp]artial'

# ---------------------------------------------------------------------------
# 5. The predicates are cross-referenced, not re-invented
# ---------------------------------------------------------------------------
echo
echo "-- 5. no drift from the installer --"
assert_contains "cross-references install.sh's wiring function" "$PRE_SECTION" \
    "merge_settings_sessionstart_hook"

# ---------------------------------------------------------------------------
# 6. The rationale that makes half 1 non-redundant
# ---------------------------------------------------------------------------
echo
echo "-- 6. why settings.json alone is not enough --"
assert_matches "records the tracked-settings / gitignored-skills split" "$PRE_SECTION" \
    '[Tt]rack.*settings\.json|settings\.json.*track'
assert_matches "records that the script is gitignored" "$PRE_SECTION" \
    'gitignor'

# ---------------------------------------------------------------------------
# 7. Distinct repairs per failing half
# ---------------------------------------------------------------------------
echo
echo "-- 7. failure reporting --"
assert_matches "stops on failure" "$PRE_SECTION" '[Ss]top|STOP'
assert_contains "repair: re-run install.sh" "$PRE_SECTION" "install.sh"
assert_contains "repair: /repo:update-tools for a stale script" "$PRE_SECTION" \
    "/repo:update-tools"

# ---------------------------------------------------------------------------
# 8. --force keeps the restart block honest
# ---------------------------------------------------------------------------
echo
echo "-- 8. --force --"
assert_contains "--force is described in step 0" "$PRE_SECTION" '`--force`'
RESTART_SECTION="$(awk '/^### 5\. Emit the restart block/{f=1} /^## Principles/{f=0} f' "$HANDOFF")"
assert_contains "step 5 handles the --force case" "$RESTART_SECTION" '--force'
assert_matches "step 5 says the note will NOT be announced" "$RESTART_SECTION" \
    'NOT be announced|not be announced'
assert_contains "step 5 tells the operator to read it by hand" "$RESTART_SECTION" \
    "cat .claude/handoff.md"

# ---------------------------------------------------------------------------
# 9. The advisories
# ---------------------------------------------------------------------------
echo
echo "-- 9. advisories that must not block --"
assert_contains "checks .claude/handoff.md is gitignored" "$PRE_SECTION" \
    "git check-ignore"
assert_contains "mentions REPO_HANDOFF_SIBLING_ROOT" "$PRE_SECTION" \
    "REPO_HANDOFF_SIBLING_ROOT"
assert_matches "the advisories are explicitly non-blocking" "$PRE_SECTION" \
    'never block|advisory|non-blocking'
assert_matches "--dry-run still runs the preflight" "$PRE_SECTION" '\-\-dry-run'

# ---------------------------------------------------------------------------
# 10. What handoff.md now depends on still exists and still says so
# ---------------------------------------------------------------------------
echo
echo "-- 10. the depended-on artifacts --"
if [[ -f "$HOOK" ]]; then
    ok "session-start-handoff.sh exists in the source tree"
    HOOK_BODY="$(cat "$HOOK")"
    assert_matches "the hook still gates on startup and resume" "$HOOK_BODY" \
        'startup\|resume'
else
    no "session-start-handoff.sh exists in the source tree" "not found at $HOOK"
fi
if [[ -f "$INSTALL" ]]; then
    ok "install.sh exists"
    INSTALL_BODY="$(cat "$INSTALL")"
    assert_contains "install.sh still defines merge_settings_sessionstart_hook" \
        "$INSTALL_BODY" "merge_settings_sessionstart_hook()"
    assert_contains "install.sh still installs to the path step 0 checks" \
        "$INSTALL_BODY" ".claude/skills/repo/hooks/session-start-handoff.sh"
    assert_matches "install.sh still wires exactly startup and resume" \
        "$INSTALL_BODY" 'SESSIONSTART_SOURCES=\(startup resume\)'
else
    no "install.sh exists" "not found at $INSTALL"
fi

echo
echo "==============================="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[[ "$SKIP" -gt 0 ]] && echo "Skipped: $SKIP"
echo "Total:  $TOTAL"
echo "==============================="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0

#!/usr/bin/env bash
# Test suite for hooks/repo/session-start-handoff.sh (and the install.sh /
# uninstall.sh settings.json wiring that installs it).
#
# Usage: ./hooks/repo/tests/test-session-start-handoff.sh
# Exit code 0 = all tests pass, 1 = failures detected.
#
# Structured like test-guard-destructive.sh next door: pure bash, no test
# framework, PASS/FAIL counters and a summary block. Each hook case pipes a
# synthetic Claude Code SessionStart payload ({"cwd":...,"source":...}) to the
# hook and asserts on stdout + exit status.
#
# The contract under test (see the hook's header):
#   - fires only for source "startup"/"resume"
#   - emits hookSpecificOutput.hookEventName == "SessionStart" with
#     additionalContext describing .claude/handoff.md (path, age, staleness) and
#     the note payload: the full body inlined at/under the size cap, a
#     headers-only outline plus an oversize warning above it (issue #33)
#   - never exits non-zero, never emits malformed JSON, never writes the note

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
HOOK="$REPO_ROOT/hooks/repo/session-start-handoff.sh"
INSTALL_SH="$REPO_ROOT/install.sh"
UNINSTALL_SH="$REPO_ROOT/uninstall.sh"

PASS=0
FAIL=0
TOTAL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

if [[ ! -f "$HOOK" ]]; then
    echo "FATAL: hook not found at $HOOK" >&2
    exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "FATAL: jq is required to run these tests" >&2
    exit 1
fi

# Resolve to a PHYSICAL path: on macOS mktemp -d hands back /var/folders/... but
# `git rev-parse --show-toplevel` reports /private/var/folders/..., and the hook
# emits git's answer. Without `pwd -P` here every path assertion below would
# compare the two spellings and fail.
SCRATCH="$(cd "$(mktemp -d)" && pwd -P)"
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
}
assert_eq() {  # <label> <expected> <actual>
    if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1" "expected [$2], got [$3]"; fi
}
assert_contains() {  # <label> <haystack> <needle>
    if [[ "$2" == *"$3"* ]]; then ok "$1"; else no "$1" "missing [$3] in output"; fi
}
assert_not_contains() {  # <label> <haystack> <needle>
    if [[ "$2" != *"$3"* ]]; then ok "$1"; else no "$1" "unexpected [$3] present in output"; fi
}
assert_empty() {  # <label> <actual>
    if [[ -z "$2" ]]; then ok "$1"; else no "$1" "expected no output, got [$2]"; fi
}

# run_hook <cwd> <source> -> stdout on HOOK_OUT, exit status in HOOK_EXIT.
# A raw stdin payload can be supplied instead via run_hook_raw.
HOOK_OUT=""
HOOK_EXIT=0
run_hook_raw() {  # <stdin-payload>
    HOOK_OUT=$(printf '%s' "$1" | bash "$HOOK" 2>/dev/null)
    HOOK_EXIT=$?
}
run_hook() {  # <cwd> <source>
    run_hook_raw "$(jq -nc --arg w "$1" --arg s "$2" '{cwd:$w, source:$s}')"
}

# Portable "N units ago" mtime setter (BSD `date -v` vs GNU `date -d`).
set_mtime_ago() {  # <file> <bsd-spec e.g. -8d> <gnu-spec e.g. "8 days ago">
    local stamp
    stamp=$(date -v"$2" +%Y%m%d%H%M 2>/dev/null) || stamp=""
    [[ -n "$stamp" ]] || stamp=$(date -d "$3" +%Y%m%d%H%M 2>/dev/null) || stamp=""
    if [[ -z "$stamp" ]]; then
        echo "FATAL: neither BSD nor GNU date available for relative timestamps" >&2
        exit 1
    fi
    touch -t "$stamp" "$1"
}

# A throwaway git repo with a handoff note in it.
make_repo() {  # <name> -> echoes path
    local d="$SCRATCH/$1"
    mkdir -p "$d/.claude"
    git -C "$d" init -q 2>/dev/null || { git init -q "$d"; }
    printf '%s' "$d"
}

NOTE_BODY='# Handoff — 2026-07-27

Prose that is inlined verbatim when the note is under the size cap.

## 1. In-flight — resolve before anything else

PR #41 awaits review. [verified]

## 2. Decisions — settled, do not relitigate

The shell wrapper is deferred. [verified]

## 3. The precise next action

Run the test suite.
'

echo "session-start-handoff.sh test suite"
echo "==================================="
echo ""

# ---------------------------------------------------------------------------
echo "-- fresh note present --"
# ---------------------------------------------------------------------------
FRESH="$(make_repo fresh)"
printf '%s' "$NOTE_BODY" > "$FRESH/.claude/handoff.md"

run_hook "$FRESH" startup
assert_eq        "startup: exit 0"                       "0" "$HOOK_EXIT"
if printf '%s' "$HOOK_OUT" | jq -e . >/dev/null 2>&1; then
    ok "startup: stdout is well-formed JSON"
else
    no "startup: stdout is well-formed JSON" "got [$HOOK_OUT]"
fi
EVENT=$(printf '%s' "$HOOK_OUT" | jq -r '.hookSpecificOutput.hookEventName // ""' 2>/dev/null)
assert_eq        "startup: hookEventName is SessionStart" "SessionStart" "$EVENT"
CTX=$(printf '%s' "$HOOK_OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
assert_contains  "startup: context names the note path"   "$CTX" "$FRESH/.claude/handoff.md"
assert_contains  "startup: context reports age"           "$CTX" "just now"
assert_contains  "startup: renders a section header"      "$CTX" "1. In-flight — resolve before anything else"
assert_contains  "startup: renders the title header"      "$CTX" "Handoff — 2026-07-27"
assert_contains  "startup: inlines note body prose"       "$CTX" "PR #41 awaits review"
assert_not_contains "startup: fresh note is not stale"    "$CTX" "STALE"
# Exactly one JSON object on stdout (a second would corrupt the hook protocol).
LINES=$(printf '%s' "$HOOK_OUT" | grep -c . || true)
assert_eq        "startup: exactly one output line"       "1" "$LINES"

run_hook "$FRESH" resume
assert_eq        "resume: exit 0"                         "0" "$HOOK_EXIT"
EVENT=$(printf '%s' "$HOOK_OUT" | jq -r '.hookSpecificOutput.hookEventName // ""' 2>/dev/null)
assert_eq        "resume: also fires"                     "SessionStart" "$EVENT"

# Read-only guarantee: content and mtime are untouched by the hook.
BEFORE_SUM=$(cksum < "$FRESH/.claude/handoff.md")
BEFORE_MTIME=$(stat -f %m "$FRESH/.claude/handoff.md" 2>/dev/null || stat -c %Y "$FRESH/.claude/handoff.md")
run_hook "$FRESH" startup
AFTER_SUM=$(cksum < "$FRESH/.claude/handoff.md")
AFTER_MTIME=$(stat -f %m "$FRESH/.claude/handoff.md" 2>/dev/null || stat -c %Y "$FRESH/.claude/handoff.md")
assert_eq        "read-only: note content unchanged"      "$BEFORE_SUM" "$AFTER_SUM"
assert_eq        "read-only: note mtime unchanged"        "$BEFORE_MTIME" "$AFTER_MTIME"

# Resolves the repo root from a subdirectory cwd, not just the root itself.
mkdir -p "$FRESH/src/deep"
run_hook "$FRESH/src/deep" startup
CTX=$(printf '%s' "$HOOK_OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
assert_contains  "subdir cwd: resolves repo root note"    "$CTX" "$FRESH/.claude/handoff.md"

# ---------------------------------------------------------------------------
echo ""
echo "-- age labelling and staleness --"
# ---------------------------------------------------------------------------
AGED="$(make_repo aged)"
printf '%s' "$NOTE_BODY" > "$AGED/.claude/handoff.md"

set_mtime_ago "$AGED/.claude/handoff.md" -5H "5 hours ago"
run_hook "$AGED" startup
CTX=$(printf '%s' "$HOOK_OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
assert_contains  "5h old: hour-granularity age label"     "$CTX" "5h old"
assert_not_contains "5h old: not flagged stale"           "$CTX" "STALE"

set_mtime_ago "$AGED/.claude/handoff.md" -3d "3 days ago"
run_hook "$AGED" startup
CTX=$(printf '%s' "$HOOK_OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
assert_contains  "3d old: day-granularity age label"      "$CTX" "3d old"
assert_not_contains "3d old: not yet stale (<7d)"         "$CTX" "STALE"

set_mtime_ago "$AGED/.claude/handoff.md" -8d "8 days ago"
run_hook "$AGED" startup
assert_eq        "8d old: exit 0"                         "0" "$HOOK_EXIT"
CTX=$(printf '%s' "$HOOK_OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
assert_contains  "8d old: age label"                      "$CTX" "8d old"
assert_contains  "8d old: flagged STALE (>=7d)"           "$CTX" "STALE"

# The 7d boundary itself is stale; 6d is not.
set_mtime_ago "$AGED/.claude/handoff.md" -6d "6 days ago"
run_hook "$AGED" startup
CTX=$(printf '%s' "$HOOK_OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
assert_not_contains "6d old: below the stale threshold"   "$CTX" "STALE"

# ---------------------------------------------------------------------------
echo ""
echo "-- oversize fallback: header outline is capped and headers-only --"
# ---------------------------------------------------------------------------
# This note must exceed MAX_BODY_BYTES (10 KB) so the hook takes the headers-only
# fallback; each section is padded to push the whole note past the cap.
MANY="$(make_repo many)"
{
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
        echo "## Section $i"
        echo "body-line-$i should never be injected"
        for _ in $(seq 1 20); do
            echo "padding padding padding padding padding padding padding padding"
        done
        echo ""
    done
    echo "### Deep heading level three"
} > "$MANY/.claude/handoff.md"
run_hook "$MANY" startup
CTX=$(printf '%s' "$HOOK_OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
assert_contains     "cap: oversize note warns it is too large" "$CTX" "OVERSIZE"
assert_contains     "cap: first header rendered"          "$CTX" "Section 1"
assert_contains     "cap: ninth header rendered"          "$CTX" "Section 9"
assert_not_contains "cap: tenth header dropped"           "$CTX" "Section 10"
assert_not_contains "cap: body lines never injected"      "$CTX" "body-line-1 should never be injected"
assert_not_contains "cap: h3 headings not treated as sections" "$CTX" "Deep heading level three"

# A note with no headers at all is still announced (path + age), and since it is
# small it is inlined verbatim.
NOHDR="$(make_repo nohdr)"
printf 'just some prose, no headings at all\n' > "$NOHDR/.claude/handoff.md"
run_hook "$NOHDR" startup
assert_eq        "no headers: exit 0"                     "0" "$HOOK_EXIT"
CTX=$(printf '%s' "$HOOK_OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
assert_contains  "no headers: still announces the note"   "$CTX" "$NOHDR/.claude/handoff.md"
assert_contains  "no headers: inlines the prose body"     "$CTX" "just some prose"

# ---------------------------------------------------------------------------
echo ""
echo "-- payload policy: capped body inline vs oversize fallback (issue #33) --"
# ---------------------------------------------------------------------------
# Under the cap: the FULL body is inlined verbatim, wrapped in markers, with no
# oversize warning and the read-in-full directive present.
UNDER="$(make_repo under)"
printf '%s' "$NOTE_BODY" > "$UNDER/.claude/handoff.md"
run_hook "$UNDER" startup
CTX=$(printf '%s' "$HOOK_OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
assert_contains  "under cap: inlines full body prose"     "$CTX" "PR #41 awaits review"
assert_contains  "under cap: inlines the next-action line" "$CTX" "Run the test suite."
assert_contains  "under cap: wraps body in a begin marker" "$CTX" "BEGIN HANDOFF NOTE"
assert_contains  "under cap: wraps body in an end marker"  "$CTX" "END HANDOFF NOTE"
assert_not_contains "under cap: no oversize warning"      "$CTX" "OVERSIZE"
assert_contains  "under cap: directive present"           "$CTX" "Read the note in full before doing anything else"

# Over the cap: headers outline + oversize warning; body omitted, no markers, but
# the read-in-full / one-shot directive is still present (BOTH branches carry it).
OVER="$(make_repo over)"
{
    echo "# Oversize handoff"
    echo "## First real section"
    echo "load-bearing-sentence-in-the-body"
    for _ in $(seq 1 220); do
        echo "filler filler filler filler filler filler filler filler"
    done
} > "$OVER/.claude/handoff.md"
run_hook "$OVER" startup
assert_eq        "over cap: exit 0"                       "0" "$HOOK_EXIT"
CTX=$(printf '%s' "$HOOK_OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
assert_contains  "over cap: emits oversize warning"       "$CTX" "OVERSIZE"
assert_contains  "over cap: renders a header outline"     "$CTX" "First real section"
assert_not_contains "over cap: omits the note body"       "$CTX" "load-bearing-sentence-in-the-body"
assert_not_contains "over cap: no inline body markers"    "$CTX" "BEGIN HANDOFF NOTE"
assert_contains  "over cap: directive present"            "$CTX" "Read the note in full before doing anything else"
assert_contains  "over cap: one-shot delete directive"    "$CTX" "delete both the note and its pointer"

# Boundary: a note of EXACTLY MAX_BODY_BYTES (10240) inlines (condition is <=).
BND="$(make_repo boundary)"
BOUND_FILE="$BND/.claude/handoff.md"
printf '# Boundary note\nunique-boundary-sentinel\n' > "$BOUND_FILE"
cur=$(wc -c < "$BOUND_FILE" | tr -d '[:space:]')
pad=$((10240 - cur))
if (( pad > 0 )); then
    head -c "$pad" /dev/zero | tr '\0' 'x' >> "$BOUND_FILE"
fi
EXACT_BYTES=$(wc -c < "$BOUND_FILE" | tr -d '[:space:]')
assert_eq        "boundary: note is exactly 10240 bytes"  "10240" "$EXACT_BYTES"
run_hook "$BND" startup
CTX=$(printf '%s' "$HOOK_OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
assert_contains  "boundary: exactly-cap note is inlined"  "$CTX" "unique-boundary-sentinel"
assert_not_contains "boundary: exactly-cap not oversize"  "$CTX" "OVERSIZE"

# One byte over the cap flips to the oversize fallback.
OVER1="$(make_repo boundary_over)"
OVER1_FILE="$OVER1/.claude/handoff.md"
printf '# Boundary note\n## Over by one\nunique-over-sentinel\n' > "$OVER1_FILE"
cur=$(wc -c < "$OVER1_FILE" | tr -d '[:space:]')
pad=$((10241 - cur))
if (( pad > 0 )); then
    head -c "$pad" /dev/zero | tr '\0' 'x' >> "$OVER1_FILE"
fi
EXACT_BYTES=$(wc -c < "$OVER1_FILE" | tr -d '[:space:]')
assert_eq        "boundary+1: note is exactly 10241 bytes" "10241" "$EXACT_BYTES"
run_hook "$OVER1" startup
CTX=$(printf '%s' "$HOOK_OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
assert_contains  "boundary+1: one byte over falls back"   "$CTX" "OVERSIZE"
assert_not_contains "boundary+1: body omitted over cap"   "$CTX" "unique-over-sentinel"

# ---------------------------------------------------------------------------
echo ""
echo "-- silent no-op paths --"
# ---------------------------------------------------------------------------
EMPTY="$(make_repo empty)"
run_hook "$EMPTY" startup
assert_eq        "no note: exit 0"                        "0" "$HOOK_EXIT"
assert_empty     "no note: no output"                     "$HOOK_OUT"

# Non-startup/resume sources are silent even when the note is present.
for src in clear compact fork; do
    run_hook "$FRESH" "$src"
    assert_eq    "source=$src: exit 0"                    "0" "$HOOK_EXIT"
    assert_empty "source=$src: no output despite note"    "$HOOK_OUT"
done

# Unreadable note (chmod 000) behaves like an absent one. Skipped when running
# as root, where the read succeeds regardless of mode bits.
if [[ "$(id -u)" != "0" ]]; then
    UNREAD="$(make_repo unreadable)"
    printf '%s' "$NOTE_BODY" > "$UNREAD/.claude/handoff.md"
    chmod 000 "$UNREAD/.claude/handoff.md"
    run_hook "$UNREAD" startup
    assert_eq    "unreadable note: exit 0"                "0" "$HOOK_EXIT"
    assert_empty "unreadable note: no output"             "$HOOK_OUT"
    chmod 644 "$UNREAD/.claude/handoff.md"
fi

# A directory named .claude/handoff.md is not a readable note.
DIRNOTE="$(make_repo dirnote)"
mkdir -p "$DIRNOTE/.claude/handoff.md"
run_hook "$DIRNOTE" startup
assert_eq        "handoff.md is a directory: exit 0"      "0" "$HOOK_EXIT"
assert_empty     "handoff.md is a directory: no output"   "$HOOK_OUT"

# ---------------------------------------------------------------------------
echo ""
echo "-- fail-open on malformed / missing input --"
# ---------------------------------------------------------------------------
run_hook_raw ''
assert_eq        "empty stdin: exit 0"                    "0" "$HOOK_EXIT"
assert_empty     "empty stdin: no output"                 "$HOOK_OUT"

run_hook_raw 'not json at all {{{'
assert_eq        "malformed JSON: exit 0"                 "0" "$HOOK_EXIT"
assert_empty     "malformed JSON: no output"              "$HOOK_OUT"

run_hook_raw '{"source":"startup"}'
assert_eq        "missing cwd: exit 0"                    "0" "$HOOK_EXIT"
assert_empty     "missing cwd: no output"                 "$HOOK_OUT"

run_hook_raw "$(jq -nc --arg w "$FRESH" '{cwd:$w}')"
assert_eq        "missing source: exit 0"                 "0" "$HOOK_EXIT"
assert_empty     "missing source: no output"              "$HOOK_OUT"

run_hook_raw '{"cwd":"/nonexistent/path/xyz","source":"startup"}'
assert_eq        "nonexistent cwd: exit 0"                "0" "$HOOK_EXIT"
assert_empty     "nonexistent cwd: no output"             "$HOOK_OUT"

run_hook_raw '[]'
assert_eq        "JSON array payload: exit 0"             "0" "$HOOK_EXIT"
assert_empty     "JSON array payload: no output"          "$HOOK_OUT"

# Non-git cwd falls back to treating cwd itself as the root (the original
# proposal's `root=$(git rev-parse --show-toplevel) || root=$PWD`).
NOGIT="$SCRATCH/nogit"
mkdir -p "$NOGIT/.claude"
printf '%s' "$NOTE_BODY" > "$NOGIT/.claude/handoff.md"
run_hook "$NOGIT" startup
assert_eq        "non-git cwd: exit 0"                    "0" "$HOOK_EXIT"
CTX=$(printf '%s' "$HOOK_OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
assert_contains  "non-git cwd: falls back to cwd as root" "$CTX" "$NOGIT/.claude/handoff.md"

# ---------------------------------------------------------------------------
echo ""
echo "-- install.sh / uninstall.sh settings.json wiring --"
# ---------------------------------------------------------------------------
SS_CMD='${CLAUDE_PROJECT_DIR}/.claude/skills/repo/hooks/session-start-handoff.sh'
GUARD_CMD='${CLAUDE_PROJECT_DIR}/.claude/skills/repo/hooks/guard-destructive.sh'

count_entries() {  # <settings> <command> -> total number of matching hook entries
    jq --arg c "$2" '[(.hooks.SessionStart // [])[] | (.hooks // [])[] | select(.command == $c)] | length' "$1"
}

TGT="$SCRATCH/target"
mkdir -p "$TGT"
git init -q "$TGT" 2>/dev/null
bash "$INSTALL_SH" -y "$TGT" >/dev/null 2>&1
INSTALL_RC=$?
assert_eq        "install: exits 0"                       "0" "$INSTALL_RC"

if [[ -f "$TGT/.claude/skills/repo/hooks/session-start-handoff.sh" ]]; then
    ok "install: hook script copied into the target"
else
    no "install: hook script copied into the target"
fi
if [[ -x "$TGT/.claude/skills/repo/hooks/session-start-handoff.sh" ]]; then
    ok "install: hook script is executable"
else
    no "install: hook script is executable"
fi

SETTINGS="$TGT/.claude/settings.json"
assert_eq "install: wired under matcher startup" "1" \
    "$(jq --arg c "$SS_CMD" '[(.hooks.SessionStart // [])[] | select(.matcher == "startup") | (.hooks // [])[] | select(.command == $c)] | length' "$SETTINGS")"
assert_eq "install: wired under matcher resume"  "1" \
    "$(jq --arg c "$SS_CMD" '[(.hooks.SessionStart // [])[] | select(.matcher == "resume") | (.hooks // [])[] | select(.command == $c)] | length' "$SETTINGS")"
assert_eq "install: no clear/compact/fork matcher wired" "0" \
    "$(jq '[(.hooks.SessionStart // [])[] | select(.matcher == "clear" or .matcher == "compact" or .matcher == "fork")] | length' "$SETTINGS")"
assert_eq "install: PreToolUse guard still wired alongside" "1" \
    "$(jq --arg c "$GUARD_CMD" '[(.hooks.PreToolUse // [])[] | (.hooks // [])[] | select(.command == $c)] | length' "$SETTINGS")"

# Idempotency: a second install must not duplicate the entries.
bash "$INSTALL_SH" -y "$TGT" >/dev/null 2>&1
assert_eq "re-install: still exactly 2 SessionStart entries" "2" "$(count_entries "$SETTINGS" "$SS_CMD")"

# Coexistence: a hand-authored SessionStart hook survives install and uninstall,
# including one sharing our "startup" matcher group.
jq '.hooks.SessionStart += [{matcher: "clear", hooks: [{type: "command", command: "/usr/local/bin/mine.sh"}]}]
    | .hooks.SessionStart |= map(if .matcher == "startup"
        then .hooks += [{type: "command", command: "/usr/local/bin/also-mine.sh"}] else . end)' \
   "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
bash "$INSTALL_SH" -y "$TGT" >/dev/null 2>&1
assert_eq "coexist: foreign clear hook preserved by install" "1" \
    "$(jq '[(.hooks.SessionStart // [])[] | (.hooks // [])[] | select(.command == "/usr/local/bin/mine.sh")] | length' "$SETTINGS")"
assert_eq "coexist: foreign startup hook preserved by install" "1" \
    "$(jq '[(.hooks.SessionStart // [])[] | (.hooks // [])[] | select(.command == "/usr/local/bin/also-mine.sh")] | length' "$SETTINGS")"
assert_eq "coexist: ours still not duplicated" "2" "$(count_entries "$SETTINGS" "$SS_CMD")"

bash "$UNINSTALL_SH" -y "$TGT" >/dev/null 2>&1
UNINSTALL_RC=$?
assert_eq "uninstall: exits 0"                            "0" "$UNINSTALL_RC"
assert_eq "uninstall: our SessionStart entries removed"   "0" "$(count_entries "$SETTINGS" "$SS_CMD")"
assert_eq "uninstall: foreign clear hook survives"        "1" \
    "$(jq '[(.hooks.SessionStart // [])[] | (.hooks // [])[] | select(.command == "/usr/local/bin/mine.sh")] | length' "$SETTINGS")"
assert_eq "uninstall: foreign startup hook survives"      "1" \
    "$(jq '[(.hooks.SessionStart // [])[] | (.hooks // [])[] | select(.command == "/usr/local/bin/also-mine.sh")] | length' "$SETTINGS")"
assert_eq "uninstall: PreToolUse guard entry also removed" "0" \
    "$(jq --arg c "$GUARD_CMD" '[(.hooks.PreToolUse // [])[] | (.hooks // [])[] | select(.command == $c)] | length' "$SETTINGS")"
if [[ -e "$TGT/.claude/skills/repo/hooks/session-start-handoff.sh" ]]; then
    no "uninstall: hook script removed"
else
    ok "uninstall: hook script removed"
fi

# Empty-container pruning: a settings.json holding ONLY our entries loses
# .hooks.SessionStart entirely rather than leaving empty litter.
TGT2="$SCRATCH/target2"
mkdir -p "$TGT2"
git init -q "$TGT2" 2>/dev/null
bash "$INSTALL_SH" -y "$TGT2" >/dev/null 2>&1
bash "$UNINSTALL_SH" -y "$TGT2" >/dev/null 2>&1
if [[ -f "$TGT2/.claude/settings.json" ]]; then
    assert_eq "prune: SessionStart container removed when empty" "false" \
        "$(jq -c 'has("hooks") and (.hooks | has("SessionStart"))' "$TGT2/.claude/settings.json")"
else
    ok "prune: SessionStart container removed when empty (settings.json itself pruned)"
fi

# --dry-run must enumerate the new file and the new wiring line.
TGT3="$SCRATCH/target3"
mkdir -p "$TGT3"
git init -q "$TGT3" 2>/dev/null
DRY=$(bash "$INSTALL_SH" --dry-run "$TGT3" 2>&1)
assert_contains "dry-run: lists the hook script"      "$DRY" "hooks/session-start-handoff.sh"
assert_contains "dry-run: lists the SessionStart wiring" "$DRY" "merge SessionStart"
assert_contains "dry-run: names the wired sources"    "$DRY" "startup resume"
if [[ -f "$TGT3/.claude/settings.json" ]]; then
    no "dry-run: writes nothing" "settings.json was created"
else
    ok "dry-run: writes nothing"
fi

# ---------------------------------------------------------------------------
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

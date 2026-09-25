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

# Assertion helpers (ok/no/skip/assert_eq/assert_contains/assert_not_contains/
# assert_matches) plus the PASS/FAIL/SKIP/TOTAL counters and color vars are
# shared across the repo test suites — see commands/repo/tests/lib/assert.sh
# (repo#307).
source "$(dirname "${BASH_SOURCE[0]}")/../../../commands/repo/tests/lib/assert.sh"

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

assert_empty() {  # <label> <actual>
    if [[ -z "$2" ]]; then ok "$1"; else no "$1" "expected no output, got [$2]"; fi
}

# run_hook <cwd> <source> -> stdout on HOOK_OUT, exit status in HOOK_EXIT.
# A raw stdin payload can be supplied instead via run_hook_raw.
HOOK_OUT=""
HOOK_EXIT=0
run_hook_raw() {  # <stdin-payload>
    # Explicitly clear LOOM_ROLE so these "ordinary" runs are deterministic
    # regardless of the calling environment - this test suite may itself be
    # invoked from inside a Loom role session (LOOM_ROLE set), which would
    # otherwise silently trip the issue #389 Layer 2 gate under test below.
    # REPO_HANDOFF_SIBLING_ROOT is cleared for the same reason: an operator who
    # has opted into the issue #257 sibling scan in their own shell must not
    # change what these baseline cases observe.
    HOOK_OUT=$(printf '%s' "$1" | LOOM_ROLE= REPO_HANDOFF_SIBLING_ROOT= bash "$HOOK" 2>/dev/null)
    HOOK_EXIT=$?
}
run_hook() {  # <cwd> <source>
    run_hook_raw "$(jq -nc --arg w "$1" --arg s "$2" '{cwd:$w, source:$s}')"
}

# run_hook_as_role <cwd> <source> <LOOM_ROLE value> -> like run_hook, but with
# LOOM_ROLE set in the hook's environment (issue #389 audience gating).
run_hook_as_role() {  # <cwd> <source> <role>
    HOOK_OUT=$(jq -nc --arg w "$1" --arg s "$2" '{cwd:$w, source:$s}' \
        | LOOM_ROLE="$3" REPO_HANDOFF_SIBLING_ROOT= bash "$HOOK" 2>/dev/null)
    HOOK_EXIT=$?
}

# run_hook_sibling <cwd> <source> <REPO_HANDOFF_SIBLING_ROOT> -> like run_hook,
# but with the issue #257 sibling-scan opt-in set in the hook's environment.
run_hook_sibling() {  # <cwd> <source> <sibling-root>
    HOOK_OUT=$(jq -nc --arg w "$1" --arg s "$2" '{cwd:$w, source:$s}' \
        | LOOM_ROLE= REPO_HANDOFF_SIBLING_ROOT="$3" bash "$HOOK" 2>/dev/null)
    HOOK_EXIT=$?
}

# run_hook_sibling_as_role <cwd> <source> <sibling-root> <role>
run_hook_sibling_as_role() {  # <cwd> <source> <sibling-root> <role>
    HOOK_OUT=$(jq -nc --arg w "$1" --arg s "$2" '{cwd:$w, source:$s}' \
        | LOOM_ROLE="$4" REPO_HANDOFF_SIBLING_ROOT="$3" bash "$HOOK" 2>/dev/null)
    HOOK_EXIT=$?
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

# Portable mtime reader (BSD/macOS `stat -f %m` vs GNU `stat -c %Y`). GNU
# `stat -f` means "filesystem status" (not "-f FORMAT"), so it doesn't fail
# cleanly on GNU — it prints a filesystem report (including free-block counts
# that change between calls) which corrupts an unguarded `stat -f %m ... ||
# stat -c %Y ...` fallback. Capture, then validate against ^[0-9]+$, matching
# the pattern already proven correct in session-start-handoff.sh:117-119.
mtime_of() {  # <file> -> epoch seconds
    local m
    m=$(stat -f %m "$1" 2>/dev/null)
    [[ "$m" =~ ^[0-9]+$ ]] || m=$(stat -c %Y "$1" 2>/dev/null)
    printf '%s' "$m"
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
BEFORE_MTIME=$(mtime_of "$FRESH/.claude/handoff.md")
run_hook "$FRESH" startup
AFTER_SUM=$(cksum < "$FRESH/.claude/handoff.md")
AFTER_MTIME=$(mtime_of "$FRESH/.claude/handoff.md")
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
assert_contains  "under cap: conditions deletion on operator session" "$CTX" "If you are the operator's interactive session"
assert_contains  "under cap: instructs role agents not to delete" "$CTX" "do NOT act on this"

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
echo "-- LOOM_ROLE audience gating (issue #389) --"
echo "-- role/autonomous sessions never see (or are told to delete) the note --"
# ---------------------------------------------------------------------------
# Layer 2: LOOM_ROLE set -> banner is suppressed entirely, for both startup and
# resume, regardless of a pending note.
run_hook_as_role "$FRESH" startup "builder"
assert_eq        "LOOM_ROLE=builder + startup: exit 0"    "0" "$HOOK_EXIT"
assert_empty     "LOOM_ROLE=builder + startup: no output despite pending note" "$HOOK_OUT"

run_hook_as_role "$FRESH" resume "judge"
assert_eq        "LOOM_ROLE=judge + resume: exit 0"       "0" "$HOOK_EXIT"
assert_empty     "LOOM_ROLE=judge + resume: no output despite pending note" "$HOOK_OUT"

run_hook_as_role "$FRESH" startup "sweep-lifecycle"
assert_empty     "LOOM_ROLE=sweep-lifecycle: no output (daemon's own role)" "$HOOK_OUT"

# Read-only guarantee holds for role sessions too: no note/pointer is touched.
ROLE_BEFORE_SUM=$(cksum < "$FRESH/.claude/handoff.md")
run_hook_as_role "$FRESH" startup "doctor"
ROLE_AFTER_SUM=$(cksum < "$FRESH/.claude/handoff.md")
assert_eq        "LOOM_ROLE=doctor: note left untouched"  "$ROLE_BEFORE_SUM" "$ROLE_AFTER_SUM"
if [[ -f "$FRESH/.claude/handoff.md" ]]; then
    ok "LOOM_ROLE=doctor: note file still exists"
else
    no "LOOM_ROLE=doctor: note file still exists" "note was deleted"
fi

# Empty LOOM_ROLE (unset or "") is indistinguishable from the operator path -
# the ordinary full banner, including the deletion directive, is unchanged.
run_hook_as_role "$FRESH" startup ""
assert_eq        "LOOM_ROLE='' + startup: exit 0"         "0" "$HOOK_EXIT"
CTX=$(printf '%s' "$HOOK_OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
assert_contains  "LOOM_ROLE='': full banner still emitted" "$CTX" "$FRESH/.claude/handoff.md"
assert_contains  "LOOM_ROLE='': deletion directive present" "$CTX" "delete both the note and its pointer"

# Operator path (LOOM_ROLE unset entirely): unchanged from pre-#389 behavior -
# full banner, deletion directive conditioned on the operator's session.
run_hook "$FRESH" startup
assert_eq        "no LOOM_ROLE + startup: exit 0"         "0" "$HOOK_EXIT"
CTX=$(printf '%s' "$HOOK_OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
assert_contains  "no LOOM_ROLE: full banner emitted"       "$CTX" "$FRESH/.claude/handoff.md"
assert_contains  "no LOOM_ROLE: deletion directive present for operator" "$CTX" \
    "If you are the operator's interactive session"
assert_contains  "no LOOM_ROLE: role-agent non-deletion instruction present" "$CTX" \
    "do NOT act on this"

# ---------------------------------------------------------------------------
echo ""
echo "-- sibling-repo visibility, opt-in via REPO_HANDOFF_SIBLING_ROOT (#257) --"
# ---------------------------------------------------------------------------
# A root of checkouts: alpha has a fresh note, beta a stale one, gamma none.
# A loose FILE at the root level proves the single-level glob ignores non-dirs.
SIBROOT="$SCRATCH/siblings"
mkdir -p "$SIBROOT/alpha/.claude" "$SIBROOT/beta/.claude" "$SIBROOT/gamma"
git -C "$SIBROOT/alpha" init -q 2>/dev/null || git init -q "$SIBROOT/alpha"
printf '%s' "$NOTE_BODY"                   > "$SIBROOT/alpha/.claude/handoff.md"
printf 'sibling-beta-body-sentinel\n'      > "$SIBROOT/beta/.claude/handoff.md"
set_mtime_ago "$SIBROOT/beta/.claude/handoff.md" -9d "9 days ago"
printf 'not a directory\n'                 > "$SIBROOT/loose-file.txt"

# The session's own repo: a real repo with NO note of its own.
BARE="$(make_repo sibling_local)"

# (a) Opt-in unset: byte-identical to today — the sibling notes are invisible.
run_hook "$BARE" startup
assert_eq    "sibling opt-in unset: exit 0"               "0" "$HOOK_EXIT"
assert_empty "sibling opt-in unset: silent despite sibling notes" "$HOOK_OUT"

# (b) Opt-in set: path + age for each sibling note, and nothing else.
run_hook_sibling "$BARE" startup "$SIBROOT"
assert_eq    "sibling scan: exit 0"                       "0" "$HOOK_EXIT"
if printf '%s' "$HOOK_OUT" | jq -e . >/dev/null 2>&1; then
    ok "sibling scan: stdout is well-formed JSON"
else
    no "sibling scan: stdout is well-formed JSON" "got [$HOOK_OUT]"
fi
EVENT=$(printf '%s' "$HOOK_OUT" | jq -r '.hookSpecificOutput.hookEventName // ""' 2>/dev/null)
assert_eq    "sibling scan: hookEventName is SessionStart" "SessionStart" "$EVENT"
LINES=$(printf '%s' "$HOOK_OUT" | grep -c . || true)
assert_eq    "sibling scan: exactly one output line"      "1" "$LINES"
CTX=$(printf '%s' "$HOOK_OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
assert_contains "sibling scan: says no note is pending here" "$CTX" \
    "No /repo:handoff note is pending in THIS repository"
assert_contains "sibling scan: names the opt-in variable"  "$CTX" "REPO_HANDOFF_SIBLING_ROOT ($SIBROOT)"
assert_contains "sibling scan: reports the alpha note path" "$CTX" "$SIBROOT/alpha/.claude/handoff.md"
assert_contains "sibling scan: reports the beta note path"  "$CTX" "$SIBROOT/beta/.claude/handoff.md"
assert_contains "sibling scan: counts both notes"          "$CTX" "found 2 pending handoff notes"
assert_contains "sibling scan: fresh sibling age label"    "$CTX" "just now"
assert_contains "sibling scan: stale sibling age label"    "$CTX" "9d old"
assert_contains "sibling scan: stale sibling flagged"      "$CTX" "STALE"
# Path and age ONLY: neither sibling body may appear, in any form.
assert_not_contains "sibling scan: alpha body never inlined"  "$CTX" "PR #41 awaits review"
assert_not_contains "sibling scan: alpha headers never shown" "$CTX" "In-flight — resolve before anything else"
assert_not_contains "sibling scan: beta body never inlined"   "$CTX" "sibling-beta-body-sentinel"
assert_not_contains "sibling scan: no inline body markers"    "$CTX" "BEGIN HANDOFF NOTE"
# ...and no one-shot deletion directive for a note that belongs to another repo.
assert_not_contains "sibling scan: no deletion directive"     "$CTX" "delete both the note and its pointer"
assert_contains "sibling scan: warns against acting from here" "$CTX" \
    "Do NOT open, act on, or delete another repository's note"
assert_not_contains "sibling scan: non-repo dir not reported"  "$CTX" "gamma"
assert_not_contains "sibling scan: loose file not reported"    "$CTX" "loose-file.txt"

run_hook_sibling "$BARE" resume "$SIBROOT"
CTX=$(printf '%s' "$HOOK_OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
assert_contains "sibling scan: fires on resume too"       "$CTX" "$SIBROOT/alpha/.claude/handoff.md"

for src in clear compact fork; do
    run_hook_sibling "$BARE" "$src" "$SIBROOT"
    assert_empty "sibling scan: source=$src stays silent" "$HOOK_OUT"
done

# A trailing slash on the configured root must not double up in reported paths.
run_hook_sibling "$BARE" startup "$SIBROOT/"
CTX=$(printf '%s' "$HOOK_OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
assert_contains     "trailing slash: path reported cleanly" "$CTX" "$SIBROOT/alpha/.claude/handoff.md"
assert_not_contains "trailing slash: no doubled separator"  "$CTX" "$SIBROOT//"

# (c) Configured root that does not exist: fails open to silence.
run_hook_sibling "$BARE" startup "$SCRATCH/no-such-root"
assert_eq    "sibling root missing: exit 0"               "0" "$HOOK_EXIT"
assert_empty "sibling root missing: no output"            "$HOOK_OUT"

# A root that is a file rather than a directory is equally inert.
run_hook_sibling "$BARE" startup "$SIBROOT/loose-file.txt"
assert_empty "sibling root is a file: no output"          "$HOOK_OUT"

# An unreadable root fails open too (skipped as root, where mode bits don't bite).
if [[ "$(id -u)" != "0" ]]; then
    NOREAD="$SCRATCH/sibroot-unreadable"
    mkdir -p "$NOREAD/one/.claude"
    printf 'x\n' > "$NOREAD/one/.claude/handoff.md"
    chmod 000 "$NOREAD"
    run_hook_sibling "$BARE" startup "$NOREAD"
    assert_eq    "sibling root unreadable: exit 0"        "0" "$HOOK_EXIT"
    assert_empty "sibling root unreadable: no output"     "$HOOK_OUT"
    chmod 755 "$NOREAD"
fi

# (d) "No note anywhere" is still silence — the point is only to distinguish it
#     from "no note here", never to announce an empty scan.
EMPTYROOT="$SCRATCH/sibroot-empty"
mkdir -p "$EMPTYROOT/one" "$EMPTYROOT/two/.claude"
run_hook_sibling "$BARE" startup "$EMPTYROOT"
assert_eq    "sibling root has no notes: exit 0"          "0" "$HOOK_EXIT"
assert_empty "sibling root has no notes: no output"       "$HOOK_OUT"

# (e) A local note always wins: the scan never runs, so the ordinary banner is
#     unchanged even with the opt-in set.
LOCALWINS="$SIBROOT/localwins"
mkdir -p "$LOCALWINS/.claude"
git -C "$LOCALWINS" init -q 2>/dev/null || git init -q "$LOCALWINS"
printf '%s' "$NOTE_BODY" > "$LOCALWINS/.claude/handoff.md"
run_hook_sibling "$LOCALWINS" startup "$SIBROOT"
CTX=$(printf '%s' "$HOOK_OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
assert_contains "local note wins: ordinary banner emitted" "$CTX" "$LOCALWINS/.claude/handoff.md"
assert_contains "local note wins: body still inlined"      "$CTX" "PR #41 awaits review"
assert_not_contains "local note wins: no sibling section"  "$CTX" "A sibling scan"
assert_not_contains "local note wins: sibling not listed"  "$CTX" "$SIBROOT/alpha/.claude/handoff.md"
rm -rf "$LOCALWINS"

# The current repo is never reported to itself: an unreadable local note under
# the configured root is skipped by the scan, while siblings still surface.
if [[ "$(id -u)" != "0" ]]; then
    SELFREPO="$SIBROOT/selfrepo"
    mkdir -p "$SELFREPO/.claude"
    git -C "$SELFREPO" init -q 2>/dev/null || git init -q "$SELFREPO"
    printf 'self-note-sentinel\n' > "$SELFREPO/.claude/handoff.md"
    chmod 000 "$SELFREPO/.claude/handoff.md"
    run_hook_sibling "$SELFREPO" startup "$SIBROOT"
    CTX=$(printf '%s' "$HOOK_OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
    assert_contains "self-exclusion: siblings still reported" "$CTX" "$SIBROOT/alpha/.claude/handoff.md"
    assert_not_contains "self-exclusion: own repo not listed" "$CTX" "$SELFREPO/.claude/handoff.md"
    chmod 644 "$SELFREPO/.claude/handoff.md"
    rm -rf "$SELFREPO"
fi

# (f) Bounded scan: at most MAX_SIBLING_DIRS (64) directories are examined, in
#     glob order, and the truncation is disclosed rather than hidden.
CAPROOT="$SCRATCH/sibroot-cap"
for i in $(seq -w 1 70); do mkdir -p "$CAPROOT/d$i"; done
mkdir -p "$CAPROOT/d01/.claude" "$CAPROOT/d70/.claude"
printf 'early\n' > "$CAPROOT/d01/.claude/handoff.md"
printf 'late\n'  > "$CAPROOT/d70/.claude/handoff.md"
run_hook_sibling "$BARE" startup "$CAPROOT"
assert_eq    "cap: exit 0"                                "0" "$HOOK_EXIT"
CTX=$(printf '%s' "$HOOK_OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
assert_contains "cap: note within the first 64 dirs is reported" "$CTX" "$CAPROOT/d01/.claude/handoff.md"
assert_not_contains "cap: note past the 64-dir cap is not reached" "$CTX" "$CAPROOT/d70/.claude/handoff.md"
assert_contains "cap: truncation is disclosed"            "$CTX" "scan stopped after 64 directories"

# (g) Read-only: the scan never touches a sibling note (content, mtime, or
#     existence) — a note is one-shot for the repo it belongs to.
SIB_A_SUM_BEFORE=$(cksum < "$SIBROOT/alpha/.claude/handoff.md")
SIB_A_MTIME_BEFORE=$(mtime_of "$SIBROOT/alpha/.claude/handoff.md")
SIB_B_MTIME_BEFORE=$(mtime_of "$SIBROOT/beta/.claude/handoff.md")
run_hook_sibling "$BARE" startup "$SIBROOT"
assert_eq "read-only: sibling note content unchanged"     "$SIB_A_SUM_BEFORE" \
    "$(cksum < "$SIBROOT/alpha/.claude/handoff.md")"
assert_eq "read-only: sibling note mtime unchanged"       "$SIB_A_MTIME_BEFORE" \
    "$(mtime_of "$SIBROOT/alpha/.claude/handoff.md")"
assert_eq "read-only: stale sibling mtime unchanged"      "$SIB_B_MTIME_BEFORE" \
    "$(mtime_of "$SIBROOT/beta/.claude/handoff.md")"
if [[ -f "$SIBROOT/beta/.claude/handoff.md" ]]; then
    ok "read-only: sibling note still exists"
else
    no "read-only: sibling note still exists" "sibling note was deleted"
fi

# (h) Audience gating still wins: a role session sees nothing, opt-in or not.
run_hook_sibling_as_role "$BARE" startup "$SIBROOT" "builder"
assert_eq    "LOOM_ROLE + sibling scan: exit 0"           "0" "$HOOK_EXIT"
assert_empty "LOOM_ROLE + sibling scan: no output"        "$HOOK_OUT"

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
echo "-- repo#482: the shared logs directory ignores its own contents --"
# ---------------------------------------------------------------------------
# This hook and guard-destructive.sh write hook-errors.log into the SAME
# directory (.claude/skills/repo/logs/ in a real install), and whichever hook
# runs first is the one that creates it — the installer never does. So the
# self-ignoring .gitignore must be written by EITHER creator, not just by the
# guard: the fix must not be order-dependent. Exercised here against a
# real installed layout (the hook resolves the logs dir relative to its own
# location) in a git repo carrying NO .gitignore rule of its own.
LOGIG="$SCRATCH/logs-ignore"
mkdir -p "$LOGIG/.claude/skills/repo/hooks"
git init -q "$LOGIG" 2>/dev/null
cp "$HOOK" "$LOGIG/.claude/skills/repo/hooks/session-start-handoff.sh"
LOGIG_DIR="$LOGIG/.claude/skills/repo/logs"
# A missing sibling root is this hook's cheapest log_hook_error trigger, and the
# repo has no handoff note of its own, so the scan is reached.
jq -nc --arg w "$LOGIG" '{cwd:$w, source:"startup"}' \
    | LOOM_ROLE= REPO_HANDOFF_SIBLING_ROOT="$SCRATCH/no-such-root-482" \
      bash "$LOGIG/.claude/skills/repo/hooks/session-start-handoff.sh" >/dev/null 2>&1
if [[ -f "$LOGIG_DIR/hook-errors.log" ]]; then
    ok "logs dir: the hook's error path creates the shared logs directory"
else
    no "logs dir: the hook's error path creates the shared logs directory" \
        "$(ls -a "$LOGIG_DIR" 2>&1)"
fi
if [[ -f "$LOGIG_DIR/.gitignore" ]] && \
   [[ "$(grep -v '^#' "$LOGIG_DIR/.gitignore" | grep -v '^[[:space:]]*$')" == "*" ]]; then
    ok "logs dir: this hook (not just the guard) writes the '*'-only .gitignore"
else
    no "logs dir: this hook (not just the guard) writes the '*'-only .gitignore" \
        "$(cat "$LOGIG_DIR/.gitignore" 2>&1)"
fi
LOGIG_STATUS="$(git -C "$LOGIG" status --porcelain 2>&1 | grep -F '.claude/skills/repo/logs' || true)"
assert_eq "logs dir: leaves git status clean with no consumer .gitignore rule" "" "$LOGIG_STATUS"

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

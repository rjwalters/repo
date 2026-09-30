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
#     check. It is the opposite of redundant. Where a consumer TRACKS
#     .claude/settings.json while GITIGNORING .claude/skills/, the wiring
#     propagates through git pull to every clone and the script it points at
#     travels with none of them: the repo reads as correctly configured to
#     anyone inspecting settings.json by eye, while Claude Code invokes a
#     missing command on every launch. A fresh clone of such a consumer
#     starts there before drifting at all. rjwalters/loom has exactly this
#     shape. How common the split is across consumers is NOT established, and
#     it needs to occur only once to lose a handoff -- do not restate it as a
#     frequency claim; #494 softened exactly that wording in handoff.md and
#     repo#499 caught this copy still carrying it.
#   - The two checks get collapsed into one "hook is broken" message. They
#     have different repairs; a merged message sends the operator to the
#     wrong one.
#   - The jq predicate drifts from install.sh's merge_settings_sessionstart_hook,
#     so writer and installer disagree on what "wired" means. Case 5 no longer
#     takes this on trust: it EXTRACTS both jq programs and compares them, the
#     one assertion the first revision of this file was missing (repo#494
#     review). Pinning the function name, install path and matcher list -- all
#     of which case 10 still does -- did not catch a predicate-shape change.
#   - The coexistence predicate gets dropped. merge_settings_sessionstart_hook
#     has TWO predicates: the idempotency test, and an early return that DEFERS
#     when a differently-pathed session-start-handoff.sh is already wired. A
#     preflight checking only the first FALSE-BLOCKS that repo -- it reports no
#     reader, sends the operator to install.sh, and install.sh defers again, so
#     the operator loops while a reader was present all along. That branch has
#     existed since the hook's first commit (#34).
#   - A partial wiring (startup but not resume) gets treated as acceptable.
#     install.sh treats it as incomplete and completes it; so must this.
#   - --force loses its obligation to tell the truth in the restart block,
#     leaving an operator with a note they believe will be announced.
#
# WHERE THE RATIONALE LIVES (repo#499): step 0 had grown to 163 of
# handoff.md's 339 lines -- 48% of a command that install.sh copies into
# every consumer repo, so the prose was context paid on every /repo:handoff
# everywhere. #499 compressed it to a checklist plus a repair table and moved
# the justification HERE: this file is read when someone changes the step,
# which is exactly when the reasoning is needed, and it is not installed into
# consumers. handoff.md keeps the operative sentence of every rule -- the part
# an executor acts on -- and points here for the rest.
#
# That split is load-bearing in one direction. The assertions below pin
# handoff.md's behavioural sentences, because those guard the branches; they
# also pin the moved rationale in THIS header (via SELF_HEADER), so a
# compression that drops an explanation from both files still fails. What is
# deliberately unpinned is only the surrounding exposition. Moving a rule's
# behavioural sentence OUT of handoff.md silently unguards it -- keep each
# rule's operative sentence in the command, and only the "why" here.
#
# The contract under test:
#   1  handoff.md still exists, is user-invocable, and documents --force
#   2  a preflight step exists, is numbered 0, and precedes followups (1)
#      and reset (2)
#   3  it checks the script's existence AND executability
#   4  it checks the settings.json wiring for BOTH startup and resume, and
#      names a partial wiring a failure
#  4b  step 0 still points a reader at this file's header
#  4c  ...and the header block it points at still exists and still states
#      the split's contract (repo#503: the reverse direction of 4b)
#   5  it cross-references install.sh's merge_settings_sessionstart_hook AND
#      the jq programs in the two files are literally equal after
#      normalization -- enforced, not asserted in prose
#  5b  the coexistence branch is handled: a foreign-pathed hook is a
#      satisfied reader, not a blocking failure
#   6  it records WHY the script check cannot be replaced by the wiring check
#      (tracked settings.json + gitignored skills dir)
#   7  failures are reported per-half with distinct repairs, and the two
#      cases install.sh CANNOT repair (a missing foreign 2b script; a
#      malformed settings.json) are not sent to it
#  7b  the converse and the remainder (repo#498): the one case install.sh CAN
#      repair but the table sent to a by-hand fix (an ABSENT settings.json) is
#      routed to it, the jq-WRITE-failure terminal state is named, and the
#      stale-script repair row -- which had no check behind it -- is out of
#      the "Failing check" table
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
# Flattened copy: several pins below match phrases that wrap across lines,
# and grep is line-oriented. Defined here beside PRE_SECTION because `set -u`
# aborts on a forward reference (caught when section 4b was added).
PRE_FLAT="$(printf '%s' "$PRE_SECTION" | tr '\n' ' ' | tr -s ' ')"

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
# NOT a bare '[Pp]artial' word-match — the #501 review named that the weakest
# pin in the file, and it is: the word survives any rewrite that inverts the
# rule around it. Demand the verdict too.
assert_matches "a partial wiring is a failure, not a pass" "$PRE_FLAT" \
    '[Pp]artial\*{0,2} wiring[^.]*is[[:space:]]*\*{0,2}a failure'

# ---------------------------------------------------------------------------
# 4b. The keystone: handoff.md must keep POINTING here
#
# repo#499 moved this step's rationale out of handoff.md and into this header.
# That split has exactly one load-bearing link -- the sentence in step 0 that
# sends a reader here before changing anything. The #501 review found that
# deleting it survived all 20 mutations: the only survivor new to that PR.
# Sever it and this header becomes orphaned prose that the next compression
# deletes as dead weight, taking the rationale with it and silently undoing
# repo#499's premise. Cheap to pin; expensive to lose.
# ---------------------------------------------------------------------------
echo
echo "-- 4b. the pointer that holds the doc/test split together --"
assert_contains "step 0 names this test file" "$PRE_SECTION" \
    "commands/repo/tests/test-handoff-preflight.sh"
assert_matches "step 0 tells the reader to read it BEFORE changing anything" \
    "$PRE_FLAT" 'read it before changing[[:space:]]*anything here'
assert_matches "step 0 says why: the pins are load-bearing" "$PRE_FLAT" \
    'pins[^.]*by mutation-verified[[:space:]]*regex|drops a pin[^.]*reopens the branch'

# ---------------------------------------------------------------------------
# 4c. ...and the block it points AT must still be here (repo#503)
#
# 4b pins the pointer; nothing pinned its target. Keep the pointer and delete
# this header's rationale block and every assertion stayed green, leaving
# handoff.md sending readers to an empty room. Worse, that block carries the
# split's own contract -- which half lives where, and what moving a sentence
# costs -- so a compression that deletes it removes the rule that governs the
# next compression. Pinned against the header ONLY (SELF_HEADER stops at
# `set -uo pipefail`), so the literals below cannot satisfy themselves, and
# flattened because every contract sentence wraps across comment lines.
# ---------------------------------------------------------------------------
echo
echo "-- 4c. the rationale block the pointer names --"
SELF_HEADER="$(sed -n '1,/^set -uo pipefail/p' "${BASH_SOURCE[0]}")"
SELF_FLAT="$(printf '%s' "$SELF_HEADER" | sed 's/^#[[:space:]]*//' | tr '\n' ' ' | tr -s ' ')"
# Anchored to a line start, so the contract list's mention of 4c cannot stand
# in for the block's own heading.
assert_matches "the header still opens a WHERE THE RATIONALE LIVES block" \
    "$SELF_HEADER" '^# WHERE THE RATIONALE LIVES \(repo#499\):'
assert_matches "the block says the justification moved HERE, not elsewhere" \
    "$SELF_FLAT" 'moved the justification HERE'
assert_matches "the block says handoff.md keeps every rule's operative sentence" \
    "$SELF_FLAT" 'handoff\.md keeps the operative sentence of every rule'
assert_matches "the block says moving a behavioural sentence out unguards it" \
    "$SELF_FLAT" "behavioural sentence OUT of handoff\\.md silently unguards it"
assert_matches "the block says operative sentences stay in the command" \
    "$SELF_FLAT" "keep each rule's operative sentence in the command, and only the \"why\" here"

# ---------------------------------------------------------------------------
# 5. The predicates are not re-invented -- and that is ENFORCED, not asserted
#
# The first revision of this file pinned the function name, the install path
# and the matcher list, and called the predicates undriftable. A review
# mutation that changed install.sh's predicate shape left all 35 cases green
# (repo#494). Prose cross-referencing is not enforcement; comparing the
# programs is. Both files carry the two jq programs as literal text, so
# extract and compare them.
# ---------------------------------------------------------------------------
echo
echo "-- 5. no drift from the installer (enforced) --"
assert_contains "cross-references install.sh's wiring function" "$PRE_SECTION" \
    "merge_settings_sessionstart_hook"

# Normalize a jq program to a drift-detecting canonical form: strip comments,
# collapse all whitespace, and neutralize the ONE intended difference -- the
# installer parameterizes the matcher list as $sources (fed from
# SESSIONSTART_SOURCES), while the doc inlines ["startup","resume"].
norm_jq() {  # reads stdin
    sed 's/#.*$//' \
      | tr '\n' ' ' \
      | sed -e 's/\$sources/MATCHERS/g' \
            -e 's/\["startup","resume"\]/MATCHERS/g' \
            -e 's/\[ *"startup" *, *"resume" *\]/MATCHERS/g' \
      | tr -s ' ' \
      | sed "s/'[^']*\$//" \
      | sed -e 's/^ *//' -e 's/ *$//'
}

# The idempotency predicate: the `(.hooks.SessionStart // []) as $ss |` form.
extract_idem() {  # <file>
    awk '/\(\.hooks\.SessionStart \/\/ \[\]\) as \$ss \|/{f=1}
         f{print}
         f && /\x27/ && !/as \$ss/{exit}' "$1" 2>/dev/null \
      | sed -n '1,6p'
}

# The coexistence predicate: the one carrying the test("...") regex.
extract_coex() {  # <file>
    grep -A2 -B2 'test("session-start-handoff' "$1" 2>/dev/null \
      | grep -E '\(\.hooks\.SessionStart|any\(|test\(|\.command'
}

IDEM_DOC="$(extract_idem "$HANDOFF" | norm_jq)"
IDEM_INS="$(extract_idem "$INSTALL" | norm_jq)"
if [[ -z "$IDEM_DOC" || -z "$IDEM_INS" ]]; then
    no "idempotency predicate extractable from both files" \
       "doc=[${IDEM_DOC:0:60}] install=[${IDEM_INS:0:60}]"
else
    ok "idempotency predicate extractable from both files"
    assert_eq "idempotency predicate is identical in handoff.md and install.sh" \
        "$IDEM_INS" "$IDEM_DOC"
fi

COEX_DOC="$(extract_coex "$HANDOFF" | norm_jq)"
COEX_INS="$(extract_coex "$INSTALL" | norm_jq)"
if [[ -z "$COEX_DOC" || -z "$COEX_INS" ]]; then
    no "coexistence predicate extractable from both files" \
       "doc=[${COEX_DOC:0:60}] install=[${COEX_INS:0:60}]"
else
    ok "coexistence predicate extractable from both files"
    assert_eq "coexistence predicate is identical in handoff.md and install.sh" \
        "$COEX_INS" "$COEX_DOC"
fi

# The regex escaping is the easiest thing to get wrong when hand-copying a jq
# program between a markdown fence and a bash single-quoted string.
assert_contains "the doc's coexistence regex is escaped exactly as install.sh's" \
    "$PRE_SECTION" 'test("session-start-handoff\\.sh")'

# ---------------------------------------------------------------------------
# 5b. Coexistence is a satisfied reader, not a blocking failure
# ---------------------------------------------------------------------------
echo
echo "-- 5b. the coexistence branch --"
assert_matches "step 0 knows install.sh has TWO predicates, not one" "$PRE_FLAT" \
    '\*{0,2}[Tt]wo\*{0,2} +predicates'
# Structural, not vocabulary: a rewrite that reverts to blocking on
# coexistence has to change these, whereas the word "defer" can survive
# anywhere in the section and prove nothing (repo#494 review, mutation M3).
assert_contains "both predicates are labelled, so neither can quietly vanish" \
    "$PRE_SECTION" "2a."
assert_contains "the coexistence predicate is labelled 2b" "$PRE_SECTION" "2b."
assert_matches "2b is declared mandatory, not an optional extra" "$PRE_FLAT" \
    '2b is not optional'
# NOT a bare 'satisfied reader' (repo#503): the phrase survives "A 2b match is
# NOT a satisfied reader", which is the false-block regression this section
# exists to stop. Demand the subject and the verdict together.
assert_matches "a foreign-pathed hook is a satisfied reader, not a failure" "$PRE_FLAT" \
    '2b match is a[[:space:]]*\*{0,2}satisfied reader'
assert_matches "the preflight continues past 2b rather than stopping" "$PRE_FLAT" \
    'report the foreign path as \*{0,2}information\*{0,2} and[[:space:]]*continue'
# The repair table is the other place a revert would show: a 2b pass must not
# be reachable as a blocking row.
assert_matches "the repair table scopes the no-wiring row to 2a AND 2b failing" \
    "$PRE_FLAT" '2a and 2b both fail'
assert_matches "records the false-block / operator-loop consequence" "$PRE_SECTION" \
    '[Ff]alse block|loops?\b'
# repo#499 renumbered the "halves" as checks 1-4. Retargeted, not relaxed:
# the #501 review demonstrated that the old single alternation accepted a
# REVERSED rule ("which is always the installed path, never the foreign path
# when 2b matched") because the matched phrase survived the reversal. The
# pair below demands the redirect AND which path it redirects to.
assert_matches "check 3 follows the hook that will actually run" "$PRE_FLAT" \
    '[Cc]heck 3 follows the hook that will actually run'
assert_matches "check 3 names the foreign path as what it redirects to" "$PRE_FLAT" \
    'foreign[[:space:]]*path when 2b matched, not the installed path'

# ---------------------------------------------------------------------------
# 6. The rationale that makes half 1 non-redundant
# ---------------------------------------------------------------------------
echo
echo "-- 6. why settings.json alone is not enough --"
# SELF_HEADER is defined in 4c above (set -u forbids a forward reference).
# NOT 'TRACKS[[:space:]]*$' -- that alternative matched any line merely ENDING
# in the word, which a gutted header still does. Require the actual pairing.
assert_matches "the tracked-settings / gitignored-skills split is recorded" "$SELF_HEADER" \
    'GITIGNORING \.claude/skills'
assert_matches "the split names the tracked side too" "$SELF_HEADER" \
    'TRACKS[[:space:]]*#? *\.claude/settings\.json|\.claude/settings\.json while GITIGNORING'
assert_matches "the split's consequence is recorded, not just the fact" "$SELF_HEADER" \
    'reads as correctly configured|missing command on every launch'
# The frequency claim #494 softened must not creep back (repo#499).
assert_not_contains "no unsupported frequency claim about consumers" \
    "$SELF_HEADER" "consumers commonly TRACK"

# ---------------------------------------------------------------------------
# 7. Distinct repairs per failing half
# ---------------------------------------------------------------------------
echo
echo "-- 7. failure reporting --"
# NOT '[Ss]top|STOP' or a bare "install.sh" (repo#503): the section says
# "stop" and "install.sh" in a dozen places, so both pins survived rewriting
# the rule around them -- "on a blocking failure, continue", or every repair
# cell sent to "By hand". Demand the verdict: what happens on failure, and
# which rows install.sh is the repair FOR.
assert_matches "stops on failure" "$PRE_FLAT" \
    '[Oo]n a blocking failure,[[:space:]]*stop and report which check failed'
assert_matches "repair: re-run install.sh for a missing/non-executable script" "$PRE_FLAT" \
    'not executable \| `install\.sh` re-copies it'
assert_matches "repair: re-run install.sh when neither 2a nor 2b is wired" "$PRE_FLAT" \
    '2a and 2b both fail\) \| `install\.sh` merges it'
assert_matches "repair: 'install.sh' in the table means re-running the installer" "$PRE_FLAT" \
    '`install\.sh` in that table means re-running'
assert_contains "repair: /repo:update-tools for a stale script" "$PRE_SECTION" \
    "/repo:update-tools"
# install.sh copies ONLY to .claude/skills/repo/hooks/ and, on a 2b match,
# defers on the wiring -- so "re-run install.sh" is the WRONG repair when the
# foreign-pathed script 2b found is itself missing. Saying otherwise rebuilds
# the same operator loop one branch deeper (repo#494 follow-up).
assert_matches "a missing foreign (2b) script is not repaired by install.sh alone" \
    "$PRE_FLAT" 'is the wrong repair|[Bb]y hand: fix or delete that entry'
assert_matches "the table carries a row for a missing foreign script" "$PRE_FLAT" \
    '2b matched, but the \*foreign\* script'
# The third early return in merge_settings_sessionstart_hook: invalid JSON.
# jq -e fails identically for "malformed" and "not wired", and install.sh
# refuses to touch a malformed settings file -- so the table must not send the
# operator there for it.
assert_matches "malformed settings.json is separated from 'not wired'" "$PRE_FLAT" \
    'malformed .?\.claude/settings\.json'
assert_matches "install.sh is not offered as the repair for invalid JSON" "$PRE_FLAT" \
    'not valid JSON \| By hand'

# ---------------------------------------------------------------------------
# 7b. The residual states the table used to get wrong (repo#498)
#
# merge_settings_sessionstart_hook has three early returns AND a non-returning
# terminal state. Case 7 above covers two early returns. These are the rest:
#
#   - An ABSENT settings.json. `jq -e .` fails identically for "missing" and
#     "malformed", so a missing file was routed to the malformed row's by-hand
#     repair -- which is false: install.sh runs
#     `[[ -f "$settings" ]] || echo '{}' >"$settings"` BEFORE its invalid-JSON
#     guard, so a missing file is created, wired and scripted in one re-install.
#     Reachable on a fresh clone of any repo that tracks .claude/commands/ via
#     a `!` negation while gitignoring the rest of .claude/.
#   - The jq-WRITE failure: the fourth terminal state does not return early, it
#     warns "Failed to update ... left unchanged" and wires nothing. With 2a and
#     2b both failing, the table sends the operator to install.sh, which fails
#     the same way -- the operator loop of #494, one branch deeper. The table
#     must name it so a still-failing preflight after a repair is legible.
#   - A repair row with no check behind it: "Script present but stale vs.
#     source" sat under a "Failing check" heading, but step 0 only ever runs
#     `test -x` and nothing it runs can produce "stale".
# ---------------------------------------------------------------------------
echo
echo "-- 7b. the residual install.sh terminal states (repo#498) --"

# (1) Absent settings.json is disambiguated from malformed, and routed to
#     install.sh rather than to a by-hand fix.
assert_matches "step 0 probes for an ABSENT settings.json" "$PRE_SECTION" \
    '^test -f \.claude/settings\.json'
L_TESTF="$(grep -nE '^test -f \.claude/settings\.json' "$HANDOFF" | head -1 | cut -d: -f1)"
L_JQDOT="$(grep -nE '^jq -e \. \.claude/settings\.json' "$HANDOFF" | head -1 | cut -d: -f1)"
if [[ -n "$L_TESTF" && -n "$L_JQDOT" && "$L_TESTF" -lt "$L_JQDOT" ]]; then
    ok "the existence probe precedes the malformed-JSON probe"
else
    no "the existence probe precedes the malformed-JSON probe" \
       "test -f@${L_TESTF:-none} jq -e .@${L_JQDOT:-none}"
fi
assert_matches "the table carries a distinct row for a missing settings.json" \
    "$PRE_FLAT" 'No `\.claude/settings\.json` at all \| `install\.sh`'
assert_matches "a missing settings.json is repaired by install.sh, not by hand" \
    "$PRE_FLAT" '[Aa]bsent is fully repaired by'
# The reason it is repairable is an ORDERING fact inside the installer; record
# it, so a future edit cannot re-merge "missing" back into "malformed".
assert_matches "records that install.sh creates {} BEFORE its JSON guard" \
    "$PRE_FLAT" '\*before\* its invalid-JSON guard'

# (2) The jq-write failure branch is named, and not sold as install.sh-repairable.
assert_matches "the jq-write-failure terminal state is named" "$PRE_FLAT" \
    'Failed to update \.claude/settings\.json'
assert_matches "the jq-write-failure state is not sold as self-repairing" \
    "$PRE_FLAT" 'self-diagnosing but not self-repairing'

# (3) Staleness has no probe, so it is not a "Failing check" row.
assert_not_contains "staleness is no longer a 'Failing check' table row" \
    "$PRE_SECTION" "| Script present but stale vs. source |"
assert_matches "staleness is declared unchecked, with the reason" "$PRE_FLAT" \
    'does not check\*{0,2} whether the installed script is'
# Structural, not vocabulary: the /repo:update-tools mention must sit AFTER the
# repair table, not inside it. A row reinstated above would flip this.
L_TABLE_END="$(grep -nE '^\| `\.claude/settings\.json` is not valid JSON' "$HANDOFF" \
    | head -1 | cut -d: -f1)"
L_UPDTOOLS="$(grep -n '/repo:update-tools' "$HANDOFF" | head -1 | cut -d: -f1)"
if [[ -n "$L_TABLE_END" && -n "$L_UPDTOOLS" && "$L_UPDTOOLS" -gt "$L_TABLE_END" ]]; then
    ok "/repo:update-tools sits below the repair table, not in it"
else
    no "/repo:update-tools sits below the repair table, not in it" \
       "table end@${L_TABLE_END:-none} update-tools@${L_UPDTOOLS:-none}"
fi

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
# NOT a bare '\-\-dry-run' (repo#503): the flag is named in the section either
# way, so the pin survived "Under --dry-run, skip every check". Demand the
# verdict -- the checks still run, for real.
assert_matches "--dry-run still runs the preflight" "$PRE_FLAT" \
    'Under `--dry-run`, run every check for real'
# The gitignore check auto-fixes (it is the archetypal safe fix, and step 4
# would have done it anyway) -- but --dry-run's contract is that the run
# writes nothing, so the auto-fix must be suppressed there (repo#494 review).
# An auto-fix the operator is never TOLD about is indistinguishable from the
# command quietly editing .gitignore behind their back. repo#499 dropped this
# sentence and the #501 review caught the loss -- it was unpinned before and
# after, so restoring it without a pin just loses it again.
assert_matches "the gitignore auto-fix is reported, not silent" "$PRE_FLAT" \
    'Say that it was[[:space:]]*added'
assert_matches "the gitignore check auto-fixes rather than blocks" "$PRE_FLAT" \
    'auto-fixes\*{0,2} rather than blocks'
assert_matches "--dry-run suppresses the gitignore auto-fix" "$PRE_FLAT" \
    'add nothing|apply no repair'
assert_not_contains "the gitignore row is no longer a blocking repair row" \
    "$PRE_SECTION" "| \`.claude/handoff.md\` not gitignored |"

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

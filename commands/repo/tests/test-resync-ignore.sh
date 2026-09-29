#!/usr/bin/env bash
# Test suite for the repo-owned pin list — `.claude/skills/repo/resync-ignore`,
# requirement C10 of INSTALLER-CONTRACT.md (repo#511).
#
# Usage: ./commands/repo/tests/test-resync-ignore.sh
# Exit code 0 = all tests pass, 1 = failures detected.
#
# Structured like commands/repo/tests/test-resync-installed.sh (whose fixture
# builders this mirrors): pure bash, no framework, PASS/FAIL/SKIP/TOTAL counters
# and a summary block. `pnpm test` delegates to this file via
# hooks/repo/tests/run.sh.
#
# WHY THIS FILE EXISTS. The mechanism under test exists because ONE consumer
# (2AMLogic/2am, private) lost the SAME customization four separate times over a
# few months — a subsection of the installed `.claude/commands/repo/scrub.md`
# wiring in a repo-local allowlist-drift check:
#
#   2am#463                      script written, subsection added to scrub.md
#   2am#593                      found unwired
#   2am#594                      subsection re-added
#   Repo Skills v0.10.0->v0.11.12  gone
#   2am#775 / #776               re-added, plus a regression test
#   v0.12.2 / v0.14.0 reinstalls gone again
#   2am#1596                     wiring moved out of scrub.md entirely
#
# Four regressions, zero of them caught by a test in THIS repo, because the
# thing that broke was an absence: install.sh rendered over every destination
# unconditionally and resync-installed.sh did the same on every refresh. So this
# suite's central assertion is not "the ignore file parses" — it is the
# end-to-end scenario above: a consumer's edit to an installed file, pinned,
# survives BOTH a reinstall and a resync byte-for-byte.
#
# Every case that asserts survival is paired with a POSITIVE CONTROL asserting
# the same edit is clobbered WITHOUT the pin. A survival test that passes
# because the writer never ran (a broken fixture, a silently-failing install)
# would otherwise be indistinguishable from the mechanism working.
#
# Every fixture lives under a scratch dir with HOME redirected, so nothing here
# can touch the developer's real repos or shell rc files.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
RESYNC_SRC="$REPO_ROOT/scripts/repo/resync-installed.sh"
IGNORE_LIB="$REPO_ROOT/lib/resync-ignore.sh"
IGNORE_REL=".claude/skills/repo/resync-ignore"

# Assertion helpers (ok/no/skip/assert_eq/assert_contains/assert_not_contains/
# assert_matches) plus the PASS/FAIL/SKIP/TOTAL counters and color vars are
# shared across the repo test suites — see lib/assert.sh (repo#307).
source "$(dirname "${BASH_SOURCE[0]}")/lib/assert.sh"
 . 
# Fixture hermeticity (repo#518): a Loom-dispatched session overrides
# core.hooksPath through GIT_CONFIG_* env pairs (loom-daemon's provenance
# hooks), which fixture repos inherit unless the override is scrubbed â see
# lib/git-fixture.sh.
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-fixture.sh"
git_fixture_scrub_env

for f in "$RESYNC_SRC" "$IGNORE_LIB" "$REPO_ROOT/install.sh"; do
    if [[ ! -f "$f" ]]; then
        echo "FATAL: required file not found at $f" >&2
        exit 1
    fi
done

SCRATCH="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$SCRATCH"' EXIT
FAKE_HOME="$SCRATCH/home"
mkdir -p "$FAKE_HOME"

# ---------------------------------------------------------------------------
# Fixture builders. The source fixture is a COPY of this repo's installable
# surfaces (not this repo itself) so a case can delete a lib or a command file
# to simulate upstream movement without ever writing to the working tree it
# runs from.
# ---------------------------------------------------------------------------
new_source() {  # <dir> — build a Repo Skills source clone at <dir>
    local dir="$1"
    mkdir -p "$dir/lib" "$dir/skills/repo" "$dir/commands/repo" "$dir/hooks/repo" "$dir/scripts/repo"
    cp "$REPO_ROOT/install.sh" "$REPO_ROOT/uninstall.sh" "$REPO_ROOT/VERSION" "$dir/"
    cp "$REPO_ROOT"/lib/*.sh "$dir/lib/"
    cp "$REPO_ROOT/skills/repo/SKILL.md" "$dir/skills/repo/"
    cp "$REPO_ROOT"/commands/repo/*.md "$dir/commands/repo/"
    cp "$REPO_ROOT"/hooks/repo/*.sh "$dir/hooks/repo/"
    cp "$REPO_ROOT"/scripts/repo/*.sh "$REPO_ROOT"/scripts/repo/*.py "$dir/scripts/repo/"
    chmod +x "$dir/install.sh" "$dir/uninstall.sh" "$dir"/scripts/repo/*.sh "$dir"/scripts/repo/*.py
    git_fixture_init "$dir"
    git -C "$dir" add -A >/dev/null 2>&1
    git -C "$dir" -c user.email=t@example.com -c user.name=Test \
        commit -qm "fixture" >/dev/null 2>&1
}

new_target() { mkdir -p "$1"; git_fixture_init "$1"; }

IN_OUT=""; IN_RC=0
do_install() {  # <source> <target> [extra install.sh args...]
    local src="$1" tgt="$2"; shift 2
    IN_OUT="$( cd "$tgt" && HOME="$FAKE_HOME" bash "$src/install.sh" -y "$@" "$tgt" 2>&1 )"
    IN_RC=$?
}

RS_OUT=""; RS_RC=0
run_resync() {  # <target> [args...] — cwd = target, as a consumer would run it
    local tgt="$1"; shift
    RS_OUT="$( cd "$tgt" && HOME="$FAKE_HOME" bash "$RESYNC_SRC" "$@" 2>&1 )"
    RS_RC=$?
}

pin() {  # <target> <line>... — append entries to the target's pin list
    local tgt="$1"; shift
    mkdir -p "$tgt/.claude/skills/repo"
    printf '%s\n' "$@" >>"$tgt/$IGNORE_REL"
}

# The marker a consumer's local customization leaves behind. Deliberately shaped
# like the real one: a subsection appended to an installed command file.
#
# The sentinel string is nonsense on purpose. An earlier draft grepped for
# `scripts/scrub-allowlist-drift.sh` — the real consumer's script name — which
# also appears verbatim in scrub.md's own `[[local_check]]` example, so the
# "unpinned edit was clobbered" control passed against the PRISTINE file and
# proved nothing. A sentinel that cannot occur upstream is what makes the
# control a control.
LOCAL_SENTINEL='CONSUMER-OWNED-WIRING-d41f8b'
LOCAL_MARK="## Repo-local check (consumer-owned)

Run \`scripts/scrub-allowlist-drift.sh\` on every pass ($LOCAL_SENTINEL)."

customize() {  # <file> — append the consumer's local subsection
    printf '\n%s\n' "$LOCAL_MARK" >>"$1"
}
has_local_mark() { grep -qF "$LOCAL_SENTINEL" "$1" 2>/dev/null; }

tree_fingerprint() {  # <dir> — content+mode manifest, for "wrote nothing" proofs
    [[ -d "$1" ]] || { echo "ABSENT"; return; }
    ( cd "$1" && find . \( -type f -o -type l \) | LC_ALL=C sort | while IFS= read -r f; do
        if [[ -L "$f" ]]; then printf '%s SYMLINK %s\n' "$f" "$(readlink "$f")"
        else printf '%s %s\n' "$f" "$(cksum <"$f")"; fi
      done )
}

echo "resync-ignore (C10 repo-owned pins) test suite"
echo "=============================================="

SRC="$SCRATCH/source"
new_source "$SRC"

SCRUB_DST=".claude/commands/repo/scrub.md"
TIDY_DST=".claude/commands/repo/tidy.md"

# ---------------------------------------------------------------------------
echo ""
echo "1. Positive control — WITHOUT a pin, a local edit is clobbered"
# ---------------------------------------------------------------------------
# This is the pre-repo#511 behaviour, and it must stay true: the pin is the only
# thing that protects a file. If this case ever passes for the wrong reason (the
# writers stopped writing at all), every survival assertion below becomes
# vacuous — which is exactly why it runs first.
T1="$SCRATCH/t1"; new_target "$T1"
do_install "$SRC" "$T1" --no-codex
assert_eq "baseline install exits 0" "0" "$IN_RC"
# Fixture precondition: the sentinel must not occur upstream, or every
# has_local_mark() assertion in this file is vacuously true.
if grep -rqF "$LOCAL_SENTINEL" "$SRC" 2>/dev/null; then
    no "the local-edit sentinel does not occur in the pristine source (precondition)" \
       "pick a different LOCAL_SENTINEL — this one now appears upstream, which silently disarms every survival assertion below"
else
    ok "the local-edit sentinel does not occur in the pristine source (precondition)"
fi
customize "$T1/$SCRUB_DST"
if has_local_mark "$T1/$SCRUB_DST"; then ok "the fixture's local edit is in place"; else no "the fixture's local edit is in place"; fi

run_resync "$T1"
assert_eq "resync exits 0" "0" "$RS_RC"
if has_local_mark "$T1/$SCRUB_DST"; then
    no "an UNPINNED local edit is clobbered by resync (positive control)" \
       "the edit survived without a pin — either the resync did not run, or it stopped writing scrub.md at all, which would make every survival case below vacuous"
else
    ok "an UNPINNED local edit is clobbered by resync (positive control)"
fi

customize "$T1/$SCRUB_DST"
do_install "$SRC" "$T1" --no-codex
if has_local_mark "$T1/$SCRUB_DST"; then
    no "an UNPINNED local edit is clobbered by a reinstall (positive control)"
else
    ok "an UNPINNED local edit is clobbered by a reinstall (positive control)"
fi

# ---------------------------------------------------------------------------
echo ""
echo "2. The four-time regression, end to end — pinned, it survives both writers"
# ---------------------------------------------------------------------------
T2="$SCRATCH/t2"; new_target "$T2"
do_install "$SRC" "$T2" --no-codex
customize "$T2/$SCRUB_DST"
pin "$T2" "# our allowlist-drift wiring lives here (2am#1596)" "$SCRUB_DST"
PINNED_BYTES="$(cksum <"$T2/$SCRUB_DST")"

run_resync "$T2"
assert_eq "resync over a pinned file exits 0" "0" "$RS_RC"
assert_eq "the pinned file is byte-identical after a resync" "$PINNED_BYTES" "$(cksum <"$T2/$SCRUB_DST")"
assert_contains "the resync report names the file as pinned" "$RS_OUT" "pinned"
assert_contains "the pinned report line names the pin list" "$RS_OUT" "$IGNORE_REL"
assert_matches "the summary counts the pin" "$RS_OUT" '[0-9]+ pinned'

do_install "$SRC" "$T2" --no-codex
assert_eq "a reinstall over a pinned file exits 0" "0" "$IN_RC"
assert_eq "the pinned file is byte-identical after a reinstall" "$PINNED_BYTES" "$(cksum <"$T2/$SCRUB_DST")"
assert_contains "install.sh reports the pinned path as left alone" "$IN_OUT" "Pinned (repo-owned, left alone): $SCRUB_DST"
assert_not_contains "install.sh does not claim it installed the pinned file" "$IN_OUT" "Installed $SCRUB_DST"

# The full alternating cycle the consumer actually experienced: install, resync,
# install, resync. Four writer passes, one surviving customization.
run_resync "$T2"; do_install "$SRC" "$T2" --no-codex; run_resync "$T2"
assert_eq "the pin holds across an install/resync/install/resync cycle" \
    "$PINNED_BYTES" "$(cksum <"$T2/$SCRUB_DST")"
if has_local_mark "$T2/$SCRUB_DST"; then ok "the consumer's subsection is still present after four writer passes"; else no "the consumer's subsection is still present after four writer passes"; fi

# ---------------------------------------------------------------------------
echo ""
echo "3. A pin is scoped — unpinned siblings still get refreshed"
# ---------------------------------------------------------------------------
# The failure this guards: implementing the pin as an early `return` in the wrong
# place (or a global flag) turns the whole resync into a no-op, which "passes"
# every survival test above while silently freezing the consumer at one version.
customize "$T2/$TIDY_DST"
run_resync "$T2"
if has_local_mark "$T2/$TIDY_DST"; then
    no "an unpinned sibling in the same run is still refreshed" \
       "tidy.md kept its local edit — the pin is acting as a global off-switch, not a per-path pin"
else
    ok "an unpinned sibling in the same run is still refreshed"
fi
assert_eq "the pinned file was untouched by that same run" "$PINNED_BYTES" "$(cksum <"$T2/$SCRUB_DST")"

# ---------------------------------------------------------------------------
echo ""
echo "4. Format — comments, blanks, ./ prefix, directory subtrees"
# ---------------------------------------------------------------------------
T4="$SCRATCH/t4"; new_target "$T4"
do_install "$SRC" "$T4" --no-codex
customize "$T4/$SCRUB_DST"
customize "$T4/$TIDY_DST"
customize "$T4/.claude/skills/repo/scripts/repo-scrub-forks.sh"
{
    echo "# a comment line"
    echo ""
    echo "   ./$SCRUB_DST   "
    echo "$TIDY_DST   # trailing comment"
    echo ".claude/skills/repo/scripts/"
} >"$T4/$IGNORE_REL"

run_resync "$T4"
assert_eq "a run with comments/blanks in the pin list exits 0" "0" "$RS_RC"
if has_local_mark "$T4/$SCRUB_DST"; then ok "a './'-prefixed, whitespace-padded entry pins the file"; else no "a './'-prefixed, whitespace-padded entry pins the file"; fi
if has_local_mark "$T4/$TIDY_DST"; then ok "an entry with a trailing '# comment' pins the file"; else no "an entry with a trailing '# comment' pins the file"; fi
if has_local_mark "$T4/.claude/skills/repo/scripts/repo-scrub-forks.sh"; then
    ok "a trailing-slash entry pins the whole subtree"
else
    no "a trailing-slash entry pins the whole subtree"
fi
assert_not_contains "a comment line is never reported as a dead pin" "$RS_OUT" "pin had no effect: '# a comment"
assert_not_contains "a blank line is never reported as a dead pin" "$RS_OUT" "pin had no effect: ''"

# A directory pin must not be readable as a prefix without the slash: the same
# text minus the slash names no file, so it is a DEAD pin, not a subtree match.
T4B="$SCRATCH/t4b"; new_target "$T4B"
do_install "$SRC" "$T4B" --no-codex
customize "$T4B/.claude/skills/repo/scripts/repo-scrub-forks.sh"
echo ".claude/skills/repo/scripts" >"$T4B/$IGNORE_REL"
run_resync "$T4B"
if has_local_mark "$T4B/.claude/skills/repo/scripts/repo-scrub-forks.sh"; then
    no "a slashless directory-ish entry does NOT silently pin the subtree" \
       "an entry without a trailing slash matched as a prefix — a pin must be an exact path or an explicit directory, never an accidental substring"
else
    ok "a slashless directory-ish entry does NOT silently pin the subtree"
fi
assert_contains "the slashless entry is reported as a dead pin instead" "$RS_OUT" \
    "pin had no effect: '.claude/skills/repo/scripts'"

# ---------------------------------------------------------------------------
echo ""
echo "5. A dead pin is named, never silent — and never fatal"
# ---------------------------------------------------------------------------
# loom#6515's failure mode: the pin LOOKS installed and does nothing, so the
# file it was meant to protect is clobbered anyway and nobody learns why.
T5="$SCRATCH/t5"; new_target "$T5"
do_install "$SRC" "$T5" --no-codex
pin "$T5" ".claude/commands/repo/scrubb.md"
run_resync "$T5"
assert_eq "a dead pin does not fail the resync" "0" "$RS_RC"
assert_contains "the resync names the dead pin" "$RS_OUT" \
    "pin had no effect: '.claude/commands/repo/scrubb.md'"
do_install "$SRC" "$T5" --no-codex
assert_eq "a dead pin does not fail the install" "0" "$IN_RC"
assert_contains "install.sh names the dead pin too" "$IN_OUT" \
    "pin had no effect: '.claude/commands/repo/scrubb.md'"

# ---------------------------------------------------------------------------
echo ""
echo "6. A pinned path that no longer exists upstream is not an error"
# ---------------------------------------------------------------------------
# The curator's named edge case: pinning a file this tool used to ship must
# degrade to "pinned", not to a failure or a confusing "no counterpart in
# source" line about a file the consumer deliberately owns.
T6="$SCRATCH/t6"; new_target "$T6"
SRC6="$SCRATCH/source-retired"; new_source "$SRC6"
do_install "$SRC6" "$T6" --no-codex
customize "$T6/$SCRUB_DST"
pin "$T6" "$SCRUB_DST"
rm -f "$SRC6/commands/repo/scrub.md"   # retired upstream, still pinned locally
run_resync "$T6"
assert_eq "a pinned-but-retired path exits 0" "0" "$RS_RC"
assert_not_contains "it is not reported as a missing-source skip" "$RS_OUT" \
    "$SCRUB_DST  (no counterpart in source)"
if has_local_mark "$T6/$SCRUB_DST"; then ok "the consumer's copy of a retired file survives"; else no "the consumer's copy of a retired file survives"; fi

# ---------------------------------------------------------------------------
echo ""
echo "7. install.sh on a pinned path that was never installed"
# ---------------------------------------------------------------------------
# A pin means "mine" on the FIRST install too. Writing it "just this once"
# would make the pin mean something different depending on which writer ran —
# the exact ambiguity this list exists to remove — so the file stays absent and
# the installer says so out loud rather than leaving a silent hole.
T7="$SCRATCH/t7"; new_target "$T7"
pin "$T7" "$SCRUB_DST"
do_install "$SRC" "$T7" --no-codex
assert_eq "a first install with a pin exits 0" "0" "$IN_RC"
if [[ ! -e "$T7/$SCRUB_DST" ]]; then
    ok "a pinned path is not created by a first install"
else
    no "a pinned path is not created by a first install"
fi
assert_contains "the installer warns that the pinned path is absent" "$IN_OUT" \
    "Pinned (repo-owned) but absent: $SCRUB_DST"
if [[ -f "$T7/$TIDY_DST" ]]; then ok "the rest of the install proceeded normally"; else no "the rest of the install proceeded normally"; fi
assert_matches "the command count reports what was written, and the pin separately" "$IN_OUT" \
    'commands into \.claude/commands/repo/ \(1 pinned as repo-owned, left alone\)'

# ---------------------------------------------------------------------------
echo ""
echo "8. --dry-run: a pin is reported, and never counted as drift"
# ---------------------------------------------------------------------------
# A pinned file that diverges from upstream forever would otherwise make
# `--dry-run` exit 2 on every run in every repo that pins anything, which is
# how a fleet-wide "is anything stale?" driver gets muted.
T8="$SCRATCH/t8"; new_target "$T8"
do_install "$SRC" "$T8" --no-codex
customize "$T8/$SCRUB_DST"
pin "$T8" "$SCRUB_DST"
T8_BEFORE="$(tree_fingerprint "$T8/.claude")"
run_resync "$T8" --dry-run
assert_eq "--dry-run over a diverged pinned file exits 0 (in sync), not 2" "0" "$RS_RC"
assert_eq "--dry-run wrote nothing" "$T8_BEFORE" "$(tree_fingerprint "$T8/.claude")"
assert_contains "--dry-run still reports the pin" "$RS_OUT" "pinned"

# install.sh --dry-run must enumerate pins too — a preview that omits them
# understates what the real run will leave alone.
IN_DRY="$( cd "$T8" && HOME="$FAKE_HOME" bash "$SRC/install.sh" --dry-run "$T8" 2>&1 )"
assert_contains "install.sh --dry-run names the pin list" "$IN_DRY" "$IGNORE_REL"
assert_contains "install.sh --dry-run lists the pinned path" "$IN_DRY" "$SCRUB_DST"

# ---------------------------------------------------------------------------
echo ""
echo "9. The pin list itself is never rewritten, deleted, or called an orphan"
# ---------------------------------------------------------------------------
T9="$SCRATCH/t9"; new_target "$T9"
do_install "$SRC" "$T9" --no-codex
pin "$T9" "$SCRUB_DST"
IGN_BYTES="$(cksum <"$T9/$IGNORE_REL")"
run_resync "$T9"
do_install "$SRC" "$T9" --no-codex
if [[ -f "$T9/$IGNORE_REL" ]]; then ok "the pin list survives both writers"; else no "the pin list survives both writers"; fi
assert_eq "the pin list is byte-identical afterwards" "$IGN_BYTES" "$(cksum <"$T9/$IGNORE_REL")"
run_resync "$T9"
assert_not_contains "the pin list is not reported as an unrecognized leftover" "$RS_OUT" \
    "    $IGNORE_REL"

# ---------------------------------------------------------------------------
echo ""
echo "10. The Codex surface honors the same list"
# ---------------------------------------------------------------------------
# A pin honored on one installed surface and not the other is a pin half the
# time, which is the same class of bug as a pin honored by one writer only.
T10="$SCRATCH/t10"; new_target "$T10"
do_install "$SRC" "$T10"
CODEX_REF=".agents/skills/repo/references/scrub.md"
if [[ -f "$T10/$CODEX_REF" ]]; then
    customize "$T10/$CODEX_REF"
    pin "$T10" "$CODEX_REF"
    run_resync "$T10"
    if has_local_mark "$T10/$CODEX_REF"; then ok "a pinned Codex reference survives a resync"; else no "a pinned Codex reference survives a resync"; fi
    do_install "$SRC" "$T10"
    if has_local_mark "$T10/$CODEX_REF"; then ok "a pinned Codex reference survives a reinstall"; else no "a pinned Codex reference survives a reinstall"; fi
else
    skip "a pinned Codex reference survives a resync" "no Codex surface installed in this fixture"
    skip "a pinned Codex reference survives a reinstall" "no Codex surface installed in this fixture"
fi

# ---------------------------------------------------------------------------
echo ""
echo "11. A source clone too old to honor pins REFUSES, rather than clobbering"
# ---------------------------------------------------------------------------
# Every other optional lib in resync-installed.sh degrades toward "refresh what
# we can". This one must not: degrading would silently overwrite files the
# consumer declared theirs, which is strictly worse than doing nothing.
T11="$SCRATCH/t11"; new_target "$T11"
SRC11="$SCRATCH/source-old"; new_source "$SRC11"
do_install "$SRC11" "$T11" --no-codex
customize "$T11/$SCRUB_DST"
pin "$T11" "$SCRUB_DST"
rm -f "$SRC11/lib/resync-ignore.sh"
T11_BEFORE="$(tree_fingerprint "$T11/.claude")"
run_resync "$T11"
assert_eq "a pin list with no lib to honor it exits 1" "1" "$RS_RC"
assert_eq "nothing was written on that refusal" "$T11_BEFORE" "$(tree_fingerprint "$T11/.claude")"
assert_contains "the refusal names the missing lib" "$RS_OUT" "lib/resync-ignore.sh"

# ...and with NO pin list, the same old clone still resyncs normally: the refusal
# is scoped to "there are pins I cannot honor", not "this clone is too old".
T11B="$SCRATCH/t11b"; new_target "$T11B"
do_install "$SRC11" "$T11B" --no-codex 2>/dev/null
cp "$REPO_ROOT/lib/resync-ignore.sh" "$SRC11/lib/" 2>/dev/null
do_install "$SRC11" "$T11B" --no-codex
rm -f "$SRC11/lib/resync-ignore.sh"
run_resync "$T11B"
assert_eq "an old clone with no pin list resyncs normally" "0" "$RS_RC"

# ---------------------------------------------------------------------------
echo ""
echo "11b. Uninstall removes pinned paths — but names them first"
# ---------------------------------------------------------------------------
# A pin protects a file from a REFRESH, not from a deliberate uninstall. The
# requirement is honesty, not immunity: removing a consumer's own content inside
# a directory-wide `rm -rf` with no mention of it is how a pin turns into a
# false sense of safety.
T11C="$SCRATCH/t11c"; new_target "$T11C"
do_install "$SRC" "$T11C" --no-codex
customize "$T11C/$SCRUB_DST"
pin "$T11C" "$SCRUB_DST"
UN_OUT="$( cd "$T11C" && HOME="$FAKE_HOME" bash "$SRC/uninstall.sh" -y "$T11C" 2>&1 )"
UN_RC=$?
assert_eq "uninstall exits 0 with pins present" "0" "$UN_RC"
assert_contains "uninstall names the pin list before removing" "$UN_OUT" "$IGNORE_REL"
assert_contains "uninstall names the pinned path itself" "$UN_OUT" "$SCRUB_DST"
assert_contains "uninstall says a pin does not survive a deliberate uninstall" "$UN_OUT" \
    "not from a"

# ---------------------------------------------------------------------------
echo ""
echo "12. One implementation, two writers"
# ---------------------------------------------------------------------------
# The regression that would reopen repo#511 without touching either writer's
# behaviour visibly: one of them growing its own copy of the parsing. Two
# readers of the same list eventually disagree, and the disagreement is
# invisible until it reaches a consumer.
INSTALL_TXT="$(cat "$REPO_ROOT/install.sh")"
RESYNC_TXT="$(cat "$RESYNC_SRC")"
assert_contains "install.sh sources the shared pin lib" "$INSTALL_TXT" \
    'source "$SOURCE_ROOT/lib/resync-ignore.sh"'
assert_contains "resync-installed.sh sources the shared pin lib" "$RESYNC_TXT" \
    'source "$SOURCE_ROOT/lib/resync-ignore.sh"'
assert_contains "install.sh consults the shared predicate" "$INSTALL_TXT" \
    "resync_ignore_is_pinned"
assert_contains "resync-installed.sh consults the shared predicate" "$RESYNC_TXT" \
    "resync_ignore_is_pinned"
# Neither writer may re-parse the file itself — the lib is the only reader.
for f in "$REPO_ROOT/install.sh" "$RESYNC_SRC"; do
    label="$(basename "$f")"
    if [[ "$(grep -c "read -r line.*resync-ignore\|< *\"\$IGNORE_FILE\"" "$f")" == "0" ]]; then
        ok "$label does not re-parse the pin list itself"
    else
        no "$label does not re-parse the pin list itself" \
           "a second parser of the same list will eventually disagree with lib/resync-ignore.sh"
    fi
done
assert_contains "the pin path is declared once, in the lib" "$(cat "$IGNORE_LIB")" \
    'RESYNC_IGNORE_REL=".claude/skills/repo/resync-ignore"'

# ---------------------------------------------------------------------------
echo ""
echo "13. The contract documents C10, and the docs point somewhere real"
# ---------------------------------------------------------------------------
CONTRACT_TXT="$(cat "$REPO_ROOT/INSTALLER-CONTRACT.md")"
assert_contains "the contract has a C10 section" "$CONTRACT_TXT" "### C10"
assert_contains "C10 publishes a spot-check" "$CONTRACT_TXT" "resync-ignore"
assert_contains "C10 requires BOTH writers to honor the list" "$CONTRACT_TXT" \
    "every writer of the installed surface"
assert_contains "C10 has a conformance-table row" "$CONTRACT_TXT" "| C10 "
SKILL_TXT="$(cat "$REPO_ROOT/skills/repo/SKILL.md")"
assert_contains "SKILL.md documents the pin list for consumers" "$SKILL_TXT" \
    ".claude/skills/repo/resync-ignore"

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

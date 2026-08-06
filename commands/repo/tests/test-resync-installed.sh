#!/usr/bin/env bash
# Test suite for scripts/repo/resync-installed.sh — the consumer-side resync
# required by INSTALLER-CONTRACT.md C7 (repo#156).
#
# Usage: ./commands/repo/tests/test-resync-installed.sh
# Exit code 0 = all tests pass, 1 = failures detected.
#
# Structured like commands/repo/tests/test-repo-remote.sh: pure bash, no
# framework, PASS/FAIL/TOTAL counters and a summary block. `pnpm test` delegates
# to this file via hooks/repo/tests/run.sh.
#
# WHY THIS FILE EXISTS: the three properties C7 names are exactly the three that
# are invisible until they bite a consumer, so each gets direct coverage here:
#   1. --dry-run really changes nothing (asserted by fingerprinting the whole
#      installed tree before and after, not by trusting the report);
#   2. it NEVER uninstalls (a consumer-local file with no source counterpart
#      survives and is named in the report);
#   3. it is idempotent (a second run reports zero writes).
# Plus the failure modes that would otherwise be silent: a target that was never
# installed, an unresolvable source clone, a --dev (symlinked) install, and the
# C5/C6 split that keeps the per-machine `last_resync` stamp OUT of the tracked
# metadata file.
#
# Every fixture lives under a scratch dir with HOME redirected, so nothing here
# can touch the developer's real repos or shell rc files.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
RESYNC_SRC="$REPO_ROOT/scripts/repo/resync-installed.sh"
CONTRACT="$REPO_ROOT/INSTALLER-CONTRACT.md"

PASS=0
FAIL=0
TOTAL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

if [[ ! -f "$RESYNC_SRC" ]]; then
    echo "FATAL: resync-installed.sh not found at $RESYNC_SRC" >&2
    exit 1
fi

SCRATCH="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$SCRATCH"' EXIT

# ---------------------------------------------------------------------------
# Assertion helpers (same shape as test-repo-remote.sh)
# ---------------------------------------------------------------------------
ok() { TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1)); printf "  ${GREEN}PASS${NC}: %s\n" "$1"; }
no() {
    TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
    printf "  ${RED}FAIL${NC}: %s\n" "$1"
    [[ -n "${2:-}" ]] && printf "        %s\n" "$2"
    return 0
}
assert_eq()           { if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1" "expected [$2], got [$3]"; fi; }
assert_contains()     { if [[ "$2" == *"$3"* ]]; then ok "$1"; else no "$1" "missing [$3] in [$2]"; fi; }
assert_not_contains() { if [[ "$2" != *"$3"* ]]; then ok "$1"; else no "$1" "unexpected [$3] present"; fi; }
assert_file()         { if [[ -f "$2" ]]; then ok "$1"; else no "$1" "no such file: $2"; fi; }

# ---------------------------------------------------------------------------
# Fixture builders.
#
# The source fixture is a COPY of this repo's installable surfaces (not this
# repo itself) so tests can bump VERSION and edit command files to simulate
# upstream movement without ever writing to the working tree they run from.
# ---------------------------------------------------------------------------
FAKE_HOME="$SCRATCH/home"
mkdir -p "$FAKE_HOME"

new_source() {  # <dir> — build a Repo Skills source clone at <dir>
    local dir="$1"
    mkdir -p "$dir/lib" "$dir/skills/repo" "$dir/commands/repo" "$dir/hooks/repo" "$dir/scripts/repo"
    cp "$REPO_ROOT/install.sh" "$REPO_ROOT/uninstall.sh" "$REPO_ROOT/VERSION" "$dir/"
    cp "$REPO_ROOT"/lib/*.sh "$dir/lib/"
    cp "$REPO_ROOT/skills/repo/SKILL.md" "$dir/skills/repo/"
    cp "$REPO_ROOT"/commands/repo/*.md "$dir/commands/repo/"
    cp "$REPO_ROOT"/hooks/repo/*.sh "$dir/hooks/repo/"
    cp "$REPO_ROOT"/scripts/repo/*.sh "$dir/scripts/repo/"
    chmod +x "$dir/install.sh" "$dir/uninstall.sh" "$dir"/scripts/repo/*.sh
    git -C "$dir" init -q
    git -C "$dir" add -A >/dev/null 2>&1
    git -C "$dir" -c user.email=t@example.com -c user.name=Test \
        commit -qm "fixture" >/dev/null 2>&1
}

new_target() {  # <dir> — an empty git repo to install into
    mkdir -p "$1"
    git -C "$1" init -q
}

do_install() {  # <source> <target> [extra install.sh args...]
    local src="$1" tgt="$2"; shift 2
    ( cd "$tgt" && HOME="$FAKE_HOME" bash "$src/install.sh" -y "$@" "$tgt" ) >/dev/null 2>&1
}

# run_resync <target> [args...] — runs with cwd = target, captures stdout+stderr
RS_OUT=""; RS_RC=0
run_resync() {
    local tgt="$1"; shift
    RS_OUT="$( cd "$tgt" && HOME="$FAKE_HOME" bash "$RESYNC_SRC" "$@" 2>&1 )"
    RS_RC=$?
}

# tree_fingerprint <dir> — a stable content+mode manifest of every file under
# <dir>, used to prove --dry-run wrote nothing at all (rather than trusting the
# script's own report of what it would have done).
tree_fingerprint() {
    ( cd "$1" && find . -type f -o -type l | LC_ALL=C sort | while IFS= read -r f; do
        if [[ -L "$f" ]]; then
            printf '%s SYMLINK %s\n' "$f" "$(readlink "$f")"
        else
            printf '%s %s %s\n' "$f" "$(cksum <"$f")" "$([[ -x "$f" ]] && echo x || echo -)"
        fi
      done )
}

echo "resync-installed.sh test suite"
echo "=============================="

# ---------------------------------------------------------------------------
echo ""
echo "-- packaging: install.sh ships the script --"
SRC="$SCRATCH/src"; TGT="$SCRATCH/tgt"
new_source "$SRC"
new_target "$TGT"
do_install "$SRC" "$TGT"

INSTALLED="$TGT/.claude/skills/repo/scripts/resync-installed.sh"
assert_file "install.sh installs resync-installed.sh into the skill scripts dir" "$INSTALLED"
if [[ -x "$INSTALLED" ]]; then ok "the installed copy is executable"; else no "the installed copy is executable"; fi

INSTALL_SH="$(cat "$REPO_ROOT/install.sh")"
assert_contains "install.sh copies scripts/repo/resync-installed.sh" \
    "$INSTALL_SH" "scripts/repo/resync-installed.sh"
assert_contains "install.sh --dry-run enumerates the resync script" \
    "$INSTALL_SH" '.claude/skills/repo/scripts/resync-installed.sh"'

DRY_INSTALL="$( cd "$TGT" && HOME="$FAKE_HOME" bash "$SRC/install.sh" --dry-run "$TGT" 2>&1 )"
assert_contains "install.sh --dry-run lists the resync script as a planned write" \
    "$DRY_INSTALL" "scripts/resync-installed.sh"

# ---------------------------------------------------------------------------
echo ""
echo "-- a fresh install is already in sync --"
run_resync "$TGT" --dry-run
assert_eq "dry-run on a fresh install exits 0" "0" "$RS_RC"
assert_contains "dry-run on a fresh install reports in-sync" "$RS_OUT" "Already in sync"
assert_not_contains "dry-run on a fresh install syncs nothing" "$RS_OUT" "would sync"

run_resync "$TGT"
assert_eq "apply on a fresh install exits 0" "0" "$RS_RC"
assert_contains "apply on a fresh install reports in-sync" "$RS_OUT" "Already in sync"

# ---------------------------------------------------------------------------
echo ""
echo "-- --dry-run detects drift and writes NOTHING --"
printf '\nlocal drift\n' >>"$TGT/.claude/commands/repo/help.md"
rm -f "$TGT/.claude/skills/repo/hooks/guard-destructive.sh"

BEFORE="$(tree_fingerprint "$TGT")"
run_resync "$TGT" --dry-run
AFTER="$(tree_fingerprint "$TGT")"

assert_eq "dry-run with drift exits 2" "2" "$RS_RC"
assert_contains "dry-run names the drifted command file" "$RS_OUT" "would sync .claude/commands/repo/help.md"
assert_contains "dry-run names the missing hook as an addition" "$RS_OUT" "would add .claude/skills/repo/hooks/guard-destructive.sh"
assert_contains "dry-run says nothing was written" "$RS_OUT" "nothing written"
assert_eq "dry-run left the installed tree byte-identical" "$BEFORE" "$AFTER"

# ---------------------------------------------------------------------------
echo ""
echo "-- apply restores drift, then is idempotent --"
run_resync "$TGT"
assert_eq "apply with drift exits 0" "0" "$RS_RC"
assert_contains "apply reports the resynced file" "$RS_OUT" "synced    .claude/commands/repo/help.md"
assert_contains "apply reports the re-added hook" "$RS_OUT" "added     .claude/skills/repo/hooks/guard-destructive.sh"

if cmp -s "$SRC/commands/repo/help.md" "$TGT/.claude/commands/repo/help.md"; then
    ok "the drifted command file now matches the source"
else
    no "the drifted command file now matches the source"
fi
assert_file "the deleted hook was restored" "$TGT/.claude/skills/repo/hooks/guard-destructive.sh"
if [[ -x "$TGT/.claude/skills/repo/hooks/guard-destructive.sh" ]]; then
    ok "the restored hook is executable"
else
    no "the restored hook is executable"
fi

run_resync "$TGT"
assert_eq "the second apply exits 0" "0" "$RS_RC"
assert_contains "the second apply is a no-op" "$RS_OUT" "Already in sync"
assert_not_contains "the second apply syncs nothing" "$RS_OUT" "synced    ."

run_resync "$TGT" --dry-run
assert_eq "dry-run after apply exits 0 (in sync)" "0" "$RS_RC"

# ---------------------------------------------------------------------------
echo ""
echo "-- it NEVER uninstalls --"
mkdir -p "$TGT/.claude/commands/repo"
echo "consumer-local command" >"$TGT/.claude/commands/repo/local-only.md"
echo "consumer notes" >"$TGT/.claude/skills/repo/notes.md"
printf '{"guards":{"sqlDdl":false}}\n' >"$TGT/.claude/skills/repo/config.json"

run_resync "$TGT"
assert_eq "apply with consumer-local files exits 0" "0" "$RS_RC"
assert_file "a consumer-local command file survives resync" "$TGT/.claude/commands/repo/local-only.md"
assert_file "a consumer-local skill file survives resync" "$TGT/.claude/skills/repo/notes.md"
assert_file "the consumer's config.json survives resync" "$TGT/.claude/skills/repo/config.json"
assert_contains "the report names what it left alone" "$RS_OUT" "left alone"
assert_contains "the left-alone list names the consumer command" "$RS_OUT" "local-only.md"
assert_not_contains "config.json is not reported as an orphan" "$RS_OUT" "config.json"

# The strongest form of the guarantee: the script contains no removal of any
# path in the target. Every `rm` in it must be a temp file it created itself.
RESYNC_BODY="$(grep -nE '(^|[^[:alnum:]_])(rm|unlink)[[:space:]]' "$RESYNC_SRC" \
    | grep -v '^[0-9]*:#' | grep -v 'rm -f "\$tmp"' | grep -v 'rm -rf "\$SCRATCH"')"
assert_eq "no rm/unlink targets anything but this script's own temp files" "" "$RESYNC_BODY"

# ---------------------------------------------------------------------------
echo ""
echo "-- an unfiltered install picks up NEW upstream commands --"
cat >"$SRC/commands/repo/brandnew.md" <<'EOF'
---
name: "brandnew"
description: "A command added upstream after the install"
domain: repo
type: command
user-invocable: true
---
# /repo:brandnew
EOF
run_resync "$TGT" --dry-run
assert_eq "dry-run sees the new upstream command as drift" "2" "$RS_RC"
assert_contains "dry-run names the new upstream command" "$RS_OUT" "would add .claude/commands/repo/brandnew.md"
run_resync "$TGT"
assert_file "apply installs the new upstream command" "$TGT/.claude/commands/repo/brandnew.md"

# ---------------------------------------------------------------------------
echo ""
echo "-- a --skills= (filtered) install is NOT widened --"
FTGT="$SCRATCH/tgt-filtered"
new_target "$FTGT"
do_install "$SRC" "$FTGT" "--skills=reset"
FMETA="$FTGT/.claude/skills/repo/install-metadata.json"
assert_contains "a filtered install records filtered:true" "$(cat "$FMETA")" '"filtered": true'
run_resync "$FTGT" --dry-run
assert_eq "dry-run on a filtered install is in sync" "0" "$RS_RC"
run_resync "$FTGT"
if [[ ! -e "$FTGT/.claude/commands/repo/brandnew.md" ]]; then
    ok "resync does not add commands the operator filtered out"
else
    no "resync does not add commands the operator filtered out"
fi
assert_file "the filtered install keeps the commands it did install" "$FTGT/.claude/commands/repo/reset.md"
assert_contains "an unfiltered install records filtered:false" \
    "$(cat "$TGT/.claude/skills/repo/install-metadata.json")" '"filtered": false'

# ---------------------------------------------------------------------------
echo ""
echo "-- version stamping keeps the C5/C6 split --"
echo "99.9.9" >"$SRC/VERSION"
run_resync "$TGT"
assert_eq "apply after a source version bump exits 0" "0" "$RS_RC"
META="$(cat "$TGT/.claude/skills/repo/install-metadata.json")"
SIDE="$(cat "$TGT/.claude/skills/repo/.install-local.json")"
assert_contains "tracked metadata is re-stamped to the source version" "$META" '"version": "99.9.9"'
assert_not_contains "tracked metadata carries NO machine-local resync stamp (C5)" "$META" "last_resync"
assert_not_contains "tracked metadata carries no source path (C5)" "$META" '"source"'
assert_contains "the gitignored sidecar records last_resync (C6)" "$SIDE" "last_resync"
assert_contains "the sidecar still records the source path" "$SIDE" '"source"'
assert_contains "the sidecar preserves the original install timestamp" "$SIDE" "installed_at"

# A dry run must never stamp anything either.
echo "99.9.10" >"$SRC/VERSION"
run_resync "$TGT" --dry-run
assert_contains "a dry run does not re-stamp the version" \
    "$(cat "$TGT/.claude/skills/repo/install-metadata.json")" '"version": "99.9.9"'

# ---------------------------------------------------------------------------
echo ""
echo "-- --quiet --"
printf '\nmore drift\n' >>"$TGT/.claude/commands/repo/help.md"
run_resync "$TGT" --quiet
assert_eq "--quiet apply exits 0" "0" "$RS_RC"
assert_eq "--quiet prints exactly one line" "1" "$(printf '%s\n' "$RS_OUT" | grep -c .)"
assert_contains "--quiet still prints the summary" "$RS_OUT" "synced"
# The summary counts legitimately mention "unchanged"; what --quiet must suppress
# is the per-file lines, i.e. any installed path.
assert_not_contains "--quiet prints no per-file paths" "$RS_OUT" ".claude/"

run_resync "$TGT" --quiet --dry-run
assert_eq "--quiet --dry-run on an in-sync tree exits 0" "0" "$RS_RC"
assert_eq "--quiet --dry-run prints exactly one line" "1" "$(printf '%s\n' "$RS_OUT" | grep -c .)"

# ---------------------------------------------------------------------------
echo ""
echo "-- loud failures instead of partial installs --"
BARE="$SCRATCH/never-installed"
new_target "$BARE"
run_resync "$BARE" --dry-run
assert_eq "a never-installed target exits 1" "1" "$RS_RC"
assert_contains "a never-installed target says so" "$RS_OUT" "No Repo Skills install found"
assert_contains "a never-installed target points at install.sh" "$RS_OUT" "install.sh"
if [[ ! -e "$BARE/.claude" ]]; then
    ok "a never-installed target is not partially populated"
else
    no "a never-installed target is not partially populated"
fi

NOSRC="$SCRATCH/tgt-nosource"
new_target "$NOSRC"
do_install "$SRC" "$NOSRC"
rm -f "$NOSRC/.claude/skills/repo/.install-local.json"
run_resync "$NOSRC" --dry-run
assert_eq "an unresolvable source exits 1" "1" "$RS_RC"
assert_contains "an unresolvable source explains the repo#96 recovery" "$RS_OUT" "regenerate the sidecar"
run_resync "$NOSRC" --dry-run --source "$SRC"
assert_eq "--source overrides the missing sidecar" "0" "$RS_RC"

MOVED="$SCRATCH/tgt-movedsource"
new_target "$MOVED"
do_install "$SRC" "$MOVED"
MOVED_SIDECAR="$MOVED/.claude/skills/repo/.install-local.json"
printf '{\n  "source": "%s",\n  "installed_at": "2026-01-01T00:00:00Z"\n}\n' \
    "$SCRATCH/gone" >"$MOVED_SIDECAR"
run_resync "$MOVED" --dry-run
assert_eq "a source clone that no longer exists exits 1" "1" "$RS_RC"
assert_contains "a vanished source clone says so" "$RS_OUT" "no longer exists on disk"

NOTSRC="$SCRATCH/not-a-source"
mkdir -p "$NOTSRC"
run_resync "$TGT" --dry-run --source "$NOTSRC"
assert_eq "a --source that isn't a Repo Skills clone exits 1" "1" "$RS_RC"
assert_contains "a bogus --source says what it expected" "$RS_OUT" "does not look like a Repo Skills clone"

run_resync "$TGT" /some/positional
assert_eq "a positional argument is rejected" "1" "$RS_RC"
assert_contains "the positional rejection names --target" "$RS_OUT" "--target"

run_resync "$TGT" --nope
assert_eq "an unknown option is rejected" "1" "$RS_RC"

run_resync "$TGT" --help
assert_eq "--help exits 0" "0" "$RS_RC"
assert_contains "--help documents --dry-run" "$RS_OUT" "--dry-run"
assert_contains "--help documents --quiet" "$RS_OUT" "--quiet"

# ---------------------------------------------------------------------------
echo ""
echo "-- a --dev (symlinked) install is left alone --"
DTGT="$SCRATCH/tgt-dev"
new_target "$DTGT"
do_install "$SRC" "$DTGT" "--dev"
# The version/resync stamps ARE rewritten on a dev install (a resync did happen);
# what must not change is any copied surface — every one of them is a symlink
# into the source clone and replacing one would silently break live editing.
dev_fingerprint() { tree_fingerprint "$1" | grep -v 'install-metadata\|install-local'; }
DEV_BEFORE="$(dev_fingerprint "$DTGT")"
run_resync "$DTGT"
DEV_AFTER="$(dev_fingerprint "$DTGT")"
assert_eq "resync on a dev install exits 0" "0" "$RS_RC"
assert_contains "resync reports the dev install" "$RS_OUT" "dev install"
assert_contains "resync skips symlinked destinations" "$RS_OUT" "symlinked (dev-mode install)"
if [[ -L "$DTGT/.claude/skills/repo/SKILL.md" ]]; then
    ok "the dev symlink is still a symlink after resync"
else
    no "the dev symlink is still a symlink after resync"
fi
assert_eq "resync left every dev-install surface byte-identical" "$DEV_BEFORE" "$DEV_AFTER"

# ---------------------------------------------------------------------------
echo ""
echo "-- it refreshes itself (deferred self-update) --"
printf '\n# upstream tweak\n' >>"$SRC/scripts/repo/resync-installed.sh"
run_resync "$TGT"
assert_eq "self-update apply exits 0" "0" "$RS_RC"
if cmp -s "$SRC/scripts/repo/resync-installed.sh" "$TGT/.claude/skills/repo/scripts/resync-installed.sh"; then
    ok "the installed resync script refreshed itself"
else
    no "the installed resync script refreshed itself"
fi
if [[ -x "$TGT/.claude/skills/repo/scripts/resync-installed.sh" ]]; then
    ok "the refreshed copy is still executable"
else
    no "the refreshed copy is still executable"
fi
RS_SELF_INDEX="$(printf '%s\n' "$RS_OUT" | grep -n 'scripts/resync-installed.sh' | head -n1 | cut -d: -f1)"
RS_LAST_FILE_INDEX="$(printf '%s\n' "$RS_OUT" | grep -nE '^  (synced|added|unchanged|skipped)' | tail -n1 | cut -d: -f1)"
assert_eq "the self-copy is the last file in the plan" "$RS_SELF_INDEX" "$RS_LAST_FILE_INDEX"

# The installed copy must be runnable in its own right — it is what a consumer
# (and 2am/scripts/fleet-resync.sh) actually invokes.
INSTALLED_OUT="$( cd "$TGT" && HOME="$FAKE_HOME" \
    bash "$TGT/.claude/skills/repo/scripts/resync-installed.sh" --dry-run --quiet 2>&1 )"
INSTALLED_RC=$?
assert_eq "the INSTALLED copy runs and reports in-sync" "0" "$INSTALLED_RC"
assert_contains "the installed copy prints a summary" "$INSTALLED_OUT" "in sync"

# ---------------------------------------------------------------------------
echo ""
echo "-- uninstall.sh still owns removal --"
UN="$(cat "$REPO_ROOT/uninstall.sh")"
assert_contains "uninstall.sh enumerates the resync script" "$UN" "resync-installed.sh"

# ---------------------------------------------------------------------------
echo ""
echo "-- the contract document backs the script --"
assert_file "INSTALLER-CONTRACT.md exists at the repo root" "$CONTRACT"
if [[ -f "$CONTRACT" ]]; then
    CT="$(cat "$CONTRACT")"
    assert_contains "the contract names the resync script path" "$CT" "resync-installed.sh"
    assert_contains "the contract requires --dry-run" "$CT" '`--dry-run`'
    assert_contains "the contract requires --quiet" "$CT" '`--quiet`'
    assert_contains "the contract forbids uninstalling" "$CT" "**MUST NOT** uninstall"
    assert_contains "the contract says why" "$CT" "refresh that can delete"
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

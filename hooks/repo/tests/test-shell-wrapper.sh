#!/usr/bin/env bash
# Test suite for lib/shell-wrapper.sh and its install.sh --shell-wrapper /
# uninstall.sh wiring (repo#35).
#
# Usage: ./hooks/repo/tests/test-shell-wrapper.sh
# Exit code 0 = all tests pass, 1 = failures detected.
#
# Structured like test-session-start-handoff.sh / test-install-claude-md-markers.sh
# next door: pure bash, no test framework, PASS/FAIL counters and a summary
# block. install.sh/uninstall.sh are driven with HOME pointed at a scratch
# directory so real shell rc files are never touched.
#
# The contract under test:
#   - --yes without --shell-wrapper is a strict no-op (rc never read/written)
#   - --shell-wrapper folds an existing `alias claude=...`'s flags into the
#     function, adds `unalias claude` ahead of the function definition, and
#     never invokes `claude` recursively (always `command claude`)
#   - the block is marker-bounded and idempotent (re-install replaces in place)
#   - a backup exists after every edit
#   - fish is skipped with a clear message, rc untouched
#   - uninstall.sh removes the block (backed up) and is a no-op once absent
#   - the rendered banner function itself behaves correctly at runtime (fresh
#     note, stale note, no note, non-git cwd)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
UNINSTALL_SH="$REPO_ROOT/uninstall.sh"
LIB="$REPO_ROOT/lib/shell-wrapper.sh"

PASS=0
FAIL=0
TOTAL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

for f in "$INSTALL_SH" "$UNINSTALL_SH" "$LIB"; do
    if [[ ! -f "$f" ]]; then
        echo "FATAL: required file not found at $f" >&2
        exit 1
    fi
done

# Resolve to a PHYSICAL path (macOS mktemp -d hands back /var/folders/..., a
# symlink to /private/var/folders/...) so md5/diff comparisons never trip on
# the two spellings of the same path.
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
    [[ -n "${2:-}" ]] && printf "%s\n" "$2" | sed 's/^/        /'
    return 0
}
assert_eq() {  # <label> <expected> <actual>
    if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1" "expected [$2], got [$3]"; fi
}
assert_contains() {  # <label> <haystack> <needle>
    if [[ "$2" == *"$3"* ]]; then ok "$1"; else no "$1" "missing [$3] in:
$2"; fi
}
assert_not_contains() {  # <label> <haystack> <needle>
    if [[ "$2" != *"$3"* ]]; then ok "$1"; else no "$1" "unexpectedly present: [$3]"; fi
}
assert_file_bytes_eq() {  # <label> <file-a> <file-b>
    if diff -u "$2" "$3" >/dev/null 2>&1; then
        ok "$1"
    else
        no "$1" "$(diff -u "$2" "$3" | head -20)"
    fi
}

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

new_home_target() {  # <name> -> prints "home_dir target_dir" (space-separated)
    local base="$SCRATCH/$1" home target
    home="$base/home"; target="$base/target"
    mkdir -p "$home" "$target"
    git init -q "$target" 2>/dev/null
    printf '%s %s' "$home" "$target"
}

# ===========================================================================
echo "lib/shell-wrapper.sh + install.sh --shell-wrapper suite"
echo "========================================================="

# ---------------------------------------------------------------------------
echo ""
echo "-- unit: shell_wrapper_detect_shell / shell_wrapper_rc_path --"
(
    source "$LIB"
    OUT_ZSH="$(SHELL=/bin/zsh shell_wrapper_detect_shell)"
    [[ "$OUT_ZSH" == "zsh" ]] && echo "PASS: zsh detected via \$SHELL" || echo "FAIL: zsh detected via \$SHELL -> got [$OUT_ZSH]"

    OUT_BASH="$(SHELL=/bin/bash shell_wrapper_detect_shell)"
    [[ "$OUT_BASH" == "bash" ]] && echo "PASS: bash detected via \$SHELL" || echo "FAIL: bash detected via \$SHELL -> got [$OUT_BASH]"

    OUT_FISH="$(SHELL=/usr/local/bin/fish shell_wrapper_detect_shell)"; FISH_RC=$?
    [[ "$OUT_FISH" == "fish" && "$FISH_RC" -eq 1 ]] && echo "PASS: fish detected, non-zero return" || echo "FAIL: fish detection -> [$OUT_FISH] rc=$FISH_RC"

    RC_ZSH="$(HOME=/scratch-home shell_wrapper_rc_path zsh)"
    [[ "$RC_ZSH" == "/scratch-home/.zshrc" ]] && echo "PASS: zsh rc path" || echo "FAIL: zsh rc path -> [$RC_ZSH]"

    RC_BASH="$(HOME=/scratch-home shell_wrapper_rc_path bash)"
    [[ "$RC_BASH" == "/scratch-home/.bashrc" ]] && echo "PASS: bash rc path" || echo "FAIL: bash rc path -> [$RC_BASH]"
) > "$SCRATCH/unit1.out" 2>&1
while IFS= read -r line; do
    case "$line" in
        PASS:*) ok "${line#PASS: }" ;;
        FAIL:*) no "${line#FAIL: }" ;;
    esac
done < "$SCRATCH/unit1.out"

# ---------------------------------------------------------------------------
echo ""
echo "-- unit: shell_wrapper_parse_alias_flags --"
(
    source "$LIB"
    if shell_wrapper_parse_alias_flags "alias claude='command claude --dangerously-skip-permissions'" \
        && [[ "$SHELL_WRAPPER_FLAGS" == "--dangerously-skip-permissions" ]]; then
        echo "PASS: parses 'command claude <flags>' form"
    else
        echo "FAIL: parses 'command claude <flags>' form -> [$SHELL_WRAPPER_FLAGS]"
    fi

    if shell_wrapper_parse_alias_flags "alias claude='claude --foo --bar=baz'" \
        && [[ "$SHELL_WRAPPER_FLAGS" == "--foo --bar=baz" ]]; then
        echo "PASS: parses bare 'claude <flags>' form"
    else
        echo "FAIL: parses bare 'claude <flags>' form -> [$SHELL_WRAPPER_FLAGS]"
    fi

    if shell_wrapper_parse_alias_flags "alias claude='claude'" && [[ -z "$SHELL_WRAPPER_FLAGS" ]]; then
        echo "PASS: parses no-flags alias as empty flags"
    else
        echo "FAIL: parses no-flags alias -> [$SHELL_WRAPPER_FLAGS]"
    fi

    if shell_wrapper_parse_alias_flags "alias claude='somethingelse --x'"; then
        echo "FAIL: unrecognized alias target should be refused"
    else
        echo "PASS: unrecognized alias target refused"
    fi
) > "$SCRATCH/unit2.out" 2>&1
while IFS= read -r line; do
    case "$line" in
        PASS:*) ok "${line#PASS: }" ;;
        FAIL:*) no "${line#FAIL: }" ;;
    esac
done < "$SCRATCH/unit2.out"

# ---------------------------------------------------------------------------
echo ""
echo "-- install.sh: --yes without --shell-wrapper is a strict no-op --"

read -r H1 T1 <<<"$(new_home_target strict-noop)"
cat > "$H1/.zshrc" <<'EOF'
export FOO=bar
EOF
cp "$H1/.zshrc" "$SCRATCH/strict-noop-before.zshrc"

OUT1="$(HOME="$H1" SHELL=/bin/zsh bash "$INSTALL_SH" -y "$T1" 2>&1)"; RC1=$?
assert_eq "strict no-op: install exits 0" "0" "$RC1"
assert_file_bytes_eq "strict no-op: .zshrc byte-identical" "$SCRATCH/strict-noop-before.zshrc" "$H1/.zshrc"
assert_not_contains "strict no-op: no wrapper marker mentioned in output" "$OUT1" "REPO-SKILLS CLAUDE WRAPPER"

# ---------------------------------------------------------------------------
echo ""
echo "-- install.sh --shell-wrapper: existing alias flags are preserved --"

read -r H2 T2 <<<"$(new_home_target alias-preserve)"
cat > "$H2/.zshrc" <<'EOF'
# my zshrc
export FOO=bar
alias claude='command claude --dangerously-skip-permissions'
EOF

OUT2="$(HOME="$H2" SHELL=/bin/zsh bash "$INSTALL_SH" -y --shell-wrapper "$T2" 2>&1)"; RC2=$?
BODY2="$(cat "$H2/.zshrc")"

assert_eq "alias-preserve: install exits 0" "0" "$RC2"
assert_contains "alias-preserve: reports success" "$OUT2" "Installed claude shell wrapper"
assert_contains "alias-preserve: flag folded into command claude"  "$BODY2" "command claude --dangerously-skip-permissions \"\$@\""
assert_contains "alias-preserve: unalias precedes the function"    "$BODY2" "unalias claude 2>/dev/null"
assert_contains "alias-preserve: marker-bounded"                   "$BODY2" "# BEGIN REPO-SKILLS CLAUDE WRAPPER"
assert_contains "alias-preserve: original alias line untouched"    "$BODY2" "alias claude='command claude --dangerously-skip-permissions'"
assert_not_contains "alias-preserve: no bare recursive 'claude' call" "$BODY2" $'\n  claude "$@"'

# unalias must appear textually BEFORE the function definition, or it cannot
# neutralize an alias sourced earlier in the same rc.
UNALIAS_POS="${BODY2%%unalias claude*}"
FUNC_POS="${BODY2%%claude() {*}"
assert_eq "alias-preserve: unalias precedes 'claude()' textually" "true" \
    "$([[ ${#UNALIAS_POS} -lt ${#FUNC_POS} ]] && echo true || echo false)"

# A backup must exist after the edit.
BACKUP2="$(printf '%s\n' "$OUT2" | grep -o '/[^ ]*\.zshrc\.repo-skills-backup\.[A-Za-z0-9]*' | tail -1)"
if [[ -n "$BACKUP2" && -f "$BACKUP2" ]]; then
    ok "alias-preserve: backup file exists"
    assert_contains "alias-preserve: backup holds the pre-edit content" "$(cat "$BACKUP2")" "alias claude='command claude --dangerously-skip-permissions'"
else
    no "alias-preserve: backup file exists" "no backup path found/created (parsed: [$BACKUP2])"
fi

# Idempotency: re-running with the same flag yields byte-identical content and
# exactly one marker pair.
BEFORE_RERUN="$(cat "$H2/.zshrc")"
HOME="$H2" SHELL=/bin/zsh bash "$INSTALL_SH" -y --shell-wrapper "$T2" >/dev/null 2>&1
AFTER_RERUN="$(cat "$H2/.zshrc")"
assert_eq "alias-preserve: idempotent re-install (byte-identical)" "$BEFORE_RERUN" "$AFTER_RERUN"
N_BEGIN="$(grep -cxF '# BEGIN REPO-SKILLS CLAUDE WRAPPER' "$H2/.zshrc")"
assert_eq "alias-preserve: exactly one marker pair after re-install" "1" "$N_BEGIN"

# ---------------------------------------------------------------------------
echo ""
echo "-- install.sh --shell-wrapper: no pre-existing alias --"

read -r H3 T3 <<<"$(new_home_target no-alias)"
cat > "$H3/.bashrc" <<'EOF'
export FOO=bar
EOF

HOME="$H3" SHELL=/bin/bash bash "$INSTALL_SH" -y --shell-wrapper "$T3" >/dev/null 2>&1
BODY3="$(cat "$H3/.bashrc")"
assert_contains "no-alias: plain 'command claude' with no extra flags" "$BODY3" $'command claude "$@"'
assert_not_contains "no-alias: no stray double space from empty flags" "$BODY3" "command claude  \"\$@\""

# ---------------------------------------------------------------------------
echo ""
echo "-- install.sh --shell-wrapper: rc file does not exist yet --"

read -r H4 T4 <<<"$(new_home_target missing-rc)"
# H4/.zshrc deliberately not created.
HOME="$H4" SHELL=/bin/zsh bash "$INSTALL_SH" -y --shell-wrapper "$T4" >/dev/null 2>&1
if [[ -f "$H4/.zshrc" ]]; then
    ok "missing-rc: .zshrc created"
    assert_contains "missing-rc: contains the wrapper block" "$(cat "$H4/.zshrc")" "# BEGIN REPO-SKILLS CLAUDE WRAPPER"
else
    no "missing-rc: .zshrc created" "file was not created"
fi

# ---------------------------------------------------------------------------
echo ""
echo "-- install.sh --shell-wrapper: fish is skipped, rc untouched --"

read -r H5 T5 <<<"$(new_home_target fish-skip)"
OUT5="$(HOME="$H5" SHELL=/usr/local/bin/fish bash "$INSTALL_SH" -y --shell-wrapper "$T5" 2>&1)"; RC5=$?
assert_eq "fish-skip: install still exits 0" "0" "$RC5"
assert_contains "fish-skip: clear skip message" "$OUT5" "fish"
if [[ -e "$H5/.zshrc" || -e "$H5/.bashrc" || -e "$H5/.config/fish" ]]; then
    no "fish-skip: no rc file created for any shell" "found an rc under $H5"
else
    ok "fish-skip: no rc file created for any shell"
fi

# ---------------------------------------------------------------------------
echo ""
echo "-- install.sh --shell-wrapper: unparseable existing alias bails cleanly --"

read -r H6 T6 <<<"$(new_home_target alias-unparseable)"
cat > "$H6/.zshrc" <<'EOF'
# my zshrc
alias claude='some-wrapper-script.sh --flag'
EOF
cp "$H6/.zshrc" "$SCRATCH/alias-unparseable-before.zshrc"

OUT6="$(HOME="$H6" SHELL=/bin/zsh bash "$INSTALL_SH" -y --shell-wrapper "$T6" 2>&1)"; RC6=$?
assert_eq "alias-unparseable: install still exits 0 (feature-local bail, not fatal)" "0" "$RC6"
assert_contains "alias-unparseable: explains the bail" "$OUT6" "isn't in the supported single-line form"
assert_file_bytes_eq "alias-unparseable: rc byte-identical (never guessed)" "$SCRATCH/alias-unparseable-before.zshrc" "$H6/.zshrc"

# ---------------------------------------------------------------------------
echo ""
echo "-- install.sh --dry-run --shell-wrapper: enumerates without writing --"

read -r H7 T7 <<<"$(new_home_target dry-run)"
DRY7="$(HOME="$H7" SHELL=/bin/zsh bash "$INSTALL_SH" --dry-run --shell-wrapper "$T7" 2>&1)"
assert_contains "dry-run: mentions the rc path" "$DRY7" "$H7/.zshrc"
if [[ -f "$H7/.zshrc" ]]; then
    no "dry-run: writes nothing" ".zshrc was created"
else
    ok "dry-run: writes nothing"
fi

# ---------------------------------------------------------------------------
echo ""
echo "-- uninstall.sh: removes the block, backs it up, leaves the rest byte-identical --"

read -r H8 T8 <<<"$(new_home_target uninstall-roundtrip)"
cat > "$H8/.zshrc" <<'EOF'
# my zshrc
export FOO=bar
EOF
cp "$H8/.zshrc" "$SCRATCH/uninstall-roundtrip-expected.zshrc"

HOME="$H8" SHELL=/bin/zsh bash "$INSTALL_SH" -y --shell-wrapper "$T8" >/dev/null 2>&1
assert_contains "uninstall-roundtrip: wrapper present before uninstall" "$(cat "$H8/.zshrc")" "# BEGIN REPO-SKILLS CLAUDE WRAPPER"

OUT8="$(HOME="$H8" SHELL=/bin/zsh bash "$UNINSTALL_SH" -y "$T8" 2>&1)"; RC8=$?
assert_eq "uninstall-roundtrip: uninstall exits 0" "0" "$RC8"
assert_contains "uninstall-roundtrip: reports removal" "$OUT8" "Removed claude shell wrapper from"
assert_file_bytes_eq "uninstall-roundtrip: .zshrc back to original content" \
    "$SCRATCH/uninstall-roundtrip-expected.zshrc" "$H8/.zshrc"

# Second uninstall run: no-op (block already absent).
BEFORE9="$(cat "$H8/.zshrc")"
OUT9="$(HOME="$H8" SHELL=/bin/zsh bash "$UNINSTALL_SH" -y "$T8" 2>&1)"
AFTER9="$(cat "$H8/.zshrc")"
assert_eq "uninstall-roundtrip: second run leaves .zshrc unchanged" "$BEFORE9" "$AFTER9"
assert_not_contains "uninstall-roundtrip: second run reports no removal" "$OUT9" "Removed claude shell wrapper from"

# ---------------------------------------------------------------------------
echo ""
echo "-- guard: ambiguous marker layout is refused, never guessed --"

read -r H10 T10 <<<"$(new_home_target ambiguous)"
cat > "$H10/.zshrc" <<'EOF'
# BEGIN REPO-SKILLS CLAUDE WRAPPER
first (hand-duplicated)
# END REPO-SKILLS CLAUDE WRAPPER
# BEGIN REPO-SKILLS CLAUDE WRAPPER
second (hand-duplicated)
# END REPO-SKILLS CLAUDE WRAPPER
EOF
cp "$H10/.zshrc" "$SCRATCH/ambiguous-before.zshrc"

OUT10="$(HOME="$H10" SHELL=/bin/zsh bash "$INSTALL_SH" -y --shell-wrapper "$T10" 2>&1)"
assert_contains "ambiguous: reports refusal" "$OUT10" "ambiguous REPO-SKILLS CLAUDE WRAPPER marker layout"
assert_file_bytes_eq "ambiguous: rc untouched" "$SCRATCH/ambiguous-before.zshrc" "$H10/.zshrc"

# ---------------------------------------------------------------------------
echo ""
echo "-- runtime: the rendered banner function behaves correctly --"

# Extract just the body between the markers and source it into a throwaway
# bash, then exercise _repo_claude_handoff_banner directly — this is the part
# that actually runs every time a user launches `claude`, so it is verified
# for real rather than just asserting the text is present.
render_body() {  # <flags> -> the block's body (markers stripped), to stdout
    (
        source "$LIB"
        shell_wrapper_render_block "$1"
    ) | sed '1d;$d'
}

RT_HOME="$SCRATCH/runtime-repo"
mkdir -p "$RT_HOME"
git init -q "$RT_HOME" 2>/dev/null

BLOCK_FILE="$SCRATCH/runtime-block.sh"
render_body "" > "$BLOCK_FILE"

# No note present -> silent, no output.
OUT_NONOTE="$(cd "$RT_HOME" && bash -c "source '$BLOCK_FILE'; _repo_claude_handoff_banner" 2>&1)"
assert_eq "runtime: no note -> silent" "" "$OUT_NONOTE"

# Fresh note -> banner with path + "just now", no STALE warning.
mkdir -p "$RT_HOME/.claude"
cat > "$RT_HOME/.claude/handoff.md" <<'EOF'
# Handoff — today

## In-flight
Resolve this first.

## Decisions
Settled.
EOF
OUT_FRESH="$(cd "$RT_HOME" && bash -c "source '$BLOCK_FILE'; _repo_claude_handoff_banner" 2>&1)"
assert_contains "runtime: fresh note -> banner header" "$OUT_FRESH" "Handoff note pending"
assert_contains "runtime: fresh note -> path shown" "$OUT_FRESH" "$RT_HOME/.claude/handoff.md"
assert_contains "runtime: fresh note -> age just now" "$OUT_FRESH" "just now"
assert_contains "runtime: fresh note -> section outline" "$OUT_FRESH" "In-flight"
assert_not_contains "runtime: fresh note -> no STALE warning" "$OUT_FRESH" "STALE"

# Stale note (mtime forced 8 days back) -> STALE warning present.
OLD_EPOCH=$(( $(date +%s) - 8*24*3600 ))
if touch -d "@$OLD_EPOCH" "$RT_HOME/.claude/handoff.md" 2>/dev/null \
    || touch -t "$(date -r "$OLD_EPOCH" +%Y%m%d%H%M.%S 2>/dev/null)" "$RT_HOME/.claude/handoff.md" 2>/dev/null; then
    OUT_STALE="$(cd "$RT_HOME" && bash -c "source '$BLOCK_FILE'; _repo_claude_handoff_banner" 2>&1)"
    assert_contains "runtime: stale note -> STALE warning" "$OUT_STALE" "STALE"
else
    no "runtime: stale note -> STALE warning" "could not backdate mtime with either GNU or BSD touch"
fi
rm -f "$RT_HOME/.claude/handoff.md"

# Non-git cwd -> falls back to $PWD, never errors.
NONGIT="$SCRATCH/nongit-dir"
mkdir -p "$NONGIT"
OUT_NONGIT="$(cd "$NONGIT" && bash -c "source '$BLOCK_FILE'; _repo_claude_handoff_banner" 2>&1)"
assert_eq "runtime: non-git cwd -> silent, no error" "" "$OUT_NONGIT"

# _repo_claude_is_session gating — matches the minimum list from repo#32/#35.
GATE_OUT="$(bash -c "source '$BLOCK_FILE'
for s in update doctor mcp config install migrate-installer setup-token -v --version -h --help; do
  if _repo_claude_is_session \"\$s\"; then echo \"FAIL:\$s\"; fi
done
for s in '' chat 'some-prompt'; do
  if ! _repo_claude_is_session \"\$s\"; then echo \"FAIL:default:\$s\"; fi
done
echo DONE" 2>&1)"
if [[ "$GATE_OUT" == *DONE ]] && [[ "$GATE_OUT" != *FAIL* ]]; then
    ok "runtime: _repo_claude_is_session gates the documented subcommand list"
else
    no "runtime: _repo_claude_is_session gates the documented subcommand list" "$GATE_OUT"
fi

# The claude() function itself: never recurses (never calls bare "claude"),
# and always falls through to `command claude "$@"` even when its own helpers
# are undefined (repo#35 field-report fail-transparent requirement).
RECURSE_CHECK="$(bash -c "
claude() { echo SHOULD_NOT_RUN; }  # simulate a shadow the wrapper must not hit
$(cat "$BLOCK_FILE")
command() { if [[ \"\$1\" == claude ]]; then shift; echo \"command-claude-called:\$*\"; else builtin command \"\$@\"; fi; }
claude --version
" 2>&1)"
assert_eq "runtime: claude() invokes 'command claude', passing argv through" \
    "command-claude-called:--version" "$RECURSE_CHECK"

# Helpers deliberately undefined -> claude() still falls through transparently.
NOHELPERS="$(bash -c "
claude() {
  if type _repo_claude_is_session >/dev/null 2>&1 && type _repo_claude_handoff_banner >/dev/null 2>&1; then
    _repo_claude_is_session \"\${1:-}\" && _repo_claude_handoff_banner
  fi
  command claude \"\$@\"
}
command() { if [[ \"\$1\" == claude ]]; then shift; echo \"passthrough:\$*\"; else builtin command \"\$@\"; fi; }
claude mcp list
" 2>&1)"
assert_eq "runtime: missing helpers -> transparent passthrough, argv unchanged" \
    "passthrough:mcp list" "$NOHELPERS"

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

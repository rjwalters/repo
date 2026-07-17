#!/usr/bin/env bash
# Repo Skills uninstaller — remove installed skills from a target repository.
#
# Usage: ./uninstall.sh [-y] [/path/to/target-repo]

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

error()   { echo -e "${RED}✗ Error: $*${NC}" >&2; exit 1; }
info()    { echo -e "${BLUE}ℹ $*${NC}"; }
success() { echo -e "${GREEN}✓ $*${NC}"; }

MARKER_BEGIN='<!-- BEGIN REPO-SKILLS -->'
MARKER_END='<!-- END REPO-SKILLS -->'

# The PreToolUse guard command install.sh wires into .claude/settings.json. The
# hook *script* lives under .claude/skills/repo/hooks/ and is removed with the
# skills dir below; only this settings.json entry needs explicit removal.
HOOK_CMD="\${CLAUDE_PROJECT_DIR}/.claude/skills/repo/hooks/guard-destructive.sh"

# Remove only the Repo-Skills-owned PreToolUse/Bash hook entry from
# .claude/settings.json, leaving any other entries (a hand-authored hook, or
# Loom's own guard) untouched, and pruning containers that become empty so no
# `"hooks": {}` litter is left behind.
remove_settings_hook() {  # <settings-path>
  local settings="$1" tmp
  [[ -f "$settings" ]] || return 0
  jq -e . "$settings" >/dev/null 2>&1 || return 0
  # Only act if our command is actually present.
  jq -e --arg c "$HOOK_CMD" \
    '(.hooks.PreToolUse // []) | any(.[]?; (.hooks // []) | any(.[]?; .command == $c))' \
    "$settings" >/dev/null 2>&1 || return 0
  tmp="$(mktemp)"
  if jq --arg c "$HOOK_CMD" '
        if (.hooks.PreToolUse | type) == "array" then
          .hooks.PreToolUse |= map(.hooks |= ((. // []) | map(select(.command != $c))))
          | .hooks.PreToolUse |= map(select(((.hooks // []) | length) > 0))
          | (if (.hooks.PreToolUse | length) == 0 then .hooks |= del(.PreToolUse) else . end)
          | (if (.hooks | length) == 0 then del(.hooks) else . end)
        else . end
      ' "$settings" >"$tmp"; then
    mv "$tmp" "$settings"
    success "Removed PreToolUse guard entry from .claude/settings.json"
  else
    rm -f "$tmp"
  fi
}

TARGET=""
YES=false
for arg in "$@"; do
  case "$arg" in
    -y|--yes) YES=true ;;
    -h|--help) sed -n '2,4p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) error "Unknown option: $arg" ;;
    *)  TARGET="$arg" ;;
  esac
done

[[ -n "$TARGET" ]] || TARGET="."
TARGET="$(cd "$TARGET" 2>/dev/null && pwd)" || error "Target directory does not exist"

[[ -d "$TARGET/.claude/skills/repo" || -d "$TARGET/.claude/commands/repo" ]] \
  || { info "No Repo Skills install found in $TARGET"; exit 0; }

echo "Will remove from $TARGET:"
[[ -d "$TARGET/.claude/skills/repo" ]]   && echo "  .claude/skills/repo/ (incl. hooks/guard-destructive.sh)"
[[ -d "$TARGET/.claude/commands/repo" ]] && echo "  .claude/commands/repo/"
grep -qF "$MARKER_BEGIN" "$TARGET/CLAUDE.md" 2>/dev/null && echo "  CLAUDE.md REPO-SKILLS block"
if [[ -f "$TARGET/.claude/settings.json" ]] && \
   jq -e --arg c "$HOOK_CMD" '(.hooks.PreToolUse // []) | any(.[]?; (.hooks // []) | any(.[]?; .command == $c))' \
     "$TARGET/.claude/settings.json" >/dev/null 2>&1; then
  echo "  .claude/settings.json PreToolUse guard entry"
fi

if [[ "$YES" != true ]]; then
  read -r -p "Proceed? [y/N] " reply
  [[ "$reply" =~ ^[Yy] ]] || { info "Uninstall cancelled"; exit 0; }
fi

rm -rf "$TARGET/.claude/skills/repo" "$TARGET/.claude/commands/repo"
success "Removed skill and command directories"

# Remove the settings.json hook entry BEFORE pruning empty .claude dirs, so the
# rmdir below can clean up an empty .claude if settings.json was the only file.
if command -v jq >/dev/null 2>&1; then
  remove_settings_hook "$TARGET/.claude/settings.json"
fi

rmdir "$TARGET/.claude/skills" "$TARGET/.claude/commands" "$TARGET/.claude" 2>/dev/null || true

if [[ -f "$TARGET/CLAUDE.md" ]] && grep -qF "$MARKER_BEGIN" "$TARGET/CLAUDE.md"; then
  TMP="$(mktemp)"
  awk -v begin="$MARKER_BEGIN" -v end="$MARKER_END" '
    $0 == begin { skip = 1; next }
    $0 == end   { skip = 0; next }
    !skip       { print }
  ' "$TARGET/CLAUDE.md" >"$TMP"
  mv "$TMP" "$TARGET/CLAUDE.md"
  success "Removed REPO-SKILLS block from CLAUDE.md"
fi

success "Repo Skills uninstalled"

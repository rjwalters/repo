#!/usr/bin/env bash
# Repo Skills uninstaller — remove installed skills from a target repository.
#
# Usage: ./uninstall.sh [-y] [/path/to/target-repo]

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

error()   { echo -e "${RED}✗ Error: $*${NC}" >&2; exit 1; }
info()    { echo -e "${BLUE}ℹ $*${NC}"; }
success() { echo -e "${GREEN}✓ $*${NC}"; }
warning() { echo -e "${YELLOW}⚠ $*${NC}"; }

SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MARKER_BEGIN='<!-- BEGIN REPO-SKILLS -->'
MARKER_END='<!-- END REPO-SKILLS -->'

# Marker-string-anchored CLAUDE.md surgery, shared with install.sh. Never
# rewrite the block by hand here — see lib/claude-md-block.sh (repo#38).
# shellcheck source=lib/claude-md-block.sh
source "$SOURCE_ROOT/lib/claude-md-block.sh"

# The PreToolUse guard command install.sh wires into .claude/settings.json. The
# hook *script* lives under .claude/skills/repo/hooks/ and is removed with the
# skills dir below; only this settings.json entry needs explicit removal.
HOOK_CMD="\${CLAUDE_PROJECT_DIR}/.claude/skills/repo/hooks/guard-destructive.sh"

# Likewise for the SessionStart handoff hook install.sh wires under one entry
# per session source ("startup", "resume"). Its script also lives under
# .claude/skills/repo/hooks/ and goes with the skills dir.
SESSIONSTART_HOOK_CMD="\${CLAUDE_PROJECT_DIR}/.claude/skills/repo/hooks/session-start-handoff.sh"

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

# Mirror image of the above for the SessionStart handoff hook: remove only
# entries whose command is exactly ours, across every source matcher, then prune
# matcher groups and containers that become empty. A hand-authored SessionStart
# hook — or another tool's — is left untouched, including one sharing the same
# "startup"/"resume" matcher group.
remove_settings_sessionstart_hook() {  # <settings-path>
  local settings="$1" tmp
  [[ -f "$settings" ]] || return 0
  jq -e . "$settings" >/dev/null 2>&1 || return 0
  # Only act if our command is actually present.
  jq -e --arg c "$SESSIONSTART_HOOK_CMD" \
    '(.hooks.SessionStart // []) | any(.[]?; (.hooks // []) | any(.[]?; .command == $c))' \
    "$settings" >/dev/null 2>&1 || return 0
  tmp="$(mktemp)"
  if jq --arg c "$SESSIONSTART_HOOK_CMD" '
        if (.hooks.SessionStart | type) == "array" then
          .hooks.SessionStart |= map(.hooks |= ((. // []) | map(select(.command != $c))))
          | .hooks.SessionStart |= map(select(((.hooks // []) | length) > 0))
          | (if (.hooks.SessionStart | length) == 0 then .hooks |= del(.SessionStart) else . end)
          | (if (.hooks | length) == 0 then del(.hooks) else . end)
        else . end
      ' "$settings" >"$tmp"; then
    mv "$tmp" "$settings"
    success "Removed SessionStart handoff entry from .claude/settings.json"
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
[[ -d "$TARGET/.claude/skills/repo" ]]   && echo "  .claude/skills/repo/ (incl. hooks/guard-destructive.sh, hooks/session-start-handoff.sh, scripts/repo-remote.sh)"
[[ -d "$TARGET/.claude/commands/repo" ]] && echo "  .claude/commands/repo/"
grep -qF "$MARKER_BEGIN" "$TARGET/CLAUDE.md" 2>/dev/null && echo "  CLAUDE.md REPO-SKILLS block"
if [[ -f "$TARGET/.claude/settings.json" ]] && \
   jq -e --arg c "$HOOK_CMD" '(.hooks.PreToolUse // []) | any(.[]?; (.hooks // []) | any(.[]?; .command == $c))' \
     "$TARGET/.claude/settings.json" >/dev/null 2>&1; then
  echo "  .claude/settings.json PreToolUse guard entry"
fi
if [[ -f "$TARGET/.claude/settings.json" ]] && \
   jq -e --arg c "$SESSIONSTART_HOOK_CMD" '(.hooks.SessionStart // []) | any(.[]?; (.hooks // []) | any(.[]?; .command == $c))' \
     "$TARGET/.claude/settings.json" >/dev/null 2>&1; then
  echo "  .claude/settings.json SessionStart handoff entry"
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
  remove_settings_sessionstart_hook "$TARGET/.claude/settings.json"
fi

rmdir "$TARGET/.claude/skills" "$TARGET/.claude/commands" "$TARGET/.claude" 2>/dev/null || true

if [[ -f "$TARGET/CLAUDE.md" ]] && grep -qF "$MARKER_BEGIN" "$TARGET/CLAUDE.md"; then
  if claude_md_block_rewrite "$TARGET/CLAUDE.md" "$MARKER_BEGIN" "$MARKER_END"; then
    info "Backed up CLAUDE.md to $CLAUDE_MD_BLOCK_BACKUP before rewriting"
    success "Removed REPO-SKILLS block from CLAUDE.md"
  else
    warning "Refusing to rewrite $TARGET/CLAUDE.md: $CLAUDE_MD_BLOCK_ERROR"
    warning "The marker layout cannot be resolved unambiguously, and guessing risks"
    warning "deleting content this uninstaller does not own. CLAUDE.md is untouched —"
    warning "remove the REPO-SKILLS block by hand."
  fi
fi

success "Repo Skills uninstalled"

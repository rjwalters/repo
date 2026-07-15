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
[[ -d "$TARGET/.claude/skills/repo" ]]   && echo "  .claude/skills/repo/"
[[ -d "$TARGET/.claude/commands/repo" ]] && echo "  .claude/commands/repo/"
grep -qF "$MARKER_BEGIN" "$TARGET/CLAUDE.md" 2>/dev/null && echo "  CLAUDE.md REPO-SKILLS block"

if [[ "$YES" != true ]]; then
  read -r -p "Proceed? [y/N] " reply
  [[ "$reply" =~ ^[Yy] ]] || { info "Uninstall cancelled"; exit 0; }
fi

rm -rf "$TARGET/.claude/skills/repo" "$TARGET/.claude/commands/repo"
rmdir "$TARGET/.claude/skills" "$TARGET/.claude/commands" "$TARGET/.claude" 2>/dev/null || true
success "Removed skill and command directories"

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

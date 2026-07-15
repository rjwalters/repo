#!/usr/bin/env bash
# Repo Skills installer — copy skills into a target repository's .claude/ directory.
#
# Usage: ./install.sh [OPTIONS] [/path/to/target-repo]
#
# Options:
#   --skills=a,b,c   Install only these commands (default: all)
#   --list           List available commands and exit
#   --dry-run        Show what would be written without writing
#   -y, --yes        Non-interactive mode (skip confirmation prompts)
#   -h, --help       Show this help
#
# Examples:
#   ./install.sh ~/projects/my-app
#   ./install.sh --skills=clean,remote .
#   ./install.sh --dry-run ~/projects/my-app

set -euo pipefail

trap 'echo ""; echo -e "\033[0;34mℹ Installation cancelled\033[0m"; exit 130' SIGINT
trap 'exit 143' SIGTERM

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
VERSION="$(cat "$SOURCE_ROOT/VERSION" 2>/dev/null || echo unknown)"
COMMIT="$(git -C "$SOURCE_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"

MARKER_BEGIN='<!-- BEGIN REPO-SKILLS -->'
MARKER_END='<!-- END REPO-SKILLS -->'

TARGET=""
SKILLS_FILTER=""
DRY_RUN=false
YES=false

usage() { sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

list_commands() {
  for f in "$SOURCE_ROOT"/commands/repo/*.md; do
    basename "$f" .md
  done
}

for arg in "$@"; do
  case "$arg" in
    --skills=*) SKILLS_FILTER="${arg#--skills=}" ;;
    --list)     list_commands; exit 0 ;;
    --dry-run)  DRY_RUN=true ;;
    -y|--yes)   YES=true ;;
    -h|--help)  usage; exit 0 ;;
    -*)         error "Unknown option: $arg (see --help)" ;;
    *)          [[ -n "$TARGET" ]] && error "Multiple targets given: $TARGET and $arg"
                TARGET="$arg" ;;
  esac
done

[[ -n "$TARGET" ]] || TARGET="."
TARGET="$(cd "$TARGET" 2>/dev/null && pwd)" || error "Target directory does not exist"

[[ "$TARGET" == "$SOURCE_ROOT" ]] && error "Refusing to install into the repo-skills source repo itself"

if [[ ! -d "$TARGET/.git" ]] && ! git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1; then
  warning "$TARGET is not a git repository"
  if [[ "$YES" != true ]]; then
    read -r -p "Install anyway? [y/N] " reply
    [[ "$reply" =~ ^[Yy] ]] || { info "Installation cancelled"; exit 0; }
  fi
fi

# Resolve command selection
ALL_COMMANDS="$(list_commands)"
if [[ -n "$SKILLS_FILTER" ]]; then
  SELECTED=""
  IFS=',' read -ra wanted <<<"$SKILLS_FILTER"
  for w in "${wanted[@]}"; do
    w="$(echo "$w" | tr -d '[:space:]')"
    [[ -f "$SOURCE_ROOT/commands/repo/$w.md" ]] || error "Unknown skill '$w' (run --list to see available skills)"
    SELECTED+="$w"$'\n'
  done
  COMMANDS="$(echo "$SELECTED" | sed '/^$/d')"
else
  COMMANDS="$ALL_COMMANDS"
fi

echo ""
info "Repo Skills v$VERSION ($COMMIT) → $TARGET"
info "Commands: $(echo "$COMMANDS" | tr '\n' ' ')"
echo ""

if [[ "$DRY_RUN" == true ]]; then
  echo "Would write:"
  echo "  $TARGET/.claude/skills/repo/SKILL.md"
  echo "  $TARGET/.claude/skills/repo/install-metadata.json"
  while IFS= read -r cmd; do
    echo "  $TARGET/.claude/commands/repo/$cmd.md"
  done <<<"$COMMANDS"
  echo "  $TARGET/CLAUDE.md (marker-bounded REPO-SKILLS block)"
  exit 0
fi

if [[ "$YES" != true ]]; then
  read -r -p "Proceed? [Y/n] " reply
  [[ -z "$reply" || "$reply" =~ ^[Yy] ]] || { info "Installation cancelled"; exit 0; }
fi

# 1. Skill file
mkdir -p "$TARGET/.claude/skills/repo"
cp "$SOURCE_ROOT/skills/repo/SKILL.md" "$TARGET/.claude/skills/repo/SKILL.md"
success "Installed .claude/skills/repo/SKILL.md"

# 2. Command files
mkdir -p "$TARGET/.claude/commands/repo"
while IFS= read -r cmd; do
  cp "$SOURCE_ROOT/commands/repo/$cmd.md" "$TARGET/.claude/commands/repo/$cmd.md"
done <<<"$COMMANDS"
success "Installed $(echo "$COMMANDS" | wc -l | tr -d ' ') commands into .claude/commands/repo/"

# 3. Install metadata
{
  echo "{"
  echo "  \"version\": \"$VERSION\","
  echo "  \"commit\": \"$COMMIT\","
  echo "  \"installed_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
  echo "  \"source\": \"$SOURCE_ROOT\","
  echo "  \"commands\": [$(echo "$COMMANDS" | sed 's/.*/"&"/' | paste -sd, -)]"
  echo "}"
} >"$TARGET/.claude/skills/repo/install-metadata.json"
success "Wrote install-metadata.json"

# 4. CLAUDE.md block (replace existing block in place, else append)
CLAUDE_MD="$TARGET/CLAUDE.md"
BLOCK_FILE="$(mktemp)"
{
  echo "$MARKER_BEGIN"
  echo ""
  echo "## Repo Skills"
  echo ""
  echo "This repository has [Repo Skills](https://github.com/rjwalters/repo) v$VERSION installed."
  echo "General repository hygiene and environment commands, invoked as \`/repo:<command>\`:"
  echo ""
  while IFS= read -r cmd; do
    desc="$(grep -m1 '^description:' "$SOURCE_ROOT/commands/repo/$cmd.md" | sed 's/^description: *//; s/^"//; s/"$//')"
    echo "- \`/repo:$cmd\` — $desc"
  done <<<"$COMMANDS"
  echo ""
  echo "Details: \`.claude/skills/repo/SKILL.md\`. All hygiene commands are report-first —"
  echo "they present findings and wait for direction before changing anything."
  echo ""
  echo "$MARKER_END"
} >"$BLOCK_FILE"

if [[ -f "$CLAUDE_MD" ]] && grep -qF "$MARKER_BEGIN" "$CLAUDE_MD"; then
  TMP="$(mktemp)"
  awk -v begin="$MARKER_BEGIN" -v end="$MARKER_END" -v block="$BLOCK_FILE" '
    $0 == begin { skip = 1; while ((getline line < block) > 0) print line; close(block); next }
    $0 == end   { skip = 0; next }
    !skip       { print }
  ' "$CLAUDE_MD" >"$TMP"
  mv "$TMP" "$CLAUDE_MD"
  success "Updated REPO-SKILLS block in CLAUDE.md"
else
  { [[ -s "$CLAUDE_MD" ]] && echo ""; cat "$BLOCK_FILE"; } >>"$CLAUDE_MD"
  success "Appended REPO-SKILLS block to CLAUDE.md"
fi
rm -f "$BLOCK_FILE"

echo ""
success "Repo Skills v$VERSION installed. Try /repo:audit in Claude Code."

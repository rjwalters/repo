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

# Template variables substituted into installed files at install time (the Loom
# pattern). Command/SKILL authors may use these; the installer renders them on
# copy and fails fast if a known placeholder survives into an installed file.
# The consumer-repo identity (owner/name) is derived from its git remote below;
# repo-specific behavior is otherwise read at runtime, not baked in here.
TEMPLATE_PLACEHOLDERS=('{{REPO_OWNER}}' '{{REPO_NAME}}' '{{REPO_SKILLS_VERSION}}' '{{REPO_SKILLS_COMMIT}}' '{{INSTALL_DATE}}')
INSTALL_DATE="$(date -u +%Y-%m-%d)"
REPO_OWNER="OWNER"
REPO_NAME="REPO"

render() {  # stdin -> stdout with template variables substituted
  sed \
    -e "s|{{REPO_OWNER}}|${REPO_OWNER}|g" \
    -e "s|{{REPO_NAME}}|${REPO_NAME}|g" \
    -e "s|{{REPO_SKILLS_VERSION}}|${VERSION}|g" \
    -e "s|{{REPO_SKILLS_COMMIT}}|${COMMIT}|g" \
    -e "s|{{INSTALL_DATE}}|${INSTALL_DATE}|g"
}

assert_no_placeholders() {  # <file> <label> — fail if a known placeholder leaked through
  local file="$1" label="$2" ph found=()
  for ph in "${TEMPLATE_PLACEHOLDERS[@]}"; do
    grep -qF "$ph" "$file" && found+=("$ph")
  done
  [[ ${#found[@]} -eq 0 ]] || error "Unsubstituted template placeholder(s) in $label: ${found[*]}"
}

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

# Derive the consumer repo's identity for template substitution (best-effort:
# parse owner/name from the origin remote, else fall back to the directory name).
REPO_NAME="$(basename "$TARGET")"
_remote="$(git -C "$TARGET" config --get remote.origin.url 2>/dev/null || true)"
if [[ -n "$_remote" ]]; then
  _remote="${_remote%.git}"
  REPO_NAME="${_remote##*/}"
  _rest="${_remote%/*}"
  REPO_OWNER="${_rest##*[:/]}"
fi

# Resolve command selection
ALL_COMMANDS="$(list_commands)"
if [[ -n "$SKILLS_FILTER" ]]; then
  # help is the entry point and only describes what is installed — always include it
  SELECTED="help"$'\n'
  IFS=',' read -ra wanted <<<"$SKILLS_FILTER"
  for w in "${wanted[@]}"; do
    w="$(echo "$w" | tr -d '[:space:]')"
    [[ -f "$SOURCE_ROOT/commands/repo/$w.md" ]] || error "Unknown skill '$w' (run --list to see available skills)"
    SELECTED+="$w"$'\n'
  done
  COMMANDS="$(echo "$SELECTED" | sed '/^$/d' | sort -u)"
else
  COMMANDS="$ALL_COMMANDS"
fi

echo ""
info "Repo Skills v$VERSION ($COMMIT) → $TARGET"
info "Commands: $(echo "$COMMANDS" | tr '\n' ' ')"
echo ""

if [[ "$DRY_RUN" == true ]]; then
  echo "Template identity: {{REPO_OWNER}}=$REPO_OWNER {{REPO_NAME}}=$REPO_NAME"
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
render <"$SOURCE_ROOT/skills/repo/SKILL.md" >"$TARGET/.claude/skills/repo/SKILL.md"
assert_no_placeholders "$TARGET/.claude/skills/repo/SKILL.md" ".claude/skills/repo/SKILL.md"
success "Installed .claude/skills/repo/SKILL.md"

# 2. Command files
mkdir -p "$TARGET/.claude/commands/repo"
while IFS= read -r cmd; do
  render <"$SOURCE_ROOT/commands/repo/$cmd.md" >"$TARGET/.claude/commands/repo/$cmd.md"
  assert_no_placeholders "$TARGET/.claude/commands/repo/$cmd.md" "commands/repo/$cmd.md"
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
# The block is intentionally lightweight: a pointer to the real docs, not an
# inlined command dump. `/repo:help` and SKILL.md carry the authoritative,
# always-current command list; duplicating it here just goes stale.
BLOCK_FILE="$(mktemp)"
{
  echo "$MARKER_BEGIN"
  echo "This repository has [Repo Skills](https://github.com/rjwalters/repo) v$VERSION installed —"
  echo "general repository hygiene and environment commands invoked as \`/repo:<command>\`. Run"
  echo "\`/repo:help\` for the command list, or see \`.claude/skills/repo/SKILL.md\` for the full"
  echo "guide. Hygiene commands are report-first: they present findings and wait before changing"
  echo "anything. Managed by \`install.sh\` — edit outside the markers only."
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
success "Repo Skills v$VERSION installed. Try /repo:help in Claude Code."

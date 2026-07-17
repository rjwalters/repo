#!/usr/bin/env bash
# Repo Skills installer — copy skills into a target repository's .claude/ directory.
#
# Usage: ./install.sh [OPTIONS] [/path/to/target-repo]
#
# Options:
#   --skills=a,b,c   Install only these commands (default: all)
#   --dev            Symlink source files instead of copying (for dogfooding);
#                    allows installing into the source repo itself
#   --list           List available commands and exit
#   --dry-run        Show what would be written without writing
#   -y, --yes        Non-interactive mode (skip confirmation prompts)
#   -h, --help       Show this help
#
# Examples:
#   ./install.sh ~/projects/my-app
#   ./install.sh --skills=clean,remote .
#   ./install.sh --dry-run ~/projects/my-app
#   ./install.sh --dev .            # dogfood: live /repo:* here via symlinks

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
DEV=false

usage() { sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

list_commands() {
  for f in "$SOURCE_ROOT"/commands/repo/*.md; do
    basename "$f" .md
  done
}

for arg in "$@"; do
  case "$arg" in
    --skills=*) SKILLS_FILTER="${arg#--skills=}" ;;
    --dev)      DEV=true ;;
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

if [[ "$TARGET" == "$SOURCE_ROOT" && "$DEV" != true ]]; then
  error "Refusing to install into the repo-skills source repo itself (use --dev to dogfood via symlinks)"
fi

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
[[ "$DEV" == true ]] && info "Dev mode: symlinking source files (edits are live)"
info "Commands: $(echo "$COMMANDS" | tr '\n' ' ')"
echo ""

if [[ "$DRY_RUN" == true ]]; then
  [[ "$DEV" == true ]] && echo "Dev mode: files below are symlinks into $SOURCE_ROOT"
  echo "Template identity: {{REPO_OWNER}}=$REPO_OWNER {{REPO_NAME}}=$REPO_NAME"
  echo "Would write:"
  echo "  $TARGET/.claude/skills/repo/SKILL.md"
  echo "  $TARGET/.claude/skills/repo/install-metadata.json"
  echo "  $TARGET/.claude/skills/repo/.install-local.json (machine-local, gitignored)"
  echo "  $TARGET/.claude/skills/repo/hooks/guard-destructive.sh"
  echo "  $TARGET/.claude/settings.json (merge PreToolUse→Bash guard hook; idempotent, coexistence-aware)"
  while IFS= read -r cmd; do
    echo "  $TARGET/.claude/commands/repo/$cmd.md"
  done <<<"$COMMANDS"
  if [[ "$DEV" == true ]]; then
    echo "  $TARGET/.gitignore (.claude/ entry; CLAUDE.md skipped in dev mode)"
  elif git -C "$TARGET" check-ignore -q .claude/commands/repo 2>/dev/null \
    || git -C "$TARGET" check-ignore -q .claude/skills/repo 2>/dev/null; then
    echo "  $TARGET/CLAUDE.md (skipped — install destination is gitignored)"
  else
    echo "  $TARGET/.gitignore (.claude/skills/repo/.install-local.json entry)"
    echo "  $TARGET/CLAUDE.md (marker-bounded REPO-SKILLS block)"
  fi
  exit 0
fi

if [[ "$YES" != true ]]; then
  read -r -p "Proceed? [Y/n] " reply
  [[ -z "$reply" || "$reply" =~ ^[Yy] ]] || { info "Installation cancelled"; exit 0; }
fi

# In dev mode we symlink source files (edits are live, no re-install needed);
# otherwise we render template variables and copy. We symlink per-file rather
# than whole directories so install-metadata.json and any target-only files
# stay real and never leak back into the source tree.
install_file() {  # <source-abs> <dest-abs> <label>
  if [[ "$DEV" == true ]]; then
    ln -sf "$1" "$2"
  else
    render <"$1" >"$2"
    assert_no_placeholders "$2" "$3"
  fi
}

# The PreToolUse guard hook's installed command, as Claude Code resolves it
# (${CLAUDE_PROJECT_DIR} expands to the consumer repo root at hook time).
HOOK_INSTALL_REL=".claude/skills/repo/hooks/guard-destructive.sh"
HOOK_CMD="\${CLAUDE_PROJECT_DIR}/${HOOK_INSTALL_REL}"
SETTINGS_JSON="$TARGET/.claude/settings.json"

# Idempotently wire the guard-destructive.sh PreToolUse/Bash hook into the
# target's .claude/settings.json WITHOUT clobbering anything else in the file.
# Unlike Loom (which owns and wholesale-copies its settings.json), Repo Skills
# must assume the consumer may already have their own hooks/permissions — so we
# JSON-merge with jq via a temp-file-and-mv write (never redirect jq straight
# onto the file: a mid-read jq failure would truncate it).
merge_settings_hook() {
  local settings="$SETTINGS_JSON" cmd="$HOOK_CMD" tmp
  [[ -f "$settings" ]] || echo '{}' >"$settings"

  # Refuse to touch a malformed file rather than risk corrupting it.
  if ! jq -e . "$settings" >/dev/null 2>&1; then
    warning "Skipping hook wiring: $settings is not valid JSON (wire it by hand)"
    return
  fi

  # Idempotent re-install: our exact command is already present.
  if jq -e --arg c "$cmd" '
        (.hooks.PreToolUse // []) | any(.[]?;
          (.matcher == "Bash") and ((.hooks // []) | any(.[]?; .command == $c)))
      ' "$settings" >/dev/null 2>&1; then
    info "PreToolUse guard already wired in .claude/settings.json (no change)"
    return
  fi

  # Coexistence: another guard-destructive.sh (e.g. Loom's .loom/hooks copy) is
  # already wired under a Bash matcher. Defer to it rather than double-guard —
  # two guards would both fire on every command and risk a double-prompt.
  if jq -e '
        (.hooks.PreToolUse // []) | any(.[]?;
          (.matcher == "Bash") and ((.hooks // []) | any(.[]?;
            (.command // "") | test("guard-destructive\\.sh"))))
      ' "$settings" >/dev/null 2>&1; then
    info "A destructive-command guard is already wired in .claude/settings.json — deferring to it (not adding a duplicate)"
    return
  fi

  tmp="$(mktemp)"
  if jq --arg c "$cmd" '
        .hooks //= {} |
        .hooks.PreToolUse //= [] |
        if (.hooks.PreToolUse | any(.[]?; .matcher == "Bash"))
        then .hooks.PreToolUse |= map(
          if .matcher == "Bash"
          then .hooks = ((.hooks // []) + [{type: "command", command: $c}])
          else . end)
        else .hooks.PreToolUse += [{matcher: "Bash", hooks: [{type: "command", command: $c}]}]
        end
      ' "$settings" >"$tmp"; then
    mv "$tmp" "$settings"
    success "Wired PreToolUse guard into .claude/settings.json"
  else
    rm -f "$tmp"
    warning "Failed to update $settings — left unchanged"
  fi
}

# 1. Skill file
mkdir -p "$TARGET/.claude/skills/repo"
install_file "$SOURCE_ROOT/skills/repo/SKILL.md" "$TARGET/.claude/skills/repo/SKILL.md" ".claude/skills/repo/SKILL.md"
success "Installed .claude/skills/repo/SKILL.md"

# 2. Command files
mkdir -p "$TARGET/.claude/commands/repo"
while IFS= read -r cmd; do
  install_file "$SOURCE_ROOT/commands/repo/$cmd.md" "$TARGET/.claude/commands/repo/$cmd.md" "commands/repo/$cmd.md"
done <<<"$COMMANDS"
success "Installed $(echo "$COMMANDS" | wc -l | tr -d ' ') commands into .claude/commands/repo/"

# 3. Install metadata
# Tracked file: only fields that are identical for any machine installing the
# same version/commit/skill-set, so repeat installs of a release are byte-
# reproducible and no machine-local path/timestamp leaks into consumer history.
{
  echo "{"
  echo "  \"version\": \"$VERSION\","
  echo "  \"commit\": \"$COMMIT\","
  echo "  \"dev\": $DEV,"
  echo "  \"commands\": [$(echo "$COMMANDS" | sed 's/.*/"&"/' | paste -sd, -)]"
  echo "}"
} >"$TARGET/.claude/skills/repo/install-metadata.json"
success "Wrote install-metadata.json"

# Machine-local sidecar (gitignored): the absolute source-clone path and the
# run-specific install timestamp. These are meaningless in any other clone and
# must never be committed. /repo:update-tools reads `source` from here to prefer
# the local source clone; this mirrors the existing .loom/loom-source-path
# precedent for the identical Loom-self-install problem.
{
  echo "{"
  echo "  \"source\": \"$SOURCE_ROOT\","
  echo "  \"installed_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
  echo "}"
} >"$TARGET/.claude/skills/repo/.install-local.json"
success "Wrote .install-local.json (machine-local, gitignored)"

# Ensure the sidecar is gitignored on every install. Dev mode ignores the whole
# .claude/ tree in step 4 below (which already covers the sidecar), so only the
# copy install needs an explicit entry here. Guard with check-ignore so we skip
# when the path is already ignored (e.g. destination-gitignored installs), and
# grep so a re-install never appends a duplicate line.
if [[ "$DEV" != true ]] \
  && ! git -C "$TARGET" check-ignore -q .claude/skills/repo/.install-local.json 2>/dev/null; then
  GITIGNORE="$TARGET/.gitignore"
  SIDECAR_IGNORE=".claude/skills/repo/.install-local.json"
  if [[ ! -f "$GITIGNORE" ]] || ! grep -qxF "$SIDECAR_IGNORE" "$GITIGNORE"; then
    { [[ -f "$GITIGNORE" && -s "$GITIGNORE" ]] && echo ""
      echo "# Repo Skills machine-local install metadata (absolute source path + timestamp)"
      echo "$SIDECAR_IGNORE"; } >>"$GITIGNORE"
    success "Added $SIDECAR_IGNORE to .gitignore"
  fi
fi

# 3b. Destructive-command guard hook + settings.json wiring.
# Colocated under the skill's own directory so uninstall's `rm -rf
# .claude/skills/repo` removes the script for free; only the settings.json entry
# needs explicit removal. render+copy drops the exec bit (the hook has no
# template placeholders, so assert_no_placeholders passes), so re-set it; in dev
# mode install_file symlinks and the chmod is a harmless no-op on the source.
mkdir -p "$TARGET/.claude/skills/repo/hooks"
install_file "$SOURCE_ROOT/hooks/repo/guard-destructive.sh" \
  "$TARGET/.claude/skills/repo/hooks/guard-destructive.sh" "hooks/repo/guard-destructive.sh"
chmod +x "$TARGET/.claude/skills/repo/hooks/guard-destructive.sh" 2>/dev/null || true
success "Installed .claude/skills/repo/hooks/guard-destructive.sh"
merge_settings_hook

# 4. CLAUDE.md block (replace existing block in place, else append).
# Skipped in dev mode: the symlinked install is machine-local (absolute symlinks
# must not be committed), so instead of advertising it in a committed CLAUDE.md
# we ensure .claude/ is gitignored and leave CLAUDE.md untouched.
if [[ "$DEV" == true ]]; then
  GITIGNORE="$TARGET/.gitignore"
  if [[ ! -f "$GITIGNORE" ]] || ! grep -qxF '.claude/' "$GITIGNORE"; then
    { [[ -f "$GITIGNORE" && -s "$GITIGNORE" ]] && echo ""; echo "# Repo Skills dev-mode symlinks (machine-local, do not commit)"; echo ".claude/"; } >>"$GITIGNORE"
    success "Added .claude/ to .gitignore"
  fi
  echo ""
  success "Repo Skills v$VERSION dev-installed (symlinked). Edits to source are live. Try /repo:help in Claude Code."
  exit 0
fi

CLAUDE_MD="$TARGET/CLAUDE.md"

# If the install destination is gitignored in the target, the command/skill
# files we just wrote are effectively machine-local (they won't be committed),
# so a tracked CLAUDE.md pointer would advertise /repo:* commands whose files
# aren't in the repo. Mirror dev mode here: skip the CLAUDE.md block entirely.
# Probe each destination separately (check-ignore -q accepts only one pathname)
# and skip if *either* is ignored, since a split state is itself broken. The
# probe exits non-zero outside a git repo or when nothing is ignored, which
# correctly falls through to the write path.
dest_is_gitignored() {
  git -C "$TARGET" check-ignore -q .claude/commands/repo 2>/dev/null \
    || git -C "$TARGET" check-ignore -q .claude/skills/repo 2>/dev/null
}
if dest_is_gitignored; then
  warning "Install destination (.claude/commands, .claude/skills) is gitignored in $TARGET;"
  warning "skipping the CLAUDE.md pointer block (a committed pointer to uncommitted command"
  warning "files is not what you want). The /repo:* commands still work in-session."
  echo ""
  success "Repo Skills v$VERSION installed. Try /repo:help in Claude Code."
  exit 0
fi

# The block is intentionally lightweight: a pointer to the real docs, not an
# inlined command dump. `/repo:help` and SKILL.md carry the authoritative,
# always-current command list; duplicating it here just goes stale.
BLOCK_FILE="$(mktemp)"
{
  echo "$MARKER_BEGIN"
  echo "This repository has [Repo Skills](https://github.com/rjwalters/repo) v$VERSION installed —"
  echo "general repository hygiene and environment commands invoked as \`/repo:<command>\`. Run"
  echo "\`/repo:help\` for the command list, or see \`.claude/skills/repo/SKILL.md\` for the full"
  echo "guide. Hygiene commands apply safe, reversible fixes by default and report each"
  echo "change; run with \`--ask\` to review first, and \`--prune\` to allow irreversible"
  echo "removals. Managed by \`install.sh\` — edit outside the markers only."
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

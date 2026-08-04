#!/usr/bin/env bash
# Repo Skills installer — copy skills into a target repository's .claude/ directory.
#
# Usage: ./install.sh [OPTIONS] [/path/to/target-repo]
#
# Options:
#   --skills=a,b,c    Install only these commands (default: all)
#   --dev             Symlink source files instead of copying (for dogfooding);
#                     allows installing into the source repo itself
#   --list            List available commands and exit
#   --dry-run         Show what would be written without writing
#   -y, --yes         Non-interactive mode (skip confirmation prompts)
#   --shell-wrapper   Opt into shell `claude` + `codex`/`codex-safe` wrappers
#                     (edits ~/.zshrc or ~/.bashrc — the only thing this
#                     installer writes outside the target repo). The claude
#                     wrapper surfaces a pending /repo:handoff note before Claude
#                     starts; the codex wrapper gives an interactive operator a
#                     bypass-approvals default plus a read-only codex-safe entry
#                     point. Default: off. Even without this flag, an
#                     interactive install still offers it via a confirm (default
#                     N, diff shown first); under --yes it is always a strict
#                     no-op unless this flag is also passed.
#   -h, --help        Show this help
#
# Examples:
#   ./install.sh ~/projects/my-app
#   ./install.sh --skills=clean,remote .
#   ./install.sh --dry-run ~/projects/my-app
#   ./install.sh --dev .            # dogfood: live /repo:* here via symlinks
#   ./install.sh -y --shell-wrapper ~/projects/my-app   # opt into the shell wrapper non-interactively

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

confirm() {  # <prompt> <default: Y|N> — returns 0 to proceed; honors --yes, never fails silently
  local prompt="$1" default="$2" reply
  [[ "$YES" == true ]] && return 0
  [[ -t 0 ]] || error "Interactive confirmation unavailable (no TTY). Re-run with --yes (-y) to proceed non-interactively."
  read -r -p "$prompt" reply \
    || error "Confirmation prompt failed (stdin closed). Re-run with --yes (-y) to proceed non-interactively."
  if [[ "$default" == Y ]]; then
    [[ -z "$reply" || "$reply" =~ ^[Yy] ]]
  else
    [[ "$reply" =~ ^[Yy] ]]
  fi
}

SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="$(cat "$SOURCE_ROOT/VERSION" 2>/dev/null || echo unknown)"
COMMIT="$(git -C "$SOURCE_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"

MARKER_BEGIN='<!-- BEGIN REPO-SKILLS -->'
MARKER_END='<!-- END REPO-SKILLS -->'

# Marker-string-anchored CLAUDE.md surgery, shared with uninstall.sh. Never
# rewrite the block by hand here — see lib/claude-md-block.sh (repo#38).
# shellcheck source=lib/claude-md-block.sh
source "$SOURCE_ROOT/lib/claude-md-block.sh"

# Shell `claude` + `codex` wrappers (opt-in via --shell-wrapper) — the one thing
# this installer can write outside the target repo. See lib/shell-wrapper.sh
# (repo#35 claude, repo#80 codex) for the detection/parsing/rewrite logic and
# its safety contract.
# shellcheck source=lib/shell-wrapper.sh
source "$SOURCE_ROOT/lib/shell-wrapper.sh"

claude_md_has_block() { [[ -f "$TARGET/CLAUDE.md" ]] && grep -qF "$MARKER_BEGIN" "$TARGET/CLAUDE.md"; }

# A pointer block committed by an earlier install goes permanently stale once
# the destination becomes gitignored (or dev-symlinked): every later install
# skips CLAUDE.md, yet the committed block still names a version and claims to
# be managed. That stale version reads as authoritative — worse than no block —
# so on the skip paths we offer to remove the orphan rather than leave it.
reconcile_orphaned_block() {
  claude_md_has_block || return 0
  warning "CLAUDE.md contains a REPO-SKILLS block from an earlier install. In this"
  warning "configuration it will never be updated again, so its version claim is stale"
  warning "(or will silently go stale) while still reading as authoritative."
  if [[ "$YES" != true && ! -t 0 ]]; then
    warning "No TTY to confirm removal — leaving the stale block in place. Re-run with"
    warning "--yes to remove it, or delete the marker-bounded block from CLAUDE.md manually."
    return 0
  fi
  if confirm "Remove the orphaned REPO-SKILLS block from CLAUDE.md? [Y/n] " Y; then
    if claude_md_block_rewrite "$TARGET/CLAUDE.md" "$MARKER_BEGIN" "$MARKER_END"; then
      info "Backed up CLAUDE.md to $CLAUDE_MD_BLOCK_BACKUP before rewriting"
      success "Removed orphaned REPO-SKILLS block from CLAUDE.md"
    else
      warning "Refusing to rewrite $TARGET/CLAUDE.md: $CLAUDE_MD_BLOCK_ERROR"
      warning "The marker layout cannot be resolved unambiguously, and guessing risks"
      warning "deleting content this installer does not own. CLAUDE.md is untouched."
      error "Could not safely remove the orphaned REPO-SKILLS block; fix the markers in $TARGET/CLAUDE.md by hand (skills and commands were installed)."
    fi
  else
    warning "Keeping the stale block. install.sh no longer manages it; update or remove it by hand."
  fi
}

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
SHELL_WRAPPER=false

usage() { sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

list_commands() {
  for f in "$SOURCE_ROOT"/commands/repo/*.md; do
    basename "$f" .md
  done
}

for arg in "$@"; do
  case "$arg" in
    --skills=*)      SKILLS_FILTER="${arg#--skills=}" ;;
    --dev)           DEV=true ;;
    --list)          list_commands; exit 0 ;;
    --dry-run)       DRY_RUN=true ;;
    -y|--yes)        YES=true ;;
    --shell-wrapper) SHELL_WRAPPER=true ;;
    -h|--help)       usage; exit 0 ;;
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
  confirm "Install anyway? [y/N] " N || { info "Installation cancelled"; exit 0; }
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

# Hook install paths and the commands Claude Code resolves them to
# (${CLAUDE_PROJECT_DIR} expands to the consumer repo root at hook time).
# Declared before the --dry-run enumeration below so that listing and doing
# read from the same constants and cannot drift.
HOOK_INSTALL_REL=".claude/skills/repo/hooks/guard-destructive.sh"
HOOK_CMD="\${CLAUDE_PROJECT_DIR}/${HOOK_INSTALL_REL}"

# The SessionStart handoff hook, same resolution. Claude Code's SessionStart
# matchers key on the session SOURCE ("startup" | "resume" | "clear" |
# "compact" | "fork"), not on a tool name. We wire the two literal sources the
# hook acts on rather than an alternation like "startup|resume". Alternation
# would work — SessionStart matchers are split on "|" the same way tool matchers
# are — but two literal entries state the intent without depending on that
# shared behavior, and each entry reads unambiguously in a consumer's
# settings.json. The hook re-checks .source itself, so this is belt-and-braces
# rather than a load-bearing filter.
SESSIONSTART_HOOK_INSTALL_REL=".claude/skills/repo/hooks/session-start-handoff.sh"
SESSIONSTART_HOOK_CMD="\${CLAUDE_PROJECT_DIR}/${SESSIONSTART_HOOK_INSTALL_REL}"
SESSIONSTART_SOURCES=(startup resume)

SETTINGS_JSON="$TARGET/.claude/settings.json"

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
  echo "  $TARGET/.claude/skills/repo/hooks/session-start-handoff.sh"
  echo "  $TARGET/.claude/skills/repo/scripts/repo-remote.sh"
  echo "  $TARGET/.claude/settings.json (merge PreToolUse→Bash guard hook; idempotent, coexistence-aware)"
  echo "  $TARGET/.claude/settings.json (merge SessionStart→${SESSIONSTART_SOURCES[*]} handoff-note hook; idempotent, coexistence-aware)"
  while IFS= read -r cmd; do
    echo "  $TARGET/.claude/commands/repo/$cmd.md"
  done <<<"$COMMANDS"
  if [[ "$DEV" == true ]]; then
    echo "  $TARGET/.gitignore (.claude/ entry; CLAUDE.md skipped in dev mode)"
    if claude_md_has_block; then
      echo "  $TARGET/CLAUDE.md (existing REPO-SKILLS block is orphaned/stale — would offer removal)"
    fi
  elif git -C "$TARGET" check-ignore -q .claude/commands/repo 2>/dev/null \
    || git -C "$TARGET" check-ignore -q .claude/skills/repo 2>/dev/null; then
    if claude_md_has_block; then
      echo "  $TARGET/CLAUDE.md (pointer skipped — destination gitignored; existing REPO-SKILLS block is orphaned/stale — would offer removal)"
    else
      echo "  $TARGET/CLAUDE.md (skipped — install destination is gitignored)"
    fi
  else
    echo "  $TARGET/.gitignore (.claude/skills/repo/.install-local.json entry)"
    echo "  $TARGET/CLAUDE.md (marker-bounded REPO-SKILLS block)"
  fi
  if [[ "$SHELL_WRAPPER" == true ]]; then
    _dry_run_sw_shell="$(shell_wrapper_detect_shell)" || _dry_run_sw_shell="unsupported"
    if [[ "$_dry_run_sw_shell" == zsh || "$_dry_run_sw_shell" == bash ]]; then
      echo "  $(shell_wrapper_rc_path "$_dry_run_sw_shell") (outside $TARGET — marker-bounded claude + codex shell wrappers; --shell-wrapper)"
    else
      echo "  (--shell-wrapper given, but no supported shell detected — would skip: $_dry_run_sw_shell)"
    fi
  else
    echo "  (pass --shell-wrapper to also preview the optional claude + codex shell wrappers, outside $TARGET)"
  fi
  exit 0
fi

confirm "Proceed? [Y/n] " Y || { info "Installation cancelled"; exit 0; }

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

# Idempotently wire session-start-handoff.sh into the target's
# .claude/settings.json under hooks.SessionStart, once per managed source
# matcher. Same discipline as merge_settings_hook above: refuse to touch
# malformed JSON, no-op when already wired, defer to an equivalent hook someone
# else wired, and write via temp-file-and-mv so a mid-read jq failure can never
# truncate the consumer's settings. Existing SessionStart entries — hand-authored
# or another tool's — are appended to, never replaced.
merge_settings_sessionstart_hook() {
  local settings="$SETTINGS_JSON" cmd="$SESSIONSTART_HOOK_CMD" tmp sources_json
  sources_json="$(jq -nc '$ARGS.positional' --args "${SESSIONSTART_SOURCES[@]}")"
  [[ -f "$settings" ]] || echo '{}' >"$settings"

  if ! jq -e . "$settings" >/dev/null 2>&1; then
    warning "Skipping SessionStart hook wiring: $settings is not valid JSON (wire it by hand)"
    return
  fi

  # Idempotent re-install: our exact command is already present under EVERY
  # source matcher we manage (a partial wiring falls through and is completed).
  if jq -e --arg c "$cmd" --argjson sources "$sources_json" '
        (.hooks.SessionStart // []) as $ss |
        ($sources | all(. as $m | $ss | any(.[]?;
          (.matcher == $m) and ((.hooks // []) | any(.[]?; .command == $c)))))
      ' "$settings" >/dev/null 2>&1; then
    info "SessionStart handoff hook already wired in .claude/settings.json (no change)"
    return
  fi

  # Coexistence: a DIFFERENT session-start-handoff.sh is already wired (e.g. a
  # copy living at another path). Defer rather than surfacing the note twice.
  if jq -e --arg c "$cmd" '
        (.hooks.SessionStart // []) | any(.[]?;
          (.hooks // []) | any(.[]?;
            ((.command // "") | test("session-start-handoff\\.sh")) and (.command != $c)))
      ' "$settings" >/dev/null 2>&1; then
    info "A handoff SessionStart hook is already wired in .claude/settings.json — deferring to it (not adding a duplicate)"
    return
  fi

  tmp="$(mktemp)"
  if jq --arg c "$cmd" --argjson sources "$sources_json" '
        .hooks //= {} |
        .hooks.SessionStart //= [] |
        reduce ($sources[]) as $m (.;
          if (.hooks.SessionStart | any(.[]?; .matcher == $m))
          then .hooks.SessionStart |= map(
            if (.matcher == $m) and (((.hooks // []) | any(.[]?; .command == $c)) | not)
            then .hooks = ((.hooks // []) + [{type: "command", command: $c}])
            else . end)
          else .hooks.SessionStart += [{matcher: $m, hooks: [{type: "command", command: $c}]}]
          end)
      ' "$settings" >"$tmp"; then
    mv "$tmp" "$settings"
    success "Wired SessionStart handoff hook into .claude/settings.json"
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

# 3c. SessionStart handoff hook + settings.json wiring. Same colocation and
# chmod rationale as the guard above. Wired unconditionally, like the guard:
# both the script and its settings entry live entirely inside the target repo,
# so there is nothing to gate behind a confirm and behaviour is identical with
# and without --yes.
install_file "$SOURCE_ROOT/hooks/repo/session-start-handoff.sh" \
  "$TARGET/.claude/skills/repo/hooks/session-start-handoff.sh" "hooks/repo/session-start-handoff.sh"
chmod +x "$TARGET/.claude/skills/repo/hooks/session-start-handoff.sh" 2>/dev/null || true
success "Installed .claude/skills/repo/hooks/session-start-handoff.sh"
merge_settings_sessionstart_hook

# 3d. Headless provisioning script for /repo:remote. Same colocation + chmod
# rationale as the hooks above: it lives inside .claude/skills/repo/ so
# uninstall's `rm -rf` removes it for free, and render+copy drops the exec bit
# so we re-set it. This is the non-interactive entry point the interactive
# skill delegates to and that a caller (e.g. loom's `fleet add-worker`) invokes
# directly — without this copy step the script would ship in the source repo
# but never reach a consumer repo (repo#52).
mkdir -p "$TARGET/.claude/skills/repo/scripts"
install_file "$SOURCE_ROOT/scripts/repo/repo-remote.sh" \
  "$TARGET/.claude/skills/repo/scripts/repo-remote.sh" "scripts/repo/repo-remote.sh"
chmod +x "$TARGET/.claude/skills/repo/scripts/repo-remote.sh" 2>/dev/null || true
success "Installed .claude/skills/repo/scripts/repo-remote.sh"

# 3e. Optional shell `claude` wrapper — surfaces a pending /repo:handoff note
# to the HUMAN before Claude starts (the SessionStart hook above is the half
# Claude itself sees). This is the one thing install.sh writes outside the
# target repo, so unlike every step above it is opt-in and defensive: a
# strict no-op under --yes without --shell-wrapper, the pending diff is always
# shown before anything is written, an interactive install without the flag
# still offers it via confirm (default N), and the rc file is backed up before
# every edit. Runs unconditionally (before the dev-mode / gitignored-target
# early exits below) since it is independent of $TARGET entirely.
if [[ "$YES" == true && "$SHELL_WRAPPER" != true ]]; then
  : # strict no-op — the rc file is neither read nor written
else
  SW_SHELL="$(shell_wrapper_detect_shell)" || true
  if [[ -z "$SW_SHELL" || "$SW_SHELL" == "unknown" ]]; then
    warning "claude shell wrapper: could not detect a supported shell (checked \$SHELL, \$ZSH_VERSION, \$BASH_VERSION) — skipping"
  elif [[ "$SW_SHELL" == "fish" ]]; then
    warning "claude shell wrapper: detected fish, which isn't supported yet (zsh/bash only) — skipping rather than half-supporting it"
  else
    SW_RC="$(shell_wrapper_rc_path "$SW_SHELL")"
    if ! shell_wrapper_plan "$SW_RC"; then
      warning "claude shell wrapper: $SHELL_WRAPPER_ERROR"
    else
      SW_PREVIEW_BEFORE="$(mktemp)"
      [[ -f "$SW_RC" ]] && cp "$SW_RC" "$SW_PREVIEW_BEFORE" || : >"$SW_PREVIEW_BEFORE"
      SW_PREVIEW_AFTER="$(mktemp)"
      cp "$SW_PREVIEW_BEFORE" "$SW_PREVIEW_AFTER"
      if ! shell_wrapper_install "$SW_PREVIEW_AFTER" "$SHELL_WRAPPER_FLAGS" \
        || ! shell_wrapper_install_codex "$SW_PREVIEW_AFTER"; then
        warning "shell wrapper: could not prepare a preview: $SHELL_WRAPPER_ERROR"
        rm -f "$SW_PREVIEW_BEFORE" "$SW_PREVIEW_AFTER"
      else
        echo ""
        info "claude + codex shell wrappers ($SW_SHELL) would change $SW_RC:"
        diff -u "$SW_PREVIEW_BEFORE" "$SW_PREVIEW_AFTER" | tail -n +3 || true
        rm -f "$SW_PREVIEW_BEFORE" "$SW_PREVIEW_AFTER" "$SHELL_WRAPPER_BACKUP"

        SW_PROCEED=false
        if [[ "$SHELL_WRAPPER" == true ]]; then
          SW_PROCEED=true
        elif confirm "Install the claude shell wrapper into $SW_RC? [y/N] " N; then
          SW_PROCEED=true
        fi

        if [[ "$SW_PROCEED" == true ]]; then
          if shell_wrapper_install "$SW_RC" "$SHELL_WRAPPER_FLAGS"; then
            success "Installed claude shell wrapper into $SW_RC (backed up to $SHELL_WRAPPER_BACKUP)"
          else
            warning "claude shell wrapper: could not install it: $SHELL_WRAPPER_ERROR"
          fi
          if shell_wrapper_install_codex "$SW_RC"; then
            success "Installed codex shell wrapper into $SW_RC (backed up to $SHELL_WRAPPER_BACKUP)"
          else
            warning "codex shell wrapper: could not install it: $SHELL_WRAPPER_ERROR"
          fi
        else
          info "Skipped the claude + codex shell wrappers"
        fi
      fi
    fi
  fi
fi

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
  reconcile_orphaned_block
  echo ""
  success "Repo Skills v$VERSION dev-installed (symlinked). Edits to source are live. Try /repo:help in Claude Code."
  exit 0
fi

CLAUDE_MD="$TARGET/CLAUDE.md"

# If the commands destination is gitignored in the target, the command files we
# just wrote are effectively machine-local (they won't be committed), so a
# tracked CLAUDE.md pointer would advertise /repo:* commands whose files aren't
# in the repo. Mirror dev mode here: skip the CLAUDE.md block entirely.
#
# Gate the decision on the commands destination *alone*, not commands OR skills.
# The pointer block exists to advertise the /repo:* commands ("The /repo:*
# commands still work in-session"), so what matters is whether those command
# files are committed. A split state where commands/ is tracked (e.g. via a
# `!.claude/commands/` negation) but skills/ is gitignored is legitimate — the
# pointer is still correct because the commands it advertises are committed. An
# earlier version OR'd both probes and wrongly skipped the pointer in that mixed
# state (see issue #51). The `.claude/skills/repo/SKILL.md` reference in the
# block degrades gracefully if skills/ is machine-local: only the link goes
# stale, the commands still work.
#
# Probe a representative *file* path rather than the bare directory so git's
# ignore resolution (including `!` negations and nested .gitignore files) is
# evaluated the same way it would be for a real committed file. check-ignore -q
# exits non-zero outside a git repo or when nothing is ignored, which correctly
# falls through to the write path.
dest_is_gitignored() {
  git -C "$TARGET" check-ignore -q .claude/commands/repo/help.md 2>/dev/null
}
if dest_is_gitignored; then
  warning "Install destination (.claude/commands) is gitignored in $TARGET;"
  warning "skipping the CLAUDE.md pointer block (a committed pointer to uncommitted command"
  warning "files is not what you want). The /repo:* commands still work in-session."
  reconcile_orphaned_block
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
  if claude_md_block_rewrite "$CLAUDE_MD" "$MARKER_BEGIN" "$MARKER_END" "$BLOCK_FILE"; then
    info "Backed up CLAUDE.md to $CLAUDE_MD_BLOCK_BACKUP before rewriting"
    success "Updated REPO-SKILLS block in CLAUDE.md"
  else
    rm -f "$BLOCK_FILE"
    warning "Refusing to update the REPO-SKILLS block in $CLAUDE_MD: $CLAUDE_MD_BLOCK_ERROR"
    warning "The marker layout cannot be resolved unambiguously, and guessing risks"
    warning "deleting content this installer does not own. CLAUDE.md is untouched."
    error "Could not safely update the REPO-SKILLS block; fix the markers in $CLAUDE_MD by hand (skills and commands were installed)."
  fi
else
  { [[ -s "$CLAUDE_MD" ]] && echo ""; cat "$BLOCK_FILE"; } >>"$CLAUDE_MD"
  success "Appended REPO-SKILLS block to CLAUDE.md"
fi
rm -f "$BLOCK_FILE"

echo ""
success "Repo Skills v$VERSION installed. Try /repo:help in Claude Code."

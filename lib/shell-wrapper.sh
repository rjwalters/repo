#!/usr/bin/env bash
# lib/shell-wrapper.sh — the shell `claude` wrapper install.sh can opt into with
# --shell-wrapper. This file is *sourced* (by install.sh and uninstall.sh),
# never executed directly.
#
# WHAT THIS SHIPS: a marker-bounded block appended to the user's shell rc
# (~/.zshrc or ~/.bashrc) that defines a `claude` function. Before a
# session-starting invocation, the function prints a banner if
# `.claude/handoff.md` exists in the current repo — the same note
# hooks/repo/session-start-handoff.sh (repo#34) injects into Claude's own
# context. That hook covers "Claude sees the note"; this wrapper covers "the
# human sees it before launch". See repo#32 (design) and repo#35 (this file).
#
# WHY THIS IS THE ONE RISKY PIECE OF THE INSTALLER: every other file
# install.sh writes lives inside the target repo. A shell rc is global — it
# affects every repo and every shell the user opens. Hard requirements that
# follow from that (see install.sh's --shell-wrapper wiring, not enforced by
# this file alone):
#   - opt-in, default N, diff shown before writing
#   - strict no-op under --yes unless --shell-wrapper is explicit
#   - rc file backed up before every edit
#   - marker-bounded, idempotent (re-running replaces the block in place)
#
# CONTRACT (functions below, all safe to call with `set -euo pipefail` active
# in the caller — none of these ever let an internal "not found" case escape
# as an uncaught non-zero under `set -e`):
#
#   shell_wrapper_detect_shell()
#       Echoes "zsh" | "bash" | "fish" | "unknown". Return status 0 for
#       zsh/bash, 1 for fish/unknown (caller decides how to report each).
#
#   shell_wrapper_rc_path <shell>
#       Echoes the rc file path for "zsh"/"bash". Return 1 (no output) for
#       anything else.
#
#   shell_wrapper_plan <rcfile>
#       Detects a pre-existing single-line `alias claude=...` in <rcfile> (if
#       any) and parses its flags into SHELL_WRAPPER_FLAGS (may be empty).
#       Never touches <rcfile>. Returns 0 (possibly with empty
#       SHELL_WRAPPER_FLAGS) when it is safe to proceed, or 1 with
#       SHELL_WRAPPER_ERROR set when an existing alias could not be parsed
#       (the common single-line `alias claude='[command] claude ...'` form is
#       supported; anything else is a deliberate bail, not a guess — see
#       repo#35's scope guard).
#
#   shell_wrapper_install <rcfile> <flags>
#       Backs up <rcfile> (path left in SHELL_WRAPPER_BACKUP), then writes the
#       marker-bounded wrapper block — replacing an existing block in place,
#       or appending if none exists — folding <flags> into the function's
#       `command claude` invocation. Creates <rcfile> if it does not exist.
#       Returns 1 with SHELL_WRAPPER_ERROR set (rcfile left untouched) if the
#       marker layout in <rcfile> is ambiguous (more than one BEGIN/END).
#
#   shell_wrapper_uninstall <rcfile>
#       Removes the marker-bounded block from <rcfile> if present (backing it
#       up first, path in SHELL_WRAPPER_BACKUP). No-op, return 0, if the block
#       is absent or <rcfile> does not exist. Same ambiguous-layout guard as
#       install.
#
#   shell_wrapper_block_present <rcfile>
#       Return 0 if <rcfile> contains our BEGIN marker, 1 otherwise (or if
#       <rcfile> does not exist).

SHELL_WRAPPER_MARKER_BEGIN='# BEGIN REPO-SKILLS CLAUDE WRAPPER'
SHELL_WRAPPER_MARKER_END='# END REPO-SKILLS CLAUDE WRAPPER'

# Codex wrapper markers (repo#80). Deliberately a SEPARATE, self-contained
# marker pair and function set from the Claude wrapper above — see the "Codex
# wrapper" section near the bottom of this file for why this is implemented in
# parallel rather than by generalizing the already-shipped Claude code path.
SHELL_WRAPPER_CODEX_MARKER_BEGIN='# BEGIN REPO-SKILLS CODEX WRAPPER'
SHELL_WRAPPER_CODEX_MARKER_END='# END REPO-SKILLS CODEX WRAPPER'

# Public output channels — set by the functions above, read by callers after a
# non-zero return (or after a successful install/uninstall, for the backup
# path). shellcheck: this file is only ever sourced, so "unused" is expected.
# shellcheck disable=SC2034
SHELL_WRAPPER_ERROR=""
SHELL_WRAPPER_BACKUP=""
SHELL_WRAPPER_FLAGS=""

shell_wrapper_detect_shell() {
  local sh_name=""
  if [[ -n "${SHELL:-}" ]]; then
    sh_name="$(basename "$SHELL" 2>/dev/null || true)"
  fi
  case "$sh_name" in
    zsh)  echo zsh;  return 0 ;;
    bash) echo bash; return 0 ;;
    fish) echo fish; return 1 ;;
  esac
  # $SHELL absent/unrecognized (e.g. not set, or a non-standard login shell
  # path) — fall back to which interpreter is actually running us.
  if [[ -n "${ZSH_VERSION:-}" ]]; then
    echo zsh; return 0
  fi
  if [[ -n "${BASH_VERSION:-}" ]]; then
    echo bash; return 0
  fi
  echo unknown
  return 1
}

shell_wrapper_rc_path() {  # <shell>
  case "$1" in
    zsh)  echo "${ZDOTDIR:-$HOME}/.zshrc" ;;
    bash) echo "$HOME/.bashrc" ;;
    *)    return 1 ;;
  esac
}

shell_wrapper_block_present() {  # <rcfile>
  [[ -f "$1" ]] && grep -qF "$SHELL_WRAPPER_MARKER_BEGIN" "$1" 2>/dev/null
}

# Last non-comment `alias claude=...` line in <rcfile> (empty if none). "Last"
# because that is what the shell itself would honor if the file were sourced
# top to bottom; "non-comment" so a stale, disabled alias someone left as a
# `# alias claude=...` note is not mistaken for a live one.
_shell_wrapper_find_alias_line() {  # <rcfile>
  local rcfile="$1"
  [[ -f "$rcfile" ]] || return 0
  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*alias[[:space:]]+claude=/ { line = $0 }
    END { if (line != "") print line }
  ' "$rcfile" 2>/dev/null || true
}

# Parse the common single-line form: alias claude='[command] claude <flags>'
# (or double-quoted). Anything else — multi-line, unquoted, aliasing to a
# different binary entirely — is refused rather than guessed (repo#35 scope
# guard: support the common form, bail out clearly otherwise).
shell_wrapper_parse_alias_flags() {  # <alias-line>
  local line="$1" body=""
  SHELL_WRAPPER_FLAGS=""
  if [[ "$line" =~ alias[[:space:]]+claude=\'([^\']*)\'[[:space:]]*$ ]]; then
    body="${BASH_REMATCH[1]}"
  elif [[ "$line" =~ alias[[:space:]]+claude=\"([^\"]*)\"[[:space:]]*$ ]]; then
    body="${BASH_REMATCH[1]}"
  else
    return 1
  fi
  if [[ "$body" =~ ^command[[:space:]]+claude([[:space:]].*)?$ ]]; then
    SHELL_WRAPPER_FLAGS="$(echo "${BASH_REMATCH[1]:-}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  elif [[ "$body" =~ ^claude([[:space:]].*)?$ ]]; then
    SHELL_WRAPPER_FLAGS="$(echo "${BASH_REMATCH[1]:-}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  else
    return 1
  fi
  return 0
}

# Detect + parse an existing alias in <rcfile> (never writes anything).
# Returns 0 with SHELL_WRAPPER_FLAGS set (possibly empty — no alias found is
# not an error) or 1 with SHELL_WRAPPER_ERROR set (an alias exists but could
# not be safely parsed).
shell_wrapper_plan() {  # <rcfile>
  local rcfile="$1" alias_line
  # shellcheck disable=SC2034 # public output var, read by callers after return
  SHELL_WRAPPER_FLAGS=""
  SHELL_WRAPPER_ERROR=""
  alias_line="$(_shell_wrapper_find_alias_line "$rcfile")"
  [[ -n "$alias_line" ]] || return 0
  if shell_wrapper_parse_alias_flags "$alias_line"; then
    return 0
  fi
  SHELL_WRAPPER_ERROR="Found an existing claude alias in $rcfile that isn't in the supported single-line form (alias claude='[command] claude <flags>'): ${alias_line}. Simplify or remove it by hand, then re-run with --shell-wrapper."
  return 1
}

# The wrapper function body, zsh+bash compatible. {{CLAUDE_INVOCATION}} is
# substituted by shell_wrapper_render_block below via literal (non-regex)
# parameter substitution — never via sed, so flags containing sed-special
# characters can't corrupt the template.
#
# Design notes (repo#35 field report on a divergent, non-reference wrapper
# breaking non-interactive `claude mcp list`): every helper this function
# calls is defined in THIS SAME BLOCK, so a shell that sources the rc gets all
# of it or none of it — never a function without its helpers. The `type`
# guard before calling the banner helper means a helper somehow missing (e.g.
# a user's own partial edit inside the markers) skips the banner rather than
# erroring, and `command claude {{CLAUDE_INVOCATION}} "$@"` runs unconditionally
# either way — argv passed to the real `claude` binary is never altered by
# whether the banner fired.
read -r -d '' _SHELL_WRAPPER_BODY_TEMPLATE <<'REPOSKILLSBLOCK' || true
# Installed by Repo Skills (https://github.com/rjwalters/repo) install.sh
# --shell-wrapper. Surfaces a pending /repo:handoff note before Claude starts
# — the human-visible half of the handoff workflow (the SessionStart hook
# covers the half Claude itself sees). Edit outside these markers only;
# re-running install.sh --shell-wrapper replaces this block in place. To
# remove: ./uninstall.sh (from the repo-skills source, or a target repo with
# repo-skills installed) — it detects and removes this block automatically.
unalias claude 2>/dev/null

_repo_claude_is_session() {
  case "$1" in
    update|doctor|mcp|config|install|migrate-installer|setup-token) return 1 ;;
    -v|--version|-h|--help) return 1 ;;
    *) return 0 ;;
  esac
}

_repo_claude_handoff_banner() {
  local root note
  root="$(command git rev-parse --show-toplevel 2>/dev/null)" || root="$PWD"
  note="$root/.claude/handoff.md"
  [ -r "$note" ] || return 0

  local now mtime age_h age_label
  now=$(command date +%s 2>/dev/null) || return 0
  mtime=$(command stat -f %m "$note" 2>/dev/null) || mtime=$(command stat -c %Y "$note" 2>/dev/null) || return 0
  case "$mtime" in
    ''|*[!0-9]*) return 0 ;;
  esac
  age_h=$(( (now - mtime) / 3600 ))
  if   [ "$age_h" -lt 1 ];  then age_label="just now"
  elif [ "$age_h" -lt 48 ]; then age_label="${age_h}h old"
  else                           age_label="$(( age_h / 24 ))d old"
  fi

  local y=$'\033[33m' d=$'\033[2m' r=$'\033[0m' b=$'\033[1m'
  printf '%s┌─ %sHandoff note pending%s%s — %s (%s)%s\n' \
    "$y" "$b" "$r" "$y" "${note/#$HOME/~}" "$age_label" "$r"

  command grep -E '^#{1,2} ' "$note" 2>/dev/null | command head -n 9 | command sed 's/^#* *//' | while IFS= read -r line; do
    printf '%s│%s  %s\n' "$y" "$r" "$line"
  done

  if [ "$age_h" -ge 168 ]; then
    printf '%s└─ %sSTALE (>7d) — a handoff describes one moment; verify before trusting.%s\n' "$y" "$b" "$r"
  else
    printf '%s└─%s %sClaude reads it via MEMORY.md; delete note + pointer once absorbed.%s\n' "$y" "$r" "$d" "$r"
  fi
}

claude() {
  if type _repo_claude_is_session >/dev/null 2>&1 && type _repo_claude_handoff_banner >/dev/null 2>&1; then
    _repo_claude_is_session "${1:-}" && _repo_claude_handoff_banner
  fi
  command claude{{CLAUDE_INVOCATION}} "$@"
}
REPOSKILLSBLOCK

shell_wrapper_render_block() {  # <flags> -> prints the marker-bounded block to stdout
  local flags="$1" invocation="" body="$_SHELL_WRAPPER_BODY_TEMPLATE"
  # Leading space only when there are flags to add, so the no-flags case
  # renders as `command claude "$@"` — never a stray double space.
  [[ -n "$flags" ]] && invocation=" $flags"
  body="${body//\{\{CLAUDE_INVOCATION\}\}/$invocation}"
  printf '%s\n' "$SHELL_WRAPPER_MARKER_BEGIN"
  printf '%s\n' "$body"
  printf '%s\n' "$SHELL_WRAPPER_MARKER_END"
}

# Replace the marker-bounded span in <rcfile> with <blockfile>'s contents,
# writing the result to stdout. Only called once shell_wrapper_install has
# already confirmed exactly one BEGIN and one END line exist.
_shell_wrapper_replace_block() {  # <rcfile> <blockfile>
  awk -v begin="$SHELL_WRAPPER_MARKER_BEGIN" -v end="$SHELL_WRAPPER_MARKER_END" -v blockfile="$2" '
    $0 == begin {
      while ((getline line < blockfile) > 0) print line
      close(blockfile)
      skip = 1
      next
    }
    $0 == end { skip = 0; next }
    !skip { print }
  ' "$1"
}

# Append <blockfile> after <rcfile>'s existing content. Deliberately does NOT
# insert a separating blank line — only the minimum newline needed so our
# BEGIN marker starts its own line (never glued onto the tail of the user's
# last line, the same adjacency hazard lib/claude-md-block.sh guards against).
# That keeps append and _shell_wrapper_replace_block's removal path exactly
# symmetric: uninstalling restores the original content byte-for-byte, with
# no leftover blank line to account for.
_shell_wrapper_append_block() {  # <rcfile> <blockfile>
  cat "$1"
  # `$(tail -c1 f)` is empty both when f is empty and when f already ends in a
  # newline (command substitution strips trailing newlines) — either way,
  # nothing more is needed before the block starts its own line.
  [[ -n "$(tail -c1 "$1" 2>/dev/null)" ]] && echo ""
  cat "$2"
}

# mktemp a backup of <rcfile> under the sentinel-and-count discipline shared
# with lib/claude-md-block.sh: refuse to proceed rather than edit without one.
_shell_wrapper_backup() {  # <rcfile>
  local rcfile="$1" backup
  backup="$(mktemp "${TMPDIR:-/tmp}/$(basename "$rcfile").repo-skills-backup.XXXXXX" 2>/dev/null)" || return 1
  cp "$rcfile" "$backup" 2>/dev/null || { rm -f "$backup"; return 1; }
  printf '%s' "$backup"
}

shell_wrapper_install() {  # <rcfile> <flags>
  local rcfile="$1" flags="$2" n_begin n_end blockfile tmp backup
  SHELL_WRAPPER_ERROR=""
  SHELL_WRAPPER_BACKUP=""

  [[ -f "$rcfile" ]] || : >"$rcfile" 2>/dev/null || {
    SHELL_WRAPPER_ERROR="could not create $rcfile"
    return 1
  }

  # grep -c prints the count even when it exits 1 (no match), so `|| echo 0`
  # here would duplicate the "0" already on stdout; `|| true` just neutralizes
  # the exit status for `set -e` without adding a second line, and the
  # parameter-expansion default covers the (should-never-happen) empty case.
  n_begin=$(grep -cxF "$SHELL_WRAPPER_MARKER_BEGIN" "$rcfile" 2>/dev/null || true); n_begin=${n_begin:-0}
  n_end=$(grep -cxF "$SHELL_WRAPPER_MARKER_END" "$rcfile" 2>/dev/null || true); n_end=${n_end:-0}
  if [[ "$n_begin" -gt 1 || "$n_end" -gt 1 || "$n_begin" -ne "$n_end" ]]; then
    SHELL_WRAPPER_ERROR="ambiguous REPO-SKILLS CLAUDE WRAPPER marker layout in $rcfile ($n_begin begin / $n_end end) — refusing to touch it; remove the stale block by hand, then re-run"
    return 1
  fi

  backup="$(_shell_wrapper_backup "$rcfile")" || {
    SHELL_WRAPPER_ERROR="could not back up $rcfile before editing it"
    return 1
  }
  SHELL_WRAPPER_BACKUP="$backup"

  blockfile="$(mktemp)" || { SHELL_WRAPPER_ERROR="could not create a temp file"; return 1; }
  shell_wrapper_render_block "$flags" >"$blockfile"

  tmp="$(mktemp)" || { rm -f "$blockfile"; SHELL_WRAPPER_ERROR="could not create a temp file"; return 1; }
  if [[ "$n_begin" -eq 1 ]]; then
    _shell_wrapper_replace_block "$rcfile" "$blockfile" >"$tmp"
  else
    _shell_wrapper_append_block "$rcfile" "$blockfile" >"$tmp"
  fi
  rm -f "$blockfile"

  if ! mv "$tmp" "$rcfile"; then
    rm -f "$tmp"
    SHELL_WRAPPER_ERROR="could not move the rewritten file into place (backup: $backup)"
    return 1
  fi
  return 0
}

shell_wrapper_uninstall() {  # <rcfile>
  local rcfile="$1" n_begin n_end backup tmp
  SHELL_WRAPPER_ERROR=""
  SHELL_WRAPPER_BACKUP=""
  [[ -f "$rcfile" ]] || return 0

  n_begin=$(grep -cxF "$SHELL_WRAPPER_MARKER_BEGIN" "$rcfile" 2>/dev/null || true); n_begin=${n_begin:-0}
  n_end=$(grep -cxF "$SHELL_WRAPPER_MARKER_END" "$rcfile" 2>/dev/null || true); n_end=${n_end:-0}
  [[ "$n_begin" -eq 0 && "$n_end" -eq 0 ]] && return 0

  if [[ "$n_begin" -ne 1 || "$n_end" -ne 1 ]]; then
    SHELL_WRAPPER_ERROR="ambiguous REPO-SKILLS CLAUDE WRAPPER marker layout in $rcfile ($n_begin begin / $n_end end) — leaving it untouched; remove the block by hand"
    return 1
  fi

  backup="$(_shell_wrapper_backup "$rcfile")" || {
    SHELL_WRAPPER_ERROR="could not back up $rcfile before editing it"
    return 1
  }
  # shellcheck disable=SC2034 # public output var, read by callers after return
  SHELL_WRAPPER_BACKUP="$backup"

  tmp="$(mktemp)" || { SHELL_WRAPPER_ERROR="could not create a temp file"; return 1; }
  awk -v begin="$SHELL_WRAPPER_MARKER_BEGIN" -v end="$SHELL_WRAPPER_MARKER_END" '
    $0 == begin { skip = 1; next }
    $0 == end   { skip = 0; next }
    !skip { print }
  ' "$rcfile" >"$tmp"

  if ! mv "$tmp" "$rcfile"; then
    rm -f "$tmp"
    # shellcheck disable=SC2034 # public output var, read by callers after return
    SHELL_WRAPPER_ERROR="could not move the rewritten file into place (backup: $backup)"
    return 1
  fi
  return 0
}

# ===========================================================================
# Codex wrapper (repo#80)
# ===========================================================================
#
# WHAT THIS SHIPS: a second, independent marker-bounded block that defines
# `codex` and `codex-safe` shell functions — the operator's approval/sandbox
# posture for interactive Codex sessions, analogous to (but deliberately NOT
# unified with) the Claude wrapper above.
#
#   codex()       — the operator default. Injects
#                   `--dangerously-bypass-approvals-and-sandbox` for a
#                   session-starting invocation UNLESS the caller already
#                   selected an explicit posture (`--sandbox`/`-s`,
#                   `--ask-for-approval`/`-a`, or the bypass flag itself), in
#                   which case the caller's choice is respected untouched.
#   codex-safe()  — passes argv to the real binary byte-for-byte, no injection.
#                   Read-only / review work.
#
# WHY PARALLEL, NOT GENERALIZED (repo#80): the Claude wrapper above is
# load-bearing (it runs in every shell the user opens) and already shipped and
# well-tested. Its purpose (surfacing a handoff banner, folding install-time
# alias flags) has nothing in common with Codex's purpose (a *runtime*
# approval/sandbox posture decision). Forcing both under one generalized engine
# now would risk regressing the released Claude path for no real DRY win, so
# this is implemented as a self-contained parallel set. The only pieces shared
# with the Claude path are the genuinely marker-agnostic `_shell_wrapper_backup`
# and `_shell_wrapper_append_block` helpers; the block surgery itself is a new
# marker-parameterized engine (`_shell_wrapper_install_generic` /
# `_shell_wrapper_uninstall_generic`) that the Claude functions do NOT call, so
# their behavior is provably unchanged by this addition.
#
# THE SECURITY-RELEVANT PART — argv-time posture detection. Unlike Claude's
# alias flags (folded in once at install time), the Codex bypass flag is gated
# at *runtime* on every invocation. If `_repo_codex_has_posture_flag` fails to
# recognize an explicit `--sandbox read-only` a user typed, `codex()` would
# silently append `--dangerously-bypass-approvals-and-sandbox` on top of it —
# quietly downgrading the user's safety posture with no error. The detector is
# therefore intentionally GENEROUS (it errs toward "a posture is present, do
# not inject"): a false positive merely declines to add the dangerous default
# (fail-safe), while a false negative would be the dangerous, hard-to-notice
# failure. See hooks/repo/tests/test-shell-wrapper.sh for the fixture matrix.

# The Codex wrapper body — static (no install-time substitution; the posture
# decision is entirely runtime). zsh+bash compatible. Every helper it calls is
# defined in THIS SAME BLOCK, so a shell that sources the rc gets all of it or
# none of it. If the helpers are somehow missing (a user's partial edit inside
# the markers), `codex()` falls through to a plain `command codex "$@"` — argv
# is never altered and the dangerous flag is never injected on the fail path.
read -r -d '' _SHELL_WRAPPER_CODEX_BODY_TEMPLATE <<'REPOSKILLSCODEXBLOCK' || true
# Installed by Repo Skills (https://github.com/rjwalters/repo) install.sh
# --shell-wrapper. Defines codex() (the interactive-operator default: bypass
# approvals + sandbox) and codex-safe() (the real binary, unchanged, for
# read-only/review work). This is an explicit OPERATOR opt-in for an
# interactive session at a human keyboard — it is NOT, and must not be confused
# with, the unattended daemon-dispatched worker sandbox policy. Edit outside
# these markers only; re-running install.sh --shell-wrapper replaces this block
# in place. To remove: ./uninstall.sh (from the repo-skills source, or a target
# repo with repo-skills installed) — it detects and removes this block
# automatically.
unalias codex 2>/dev/null
unalias codex-safe 2>/dev/null

# Non-session utility subcommands never execute model-generated shell commands,
# so the approval/sandbox posture is irrelevant to them — they must pass
# through untouched (mirrors _repo_claude_is_session next door). Return 1 =
# "not a session start", 0 = "session start".
_repo_codex_is_session() {
  case "$1" in
    doctor|update|mcp|login|logout|completion|help) return 1 ;;
    -v|--version|-h|--help) return 1 ;;
    *) return 0 ;;
  esac
}

# True (0) if argv already carries an explicit approval/sandbox posture, in
# which case codex() must NOT inject its dangerous default. Recognizes, in both
# `--flag value` and `--flag=value` forms: --sandbox/-s, --ask-for-approval/-a,
# and --dangerously-bypass-approvals-and-sandbox. Deliberately generous (a
# false positive only declines the dangerous default — the safe direction).
_repo_codex_has_posture_flag() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      -s|--sandbox|-a|--ask-for-approval|--dangerously-bypass-approvals-and-sandbox) return 0 ;;
      --sandbox=*|--ask-for-approval=*|-s=*|-a=*) return 0 ;;
      -s?*|-a?*) return 0 ;;
    esac
  done
  return 1
}

codex() {
  if type _repo_codex_is_session >/dev/null 2>&1 && type _repo_codex_has_posture_flag >/dev/null 2>&1; then
    if _repo_codex_is_session "${1:-}" && ! _repo_codex_has_posture_flag "$@"; then
      command codex --dangerously-bypass-approvals-and-sandbox "$@"
      return
    fi
  fi
  command codex "$@"
}

codex-safe() {
  command codex "$@"
}
REPOSKILLSCODEXBLOCK

shell_wrapper_render_codex_block() {  # -> prints the marker-bounded block to stdout
  printf '%s\n' "$SHELL_WRAPPER_CODEX_MARKER_BEGIN"
  printf '%s\n' "$_SHELL_WRAPPER_CODEX_BODY_TEMPLATE"
  printf '%s\n' "$SHELL_WRAPPER_CODEX_MARKER_END"
}

shell_wrapper_codex_block_present() {  # <rcfile>
  [[ -f "$1" ]] && grep -qF "$SHELL_WRAPPER_CODEX_MARKER_BEGIN" "$1" 2>/dev/null
}

# Marker-parameterized block surgery — the additive engine the Codex wrapper
# installs/uninstalls through. Structurally identical to shell_wrapper_install's
# inline logic, but takes the marker pair (and a pre-rendered block file) as
# arguments so the Claude path's own copy above is never touched. Same
# ambiguous-layout guard, same mktemp-backup discipline, same append-vs-replace
# behavior.
_shell_wrapper_install_generic() {  # <rcfile> <begin> <end> <blockfile>
  local rcfile="$1" begin="$2" end="$3" blockfile="$4" n_begin n_end tmp backup
  SHELL_WRAPPER_ERROR=""
  SHELL_WRAPPER_BACKUP=""

  [[ -f "$rcfile" ]] || : >"$rcfile" 2>/dev/null || {
    SHELL_WRAPPER_ERROR="could not create $rcfile"
    return 1
  }

  n_begin=$(grep -cxF "$begin" "$rcfile" 2>/dev/null || true); n_begin=${n_begin:-0}
  n_end=$(grep -cxF "$end" "$rcfile" 2>/dev/null || true); n_end=${n_end:-0}
  if [[ "$n_begin" -gt 1 || "$n_end" -gt 1 || "$n_begin" -ne "$n_end" ]]; then
    SHELL_WRAPPER_ERROR="ambiguous ${begin#\# BEGIN } marker layout in $rcfile ($n_begin begin / $n_end end) — refusing to touch it; remove the stale block by hand, then re-run"
    return 1
  fi

  backup="$(_shell_wrapper_backup "$rcfile")" || {
    SHELL_WRAPPER_ERROR="could not back up $rcfile before editing it"
    return 1
  }
  # shellcheck disable=SC2034 # public output var, read by callers after return
  SHELL_WRAPPER_BACKUP="$backup"

  tmp="$(mktemp)" || { SHELL_WRAPPER_ERROR="could not create a temp file"; return 1; }
  if [[ "$n_begin" -eq 1 ]]; then
    awk -v begin="$begin" -v end="$end" -v blockfile="$blockfile" '
      $0 == begin {
        while ((getline line < blockfile) > 0) print line
        close(blockfile)
        skip = 1
        next
      }
      $0 == end { skip = 0; next }
      !skip { print }
    ' "$rcfile" >"$tmp"
  else
    _shell_wrapper_append_block "$rcfile" "$blockfile" >"$tmp"
  fi

  if ! mv "$tmp" "$rcfile"; then
    rm -f "$tmp"
    SHELL_WRAPPER_ERROR="could not move the rewritten file into place (backup: $backup)"
    return 1
  fi
  return 0
}

_shell_wrapper_uninstall_generic() {  # <rcfile> <begin> <end>
  local rcfile="$1" begin="$2" end="$3" n_begin n_end backup tmp
  SHELL_WRAPPER_ERROR=""
  SHELL_WRAPPER_BACKUP=""
  [[ -f "$rcfile" ]] || return 0

  n_begin=$(grep -cxF "$begin" "$rcfile" 2>/dev/null || true); n_begin=${n_begin:-0}
  n_end=$(grep -cxF "$end" "$rcfile" 2>/dev/null || true); n_end=${n_end:-0}
  [[ "$n_begin" -eq 0 && "$n_end" -eq 0 ]] && return 0

  if [[ "$n_begin" -ne 1 || "$n_end" -ne 1 ]]; then
    SHELL_WRAPPER_ERROR="ambiguous ${begin#\# BEGIN } marker layout in $rcfile ($n_begin begin / $n_end end) — leaving it untouched; remove the block by hand"
    return 1
  fi

  backup="$(_shell_wrapper_backup "$rcfile")" || {
    SHELL_WRAPPER_ERROR="could not back up $rcfile before editing it"
    return 1
  }
  # shellcheck disable=SC2034 # public output var, read by callers after return
  SHELL_WRAPPER_BACKUP="$backup"

  tmp="$(mktemp)" || { SHELL_WRAPPER_ERROR="could not create a temp file"; return 1; }
  awk -v begin="$begin" -v end="$end" '
    $0 == begin { skip = 1; next }
    $0 == end   { skip = 0; next }
    !skip { print }
  ' "$rcfile" >"$tmp"

  if ! mv "$tmp" "$rcfile"; then
    rm -f "$tmp"
    SHELL_WRAPPER_ERROR="could not move the rewritten file into place (backup: $backup)"
    return 1
  fi
  return 0
}

# Install the Codex wrapper block into <rcfile> (create it if absent). No
# alias-flag folding — the Codex wrapper takes no install-time flags. Returns 1
# with SHELL_WRAPPER_ERROR set on ambiguous layout / backup failure, same
# contract as shell_wrapper_install.
shell_wrapper_install_codex() {  # <rcfile>
  local rcfile="$1" blockfile rc
  # shellcheck disable=SC2034 # public output var, read by callers after return
  blockfile="$(mktemp)" || { SHELL_WRAPPER_ERROR="could not create a temp file"; return 1; }
  shell_wrapper_render_codex_block >"$blockfile"
  _shell_wrapper_install_generic "$rcfile" \
    "$SHELL_WRAPPER_CODEX_MARKER_BEGIN" "$SHELL_WRAPPER_CODEX_MARKER_END" "$blockfile"
  rc=$?
  rm -f "$blockfile"
  return $rc
}

shell_wrapper_uninstall_codex() {  # <rcfile>
  _shell_wrapper_uninstall_generic "$1" \
    "$SHELL_WRAPPER_CODEX_MARKER_BEGIN" "$SHELL_WRAPPER_CODEX_MARKER_END"
}

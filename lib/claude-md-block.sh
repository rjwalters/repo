#!/usr/bin/env bash
# Marker-bounded CLAUDE.md surgery, shared by install.sh and uninstall.sh.
#
# This file is *sourced*, never executed. Every rewrite of the REPO-SKILLS block
# in a consumer repo's CLAUDE.md must go through claude_md_block_rewrite() here.
#
# Why this exists (repo#38): both installers used to bound the block with awk
# whole-line equality —
#
#     $0 == begin { skip = 1; ... }
#     $0 == end   { skip = 0; next }
#     !skip       { print }
#
# — which silently destroys data when another tool's block is appended with no
# intervening newline. The physical line
#
#     <!-- END REPO-SKILLS --><!-- BEGIN LOOM ORCHESTRATION -->
#
# never compares equal to the end marker, so `skip` never clears and every byte
# from there to EOF is dropped. That deleted Loom's entire orchestration block
# in a consumer repo during a routine upgrade, printed "✓ Updated", and exited 0.
#
# The replacement below is anchored to the marker *strings*, so text sharing a
# physical line with a marker is preserved byte-for-byte, and it refuses to
# touch the file at all when the marker layout cannot be resolved unambiguously
# (rather than guessing — consuming another tool's content is destructive and
# must never happen silently).
#
# Contract:
#   claude_md_block_validate <file> <begin> <end>
#       0 -> the marker boundaries resolve unambiguously
#       1 -> CLAUDE_MD_BLOCK_ERROR holds a human-readable reason; do not rewrite
#
#   claude_md_block_rewrite <file> <begin> <end> [block-file]
#       Validates, snapshots <file> (path left in CLAUDE_MD_BLOCK_BACKUP), then
#       replaces the marker span (markers inclusive) with <block-file>'s
#       contents — or removes the span entirely when <block-file> is omitted.
#       On failure returns 1 with CLAUDE_MD_BLOCK_ERROR set, having left <file>
#       byte-for-byte untouched. Callers decide how to report and whether to
#       abort (install.sh errors out; uninstall.sh warns and skips).

# Set by the functions below; read by callers after a non-zero return. (These
# are the file's public output channel, so shellcheck's unused-variable warning
# does not apply — this file is only ever sourced.)
# shellcheck disable=SC2034
CLAUDE_MD_BLOCK_ERROR=""
CLAUDE_MD_BLOCK_BACKUP=""

# Count non-overlapping occurrences of a fixed substring in a file. Markers
# cannot span lines, so counting per line is exact — and unlike `grep -c` this
# counts occurrences rather than matching lines, which matters precisely in the
# adjacency case where two markers share one line.
_claude_md_count() {  # <file> <needle> -> count on stdout
  awk -v needle="$2" '
    {
      s = $0
      while ((i = index(s, needle)) > 0) {
        n++
        s = substr(s, i + length(needle))
      }
    }
    END { print n + 0 }
  ' "$1"
}

# Read a whole file into the global _CLAUDE_MD_SLURPED, preserving trailing
# newlines exactly. The sentinel byte defeats command substitution's
# trailing-newline stripping; the result is returned via a variable rather than
# stdout so a caller's own `$(...)` cannot strip it right back off.
_CLAUDE_MD_SLURPED=""
_claude_md_slurp() {  # <file> -> sets _CLAUDE_MD_SLURPED
  local content
  content="$(cat "$1"; printf 'X')"
  _CLAUDE_MD_SLURPED="${content%X}"
}

claude_md_block_validate() {  # <file> <begin> <end>
  local file="$1" begin="$2" end="$3" n_begin n_end content prefix
  CLAUDE_MD_BLOCK_ERROR=""

  if [[ ! -f "$file" ]]; then
    CLAUDE_MD_BLOCK_ERROR="$file does not exist"
    return 1
  fi

  n_begin="$(_claude_md_count "$file" "$begin")"
  n_end="$(_claude_md_count "$file" "$end")"

  if [[ "$n_begin" -ne 1 ]]; then
    CLAUDE_MD_BLOCK_ERROR="found $n_begin occurrences of '$begin' (expected exactly 1)"
    return 1
  fi
  if [[ "$n_end" -ne 1 ]]; then
    CLAUDE_MD_BLOCK_ERROR="found $n_end occurrences of '$end' (expected exactly 1)"
    return 1
  fi

  _claude_md_slurp "$file"
  content="$_CLAUDE_MD_SLURPED"
  prefix="${content%%"$begin"*}"
  if [[ "$prefix" == *"$end"* ]]; then
    CLAUDE_MD_BLOCK_ERROR="'$end' appears before '$begin' (markers are out of order)"
    return 1
  fi

  return 0
}

claude_md_block_rewrite() {  # <file> <begin> <end> [block-file]
  local file="$1" begin="$2" end="$3" block="${4:-}"
  local content prefix suffix rest_of_line body backup tmp

  CLAUDE_MD_BLOCK_BACKUP=""
  claude_md_block_validate "$file" "$begin" "$end" || return 1

  _claude_md_slurp "$file"
  content="$_CLAUDE_MD_SLURPED"
  # Everything before the begin marker, and everything after the end marker.
  # Anything sharing those physical lines with a marker lands in one of these
  # two halves and survives verbatim — that is the whole point of the fix.
  prefix="${content%%"$begin"*}"
  suffix="${content#*"$end"}"

  if [[ -n "$block" ]]; then
    if [[ ! -f "$block" ]]; then
      CLAUDE_MD_BLOCK_ERROR="replacement block file $block does not exist"
      return 1
    fi
    # The block file is newline-terminated; the span it replaces ends at the end
    # marker itself, so drop that one trailing newline to avoid inserting a line
    # break the original layout did not have.
    _claude_md_slurp "$block"
    body="${_CLAUDE_MD_SLURPED%$'\n'}"
    content="$prefix$body$suffix"
  else
    # Removal. When the begin marker started its own line, the newline that
    # terminated the end marker's line is also part of the block's footprint —
    # consuming it removes whole lines (the historical behavior) instead of
    # leaving a blank one behind. When the begin marker shares a line with
    # earlier text, that same newline is what terminates the surviving line, so
    # it must stay.
    if [[ -z "$prefix" || "$prefix" == *$'\n' ]]; then
      rest_of_line="${suffix%%$'\n'*}"
      if [[ -z "${rest_of_line//[[:space:]]/}" ]]; then
        if [[ "$suffix" == *$'\n'* ]]; then
          suffix="${suffix#*$'\n'}"
        else
          suffix=""
        fi
      fi
    fi
    content="$prefix$suffix"
  fi

  # Defense in depth: snapshot before touching the file, so even a botched
  # rewrite is recoverable without git (CLAUDE.md may be gitignored, or the
  # repo may have no commit yet).
  if ! backup="$(mktemp "${TMPDIR:-/tmp}/CLAUDE.md.backup.XXXXXX")"; then
    CLAUDE_MD_BLOCK_ERROR="could not create a backup snapshot"
    return 1
  fi
  if ! cp "$file" "$backup"; then
    CLAUDE_MD_BLOCK_ERROR="could not write the backup snapshot to $backup"
    return 1
  fi
  CLAUDE_MD_BLOCK_BACKUP="$backup"

  if ! tmp="$(mktemp)"; then
    CLAUDE_MD_BLOCK_ERROR="could not create a temporary file"
    return 1
  fi
  if ! printf '%s' "$content" >"$tmp"; then
    rm -f "$tmp"
    CLAUDE_MD_BLOCK_ERROR="could not write the rewritten CLAUDE.md"
    return 1
  fi
  if ! mv "$tmp" "$file"; then
    rm -f "$tmp"
    CLAUDE_MD_BLOCK_ERROR="could not move the rewritten file into place (backup: $backup)"
    return 1
  fi

  return 0
}

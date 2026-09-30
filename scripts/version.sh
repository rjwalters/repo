#!/usr/bin/env bash
# Single source of truth for this repo's version: the root VERSION file.
#
# Why this exists: /repo:release auto-detects a version tool and honors an
# executable scripts/version.sh FIRST, ahead of npm. Without it, the mere
# presence of package.json makes release detect "npm" and run `npm version`,
# which bumps package.json (and, on a version-less package, starts from 0.0.1)
# while leaving VERSION — the file the tag history actually tracks — stale.
# This script makes VERSION authoritative and keeps package.json's version
# field mirrored to it so the two can never drift.
#
# Usage:
#   scripts/version.sh                 # print current version
#   scripts/version.sh check           # verify VERSION and package.json agree (exit 1 if not)
#   scripts/version.sh bump <level> [--tag] [--no-commit]  # level = major|minor|patch
#   scripts/version.sh set <version> [--tag] [--no-commit] # set VERSION (and package.json) to an exact value
#
# Committing: `bump` and `set` write VERSION (plus package.json), `git add` them
# — along with CHANGELOG.md when present — and then commit them. They STAGE the
# files WITHOUT committing, leaving them for the caller to fold into a commit of
# their own, in either of these two cases (#536):
#
#   * `--no-commit` was passed — for a caller assembling one commit out of
#     several steps (a release script, a scripted edit sequence).
#   * A merge, rebase or cherry-pick is in progress. Committing there turns the
#     caller's own pending commit into a "chore: bump/set version to X" commit
#     carrying none of the caller's message or trailers — the incident this
#     detection exists to prevent: someone resolving a VERSION conflict mid-merge
#     runs `set`, and the merge commit they were about to write is gone.
#
# Whenever the commit is skipped a one-line notice goes to stderr, so the
# difference is visible rather than silent.
#
# `--tag` is REJECTED (exit 2) whenever the commit is skipped: the annotated tag
# would land on the *previous* commit, naming a version that commit does not
# contain. Re-run without `--tag` and tag your own commit once you have made it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_FILE="$ROOT/VERSION"
PKG_FILE="$ROOT/package.json"

read_version() { tr -d '[:space:]' < "$VERSION_FILE"; printf '\n'; }

pkg_version() {
  [ -f "$PKG_FILE" ] || { echo ""; return; }
  node -p "require('$PKG_FILE').version || ''" 2>/dev/null \
    || grep -m1 '"version"' "$PKG_FILE" | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/'
}

# Mirror package.json's version field to $1 (only if the file has one to set).
sync_pkg() {
  [ -f "$PKG_FILE" ] || return 0
  if node -e '' 2>/dev/null; then
    node -e '
      const fs = require("fs"), f = process.argv[1], v = process.argv[2];
      const j = JSON.parse(fs.readFileSync(f, "utf8"));
      j.version = v;
      fs.writeFileSync(f, JSON.stringify(j, null, 2) + "\n");
    ' "$PKG_FILE" "$1"
  else
    # Fallback: in-place edit of an existing version line.
    sed -i.bak -E 's/("version"[[:space:]]*:[[:space:]]*")[^"]+(")/\1'"$1"'\2/' "$PKG_FILE"
    rm -f "$PKG_FILE.bak"
  fi
}

# _git_state_blocks_commit: print a short reason when an in-progress merge,
# rebase or cherry-pick means this invocation must NOT create its own commit;
# print nothing (and return 1) otherwise.
#
# The three states mirror what `git status` itself reports ("You have unmerged
# paths" / "interactive rebase in progress" / "You are currently cherry-picking"):
#   * MERGE_HEAD          — `git merge` stopped, conflicted or --no-commit
#   * rebase-merge/apply  — `git rebase` (interactive/merge backend, or am backend)
#   * CHERRY_PICK_HEAD    — `git cherry-pick` stopped or --no-commit
#
# The rebase directories are resolved through `rev-parse --absolute-git-dir`
# rather than hardcoding "$ROOT/.git/…", because in a linked worktree `.git` is a
# file and that state lives under `<common-dir>/worktrees/<name>/`.
_git_state_blocks_commit() {
  local gitdir
  if git -C "$ROOT" rev-parse --quiet --verify MERGE_HEAD >/dev/null 2>&1; then
    echo "merge in progress"
    return 0
  fi
  gitdir="$(git -C "$ROOT" rev-parse --absolute-git-dir 2>/dev/null || true)"
  if [ -n "$gitdir" ] && { [ -d "$gitdir/rebase-merge" ] || [ -d "$gitdir/rebase-apply" ]; }; then
    echo "rebase in progress"
    return 0
  fi
  if git -C "$ROOT" rev-parse --quiet --verify CHERRY_PICK_HEAD >/dev/null 2>&1; then
    echo "cherry-pick in progress"
    return 0
  fi
  return 1
}

# resolve_commit_mode <no_commit> <want_tag>: decide whether this invocation may
# commit, publishing the answer in COMMIT_SKIP_REASON ("" = commit normally),
# and reject a --tag that would point at the wrong commit.
#
# Called BEFORE anything is written, so a rejected --tag leaves VERSION and
# package.json untouched — same contract as a malformed `set <version>`.
COMMIT_SKIP_REASON=""
resolve_commit_mode() {
  local no_commit="$1" want_tag="$2"
  if [ "$no_commit" = true ]; then
    COMMIT_SKIP_REASON="--no-commit requested"
  else
    # `|| true` because the helper returns 1 for the ordinary "nothing blocks a
    # commit" case, which `set -e` would otherwise treat as fatal.
    COMMIT_SKIP_REASON="$(_git_state_blocks_commit || true)"
  fi
  if [ -n "$COMMIT_SKIP_REASON" ] && [ "$want_tag" = true ]; then
    echo "version.sh: refusing --tag ($COMMIT_SKIP_REASON) — there is no new commit to tag, so the tag would land on the previous commit and name a version that commit does not contain. Re-run without --tag and tag your own commit once you have made it." >&2
    exit 2
  fi
}

# apply_version <new> <commit-message>: write + stage the version files, then
# commit them unless resolve_commit_mode said not to. Shared by bump and set,
# whose commit plumbing was otherwise identical.
apply_version() {
  local new="$1" msg="$2"
  printf '%s\n' "$new" > "$VERSION_FILE"
  sync_pkg "$new"
  git -C "$ROOT" add VERSION package.json
  [ -f "$ROOT/CHANGELOG.md" ] && git -C "$ROOT" add CHANGELOG.md || true
  if [ -n "$COMMIT_SKIP_REASON" ]; then
    echo "version.sh: $COMMIT_SKIP_REASON — version files staged, not committed (fold them into your own commit)" >&2
    return 0
  fi
  git -C "$ROOT" commit -q -m "$msg"
}

cmd="${1:-print}"
case "$cmd" in
  print|"")
    read_version
    ;;

  check)
    v="$(read_version)"
    p="$(pkg_version)"
    # An ABSENT version field is drift, not agreement. Guarding the comparison
    # with `[ -n "$p" ]` alone made the mirror unenforceable: a tool that strips
    # the field (Loom's resync did exactly this while package.json still carried
    # the installer stub's name — see #138) left `check` reporting ok, so the
    # invariant this script exists to hold would lapse unnoticed until the next
    # bump silently restored it. Report the state actually found.
    if [ -f "$PKG_FILE" ]; then
      if [ -z "$p" ]; then
        echo "version drift: VERSION=$v but package.json has no version field (run: scripts/version.sh bump ... to restore the mirror)" >&2
        exit 1
      fi
      if [ "$p" != "$v" ]; then
        echo "version drift: VERSION=$v package.json=$p (run: scripts/version.sh bump ... or align package.json)" >&2
        exit 1
      fi
    fi
    echo "ok: $v"
    ;;

  bump)
    level="${2:-}"
    tag=false
    no_commit=false
    # Flags follow the level and may appear in any order. Shift past the
    # subcommand and level (however few of them were actually supplied) so the
    # loop below sees only flags.
    if [ "$#" -gt 2 ]; then shift 2; else shift "$#"; fi
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --tag) tag=true ;;
        --no-commit) no_commit=true ;;
        *) echo "usage: version.sh bump <major|minor|patch> [--tag] [--no-commit]" >&2; exit 2 ;;
      esac
      shift
    done
    case "$level" in major|minor|patch) ;; *)
      echo "usage: version.sh bump <major|minor|patch> [--tag] [--no-commit]" >&2; exit 2 ;;
    esac
    resolve_commit_mode "$no_commit" "$tag"
    cur="$(read_version)"
    IFS=. read -r MA MI PA <<EOF
$cur
EOF
    case "$level" in
      major) MA=$((MA+1)); MI=0; PA=0 ;;
      minor) MI=$((MI+1)); PA=0 ;;
      patch) PA=$((PA+1)) ;;
    esac
    new="$MA.$MI.$PA"
    apply_version "$new" "chore: bump version to $new"
    if [ "$tag" = true ]; then
      git -C "$ROOT" tag -a "v$new" -m "v$new"
    fi
    echo "$new"
    ;;

  set)
    new="${2:-}"
    tag=false
    no_commit=false
    # Same any-order flag parsing as bump above.
    if [ "$#" -gt 2 ]; then shift 2; else shift "$#"; fi
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --tag) tag=true ;;
        --no-commit) no_commit=true ;;
        *) echo "usage: version.sh set <major.minor.patch> [--tag] [--no-commit]" >&2; exit 2 ;;
      esac
      shift
    done
    if ! printf '%s' "$new" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
      echo "usage: version.sh set <major.minor.patch> [--tag] [--no-commit]" >&2
      exit 2
    fi
    resolve_commit_mode "$no_commit" "$tag"
    apply_version "$new" "chore: set version to $new"
    if [ "$tag" = true ]; then
      git -C "$ROOT" tag -a "v$new" -m "v$new"
    fi
    echo "$new"
    ;;

  *)
    echo "usage: version.sh [print|check|bump <level> [--tag] [--no-commit]|set <version> [--tag] [--no-commit]]" >&2
    exit 2
    ;;
esac

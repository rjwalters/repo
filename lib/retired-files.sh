#!/usr/bin/env bash
# retired-files.sh — installed paths this tool once shipped under fixed names and
# no longer does. Shared by install.sh and scripts/repo/resync-installed.sh so a
# reinstall and a resync retire exactly the same set (repo#765).
#
# WHY A LIST. resync-installed.sh "never uninstalls": an installed file with no
# source counterpart is only reported as left alone. That is right for a
# consumer-local file, but wrong for a file THIS tool installed under a fixed
# name — leaving it would keep a dead command on every consumer forever. These
# are names we own, so removing them by name is safe.
#
# Entries are target-relative. A path pinned in the consumer's resync-ignore
# (C10) is theirs and is never removed.

# /repo:remote was removed in repo#765.
RETIRED_INSTALLED_FILES=(
  ".claude/commands/repo/remote.md"
  ".claude/skills/repo/scripts/repo-remote.sh"
  ".agents/skills/repo/references/remote.md"
)

# Per-command Codex skill directories. Removed only when marker-managed
# (codex_skill_is_managed); an unmarked directory is someone else's.
RETIRED_CODEX_SKILL_DIRS=(
  ".agents/skills/repo-remote"
)

# retire_installed_files <target> <dry-run:true|false>
# Prints one "<verb>\t<target-relative-path>" line per entry acted on, where verb
# is "would drop" (dry run) or "removed". Silent when nothing is present. `rm -f`
# on a symlink (--dev install) removes the link, never its target.
retire_installed_files() {
  local target="$1" dry="$2" rel
  for rel in "${RETIRED_INSTALLED_FILES[@]}"; do
    [[ -e "$target/$rel" || -L "$target/$rel" ]] || continue
    resync_ignore_is_pinned "$rel" && continue
    if [[ "$dry" == true ]]; then
      printf 'would drop\t%s\n' "$rel"
    else
      rm -f -- "$target/$rel"
      printf 'removed\t%s\n' "$rel"
    fi
  done
  for rel in "${RETIRED_CODEX_SKILL_DIRS[@]}"; do
    [[ -d "$target/$rel" ]] || continue
    codex_skill_is_managed "$target/$rel/SKILL.md" || continue
    resync_ignore_is_pinned "$rel/SKILL.md" && continue
    if [[ "$dry" == true ]]; then
      printf 'would drop\t%s/\n' "$rel"
    else
      rm -rf -- "$target/$rel"
      printf 'removed\t%s/\n' "$rel"
    fi
  done
}

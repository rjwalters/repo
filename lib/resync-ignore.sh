#!/usr/bin/env bash
# resync-ignore.sh — the repo-owned pin list: requirement C10 of
# INSTALLER-CONTRACT.md.
#
# A consumer repo declares "this installed path is MINE, not the tool's" by
# listing it in `.claude/skills/repo/resync-ignore`. Both writers of the
# installed surface — install.sh and scripts/repo/resync-installed.sh — consult
# this one implementation before overwriting a payload file, so a pin taken at
# install time can never be silently undone by the next resync (and vice
# versa).
#
# WHY THIS FILE EXISTS (repo#511). Every `.claude/commands/repo/*.md`,
# `.claude/skills/repo/**` and `.agents/skills/repo/**` file is a rendered copy
# of a source file in this repo. Before this list existed, the only edit to one
# of those files that survived a reinstall was no edit at all: install.sh
# rendered over the destination unconditionally and resync-installed.sh did the
# same on every refresh, with no ignore list and no local-divergence gate.
#
# One consumer (2AMLogic/2am, private) lost the same customization FOUR times
# across a few months — a subsection of `.claude/commands/repo/scrub.md` wiring
# in a repo-local allowlist-drift check. Re-added in 2am#463, found gone in
# 2am#593, re-added in 2am#594, gone again across the v0.10.0 -> v0.11.12
# upgrade, re-added with a regression test in 2am#775/#776, gone again across
# v0.12.2 / v0.14.0, and finally (2am#1596) moved out of the vendored file
# entirely because the vendored file could not hold it. The tell is a fix being
# re-applied because a reinstall reverted it; the fix is a pin, and there was
# none to reach for.
#
# This mirrors rjwalters/loom's `.loom/resync-ignore` (loom#5971) deliberately:
# one list, one meaning — "this path is the repo's, not the tool's" — so an
# operator who already knows Loom's convention knows this one.
#
# FORMAT. One target-relative path per line. Blank lines and `#` comments are
# ignored; a trailing `#` comment on a path line is stripped; leading/trailing
# whitespace is trimmed. A leading `./` is tolerated. An entry ending in `/`
# pins that whole subtree.
#
#   # keep our allowlist-drift wiring in /repo:scrub
#   .claude/commands/repo/scrub.md
#   # our own fork of the fork sweeper, whole directory of local helpers
#   .claude/skills/repo/scripts/repo-scrub-forks.sh
#   .agents/skills/repo/references/scrub.md
#
# WHAT IT COVERS: the rendered payload copies, i.e. every destination
# install.sh writes through install_file() and every destination
# resync-installed.sh writes through sync_one(). That is the complete set of
# files whose content comes from this repo and would otherwise be clobbered.
#
# WHAT IT DELIBERATELY DOES NOT COVER, and why each would be a worse idea than
# it sounds:
#   - `install-metadata.json` / `.install-local.json` / `config.json` — install
#     bookkeeping, not payload. Pinning the metadata would freeze the version
#     stamp every "am I current?" check reads, which is the opposite of
#     ownership: it makes the repo lie about what it has installed.
#   - `.claude/settings.json`, `.gitignore` — already consumer-owned files the
#     installer only ever merges INTO, never overwrites. There is nothing here
#     to protect.
#   - `CLAUDE.md`'s REPO-SKILLS block — marker-bounded by construction, and the
#     block itself says "edit outside the markers only". Everything outside the
#     markers is already the consumer's.
#
# A pin is a fork, and a fork carries a maintenance cost: pinned files stop
# receiving upstream fixes. Prefer the extension points a command offers (e.g.
# `/repo:scrub` reads `.repo/scrub-local-checks.md`) and reach for a pin only
# when there is no hook to use. Both writers report every pin they honor, and
# both warn about a pin that matched nothing this run, so a dead pin (a typo, or
# a path upstream has since retired) cannot sit there looking installed while
# doing nothing.

# The pin list's location inside the installed tree, target-relative. Kept here
# so neither writer spells it out for itself.
RESYNC_IGNORE_REL=".claude/skills/repo/resync-ignore"

# Loaded state. Indexed arrays, NOT `declare -A`: bash 3.2 (the stock macOS
# /bin/bash that `#!/usr/bin/env bash` resolves to) has no associative arrays,
# and both callers must run there. These are pure sets, so a linear membership
# scan over the handful of lines in a pin list is exactly equivalent.
RESYNC_IGNORE_FILE=""
RESYNC_IGNORE_ENTRIES=()
RESYNC_IGNORE_HIT=()

# `${arr[@]+"${arr[@]}"}` rather than a bare `"${arr[@]}"`: under `set -u`,
# bash 3.2 treats an EMPTY indexed array's `"${arr[@]}"` as an unbound variable
# and aborts — and install.sh runs `set -euo pipefail`, so that abort would kill
# an install outright on the overwhelmingly common no-pin-list path.
_resync_ignore_expand() { printf '%s\n' ${RESYNC_IGNORE_ENTRIES[@]+"${RESYNC_IGNORE_ENTRIES[@]}"}; }

# resync_ignore_load <target-abs>
# Read the pin list, if any. Always returns 0 — an absent list is the normal
# case, not an error.
resync_ignore_load() {
  RESYNC_IGNORE_FILE="$1/$RESYNC_IGNORE_REL"
  RESYNC_IGNORE_ENTRIES=()
  RESYNC_IGNORE_HIT=()
  [[ -f "$RESYNC_IGNORE_FILE" ]] || return 0
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"                       # strip trailing comment
    line="${line#"${line%%[![:space:]]*}"}"  # ltrim
    line="${line%"${line##*[![:space:]]}"}"  # rtrim
    [[ -z "$line" ]] && continue
    RESYNC_IGNORE_ENTRIES+=("$line")
  done <"$RESYNC_IGNORE_FILE"
  return 0
}

# resync_ignore_active — true when at least one pin was loaded. Lets a caller
# say something different when the list exists but this source clone is too old
# to honor it.
resync_ignore_active() { [[ "${#RESYNC_IGNORE_ENTRIES[@]}" -gt 0 ]]; }

# resync_ignore_is_pinned <target-relative-path>
# True (0) when the given payload destination is declared repo-owned. Records
# the matching entry so resync_ignore_dead_pins() can tell a live pin from a
# dead one afterwards.
resync_ignore_is_pinned() {
  local rel="$1" entry norm
  [[ "${#RESYNC_IGNORE_ENTRIES[@]}" -gt 0 ]] || return 1
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    norm="${entry#./}"
    if [[ "$norm" == "$rel" ]]; then
      RESYNC_IGNORE_HIT+=("$entry"); return 0
    fi
    # Directory form: a trailing slash pins the whole subtree beneath it. The
    # `*/` guard keeps a bare `foo` from ever being read as a prefix — a pin
    # must be an exact path or an explicit directory, never an accidental
    # substring.
    if [[ "$norm" == */ && "$rel" == "$norm"* ]]; then
      RESYNC_IGNORE_HIT+=("$entry"); return 0
    fi
  done < <(_resync_ignore_expand)
  return 1
}

# resync_ignore_dead_pins — print every loaded entry that matched nothing since
# the last load, one per line. MUST be called after the full write pass, when
# every payload destination has been offered to resync_ignore_is_pinned().
#
# A dead pin was previously the silent failure mode of Loom's own list
# (loom#6515): the pin LOOKS installed and does nothing, so the customization
# it was supposed to protect gets clobbered anyway and nobody learns why until
# the next time someone re-applies the same lost edit.
resync_ignore_dead_pins() {
  local entry hit found
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    found=false
    for hit in ${RESYNC_IGNORE_HIT[@]+"${RESYNC_IGNORE_HIT[@]}"}; do
      [[ "$hit" == "$entry" ]] && { found=true; break; }
    done
    [[ "$found" == true ]] || printf '%s\n' "$entry"
  done < <(_resync_ignore_expand)
  return 0
}

# resync_ignore_warn_dead_pins — emit resync_ignore_dead_pins() through
# whichever warning function the caller defines (`warning` in install.sh, `warn`
# in resync-installed.sh), same detection lib/gitignore-check.sh uses. Always
# returns 0: a dead pin is a loud warning, never a failure — refusing to install
# over a typo in a pin list would be a far worse outcome than naming it.
resync_ignore_warn_dead_pins() {
  local emit entry
  if declare -f warning >/dev/null 2>&1; then
    emit="warning"
  elif declare -f warn >/dev/null 2>&1; then
    emit="warn"
  else
    emit="echo"
  fi
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    "$emit" "resync-ignore pin had no effect: '$entry' (no installed payload path matches it — a typo, or a file this tool no longer ships)"
  done < <(resync_ignore_dead_pins)
  return 0
}

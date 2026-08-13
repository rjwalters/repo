#!/usr/bin/env bash
# The on-disk shape of the two install-metadata files, shared by install.sh and
# scripts/repo/resync-installed.sh.
#
# WHY THIS FILE EXISTS: requirements C5 and C6 of INSTALLER-CONTRACT.md are a
# SPLIT — the tracked `install-metadata.json` must contain only fields that are
# identical on every machine at a given version, and everything machine-local
# (absolute source path, timestamps) must live in the gitignored
# `.install-local.json` sidecar. Two writers of that split (the installer and the
# resync) would eventually disagree about which field goes where, and the
# resulting bug is the one repo#96 already cost this project once: a
# machine-local value in a tracked file, wrong on every machine but one. One
# emitter, two callers.
#
# Both functions write JSON to stdout; the caller decides where it lands (and
# resync stages + renames rather than writing in place).

# Bumped when the on-disk layout of an install changes in a way a consumer must
# notice — a moved destination, a renamed/removed metadata field, a changed
# meaning. Additive fields do NOT bump it. Consumers compare the installed
# `layout_version` against the source's to decide whether a plain resync is
# enough or the installer has to be re-run.
#
# 1 -> 2 (repo#285): the install gained a second destination root, the Codex
# skill surface at `.agents/skills/repo/`. A resync deliberately will not create
# it (it refreshes what is installed; it does not adopt new surfaces), so an
# install still at layout 1 needs the installer re-run to pick it up — which is
# exactly what the mismatch warning tells the operator.
REPO_SKILLS_LAYOUT_VERSION=2

# metadata_tracked_json <version> <commit> <dev> <filtered> <commands-newline-list>
#
# The TRACKED file. Every field here is a property of the release + the selected
# command set, so two machines installing the same version with the same
# --skills= filter produce byte-identical output and consumer history stays
# clean. Never add a path, hostname, or timestamp to this function.
metadata_tracked_json() {
  local version="$1" commit="$2" dev="$3" filtered="$4" commands="$5" commands_json
  commands_json="$(printf '%s\n' "$commands" | sed '/^$/d; s/.*/"&"/' | paste -sd, -)"
  echo "{"
  echo "  \"version\": \"$version\","
  echo "  \"commit\": \"$commit\","
  echo "  \"layout_version\": $REPO_SKILLS_LAYOUT_VERSION,"
  echo "  \"dev\": $dev,"
  echo "  \"filtered\": $filtered,"
  echo "  \"commands\": [$commands_json]"
  echo "}"
}

# metadata_sidecar_json <source-root> <installed_at> [last_resync]
#
# The MACHINE-LOCAL sidecar (gitignored). The absolute path of the source clone
# and the timestamps mean nothing in any other checkout. `last_resync` is
# emitted only when a resync produced it.
metadata_sidecar_json() {
  local source_root="$1" installed_at="$2" last_resync="${3:-}"
  echo "{"
  echo "  \"source\": \"$source_root\","
  if [[ -n "$last_resync" ]]; then
    echo "  \"installed_at\": \"$installed_at\","
    echo "  \"last_resync\": \"$last_resync\""
  else
    echo "  \"installed_at\": \"$installed_at\""
  fi
  echo "}"
}

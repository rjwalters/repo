#!/usr/bin/env bash
# check-changelog-version.sh - Fail when VERSION has no matching CHANGELOG.md
# heading (#769).
#
# Why: tag-version.yml tags every VERSION bump automatically but never touches
# CHANGELOG.md, so entries piled up under `## Unreleased` for ~25 releases and
# /repo:release Phase 1.5 reported MISSING for every recent tag. scripts/version.sh
# now cuts the heading on bump; this gate catches a hand-edited VERSION or a
# bump that skipped the script.
#
# The heading regex is the one /repo:release Phase 1.5 uses, so the two agree:
# optional leading 'v', optional brackets, literal dots.
#
# Usage: check-changelog-version.sh [--root <dir>]   (default: repo root)
# Exit: 0 ok / no CHANGELOG.md / no VERSION; 1 missing heading; 2 usage.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) ROOT="${2:?--root needs a directory}"; shift 2 ;;
    *) echo "usage: check-changelog-version.sh [--root <dir>]" >&2; exit 2 ;;
  esac
done

[ -f "$ROOT/CHANGELOG.md" ] || { echo "(no CHANGELOG.md - skipping)"; exit 0; }
[ -f "$ROOT/VERSION" ] || { echo "(no VERSION - skipping)"; exit 0; }

ver="$(tr -d '[:space:]' < "$ROOT/VERSION")"
ver_re="$(printf '%s' "$ver" | sed 's/\./\\./g')"
if grep -Eq "^##[[:space:]]+v?\[?${ver_re}\]?([[:space:]]|\$)" "$ROOT/CHANGELOG.md"; then
  echo "ok: CHANGELOG.md has a heading for $ver"
else
  echo "MISSING: CHANGELOG.md has no '## $ver (YYYY-MM-DD)' heading for VERSION $ver." >&2
  echo "Run scripts/version.sh bump (it renames '## Unreleased'), or add the heading by hand." >&2
  exit 1
fi

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
#   scripts/version.sh bump <level> [--tag]   # level = major|minor|patch
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

cmd="${1:-print}"
case "$cmd" in
  print|"")
    read_version
    ;;

  check)
    v="$(read_version)"
    p="$(pkg_version)"
    if [ -n "$p" ] && [ "$p" != "$v" ]; then
      echo "version drift: VERSION=$v package.json=$p (run: scripts/version.sh bump ... or align package.json)" >&2
      exit 1
    fi
    echo "ok: $v"
    ;;

  bump)
    level="${2:-}"
    tag=false
    [ "${3:-}" = "--tag" ] && tag=true
    case "$level" in major|minor|patch) ;; *)
      echo "usage: version.sh bump <major|minor|patch> [--tag]" >&2; exit 2 ;;
    esac
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
    printf '%s\n' "$new" > "$VERSION_FILE"
    sync_pkg "$new"
    git -C "$ROOT" add VERSION package.json
    [ -f "$ROOT/CHANGELOG.md" ] && git -C "$ROOT" add CHANGELOG.md || true
    git -C "$ROOT" commit -q -m "chore: bump version to $new"
    if [ "$tag" = true ]; then
      git -C "$ROOT" tag -a "v$new" -m "v$new"
    fi
    echo "$new"
    ;;

  *)
    echo "usage: version.sh [print|check|bump <level> [--tag]]" >&2
    exit 2
    ;;
esac

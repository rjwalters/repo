#!/usr/bin/env bash
# check-installed-surface-version-bump.sh - Fail a PR that changes this repo's
# consumer-visible installed surface without either bumping VERSION or
# declaring an explicit no-surface-change marker (#387).
#
# Why this exists: install.sh copies commands/, skills/, hooks/, lib/,
# install.sh, and uninstall.sh into every consumer repo, and every "am I
# current?" check downstream (install-metadata.json, /repo:update-tools,
# 2AMLogic/2am's compute-drift tool-version axis) compares against VERSION.
# If a PR changes the installed surface without bumping VERSION, that signal
# silently lies — every consumer reports "current" for changes it does not
# have. This mirrors loom's own already-proven `defaults/` VERSION-bump CI
# gate (loom#5874, vendored here as
# .loom/scripts/check-defaults-version-bump.sh) but scoped to the surface
# THIS repo actually ships: this repo has no defaults/ tree, so that script's
# hardcoded `defaults/` watch path never fires here.
#
# This is a thin wrapper, not a fork of the logic: once
# .loom/scripts/check-defaults-version-bump.sh accepts configurable watched
# paths (rjwalters/loom#6480), retire this file and call that script directly
# with `--watch commands/ --watch skills/ ...` (or equivalent).
#
# This is deliberately NOT trying to force semantic-version inflation on
# every doc typo or test-only edit under the watched paths -- an explicit
# marker lets an author declare "this change does not alter installed
# behavior" without a version bump.
#
# Usage:
#   check-installed-surface-version-bump.sh --base <ref> [--head <ref>]
#     --base <ref>   Git ref/sha to diff FROM (the PR's base commit, e.g. a
#                     fetched base sha, or origin/main for a local check).
#                     Required.
#     --head <ref>   Git ref/sha to diff TO. Defaults to HEAD.
#   check-installed-surface-version-bump.sh --help
#
# No-surface-change marker: a PR whose body OR whose HEAD-reachable commit
# messages (between --base and --head) contain the literal string
#     <!-- loom:no-surface-change -->
# is exempt even when the watched surface changed and VERSION did not. Pass
# the PR body via the PR_BODY environment variable (GitHub Actions:
# `env: PR_BODY: ${{ github.event.pull_request.body }}`); the commit-message
# path needs no extra plumbing beyond --base/--head.
#
# Exit codes:
#   0 - nothing under the watched surface changed in the diff, OR VERSION was
#       also changed, OR the no-surface-change marker is present.
#   1 - the watched surface changed, VERSION was not, and no marker is
#       present.
#   2 - bad usage (missing/invalid --base or --head).

set -euo pipefail

MARKER='<!-- loom:no-surface-change -->'

# Consumer-visible surface this repo installs into other repos (see README.md
# "Write footprint" / INSTALLER-CONTRACT.md). Keep in sync with what
# install.sh actually copies.
WATCHED_PATHS=(commands/ skills/ hooks/ lib/ install.sh uninstall.sh)

BASE=""
HEAD="HEAD"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)
      BASE="${2:-}"
      shift 2
      ;;
    --head)
      HEAD="${2:-}"
      shift 2
      ;;
    --help|-h)
      sed -n '2,44p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "check-installed-surface-version-bump: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$BASE" ]]; then
  echo "check-installed-surface-version-bump: --base <ref> is required." >&2
  exit 2
fi

if ! git rev-parse --verify --quiet "${BASE}^{commit}" >/dev/null; then
  echo "check-installed-surface-version-bump: base ref '$BASE' not found (not fetched?)." >&2
  exit 2
fi

if ! git rev-parse --verify --quiet "${HEAD}^{commit}" >/dev/null; then
  echo "check-installed-surface-version-bump: head ref '$HEAD' not found." >&2
  exit 2
fi

# Deliberately a direct two-ref diff, not a merge-base-narrowed one -- this
# script may be invoked from a shallow CI checkout where the base and head
# shallow histories may not share enough depth to resolve a merge-base. A
# direct diff answers the question this check actually cares about ("does
# applying head's changes touch the installed surface without touching
# VERSION") without requiring ancestry.
CHANGED_FILES="$(git diff --name-only "$BASE" "$HEAD" -- "${WATCHED_PATHS[@]}" 2>/dev/null || true)"

if [[ -z "$CHANGED_FILES" ]]; then
  echo "check-installed-surface-version-bump: OK — no installed-surface changes in this diff."
  exit 0
fi

VERSION_CHANGED="$(git diff --name-only "$BASE" "$HEAD" -- VERSION 2>/dev/null || true)"

if [[ -n "$VERSION_CHANGED" ]]; then
  echo "check-installed-surface-version-bump: OK — installed surface changed and VERSION was bumped."
  exit 0
fi

# --- no-surface-change marker check -----------------------------------------

if [[ -n "${PR_BODY:-}" ]] && grep -qF "$MARKER" <<<"$PR_BODY"; then
  echo "check-installed-surface-version-bump: OK — no-surface-change marker found in the PR body."
  exit 0
fi

if git log --format=%B "${BASE}..${HEAD}" 2>/dev/null | grep -qF "$MARKER"; then
  echo "check-installed-surface-version-bump: OK — no-surface-change marker found in a commit message."
  exit 0
fi

echo "check-installed-surface-version-bump: FAIL — installed surface changed without a VERSION bump:" >&2
echo "" >&2
echo "$CHANGED_FILES" | sed 's/^/  /' >&2
echo "" >&2
echo "commands/, skills/, hooks/, lib/, install.sh, and uninstall.sh are copied" >&2
echo "into every consumer repo at install time -- NOT refreshed by a git pull." >&2
echo "VERSION is the only mechanical signal consumers have that those copies" >&2
echo "are stale (install-metadata.json, /repo:update-tools, and downstream" >&2
echo "compute-drift checks all key off it), so a change to this surface must" >&2
echo "bump it (at minimum the patch component):" >&2
echo "    ./scripts/version.sh bump patch" >&2
echo "" >&2
echo "If this change genuinely does not alter installed behavior (e.g. a" >&2
echo "comment, a test-only edit, a typo fix), declare that explicitly instead" >&2
echo "of bumping VERSION -- add this exact marker to the PR body or to a commit" >&2
echo "message in this PR:" >&2
echo "    $MARKER" >&2
exit 1

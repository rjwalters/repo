#!/usr/bin/env bash
# warn_gitignored_payload — requirement C9 of INSTALLER-CONTRACT.md: after an
# installer (or resync) writes its payload, sweep every file it wrote through
# `git check-ignore` in the consumer repo and WARN (never fail) about any hit,
# naming both the path and the matching .gitignore rule.
#
# WHY THIS FILE EXISTS: repo#385 — six Anvil-installed CSS assets sat silently
# untracked for months in a consumer repo because an unrelated legacy `*.css`
# .gitignore rule happened to also match paths inside the installed surface.
# The installer succeeded, the files existed on disk, and nothing ever
# reported the gap. `dest_is_gitignored()` in install.sh already checked
# whether the whole tool root was hidden using ONE representative path; this
# generalizes that idea to every path the installer/resync actually wrote,
# which also catches the "otherwise-tracked tree, one file hidden by an
# unrelated rule" case that a single-file probe cannot see.
#
# Shared by install.sh and scripts/repo/resync-installed.sh (C7 SHOULD run the
# same sweep after a refresh) so the check has exactly one implementation.

# warn_gitignored_payload <target-abs> <dir>...
#
# Every regular file under the given (absolute) directories is checked in ONE
# `git check-ignore --stdin -v` invocation (not one call per file). A match is
# reported via whichever of `warning` (install.sh) or `warn`
# (resync-installed.sh) the caller has defined — never via a hard failure, and
# this function always returns 0 regardless of what it finds.
#
# Files the installer itself deliberately gitignores (the C6 machine-local
# sidecar, `.install-local.json`) are excluded from the sweep: warning about a
# file we intentionally hid is noise, not a bug report.
#
# Runtime output written by the *installed hooks themselves* after install —
# any file under a top-level `logs/` directory beneath one of the swept
# roots (e.g. `.claude/skills/repo/logs/guard-decisions.log`,
# `.claude/skills/repo/logs/hook-errors.log`) — is excluded the same way.
# These paths did not exist when the installer ran; they are hook execution
# artifacts that routinely carry the operator's absolute filesystem paths, so
# "ignored" is the correct, intended state for them, not a defect to repair
# (repo#425). `logs/` is never a source path this installer ships from, so the
# exclusion cannot shadow real payload.
warn_gitignored_payload() {
  local target="$1"
  shift
  local -a dirs=("$@")

  local emit
  if declare -f warning >/dev/null 2>&1; then
    emit="warning"
  elif declare -f warn >/dev/null 2>&1; then
    emit="warn"
  else
    emit="echo"
  fi

  # Nothing to check against outside a git repo — and check-ignore would just
  # error, so skip rather than print a confusing warning about git internals.
  git -C "$target" rev-parse --git-dir >/dev/null 2>&1 || return 0

  local -a files=()
  local d f rel
  for d in "${dirs[@]}"; do
    [[ -d "$d" ]] || continue
    while IFS= read -r f; do
      rel="${f#"$target"/}"
      case "$rel" in
        */.install-local.json | .install-local.json) continue ;;
        */logs/* | logs/*) continue ;;
      esac
      files+=("$rel")
    done < <(find "$d" -type f 2>/dev/null)
  done
  [[ ${#files[@]} -gt 0 ]] || return 0

  # git check-ignore exits 1 when nothing is ignored (not an error condition
  # here) and 0 when at least one path matched; `|| true` inside the
  # substitution keeps that from tripping `set -e` in either caller.
  local hits
  hits="$(printf '%s\n' "${files[@]}" | git -C "$target" check-ignore --stdin -v 2>/dev/null || true)"
  [[ -n "$hits" ]] || return 0

  "$emit" "Installed file(s) are hidden by this repo's .gitignore (INSTALLER-CONTRACT.md C9)"
  "$emit" "— they exist on disk but git will never track them:"
  local line rule path
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    rule="${line%%$'\t'*}"
    path="${line#*$'\t'}"
    "$emit" "  $path  <- $rule"
  done <<<"$hits"
  "$emit" "If the path(s) above are meant to be tracked, fix the matching .gitignore rule"
  "$emit" "(or relocate the file) so they get tracked. Everything under this sweep is"
  "$emit" "installed payload, not runtime output — but double-check before un-ignoring:"
  "$emit" "un-ignoring a path that legitimately belongs machine-local (e.g. one carrying"
  "$emit" "absolute filesystem paths) would commit it instead of fixing anything."
  return 0
}

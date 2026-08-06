#!/usr/bin/env bash
# Template-variable rendering, shared by install.sh and
# scripts/repo/resync-installed.sh.
#
# WHY THIS FILE EXISTS: install.sh substitutes a fixed set of `{{PLACEHOLDER}}`
# tokens into every file it copies into a consumer repo. resync-installed.sh
# (requirement C7 of INSTALLER-CONTRACT.md) copies the SAME files into the SAME
# destinations, so it must render them identically — a second, hand-copied
# implementation would drift, and the failure mode is silent: an installed file
# shipping a literal `{{REPO_OWNER}}` to a consumer. Both callers source this
# file so there is exactly one substitution table and one leak check.
#
# Sourcing contract: define nothing, assume nothing about the caller's shell
# options, and touch no global except the RENDER_* names below.
#
# Usage:
#   source "$SOURCE_ROOT/lib/render.sh"
#   render_repo_identity "$TARGET"          # sets REPO_OWNER / REPO_NAME
#   VERSION=... COMMIT=... INSTALL_DATE=...  # caller-owned, read by render()
#   render <template-file >rendered-file
#   render_assert_no_placeholders <file> || echo "leaked: ${RENDER_LEAKED[*]}"

# The tokens install.sh and resync-installed.sh substitute. Adding one here is
# the ONLY place it needs to be declared: render() below and the leak check both
# read from this list, and both callers inherit the change.
RENDER_TEMPLATE_PLACEHOLDERS=(
  '{{REPO_OWNER}}'
  '{{REPO_NAME}}'
  '{{REPO_SKILLS_VERSION}}'
  '{{REPO_SKILLS_COMMIT}}'
  '{{INSTALL_DATE}}'
)

# render_repo_identity <target-dir>
# Derive the consumer repo's identity for `{{REPO_OWNER}}` / `{{REPO_NAME}}`
# (best-effort: parse owner/name from the origin remote, else fall back to the
# directory name). Sets the REPO_OWNER and REPO_NAME globals read by render().
render_repo_identity() {
  local target="$1" remote rest
  REPO_OWNER="OWNER"
  REPO_NAME="$(basename "$target")"
  remote="$(git -C "$target" config --get remote.origin.url 2>/dev/null || true)"
  if [[ -n "$remote" ]]; then
    remote="${remote%.git}"
    REPO_NAME="${remote##*/}"
    rest="${remote%/*}"
    REPO_OWNER="${rest##*[:/]}"
  fi
}

# render  (stdin -> stdout with template variables substituted)
# Reads REPO_OWNER / REPO_NAME / VERSION / COMMIT / INSTALL_DATE from the
# caller's environment; each is expanded with `:-` so an unset one renders empty
# rather than aborting a caller running under `set -u`.
render() {
  sed \
    -e "s|{{REPO_OWNER}}|${REPO_OWNER:-}|g" \
    -e "s|{{REPO_NAME}}|${REPO_NAME:-}|g" \
    -e "s|{{REPO_SKILLS_VERSION}}|${VERSION:-}|g" \
    -e "s|{{REPO_SKILLS_COMMIT}}|${COMMIT:-}|g" \
    -e "s|{{INSTALL_DATE}}|${INSTALL_DATE:-}|g"
}

# render_assert_no_placeholders <file>
# Returns 0 when no known placeholder survived into <file>; otherwise returns 1
# and leaves the offending tokens in the RENDER_LEAKED array. Deliberately does
# NOT exit or print: install.sh treats a leak as fatal, resync-installed.sh
# treats it as a per-file failure that must not abort the remaining files.
render_assert_no_placeholders() {
  local file="$1" ph
  RENDER_LEAKED=()
  for ph in "${RENDER_TEMPLATE_PLACEHOLDERS[@]}"; do
    grep -qF "$ph" "$file" && RENDER_LEAKED+=("$ph")
  done
  [[ ${#RENDER_LEAKED[@]} -eq 0 ]]
}

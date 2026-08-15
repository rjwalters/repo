#!/usr/bin/env bash
# Test suite for the version-citation check documented in
# commands/repo/release.md Phase 3.5 — the advisory gate that flags tracked
# markdown prose citing a version that has neither shipped (no `## <version>`
# section in CHANGELOG.md) nor is the one this run is cutting ($NEW).
#
# Usage: ./commands/repo/tests/test-release-version-citation-check.sh
# Exit code 0 = all tests pass, 1 = failures detected.
#
# Structured like commands/repo/tests/test-branches-loss-check.sh: pure bash,
# no test framework, PASS/FAIL/TOTAL counters, a scratch-git fixture harness,
# and a doc-drift block pinning this file's prose against what this suite
# implements. `pnpm test` delegates to this file via hooks/repo/tests/run.sh.
#
# WHY THIS FILE EXISTS (repo#228): release.md is prose an agent reads, not
# code any harness executes, so nothing in this repo could catch a regression
# in the check. But the check is a small set of self-contained shell/grep
# invocations, independent of the surrounding prose — so they can be run
# directly against scratch-repo fixtures. check_version_citations() below is a
# faithful transcription of release.md Phase 3.5.
#
# The false-positive risk the check exists to avoid (repo#228's Design notes):
# a bare `\d+\.\d+\.\d+` scan over all markdown would flag dependency pins
# ("loom 0.18.0"), image tags ("ubuntu:24.04"), and lockfile fields
# ("lockfileVersion: '9.0'") — none of which cite THIS repo's own release
# state. Phase 3.5 avoids that by anchoring to version-boundary phrasing
# ("before"/"since"/"as of"/…) AND deriving this repo's own header-citation
# style (leading-'v' or bare) from CHANGELOG.md itself, so a document that
# extensively discusses a DIFFERENT tool's version history in the same
# phrasing (e.g. "removed in v0.10.0" naming an embedded orchestrator) is not
# mistaken for a citation of this repo's own version.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
RELEASE_MD="$REPO_ROOT/commands/repo/release.md"

# Assertion helpers (ok/no/skip/assert_eq/assert_contains/assert_not_contains/
# assert_matches) plus the PASS/FAIL/SKIP/TOTAL counters and color vars are
# shared across the repo test suites — see lib/assert.sh (repo#307).
source "$(dirname "${BASH_SOURCE[0]}")/lib/assert.sh"

if [[ ! -f "$RELEASE_MD" ]]; then
    echo "FATAL: release.md not found at $RELEASE_MD" >&2
    exit 1
fi

SCRATCH="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$SCRATCH"' EXIT

# ---------------------------------------------------------------------------
# The check under test — a direct transcription of release.md Phase 3.5.
# ---------------------------------------------------------------------------

# check_version_citations <repo-dir> <new-version> -> "CITED-UNSHIPPED: file:line: match"
# lines, one per finding, on stdout. Silent (no findings, no "ok:" line) when
# clean — callers that want the "ok:" line can special-case an empty result.
check_version_citations() {
    local repo="$1" new="$2"
    ( cd "$repo" || exit 1
      if [[ ! -f CHANGELOG.md ]]; then
          exit 0   # no-op, matching Phase 1.5's existing behavior
      fi
      V_PREFIX=""
      grep -Eq '^##[[:space:]]+v[0-9]' CHANGELOG.md && V_PREFIX='v?'
      LEADIN='(before|since|after|until|prior to|as of|as early as|starting (in|with)|introduced in|added in|removed in|deprecated (in|since)|available (since|as of)|released in|shipped in|requires( at least)?)'
      for f in $(git ls-files '*.md' | grep -v -x 'CHANGELOG.md'); do
          while IFS=: read -r lineno match; do
              ver="$(printf '%s' "$match" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+')"
              [[ "$ver" == "$new" ]] && continue
              ver_re="$(printf '%s' "$ver" | sed 's/\./\\./g')"
              if grep -Eq "^##[[:space:]]+v?\[?${ver_re}\]?([[:space:]]|\$)" CHANGELOG.md; then
                  continue
              fi
              echo "CITED-UNSHIPPED: $f:$lineno: \"$match\""
          done < <(grep -inoE "${LEADIN}[[:space:]]+${V_PREFIX}[0-9]+\.[0-9]+\.[0-9]+" "$f")
      done
    )
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

REPO=""

build_repo() {   # <name>
    local root="$SCRATCH/$1"
    git init -q -b main "$root"
    REPO="$root"
    git -C "$REPO" config user.email "test@example.invalid"
    git -C "$REPO" config user.name "Version Citation Test"
}

commit_all() {   # <message>
    git -C "$REPO" add -A && git -C "$REPO" commit -qm "$1"
}

echo "release.md version-citation check test suite"
echo "============================================="
echo ""

# ---------------------------------------------------------------------------
echo "-- case 1: unshipped, non-target version is flagged --"
# ---------------------------------------------------------------------------
build_repo "case1"
cat > "$REPO/CHANGELOG.md" <<'EOF'
# Changelog

## 0.8.1 (2026-08-01)

Initial cut.
EOF
mkdir -p "$REPO/docs"
cat > "$REPO/README.md" <<'EOF'
# Project

That was not true before 0.9.0, when the flag flipped.
EOF
commit_all "M0: base"

OUT="$(check_version_citations "$REPO" "1.0.0")"
assert_contains "flags a citation with no CHANGELOG section and not \$NEW" \
    "$OUT" "CITED-UNSHIPPED: README.md:3:"
assert_contains "the finding names the cited version" "$OUT" "before 0.9.0"

# ---------------------------------------------------------------------------
echo ""
echo "-- case 2: the version being cut is never flagged --"
# ---------------------------------------------------------------------------
# Same fixture, but this run IS cutting 0.9.0 — by definition it has no
# CHANGELOG section yet, and must still not be flagged.
OUT="$(check_version_citations "$REPO" "0.9.0")"
assert_not_contains "citing the version being cut is not flagged" "$OUT" "CITED-UNSHIPPED"

# ---------------------------------------------------------------------------
echo ""
echo "-- case 3: version-shaped strings that are not this repo's own version --"
# ---------------------------------------------------------------------------
build_repo "case3"
cat > "$REPO/CHANGELOG.md" <<'EOF'
# Changelog

## 0.8.1 (2026-08-01)

Initial cut.
EOF
cat > "$REPO/README.md" <<'EOF'
# Project

## Tool versions

| Tool | Version |
|------|---------|
| loom | 0.18.0  |

Base image: `ubuntu:24.04`.

```yaml
lockfileVersion: '9.0'
```
EOF
commit_all "M0: base"

OUT="$(check_version_citations "$REPO" "1.0.0")"
assert_eq "dependency pin / image tag / lockfile field -> no findings" "" "$OUT"

# Same shapes, but ALSO no boundary phrasing near them even when a phrase
# word appears elsewhere on the line — the LEADIN must be adjacent, not just
# present anywhere in the file.
build_repo "case3b"
cat > "$REPO/CHANGELOG.md" <<'EOF'
# Changelog

## 0.8.1 (2026-08-01)

Initial cut.
EOF
cat > "$REPO/README.md" <<'EOF'
# Project

Since installing, pin `loom 0.18.0` as the tool version.
EOF
commit_all "M0: base"
OUT="$(check_version_citations "$REPO" "1.0.0")"
assert_eq "boundary word not adjacent to the pin -> no finding" "" "$OUT"

# ---------------------------------------------------------------------------
echo ""
echo "-- case 3c: a foreign tool's version history in this repo's own phrasing --"
# ---------------------------------------------------------------------------
# repo#228's real false-positive: a workspace whose docs discuss a DIFFERENT
# embedded tool's release history using the exact same boundary phrasing this
# check looks for. This repo's own CHANGELOG headers are bare (no leading
# 'v'), so a 'v'-prefixed citation is presumed to name something else's
# version, not this repo's own — and must not be flagged.
build_repo "case3c"
cat > "$REPO/CHANGELOG.md" <<'EOF'
# Changelog

## 0.8.1 (2026-08-01)

Initial cut.
EOF
cat > "$REPO/docs.md" <<'EOF'
# Notes

The old state file was removed in v0.10.0 upstream.
EOF
commit_all "M0: base"
OUT="$(check_version_citations "$REPO" "1.0.0")"
assert_eq "v-prefixed citation, bare-only CHANGELOG style -> no finding" "" "$OUT"

# ...but if this repo's OWN CHANGELOG headers DO sometimes carry a leading
# 'v', a 'v'-prefixed prose citation counts as this repo's own vocabulary and
# is flagged like any other unshipped citation.
build_repo "case3d"
cat > "$REPO/CHANGELOG.md" <<'EOF'
# Changelog

## v0.8.1 (2026-08-01)

Initial cut.
EOF
cat > "$REPO/docs.md" <<'EOF'
# Notes

This behavior was removed in v0.10.0.
EOF
commit_all "M0: base"
OUT="$(check_version_citations "$REPO" "1.0.0")"
assert_contains "v-prefixed citation IS flagged when this repo's own headers use 'v'" \
    "$OUT" "CITED-UNSHIPPED: docs.md:3:"

# ---------------------------------------------------------------------------
echo ""
echo "-- case 4: CHANGELOG.md itself is excluded from the scan --"
# ---------------------------------------------------------------------------
build_repo "case4"
cat > "$REPO/CHANGELOG.md" <<'EOF'
# Changelog

## 0.8.1 (2026-08-01)

Forward-looking note: as of 0.9.5 this will change (self-reference, not a
target of the scan since CHANGELOG.md is excluded).
EOF
commit_all "M0: base"
OUT="$(check_version_citations "$REPO" "1.0.0")"
assert_eq "CHANGELOG.md is never scanned, even though it cites 0.9.5" "" "$OUT"

# ---------------------------------------------------------------------------
echo ""
echo "-- case 5: no CHANGELOG.md yet -> the check no-ops (matches Phase 1.5) --"
# ---------------------------------------------------------------------------
build_repo "case5"
cat > "$REPO/README.md" <<'EOF'
# Project

That was not true before 0.9.0.
EOF
commit_all "M0: base"
OUT="$(check_version_citations "$REPO" "1.0.0")"
assert_eq "absent CHANGELOG.md -> no findings (no-op)" "" "$OUT"

# ---------------------------------------------------------------------------
echo ""
echo "-- case 6: a shipped version is not flagged --"
# ---------------------------------------------------------------------------
build_repo "case6"
cat > "$REPO/CHANGELOG.md" <<'EOF'
# Changelog

## 0.9.0 (2026-08-05)

Shipped.

## 0.8.1 (2026-08-01)

Initial cut.
EOF
cat > "$REPO/README.md" <<'EOF'
# Project

That was not true before 0.9.0, and it is fixed as of 0.9.0.
EOF
commit_all "M0: base"
OUT="$(check_version_citations "$REPO" "1.0.0")"
assert_eq "citations of an already-shipped version are not flagged" "" "$OUT"

# Also cover the Keep-a-Changelog bracketed / leading-'v' header shapes that
# Phase 1.5's reused regex already tolerates.
build_repo "case6b"
cat > "$REPO/CHANGELOG.md" <<'EOF'
# Changelog

## [0.9.0] - 2026-08-05

Shipped, Keep-a-Changelog header style.
EOF
cat > "$REPO/README.md" <<'EOF'
# Project

Fixed as of 0.9.0.
EOF
commit_all "M0: base"
OUT="$(check_version_citations "$REPO" "1.0.0")"
assert_eq "bracketed Keep-a-Changelog header also clears the citation" "" "$OUT"

# ---------------------------------------------------------------------------
echo ""
echo "-- doc drift: release.md still specifies what this suite implements --"
# ---------------------------------------------------------------------------
MD="$(cat "$RELEASE_MD")"

assert_contains "release.md has a Phase 3.5 version-citation check" \
    "$MD" "## Phase 3.5 — Version-citation check (advisory)"
assert_contains "release.md places Phase 3.5 after Phase 3" \
    "$MD" "## Phase 3 — Gather changes & decide the bump"
assert_contains "release.md states the check is advisory-only" \
    "$MD" "Advisory only — report and continue, never block the release."
assert_contains "release.md no-ops when CHANGELOG.md is absent" \
    "$MD" '(no CHANGELOG.md — skipping version-citation check)'
assert_contains "release.md excludes CHANGELOG.md from the scan" \
    "$MD" "git ls-files '*.md' | grep -v -x 'CHANGELOG.md'"
assert_contains "release.md never flags the version being cut" \
    "$MD" '[ "$ver" = "$NEW" ] && continue   # the version being cut is never flagged'
assert_contains "release.md reuses Phase 1.5's header-matching regex" \
    "$MD" 'grep -Eq "^##[[:space:]]+v?\[?${ver_re}\]?([[:space:]]|\$)" CHANGELOG.md'
assert_contains "release.md derives the repo's own header 'v'-prefix style" \
    "$MD" "grep -Eq '^##[[:space:]]+v[0-9]' CHANGELOG.md"
assert_contains "release.md anchors the scan to version-boundary phrasing, not a bare scan" \
    "$MD" 'LEADIN='
assert_contains "release.md names the dependency-pin false positive it avoids" \
    "$MD" 'loom 0.18.0'
assert_contains "release.md names the image-tag false positive it avoids" \
    "$MD" 'ubuntu:24.04'
assert_contains "release.md names the lockfile-field false positive it avoids" \
    "$MD" "lockfileVersion: '9.0'"
assert_contains "release.md's finding line is tagged CITED-UNSHIPPED" \
    "$MD" 'CITED-UNSHIPPED:'

# ---------------------------------------------------------------------------
echo ""
echo "========================================="
echo "  Total:  $TOTAL"
printf "  ${GREEN}Passed${NC}: %s\n" "$PASS"
printf "  ${RED}Failed${NC}: %s\n" "$FAIL"
echo "========================================="

if [[ $FAIL -gt 0 ]]; then
    printf "\n${RED}TESTS FAILED${NC}\n"
    exit 1
fi
printf "\n${GREEN}ALL TESTS PASSED${NC}\n"
exit 0

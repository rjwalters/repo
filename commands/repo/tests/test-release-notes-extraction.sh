#!/usr/bin/env bash
# Test suite for the GitHub Release notes extraction documented in
# commands/repo/release.md Phase 6 — the awk-based CHANGELOG range extraction
# that replaced a GNU-only `sed -n "/^## \[\?$NEW/,/^## /p"` (repo#399).
#
# Usage: ./commands/repo/tests/test-release-notes-extraction.sh
# Exit code 0 = all tests pass, 1 = failures detected.
#
# Structured like commands/repo/tests/test-release-version-citation-check.sh:
# pure bash, no test framework, PASS/FAIL/TOTAL counters, a scratch CHANGELOG.md
# fixture, and a doc-drift block pinning this file's prose against what this
# suite implements. `pnpm test` delegates to this file via hooks/repo/tests/run.sh.
#
# WHY THIS FILE EXISTS (repo#399): release.md is prose an agent reads, not code
# any harness executes, so nothing in this repo could catch a regression in the
# extraction. But the extraction is a small, self-contained `awk` invocation,
# independent of the surrounding prose — so it can be run directly against
# scratch CHANGELOG.md fixtures. extract_release_notes() below is a faithful
# transcription of release.md Phase 6.
#
# THE BUG THIS REPLACES: `\?` (zero-or-one) is a GNU sed extension. On
# BSD/macOS sed it is not recognized inside a basic-regex address, so
# `sed -n "/^## \[\?$NEW/,/^## /p"` never matches the start of the range,
# prints nothing, and `gh release create --notes-file <(…)` silently publishes
# an EMPTY release body — hit live cutting v0.11.1 on macOS. The awk range
# needs no optional-bracket regex, so GNU and BSD produce identical output.

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
# The extraction under test — a direct transcription of release.md Phase 6's
# extract_release_notes() function.
# ---------------------------------------------------------------------------

# extract_release_notes <changelog-file> <version> -> matching CHANGELOG range on stdout
extract_release_notes() {
    local changelog="$1" v="$2"
    awk -v v="$v" '
      $0 ~ "^##[[:space:]]+v?\\[?" v "([[:space:]]|\\]|$)" {f=1; next}
      /^##[[:space:]]/ {f=0}
      f' "$changelog"
}

echo "release.md Phase 6 notes-extraction test suite"
echo "==============================================="
echo ""

# ---------------------------------------------------------------------------
echo "-- case 1: bracket-less header shape --"
# ---------------------------------------------------------------------------
CHANGELOG="$SCRATCH/CHANGELOG-1.md"
cat > "$CHANGELOG" <<'EOF'
# Changelog

## 0.4.1 (2026-08-20)

- Fixed a bug.
- Added a feature.

## 0.4.0 (2026-08-10)

- Initial cut.
EOF

OUT="$(extract_release_notes "$CHANGELOG" "0.4.1")"
assert_contains "bracket-less header: extracts the version's own body" "$OUT" "Fixed a bug."
assert_contains "bracket-less header: extracts multiple body lines" "$OUT" "Added a feature."
assert_not_contains "bracket-less header: stops before the next version's body" "$OUT" "Initial cut."
assert_not_contains "bracket-less header: does not include the matched header itself" "$OUT" "## 0.4.1"

# ---------------------------------------------------------------------------
echo ""
echo "-- case 2: Keep-a-Changelog bracketed header shape --"
# ---------------------------------------------------------------------------
CHANGELOG="$SCRATCH/CHANGELOG-2.md"
cat > "$CHANGELOG" <<'EOF'
# Changelog

## [0.4.1] - 2026-08-20

### Fixed
- Fixed a bug.

### Added
- Added a feature.

## [0.4.0] - 2026-08-10

### Added
- Initial cut.
EOF

OUT="$(extract_release_notes "$CHANGELOG" "0.4.1")"
assert_contains "bracketed header: extracts the version's own body" "$OUT" "Fixed a bug."
assert_contains "bracketed header: extracts multiple body lines" "$OUT" "Added a feature."
assert_not_contains "bracketed header: stops before the next version's body" "$OUT" "Initial cut."
assert_not_contains "bracketed header: does not include the matched header itself" "$OUT" "[0.4.1]"

# ---------------------------------------------------------------------------
echo ""
echo "-- case 3: leading 'v'-prefixed header shape --"
# ---------------------------------------------------------------------------
CHANGELOG="$SCRATCH/CHANGELOG-3.md"
cat > "$CHANGELOG" <<'EOF'
# Changelog

## v0.4.1 (2026-08-20)

- Fixed a bug with a leading v.

## v0.4.0 (2026-08-10)

- Initial cut.
EOF

OUT="$(extract_release_notes "$CHANGELOG" "0.4.1")"
assert_contains "v-prefixed header: extracts the version's own body" "$OUT" "Fixed a bug with a leading v."
assert_not_contains "v-prefixed header: stops before the next version's body" "$OUT" "Initial cut."

# ---------------------------------------------------------------------------
echo ""
echo "-- case 4: prefix-collision anchoring (0.4.1 vs 0.4.10) --"
# ---------------------------------------------------------------------------
# A version whose header text is a textual prefix of another version already
# in the CHANGELOG must not have its range swallow the longer entry, and vice
# versa (repo#399 edge case).
CHANGELOG="$SCRATCH/CHANGELOG-4.md"
cat > "$CHANGELOG" <<'EOF'
# Changelog

## 0.4.10 (2026-08-25)

- The tenth patch.

## 0.4.1 (2026-08-20)

- The first patch.

## 0.4.0 (2026-08-10)

- Initial cut.
EOF

OUT_4_1="$(extract_release_notes "$CHANGELOG" "0.4.1")"
assert_contains "0.4.1 extraction: gets its own body" "$OUT_4_1" "The first patch."
assert_not_contains "0.4.1 extraction: does not include 0.4.10's body" "$OUT_4_1" "The tenth patch."
assert_not_contains "0.4.1 extraction: does not include 0.4.0's body" "$OUT_4_1" "Initial cut."

OUT_4_10="$(extract_release_notes "$CHANGELOG" "0.4.10")"
assert_contains "0.4.10 extraction: gets its own body" "$OUT_4_10" "The tenth patch."
assert_not_contains "0.4.10 extraction: does not swallow 0.4.1's body" "$OUT_4_10" "The first patch."

# ---------------------------------------------------------------------------
echo ""
echo "-- case 5: absent version header -> empty extraction --"
# ---------------------------------------------------------------------------
CHANGELOG="$SCRATCH/CHANGELOG-5.md"
cat > "$CHANGELOG" <<'EOF'
# Changelog

## 0.4.0 (2026-08-10)

- Initial cut.
EOF

OUT="$(extract_release_notes "$CHANGELOG" "9.9.9")"
assert_eq "absent version header: extraction is empty" "" "$OUT"

# ---------------------------------------------------------------------------
echo ""
echo "-- case 6: empty-output guard aborts before gh release create --"
# ---------------------------------------------------------------------------
# Transcription of the guard from release.md Phase 6: extract into a file,
# then `[ -s "$NOTES_FILE" ]` must fail (empty file) and the caller must never
# reach `gh release create`.
NOTES_FILE="$SCRATCH/notes-empty.txt"
extract_release_notes "$CHANGELOG" "9.9.9" > "$NOTES_FILE"

GH_RELEASE_CREATE_CALLED=0
if [ ! -s "$NOTES_FILE" ]; then
    GUARD_ABORTED=1
else
    GUARD_ABORTED=0
    GH_RELEASE_CREATE_CALLED=1   # would have run `gh release create` — must not happen
fi
assert_eq "empty extraction: guard detects it (would exit 1)" "1" "$GUARD_ABORTED"
assert_eq "empty extraction: gh release create is never reached" "0" "$GH_RELEASE_CREATE_CALLED"

# ---------------------------------------------------------------------------
echo ""
echo "-- case 7: non-empty extraction passes the same guard --"
# ---------------------------------------------------------------------------
CHANGELOG="$SCRATCH/CHANGELOG-7.md"
cat > "$CHANGELOG" <<'EOF'
# Changelog

## 0.5.0 (2026-08-21)

- Something shipped.
EOF
NOTES_FILE="$SCRATCH/notes-nonempty.txt"
extract_release_notes "$CHANGELOG" "0.5.0" > "$NOTES_FILE"
if [ ! -s "$NOTES_FILE" ]; then
    GUARD_ABORTED=1
else
    GUARD_ABORTED=0
fi
assert_eq "non-empty extraction: guard does not abort" "0" "$GUARD_ABORTED"

# ---------------------------------------------------------------------------
echo ""
echo "-- doc drift: release.md still specifies what this suite implements --"
# ---------------------------------------------------------------------------
MD="$(cat "$RELEASE_MD")"

assert_not_contains "release.md Phase 6 no longer uses the GNU-only sed '\\?' idiom" \
    "$MD" 'sed -n "/^## \[\?$NEW/,/^## /p"'
assert_contains "release.md defines the shared extract_release_notes() function" \
    "$MD" 'extract_release_notes() {   # <version> -> writes matching CHANGELOG range to stdout'
assert_contains "release.md's awk pattern matches optional v-prefix and bracket" \
    "$MD" '$0 ~ "^##[[:space:]]+v?\\[?" v "([[:space:]]|\\]|$)" {f=1; next}'
assert_contains "release.md extracts into a NOTES_FILE once" \
    "$MD" 'NOTES_FILE="$(mktemp)"'
assert_contains "release.md guards against an empty extraction before gh release create" \
    "$MD" 'if [ ! -s "$NOTES_FILE" ]; then'
assert_contains "release.md's guard error names the unmatched version" \
    "$MD" 'ERROR: extracted release notes are empty — CHANGELOG header for $NEW not matched'
assert_contains "release.md's retry branch reuses NOTES_FILE (no second pattern copy)" \
    "$MD" 'gh release create "v$NEW" --title "v$NEW" --notes-file "$NOTES_FILE"; }'

# Both the initial attempt and the retry must reference the same NOTES_FILE
# variable rather than each embedding their own extraction call.
NOTES_FILE_REFS="$(printf '%s' "$MD" | grep -c '\-\-notes-file "\$NOTES_FILE"')"
assert_eq "release.md's initial attempt and retry both use \"\$NOTES_FILE\" (2 references)" \
    "2" "$NOTES_FILE_REFS"

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

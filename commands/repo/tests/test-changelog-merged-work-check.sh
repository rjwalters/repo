#!/usr/bin/env bash
# Test suite for the merged-work coverage check documented in
# commands/repo/release.md Phase 5 step 2 — the advisory check that flags a
# merged PR since the last tag whose #N appears nowhere in the CHANGELOG.md
# entry Phase 5 step 1 just inserted.
#
# Usage: ./commands/repo/tests/test-changelog-merged-work-check.sh
# Exit code 0 = all tests pass, 1 = failures detected.
#
# Structured like commands/repo/tests/test-release-version-citation-check.sh:
# pure bash, no test framework, PASS/FAIL/TOTAL counters, a scratch-git
# fixture harness, and a doc-drift block pinning this file's prose against
# what this suite implements. `pnpm test` delegates to this file via
# hooks/repo/tests/run.sh.
#
# WHY THIS FILE EXISTS (repo#229): Phase 1.5's CHANGELOG completeness gate
# checks one direction only — for each of the last ~5 SHIPPED tags, does
# CHANGELOG.md have a matching version header? It does not check the reverse:
# does the work merged since the last tag have an entry at ALL? At v0.9.0, 41
# commits shipped since v0.8.1 and roughly 13 PRs of real user-facing work had
# no CHANGELOG line anywhere — including two safety-relevant regressions
# (#182: EC2 instances launched with KeyName: None, unreachable by SSH by
# design; #171: `down` could terminate a repurposed fleet host's disk with no
# guard). Both shipped silently and were caught only because the operator
# asked for the gap to be closed by hand. check_merged_work_coverage() below
# is a faithful transcription of release.md Phase 5 step 2.
check_merged_work_coverage() {
    local repo="$1" last="$2"
    ( cd "$repo" || exit 1
      FILTER='^(feat|fix|security)(\(|:)'
      for sha in $(git log "${last}..HEAD" --format='%H'); do
          subject="$(git log -1 --format='%s' "$sha")"
          echo "$subject" | grep -Eq "$FILTER" || continue
          # Same grep -oE '#[0-9]+' key the Phase 4 Unreleased-fold dedup
          # uses, applied to the FULL commit message (not just the subject's
          # trailing PR number) — a squash-merge body commonly carries a
          # "Closes #NNN" naming the originating issue, which is what this
          # repo's own entries usually cite.
          nums="$(git log -1 --format='%B' "$sha" | grep -oE '#[0-9]+' | tr -d '#' | sort -u)"
          [[ -n "$nums" ]] || continue
          logged=0
          for n in $nums; do
              grep -Eq "#${n}([^0-9]|\$)" CHANGELOG.md && { logged=1; break; }
          done
          [[ "$logged" == 1 ]] && continue
          echo "UNLOGGED: $subject"
      done
    )
}

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
RELEASE_MD="$REPO_ROOT/commands/repo/release.md"

PASS=0
FAIL=0
TOTAL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

if [[ ! -f "$RELEASE_MD" ]]; then
    echo "FATAL: release.md not found at $RELEASE_MD" >&2
    exit 1
fi

SCRATCH="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$SCRATCH"' EXIT

# ---------------------------------------------------------------------------
# Assertion helpers
# ---------------------------------------------------------------------------

ok() {   # <label>
    TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1))
    printf "  ${GREEN}PASS${NC}: %s\n" "$1"
}
no() {   # <label> <detail>
    TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
    printf "  ${RED}FAIL${NC}: %s\n" "$1"
    [[ -n "${2:-}" ]] && printf "        %s\n" "$2"
    return 0
}
assert_eq() {  # <label> <expected> <actual>
    if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1" "expected [$2], got [$3]"; fi
}
assert_contains() {  # <label> <haystack> <needle>
    if [[ "$2" == *"$3"* ]]; then ok "$1"; else no "$1" "missing [$3]"; fi
}
assert_not_contains() {  # <label> <haystack> <needle>
    if [[ "$2" != *"$3"* ]]; then ok "$1"; else no "$1" "unexpected [$3] present"; fi
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
    git -C "$REPO" config user.name "Merged Work Coverage Test"
}

commit_all() {   # <message>
    git -C "$REPO" add -A && git -C "$REPO" commit -qm "$1"
}

echo "release.md merged-work coverage check test suite"
echo "=================================================="
echo ""

# ---------------------------------------------------------------------------
echo "-- case 1: a merged fix: PR absent from the draft is flagged --"
# ---------------------------------------------------------------------------
build_repo "case1"
cat > "$REPO/CHANGELOG.md" <<'EOF'
# Changelog

## 0.1.0 (2026-08-01)

Initial cut.
EOF
commit_all "M0: base"
git -C "$REPO" tag v0.1.0

cat >> "$REPO/CHANGELOG.md" <<'EOF'

## 0.2.0 (2026-08-10)

- Some unrelated entry (#200).
EOF
git -C "$REPO" commit -aqm "fix: gate repo-remote down behind the fleet-marker guard (#171)"

OUT="$(check_merged_work_coverage "$REPO" v0.1.0)"
assert_contains "an unreferenced fix: PR is flagged" "$OUT" "UNLOGGED: fix: gate repo-remote down behind the fleet-marker guard (#171)"

# ---------------------------------------------------------------------------
echo ""
echo "-- case 2: docs:/chore:/test: prefixed commits are excluded by default --"
# ---------------------------------------------------------------------------
build_repo "case2"
cat > "$REPO/CHANGELOG.md" <<'EOF'
# Changelog

## 0.1.0 (2026-08-01)

Initial cut.
EOF
commit_all "M0: base"
git -C "$REPO" tag v0.1.0

git -C "$REPO" commit --allow-empty -qm "docs: update WORK_LOG, WORK_PLAN, and README (#172)"
git -C "$REPO" commit --allow-empty -qm "chore: bump a dependency (#173)"
git -C "$REPO" commit --allow-empty -qm "test: add coverage for the parser (#175)"
git -C "$REPO" commit --allow-empty -qm "build(deps): bump ubuntu from 24.04 to 26.04 (#176)"

OUT="$(check_merged_work_coverage "$REPO" v0.1.0)"
assert_eq "docs:/chore:/test:/build: commits produce no findings" "" "$OUT"

# ---------------------------------------------------------------------------
echo ""
echo "-- case 3: a PR number present in both the log and the draft is not flagged --"
# ---------------------------------------------------------------------------
build_repo "case3"
cat > "$REPO/CHANGELOG.md" <<'EOF'
# Changelog

## 0.1.0 (2026-08-01)

Initial cut.
EOF
commit_all "M0: base"
git -C "$REPO" tag v0.1.0

cat >> "$REPO/CHANGELOG.md" <<'EOF'

## 0.2.0 (2026-08-10)

- Resolve-or-create a security group with verified SSH ingress (#181).
EOF
git -C "$REPO" commit -aqm "fix(repo-remote): resolve-or-create a security group with verified SSH ingress (#181)"

OUT="$(check_merged_work_coverage "$REPO" v0.1.0)"
assert_eq "a PR already cited in the draft is not flagged" "" "$OUT"

# ---------------------------------------------------------------------------
echo ""
echo "-- case 4: advisory only — never a non-zero/blocking exit --"
# ---------------------------------------------------------------------------
# Reuse case1's fixture, which has a genuine finding, and confirm the check
# function itself still exits 0 — the finding is reported, never enforced.
check_merged_work_coverage "$SCRATCH/case1" v0.1.0 >/dev/null
CASE4_STATUS=$?
assert_eq "the check exits 0 even when it has findings" "0" "$CASE4_STATUS"

# ---------------------------------------------------------------------------
echo ""
echo "-- case 5: a commit with no #N anywhere is skipped, not flagged --"
# ---------------------------------------------------------------------------
build_repo "case5"
cat > "$REPO/CHANGELOG.md" <<'EOF'
# Changelog

## 0.1.0 (2026-08-01)

Initial cut.
EOF
commit_all "M0: base"
git -C "$REPO" tag v0.1.0

git -C "$REPO" commit --allow-empty -qm "fix: local cleanup with no tracked PR reference"

OUT="$(check_merged_work_coverage "$REPO" v0.1.0)"
assert_eq "a numberless fix: commit produces no finding (nothing to cross-reference)" "" "$OUT"

# ---------------------------------------------------------------------------
echo ""
echo "-- case 6: a commit citing multiple #Ns is cleared if ANY of them is logged --"
# ---------------------------------------------------------------------------
build_repo "case6"
cat > "$REPO/CHANGELOG.md" <<'EOF'
# Changelog

## 0.1.0 (2026-08-01)

Initial cut.
EOF
commit_all "M0: base"
git -C "$REPO" tag v0.1.0

cat >> "$REPO/CHANGELOG.md" <<'EOF'

## 0.2.0 (2026-08-10)

- Closes the tracked gap (#188).
EOF
git -C "$REPO" commit -aqm "$(printf 'fix: port write confinement (#192)\n\nCloses #188')"

OUT="$(check_merged_work_coverage "$REPO" v0.1.0)"
assert_eq "logged via a body-cited number even though the trailing PR number is not" "" "$OUT"

# Same shape, but NEITHER number is cited anywhere in the draft -> flagged.
build_repo "case6b"
cat > "$REPO/CHANGELOG.md" <<'EOF'
# Changelog

## 0.1.0 (2026-08-01)

Initial cut.
EOF
commit_all "M0: base"
git -C "$REPO" tag v0.1.0
git -C "$REPO" commit --allow-empty -qm "$(printf 'fix: port write confinement (#192)\n\nCloses #188')"
OUT="$(check_merged_work_coverage "$REPO" v0.1.0)"
assert_contains "flagged when NEITHER cited number is in the draft" "$OUT" "UNLOGGED: fix: port write confinement (#192)"

# ---------------------------------------------------------------------------
echo ""
echo "-- case 7: a revert pair does not produce a spurious double-flag --"
# ---------------------------------------------------------------------------
build_repo "case7"
cat > "$REPO/CHANGELOG.md" <<'EOF'
# Changelog

## 0.1.0 (2026-08-01)

Initial cut.
EOF
commit_all "M0: base"
git -C "$REPO" tag v0.1.0

git -C "$REPO" commit --allow-empty -qm "fix: risky change that gets reverted (#300)"
git -C "$REPO" commit --allow-empty -qm "$(printf 'Revert "fix: risky change that gets reverted (#300)" (#301)\n\nThis reverts commit deadbeef.')"

OUT="$(check_merged_work_coverage "$REPO" v0.1.0)"
UNLOGGED_COUNT="$(printf '%s\n' "$OUT" | grep -c '^UNLOGGED:')"
assert_eq "only the fix: commit is flagged, not its Revert (subject prefix excludes it)" "1" "$UNLOGGED_COUNT"
assert_contains "the flagged line is the original fix:, not the revert" "$OUT" "UNLOGGED: fix: risky change that gets reverted (#300)"

# ---------------------------------------------------------------------------
echo ""
echo "-- doc drift: release.md still specifies what this suite implements --"
# ---------------------------------------------------------------------------
MD="$(cat "$RELEASE_MD")"

assert_contains "release.md documents the Merged-work coverage check" \
    "$MD" "**Merged-work coverage check (advisory).**"
assert_contains "release.md places it inside Phase 5 — Apply" \
    "$MD" "## Phase 5 — Apply"
assert_contains "release.md states the check is advisory-only" \
    "$MD" "**Advisory only — report and continue,"
assert_contains "release.md scopes the filter to feat/fix/security by default" \
    "$MD" "FILTER='^(feat|fix|security)(\\(|:)'"
assert_contains "release.md reuses the Unreleased fold's #N dedup key" \
    "$MD" "grep -oE '#[0-9]+' | tr -d '#' | sort -u"
assert_contains "release.md's finding line is tagged UNLOGGED" \
    "$MD" 'echo "  UNLOGGED: $subject"'
assert_contains "release.md skips commits with no #N to cross-reference" \
    "$MD" '[ -n "$nums" ] || continue   # no #N anywhere'
assert_contains "release.md names the motivating #182 EC2-key-pair regression" \
    "$MD" "#182"
assert_contains "release.md names the motivating #171 fleet-teardown regression" \
    "$MD" "#171"
assert_contains "release.md names the docs: WORK_LOG exclusion example" \
    "$MD" 'docs: update WORK_LOG'

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

#!/usr/bin/env bash
# Test suite verifying README.md's "## Repository layout" block matches disk
# (repo#212).
#
# Usage: ./commands/repo/tests/test-readme-layout-block.sh
# Exit code 0 = all tests pass, 1 = failures detected.
#
# Structured like commands/repo/tests/test-links-precision.sh: pure bash, no
# test framework, PASS/FAIL/SKIP/TOTAL counters and a summary block.
# `pnpm test` delegates to this file via hooks/repo/tests/run.sh.
#
# WHY THIS FILE EXISTS (repo#211, repo#212): the Repository layout block is a
# plain two-column listing (path/glob, then a prose description) — not an
# ASCII tree, so /repo:readme's File Tree Accuracy check (scoped to blocks
# containing box-drawing characters) never matched it, before or after #211.
# It drifted badly: four PRs in a row added a hook/command test suite without
# adding its README row, until it listed 10 of the 16 delegated suites and
# omitted scripts/repo/repo-scrub-forks.sh entirely. #211 mitigated the
# per-file-enumeration half of that by replacing the individual test rows with
# two globs (hooks/repo/tests/test-*.sh, commands/repo/tests/test-*.sh) — a new
# suite no longer requires a README edit to stay covered. But nothing verified
# the globs/rows still resolve, so the block could still drift the other way
# (a path renamed, a directory moved, a script deleted) with no check to catch
# it. This file is that check.
#
# SCOPE DECISION (repo#212 suggested AC #4): this check validates PATHS ONLY —
# every row/glob's leading token must resolve to at least one file or
# directory on disk (section 1 below), and every hooks/repo/tests/test-*.sh
# and commands/repo/tests/test-*.sh file must be matched by some row/glob in
# the block (section 2 below), so a suite that evades both globs (e.g. added
# under a naming convention other than test-*.sh, or added to a different
# directory) is caught. It deliberately does NOT verify the per-row prose
# descriptions, nor the annotation block's suite-count/description prose
# (e.g. "5 hook suites, 11 command suites" style commentary) against the
# actual delegated suites in hooks/repo/tests/run.sh — that prose can still
# drift silently. Extending /repo:readme's File Tree Accuracy check to
# recognize two-column layout blocks (rather than only ASCII trees) was
# considered a better long-term home for this — noted in repo#212 as a
# separate, agentic-command follow-up, not implemented here since it is not a
# bash script and could not be wired into `pnpm test`/CI.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
README="$REPO_ROOT/README.md"

# Assertion helpers (ok/no/skip/assert_eq/assert_contains/assert_not_contains/
# assert_matches) plus the PASS/FAIL/SKIP/TOTAL counters and color vars are
# shared across the repo test suites — see lib/assert.sh (repo#307).
source "$(dirname "${BASH_SOURCE[0]}")/lib/assert.sh"

if [[ ! -f "$README" ]]; then
    echo "FATAL: README.md not found at $README" >&2
    exit 1
fi

# Extract the fenced code block immediately under "## Repository layout".
BLOCK="$(awk '
    /^## Repository layout[[:space:]]*$/ { found=1; next }
    found && /^```/ { if (infence) { exit } else { infence = 1; next } }
    infence { print }
' "$README")"

if [[ -z "$BLOCK" ]]; then
    echo "FATAL: could not find a fenced code block under '## Repository layout' in $README" >&2
    exit 1
fi

# Each row begins in column 0 with the path/glob as its first
# whitespace-delimited token, followed by a prose description. A multi-line
# description continues on subsequent lines indented to align under the
# description column — those continuation lines are NOT new rows and are
# skipped here (they carry no path token of their own to check).
ENTRIES=()
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[[:space:]] ]] && continue
    ENTRIES+=("${line%% *}")
done <<< "$BLOCK"

if [[ ${#ENTRIES[@]} -eq 0 ]]; then
    echo "FATAL: the Repository layout block parsed to zero row entries" >&2
    exit 1
fi

# entry_matches <entry> <repo-relative path> -> true if entry (a literal path
# or a glob) matches path. Entries are used as shell patterns via [[ == ]] —
# unquoted on the right-hand side so a literal entry with no '*' still just
# matches itself, and an entry containing '*' matches per glob semantics.
entry_matches() {
    local entry="$1" path="$2"
    [[ "$path" == $entry ]]
}

# ---------------------------------------------------------------------------
echo "1. Every path/glob in the Repository layout block resolves on disk"
# ---------------------------------------------------------------------------

for entry in "${ENTRIES[@]}"; do
    if [[ "$entry" == *'*'* ]]; then
        shopt -s nullglob
        matches=("$REPO_ROOT"/$entry)
        shopt -u nullglob
        if (( ${#matches[@]} > 0 )); then
            ok "$entry resolves (${#matches[@]} match(es))"
        else
            no "$entry resolves to at least one file/directory" \
                "glob matched nothing under $REPO_ROOT"
        fi
    else
        if [[ -e "$REPO_ROOT/$entry" ]]; then
            ok "$entry exists"
        else
            no "$entry exists" "not found at $REPO_ROOT/$entry"
        fi
    fi
done

# ---------------------------------------------------------------------------
echo ""
echo "2. Every hooks/commands test-*.sh suite is covered by a row/glob"
# ---------------------------------------------------------------------------
# This is the direction the globs themselves cannot self-check: #211 stopped a
# new suite from requiring a README edit, but a suite added under a different
# naming convention, or outside these two directories, would still silently
# evade both globs. Enumerate the suite files that actually exist on disk and
# assert each one is matched by some entry in the block — not only the two
# glob rows, so an explicit per-file row would also count as coverage.

for dir in hooks/repo/tests commands/repo/tests; do
    shopt -s nullglob
    files=("$REPO_ROOT/$dir"/test-*.sh)
    shopt -u nullglob
    if (( ${#files[@]} == 0 )); then
        skip "$dir/test-*.sh files are covered by a row/glob" "no test-*.sh files found in $dir"
        continue
    fi
    for f in "${files[@]}"; do
        rel="${f#"$REPO_ROOT"/}"
        covered=0
        for entry in "${ENTRIES[@]}"; do
            if entry_matches "$entry" "$rel"; then
                covered=1
                break
            fi
        done
        if [[ "$covered" -eq 1 ]]; then
            ok "$rel is covered by a Repository layout row/glob"
        else
            no "$rel is covered by a Repository layout row/glob" \
                "no row/glob in the block matches this path"
        fi
    done
done

# ---------------------------------------------------------------------------
echo ""
echo "========================================="
echo "  Total:  $TOTAL"
printf "  ${GREEN}Passed${NC}: %s\n" "$PASS"
printf "  ${RED}Failed${NC}: %s\n" "$FAIL"
printf "  ${YELLOW}Skipped${NC}: %s\n" "$SKIP"
echo "========================================="

if [[ $FAIL -gt 0 ]]; then
    printf "\n${RED}TESTS FAILED${NC}\n"
    exit 1
fi
printf "\n${GREEN}ALL TESTS PASSED${NC}\n"
exit 0

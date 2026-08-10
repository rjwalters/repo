#!/usr/bin/env bash
# Test suite verifying skills/repo/SKILL.md's "## Commands" table matches the
# /repo:* commands on disk (repo#246).
#
# Usage: ./commands/repo/tests/test-skill-commands-table.sh
# Exit code 0 = all tests pass, 1 = failures detected.
#
# Structured like commands/repo/tests/test-readme-layout-block.sh: pure bash, no
# test framework, PASS/FAIL/SKIP/TOTAL counters and a summary block.
# `pnpm test` delegates to this file via hooks/repo/tests/run.sh.
#
# WHY THIS FILE EXISTS (repo#246): SKILL.md's "## Commands" table is
# per-item enumeration — one hand-written row per commands/repo/*.md file. That
# is exactly the shape that went stale for README's "Repository layout" block
# (repo#211/#212): every new command needs a row, and nothing verified the rows
# against disk, so adding a command and forgetting its row would go unnoticed.
# SKILL.md is more externally visible than the layout block — it is the skill
# description consumers read — so the gap mattered more here. This file is the
# equivalent check.
#
# SCOPE DECISION: this validates the command NAMES only, in both directions —
# every commands/repo/*.md has a row (section 2), and every row names a command
# that exists on disk (section 1) — plus that no command is listed twice
# (section 3). It deliberately does NOT verify the per-row "What it does" prose
# against the command file's own description; that prose can still drift
# silently, same as the layout block's descriptions.
#
# MATCHING RULE (repo#246 called this out explicitly): the table's first column
# uses **wiki-link syntax** — `[[docs]]`, `[[update-tools]]` — not `/repo:docs`
# or `docs.md`. Grepping for `repo:<cmd>` reports 18 false "missing" results
# against a table that is in fact complete, and a check whose own matching rule
# is wrong is worse than no check because it produces confident noise. So:
#   - Only the FIRST column of each row is read. Descriptions frequently contain
#     wiki links of their own (the [[scrub]] row mentions [[all]]) — treating
#     those as row entries would mask a genuinely missing row.
#   - A first cell that is not in `[[name]]` form is a FAIL, never a silent
#     skip, so a future reformat of the table cannot quietly disable this check
#     by making every row unparseable.
# Verified by fault injection before landing: deleting a row and adding a row
# for a nonexistent command each turn this suite red.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SKILL="$REPO_ROOT/skills/repo/SKILL.md"
COMMANDS_DIR="$REPO_ROOT/commands/repo"

PASS=0
FAIL=0
SKIP=0
TOTAL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

if [[ ! -f "$SKILL" ]]; then
    echo "FATAL: SKILL.md not found at $SKILL" >&2
    exit 1
fi
if [[ ! -d "$COMMANDS_DIR" ]]; then
    echo "FATAL: commands directory not found at $COMMANDS_DIR" >&2
    exit 1
fi

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
skip() {  # <label> <reason>
    SKIP=$((SKIP + 1))
    printf "  ${YELLOW}SKIP${NC}: %s\n" "$1"
    [[ -n "${2:-}" ]] && printf "        %s\n" "$2"
    return 0
}

# Extract the table rows under "## Commands", stopping at the next heading.
SECTION="$(awk '
    /^##[[:space:]]+Commands[[:space:]]*$/ { found=1; next }
    found && /^#/ { exit }
    found { print }
' "$SKILL")"

if [[ -z "$SECTION" ]]; then
    echo "FATAL: could not find a '## Commands' section in $SKILL" >&2
    exit 1
fi

# trim <string> -> string with leading/trailing whitespace removed
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Parse the markdown table: every line starting with '|' is a row; field 2
# (after splitting on '|') is the Command column. The header row and the
# `|---|---|` separator are recognized and skipped; everything else must be a
# `[[name]]` wiki link.
ROW_COMMANDS=()
BAD_CELLS=()
SAW_HEADER=0
while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*\| ]] || continue
    cell="$(trim "$(printf '%s' "$line" | cut -d'|' -f2)")"
    # Separator row: only dashes, colons and spaces.
    [[ "$cell" =~ ^[-:[:space:]]+$ ]] && continue
    # Header row.
    if [[ "$cell" == "Command" ]]; then
        SAW_HEADER=1
        continue
    fi
    if [[ "$cell" =~ ^\[\[([A-Za-z0-9][A-Za-z0-9._-]*)\]\]$ ]]; then
        ROW_COMMANDS+=("${BASH_REMATCH[1]}")
    else
        BAD_CELLS+=("$cell")
    fi
done <<< "$SECTION"

if [[ ${#ROW_COMMANDS[@]} -eq 0 && ${#BAD_CELLS[@]} -eq 0 ]]; then
    echo "FATAL: the '## Commands' table parsed to zero rows — the table is" >&2
    echo "       missing, or its shape changed and this check's matcher is stale" >&2
    exit 1
fi

# contains <needle> <haystack...> -> true if needle is among the remaining args
contains() {
    local needle="$1"; shift
    local item
    for item in "$@"; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

shopt -s nullglob
COMMAND_FILES=("$COMMANDS_DIR"/*.md)
shopt -u nullglob
DISK_COMMANDS=()
for f in ${COMMAND_FILES[@]+"${COMMAND_FILES[@]}"}; do
    base="$(basename "$f")"
    DISK_COMMANDS+=("${base%.md}")
done

# ---------------------------------------------------------------------------
echo "0. The Commands table parses in its documented [[name]] form"
# ---------------------------------------------------------------------------
# Guards the matcher itself: if the table is reshaped so rows no longer parse,
# this check must go red rather than vacuously pass with zero rows to compare.

if [[ "$SAW_HEADER" -eq 1 ]]; then
    ok "table has a 'Command' header column"
else
    no "table has a 'Command' header column" \
        "no '| Command |' header row found under '## Commands' — table shape changed"
fi

if [[ ${#BAD_CELLS[@]} -eq 0 ]]; then
    ok "every table row's first cell is a [[name]] wiki link (${#ROW_COMMANDS[@]} rows)"
else
    no "every table row's first cell is a [[name]] wiki link" \
        "unparseable first cell(s): ${BAD_CELLS[*]}"
fi

# ---------------------------------------------------------------------------
echo ""
echo "1. Every [[name]] row in the Commands table exists on disk"
# ---------------------------------------------------------------------------
# Catches a lingering row: a command was removed or renamed, its row stayed.

if [[ ${#ROW_COMMANDS[@]} -eq 0 ]]; then
    skip "table rows resolve to commands/repo/*.md" "no parseable rows"
else
    for cmd in "${ROW_COMMANDS[@]}"; do
        if [[ -f "$COMMANDS_DIR/$cmd.md" ]]; then
            ok "[[$cmd]] -> commands/repo/$cmd.md exists"
        else
            no "[[$cmd]] -> commands/repo/$cmd.md exists" \
                "table row names a command with no file at commands/repo/$cmd.md"
        fi
    done
fi

# ---------------------------------------------------------------------------
echo ""
echo "2. Every commands/repo/*.md has a row in the Commands table"
# ---------------------------------------------------------------------------
# Catches the failure mode this suite exists for: a command was added and the
# hand-written table was not updated.

if [[ ${#DISK_COMMANDS[@]} -eq 0 ]]; then
    skip "commands/repo/*.md files have table rows" "no *.md files found in $COMMANDS_DIR"
else
    for cmd in "${DISK_COMMANDS[@]}"; do
        if contains "$cmd" ${ROW_COMMANDS[@]+"${ROW_COMMANDS[@]}"}; then
            ok "commands/repo/$cmd.md -> [[$cmd]] row present"
        else
            no "commands/repo/$cmd.md -> [[$cmd]] row present" \
                "no [[$cmd]] row in SKILL.md's '## Commands' table"
        fi
    done
fi

# ---------------------------------------------------------------------------
echo ""
echo "3. No command is listed twice in the Commands table"
# ---------------------------------------------------------------------------
# A half-finished rename leaves both the old and new row; sections 1 and 2 both
# still pass in that state, so duplicates need their own assertion.

DUPES=()
if [[ ${#ROW_COMMANDS[@]} -gt 0 ]]; then
    SEEN=()
    for cmd in "${ROW_COMMANDS[@]}"; do
        if contains "$cmd" ${SEEN[@]+"${SEEN[@]}"}; then
            DUPES+=("$cmd")
        else
            SEEN+=("$cmd")
        fi
    done
fi
if [[ ${#DUPES[@]} -eq 0 ]]; then
    ok "no duplicate [[name]] rows"
else
    no "no duplicate [[name]] rows" "listed more than once: ${DUPES[*]}"
fi

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

#!/usr/bin/env bash
# Regression suite for marker-bounded CLAUDE.md surgery in install.sh /
# uninstall.sh (lib/claude-md-block.sh).
#
# Usage: ./hooks/repo/tests/test-install-claude-md-markers.sh
# Exit code 0 = all tests pass, 1 = failures detected.
#
# Structured like test-guard-destructive.sh / test-session-start-handoff.sh next
# door: pure bash, no test framework, PASS/FAIL counters and a summary block.
#
# The bug under test (repo#38): all three call sites bounded the REPO-SKILLS
# block with awk whole-line equality, so a CLAUDE.md written as
#
#     <!-- END REPO-SKILLS --><!-- BEGIN LOOM ORCHESTRATION -->
#
# (no newline between two tools' blocks — what you get when two installers each
# append without a trailing newline) made the end marker never compare equal,
# leaving the skip flag set and silently dropping every byte to EOF. An upgrade
# deleted Loom's entire orchestration block, printed "✓ Updated", and exited 0.
#
# The contract asserted below:
#   - both adjacency orderings survive byte-identical, at all three call sites
#     (install update path, reconcile_orphaned_block, uninstall)
#   - the non-adjacent common case is unchanged
#   - an unresolvable marker layout is refused loudly, leaves CLAUDE.md
#     untouched, and exits non-zero from install.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
UNINSTALL_SH="$REPO_ROOT/uninstall.sh"
VERSION="$(cat "$REPO_ROOT/VERSION" 2>/dev/null || echo unknown)"

PASS=0
FAIL=0
TOTAL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

for f in "$INSTALL_SH" "$UNINSTALL_SH" "$REPO_ROOT/lib/claude-md-block.sh"; do
    if [[ ! -f "$f" ]]; then
        echo "FATAL: required script not found at $f" >&2
        exit 1
    fi
done

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
    [[ -n "${2:-}" ]] && printf "%s\n" "$2" | sed 's/^/        /'
    return 0
}
assert_eq() {  # <label> <expected> <actual>
    if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1" "expected [$2], got [$3]"; fi
}
assert_contains() {  # <label> <haystack> <needle>
    if [[ "$2" == *"$3"* ]]; then ok "$1"; else no "$1" "missing [$3]"; fi
}
assert_not_contains() {  # <label> <haystack> <needle>
    if [[ "$2" != *"$3"* ]]; then ok "$1"; else no "$1" "unexpectedly present: [$3]"; fi
}
# Byte-exact file comparison. Deliberately file-to-file rather than
# string-to-file: `$(...)` strips trailing newlines, and whether the rewritten
# CLAUDE.md still ends in one is exactly the kind of byte the fix must preserve.
assert_bytes() {  # <label> <actual-file> <expected-file>
    if diff -u "$3" "$2" >/dev/null 2>&1; then
        ok "$1"
    else
        no "$1" "$(diff -u "$3" "$2" | head -25)"
    fi
}

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

# Slurp a file for substring assertions. Note that `$(slurp f)` still drops
# trailing newlines — that is fine for assert_contains/assert_eq, where both
# sides are stripped alike, but never use it for byte-exactness (assert_bytes
# compares files directly for exactly that reason).
slurp() {  # <file>
    local c
    c="$(cat "$1"; printf 'X')"
    printf '%s' "${c%X}"
}

# Everything from the first occurrence of <needle> to EOF (needle included).
# Substring-based, not line-based, because in the adjacency fixtures the needle
# does not start its physical line. Redirect to a file and compare with
# assert_bytes; the sentinel keeps the trailing newline intact.
tail_from() {  # <file> <needle> -> stdout
    local c=""
    c="$(cat "$1"; printf 'X')"; c="${c%X}"
    printf '%s%s' "$2" "${c#*"$2"}"
}

# Everything from the start of the file through <needle> (needle included).
head_through() {  # <file> <needle> -> stdout
    local c=""
    c="$(cat "$1"; printf 'X')"; c="${c%X}"
    printf '%s%s' "${c%%"$2"*}" "$2"
}

new_target() {  # <name> -> prints the target path
    local t="$SCRATCH/$1"
    mkdir -p "$t"
    git init -q "$t" 2>/dev/null
    printf '%s' "$t"
}

# uninstall.sh bails early unless an install is present; these tests care only
# about the CLAUDE.md surgery, so fake the directory it looks for.
fake_installed() {  # <target>
    mkdir -p "$1/.claude/skills/repo"
}

# ===========================================================================
echo "install.sh / uninstall.sh CLAUDE.md marker suite"
echo "================================================"

# ---------------------------------------------------------------------------
echo ""
echo "-- install.sh update path: our END adjacent to another tool's BEGIN (repo#38) --"

T1="$(new_target adjacent-after)"
cat > "$T1/CLAUDE.md" <<'EOF'
Some intro content.

<!-- BEGIN REPO-SKILLS -->
OLD repo skills content line 1
removals. Managed by `install.sh` — edit outside the markers only.
<!-- END REPO-SKILLS --><!-- BEGIN LOOM ORCHESTRATION -->
This repository uses Loom for AI-powered development orchestration.
<!-- END LOOM ORCHESTRATION -->

Trailing prose that must survive.
EOF
cat > "$SCRATCH/expected-loom-tail" <<'EOF'
<!-- BEGIN LOOM ORCHESTRATION -->
This repository uses Loom for AI-powered development orchestration.
<!-- END LOOM ORCHESTRATION -->

Trailing prose that must survive.
EOF

OUT1="$(bash "$INSTALL_SH" -y "$T1" 2>&1)"; RC1=$?
BODY1="$(slurp "$T1/CLAUDE.md")"

assert_eq        "adjacent-after: install exits 0"                "0" "$RC1"
tail_from "$T1/CLAUDE.md" '<!-- BEGIN LOOM ORCHESTRATION -->' > "$SCRATCH/actual-loom-tail"
assert_bytes     "adjacent-after: Loom block + tail byte-identical" \
                 "$SCRATCH/actual-loom-tail" "$SCRATCH/expected-loom-tail"
assert_contains  "adjacent-after: content before the block survives" "$BODY1" "Some intro content."
assert_contains  "adjacent-after: block was refreshed"            "$BODY1" "Repo Skills](https://github.com/rjwalters/repo) v$VERSION"
assert_not_contains "adjacent-after: stale block body is gone"    "$BODY1" "OLD repo skills content line 1"
assert_contains  "adjacent-after: adjacency preserved verbatim"   "$BODY1" '<!-- END REPO-SKILLS --><!-- BEGIN LOOM ORCHESTRATION -->'
assert_contains  "adjacent-after: reports the update"             "$OUT1" "Updated REPO-SKILLS block in CLAUDE.md"
assert_contains  "adjacent-after: reports a backup snapshot"      "$OUT1" "Backed up CLAUDE.md to "

# Re-running must be a no-op on the neighbour's block (idempotence).
BEFORE_RERUN="$(slurp "$T1/CLAUDE.md")"
bash "$INSTALL_SH" -y "$T1" >/dev/null 2>&1
assert_eq "adjacent-after: re-install is idempotent" "$BEFORE_RERUN" "$(slurp "$T1/CLAUDE.md")"

# ---------------------------------------------------------------------------
echo ""
echo "-- install.sh update path: another tool's END adjacent to our BEGIN --"

T2="$(new_target adjacent-before)"
cat > "$T2/CLAUDE.md" <<'EOF'
Preamble that must survive.

<!-- BEGIN LOOM ORCHESTRATION -->
This repository uses Loom for AI-powered development orchestration.
<!-- END LOOM ORCHESTRATION --><!-- BEGIN REPO-SKILLS -->
OLD repo skills content line 1
<!-- END REPO-SKILLS -->

Trailing prose that must survive.
EOF
# No trailing newline: head_through() stops at the marker itself.
printf '%s' 'Preamble that must survive.

<!-- BEGIN LOOM ORCHESTRATION -->
This repository uses Loom for AI-powered development orchestration.
<!-- END LOOM ORCHESTRATION -->' > "$SCRATCH/expected-loom-head"

OUT2="$(bash "$INSTALL_SH" -y "$T2" 2>&1)"; RC2=$?
BODY2="$(slurp "$T2/CLAUDE.md")"

assert_eq    "adjacent-before: install exits 0" "0" "$RC2"
head_through "$T2/CLAUDE.md" '<!-- END LOOM ORCHESTRATION -->' > "$SCRATCH/actual-loom-head"
assert_bytes "adjacent-before: preceding Loom block byte-identical" \
             "$SCRATCH/actual-loom-head" "$SCRATCH/expected-loom-head"
assert_contains     "adjacent-before: block was refreshed"     "$BODY2" "Repo Skills](https://github.com/rjwalters/repo) v$VERSION"
assert_not_contains "adjacent-before: stale block body is gone" "$BODY2" "OLD repo skills content line 1"
assert_contains     "adjacent-before: trailing prose survives"  "$BODY2" "Trailing prose that must survive."
assert_contains     "adjacent-before: reports the update"       "$OUT2"  "Updated REPO-SKILLS block in CLAUDE.md"
assert_contains     "adjacent-before: adjacency preserved verbatim" "$BODY2" '<!-- END LOOM ORCHESTRATION --><!-- BEGIN REPO-SKILLS -->'

# ---------------------------------------------------------------------------
echo ""
echo "-- install.sh append path: no block yet, neighbour has no trailing newline --"

T3="$(new_target append-no-newline)"
printf '%s' 'Preamble.

<!-- BEGIN LOOM ORCHESTRATION -->
Loom content.
<!-- END LOOM ORCHESTRATION -->' > "$T3/CLAUDE.md"
BEFORE3="$(slurp "$T3/CLAUDE.md")"

OUT3="$(bash "$INSTALL_SH" -y "$T3" 2>&1)"; RC3=$?
BODY3="$(slurp "$T3/CLAUDE.md")"

assert_eq       "append: install exits 0" "0" "$RC3"
assert_contains "append: reports the append"     "$OUT3" "Appended REPO-SKILLS block to CLAUDE.md"
assert_eq       "append: existing content is a byte-identical prefix" \
                "$BEFORE3" "${BODY3:0:${#BEFORE3}}"
assert_contains "append: our BEGIN starts its own line" "$BODY3" "$(printf '\n<!-- BEGIN REPO-SKILLS -->')"
assert_not_contains "append: no adjacency created" "$BODY3" '<!-- END LOOM ORCHESTRATION --><!-- BEGIN REPO-SKILLS -->'

# A second install must take the update path and still leave Loom alone.
bash "$INSTALL_SH" -y "$T3" >/dev/null 2>&1
assert_eq "append: re-install keeps neighbour byte-identical" \
          "$BEFORE3" "$(head_through "$T3/CLAUDE.md" '<!-- END LOOM ORCHESTRATION -->')"

# ---------------------------------------------------------------------------
echo ""
echo "-- install.sh update path: non-adjacent common case unchanged --"

T4="$(new_target non-adjacent)"
cat > "$T4/CLAUDE.md" <<'EOF'
Project notes.

<!-- BEGIN REPO-SKILLS -->
OLD repo skills content line 1
<!-- END REPO-SKILLS -->

<!-- BEGIN LOOM ORCHESTRATION -->
Loom content.
<!-- END LOOM ORCHESTRATION -->
EOF
cat > "$SCRATCH/expected-nonadjacent-tail" <<'EOF'
<!-- BEGIN LOOM ORCHESTRATION -->
Loom content.
<!-- END LOOM ORCHESTRATION -->
EOF

OUT4="$(bash "$INSTALL_SH" -y "$T4" 2>&1)"; RC4=$?
BODY4="$(slurp "$T4/CLAUDE.md")"

assert_eq    "non-adjacent: install exits 0" "0" "$RC4"
tail_from "$T4/CLAUDE.md" '<!-- BEGIN LOOM ORCHESTRATION -->' > "$SCRATCH/actual-nonadjacent-tail"
assert_bytes "non-adjacent: neighbour block byte-identical" \
             "$SCRATCH/actual-nonadjacent-tail" "$SCRATCH/expected-nonadjacent-tail"
assert_contains     "non-adjacent: reports the update"      "$OUT4"  "Updated REPO-SKILLS block in CLAUDE.md"
assert_contains     "non-adjacent: preamble survives"       "$BODY4" "Project notes."
assert_contains     "non-adjacent: block was refreshed"     "$BODY4" "Repo Skills](https://github.com/rjwalters/repo) v$VERSION"
assert_not_contains "non-adjacent: stale block body is gone" "$BODY4" "OLD repo skills content line 1"
assert_contains     "non-adjacent: markers keep their own lines" "$BODY4" "$(printf '\n<!-- END REPO-SKILLS -->\n')"

# ---------------------------------------------------------------------------
echo ""
echo "-- uninstall.sh: adjacency and common case --"

T5="$(new_target uninstall-adjacent)"
fake_installed "$T5"
cat > "$T5/CLAUDE.md" <<'EOF'
Some intro content.

<!-- BEGIN REPO-SKILLS -->
Repo skills pointer body.
<!-- END REPO-SKILLS --><!-- BEGIN LOOM ORCHESTRATION -->
This repository uses Loom for AI-powered development orchestration.
<!-- END LOOM ORCHESTRATION -->

Trailing prose that must survive.
EOF
cat > "$SCRATCH/expected-uninstall-adjacent" <<'EOF'
Some intro content.

<!-- BEGIN LOOM ORCHESTRATION -->
This repository uses Loom for AI-powered development orchestration.
<!-- END LOOM ORCHESTRATION -->

Trailing prose that must survive.
EOF

OUT5="$(bash "$UNINSTALL_SH" -y "$T5" 2>&1)"; RC5=$?
assert_eq    "uninstall adjacent: exits 0" "0" "$RC5"
assert_bytes "uninstall adjacent: everything but our block survives byte-identical" \
             "$T5/CLAUDE.md" "$SCRATCH/expected-uninstall-adjacent"
assert_contains "uninstall adjacent: reports removal" "$OUT5" "Removed REPO-SKILLS block from CLAUDE.md"

T6="$(new_target uninstall-non-adjacent)"
fake_installed "$T6"
cat > "$T6/CLAUDE.md" <<'EOF'
Project notes.

<!-- BEGIN REPO-SKILLS -->
Repo skills pointer body.
<!-- END REPO-SKILLS -->

<!-- BEGIN LOOM ORCHESTRATION -->
Loom content.
<!-- END LOOM ORCHESTRATION -->
EOF
cat > "$SCRATCH/expected-uninstall-non-adjacent" <<'EOF'
Project notes.


<!-- BEGIN LOOM ORCHESTRATION -->
Loom content.
<!-- END LOOM ORCHESTRATION -->
EOF

bash "$UNINSTALL_SH" -y "$T6" >/dev/null 2>&1
assert_bytes "uninstall non-adjacent: whole-line removal (historical behavior)" \
             "$T6/CLAUDE.md" "$SCRATCH/expected-uninstall-non-adjacent"

# ---------------------------------------------------------------------------
echo ""
echo "-- install.sh reconcile_orphaned_block (gitignored destination) --"

T7="$(new_target reconcile-adjacent)"
printf '%s\n' '.claude/' > "$T7/.gitignore"
cat > "$T7/CLAUDE.md" <<'EOF'
Some intro content.

<!-- BEGIN REPO-SKILLS -->
Stale pointer body from an earlier install.
<!-- END REPO-SKILLS --><!-- BEGIN LOOM ORCHESTRATION -->
This repository uses Loom for AI-powered development orchestration.
<!-- END LOOM ORCHESTRATION -->

Trailing prose that must survive.
EOF

OUT7="$(bash "$INSTALL_SH" -y "$T7" 2>&1)"; RC7=$?
assert_eq    "reconcile adjacent: install exits 0" "0" "$RC7"
assert_contains "reconcile adjacent: reports orphan removal" "$OUT7" "Removed orphaned REPO-SKILLS block from CLAUDE.md"
assert_bytes "reconcile adjacent: neighbour + tail survive byte-identical" \
             "$T7/CLAUDE.md" "$SCRATCH/expected-uninstall-adjacent"

T8="$(new_target reconcile-non-adjacent)"
printf '%s\n' '.claude/' > "$T8/.gitignore"
cat > "$T8/CLAUDE.md" <<'EOF'
Project notes.

<!-- BEGIN REPO-SKILLS -->
Stale pointer body from an earlier install.
<!-- END REPO-SKILLS -->

<!-- BEGIN LOOM ORCHESTRATION -->
Loom content.
<!-- END LOOM ORCHESTRATION -->
EOF

bash "$INSTALL_SH" -y "$T8" >/dev/null 2>&1
assert_bytes "reconcile non-adjacent: whole-line removal (historical behavior)" \
             "$T8/CLAUDE.md" "$SCRATCH/expected-uninstall-non-adjacent"

# ---------------------------------------------------------------------------
echo ""
echo "-- guard: unresolvable marker layouts are refused, never guessed --"

T9="$(new_target guard-unterminated)"
cat > "$T9/CLAUDE.md" <<'EOF'
Project notes.

<!-- BEGIN REPO-SKILLS -->
Someone deleted the end marker by hand.

<!-- BEGIN LOOM ORCHESTRATION -->
Loom content.
<!-- END LOOM ORCHESTRATION -->
EOF
BEFORE9="$(slurp "$T9/CLAUDE.md")"

OUT9="$(bash "$INSTALL_SH" -y "$T9" 2>&1)"; RC9=$?
assert_eq       "guard unterminated: install exits non-zero" "1" "$RC9"
assert_contains "guard unterminated: warning names the file" "$OUT9" "$T9/CLAUDE.md"
assert_contains "guard unterminated: explains the refusal"   "$OUT9" "Refusing to update the REPO-SKILLS block"
assert_not_contains "guard unterminated: never claims success" "$OUT9" "Updated REPO-SKILLS block in CLAUDE.md"
assert_eq       "guard unterminated: CLAUDE.md untouched" "$BEFORE9" "$(slurp "$T9/CLAUDE.md")"

T10="$(new_target guard-duplicate)"
cat > "$T10/CLAUDE.md" <<'EOF'
Project notes.

<!-- BEGIN REPO-SKILLS -->
First block.
<!-- END REPO-SKILLS -->

<!-- BEGIN REPO-SKILLS -->
Second block from a botched merge.
<!-- END REPO-SKILLS -->
EOF
BEFORE10="$(slurp "$T10/CLAUDE.md")"

OUT10="$(bash "$INSTALL_SH" -y "$T10" 2>&1)"; RC10=$?
assert_eq       "guard duplicate: install exits non-zero" "1" "$RC10"
assert_contains "guard duplicate: reports the occurrence count" "$OUT10" "found 2 occurrences"
assert_eq       "guard duplicate: CLAUDE.md untouched" "$BEFORE10" "$(slurp "$T10/CLAUDE.md")"

T11="$(new_target guard-uninstall)"
fake_installed "$T11"
cat > "$T11/CLAUDE.md" <<'EOF'
Project notes.

<!-- BEGIN REPO-SKILLS -->
Someone deleted the end marker by hand.

<!-- BEGIN LOOM ORCHESTRATION -->
Loom content.
<!-- END LOOM ORCHESTRATION -->
EOF
BEFORE11="$(slurp "$T11/CLAUDE.md")"

OUT11="$(bash "$UNINSTALL_SH" -y "$T11" 2>&1)"; RC11=$?
assert_eq       "guard uninstall: exits 0 (removal skipped, not fatal)" "0" "$RC11"
assert_contains "guard uninstall: warning names the file" "$OUT11" "$T11/CLAUDE.md"
assert_not_contains "guard uninstall: never claims removal" "$OUT11" "Removed REPO-SKILLS block from CLAUDE.md"
assert_eq       "guard uninstall: CLAUDE.md untouched" "$BEFORE11" "$(slurp "$T11/CLAUDE.md")"

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

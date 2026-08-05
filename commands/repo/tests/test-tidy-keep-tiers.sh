#!/usr/bin/env bash
# Test suite for /repo:tidy's two KEEP sub-cases — the split that stands between
# "this tracked file should have been gitignored" and "this tracked file is
# being parsed as real source right now".
#
# Usage: ./commands/repo/tests/test-tidy-keep-tiers.sh
# Exit code 0 = all tests pass, 1 = failures detected.
#
# Structured like commands/repo/tests/test-early-sync-switch.sh: pure bash, no
# test framework, PASS/FAIL/SKIP/TOTAL counters and a summary block. `pnpm test`
# delegates to this file via hooks/repo/tests/run.sh.
#
# WHY THIS FILE EXISTS (repo#120): a /repo:tidy run on a KiCad repo reported 11
# tracked schematic backups under one undifferentiated KEEP bullet pointing at
# /repo:gitignore. Three of them were named `<stem>_backup_<timestamp>.kicad_sch`
# — a live extension in that tree — so KiCad opened them as real schematic
# sheets and a defect scan counted one backup's contents twice. The other eight
# were `<stem>.kicad_sch.backup-<timestamp>` and were completely inert. The
# pointer was wrong for the three that mattered: gitignoring a file that is
# already tracked and already on disk does not stop any tool from parsing it.
# The only remedy is a deliberate `git rm`, which tidy must PRINT and must never
# RUN (safety rule 1).
#
# The contract under test:
#   1  KEEP has two named sub-cases with opposite remedies: generated (pointer:
#      /repo:gitignore) and name collision (pointer: a printed `git rm` recipe)
#   2  a collision requires BOTH a backup/copy marker in the STEM and a trailing
#      extension that has "real" siblings among other tracked files — the
#      extension list is derived per-repo from `git ls-files`, never hardcoded
#   3  the inert shape (`foo.kicad_sch.backup-<ts>`, where the marker IS the
#      trailing extension) must never be flagged as a collision
#   4  an empty sub-case prints no sub-header — a repo with no collisions is
#      byte-for-byte unchanged from the pre-split output
#   5  the `git rm` recipe is report text only: tidy has no execution path for
#      it, under any flag, and safety rule 1 is unchanged verbatim
#
# Two sections: a fixture section that exercises keep_collision() (a faithful
# transcription of the documented naming heuristic) against real git
# repositories including the motivating 3-harmful/8-inert case, and a doc-drift
# section asserting tidy.md still says what this suite implements — including a
# fence-level guard that no ```bash block in tidy.md contains `git rm`.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CMD_DIR="$REPO_ROOT/commands/repo"

TIDY_MD="$CMD_DIR/tidy.md"

PASS=0
FAIL=0
SKIP=0
TOTAL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

if [[ ! -f "$TIDY_MD" ]]; then
    echo "FATAL: tidy.md not found at $TIDY_MD" >&2
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
# A skipped assertion is neither pass nor fail: the environment cannot exercise
# it. Counted separately and surfaced in the summary so a silently-skipped suite
# is never mistaken for a full pass (repo#46).
skip() {  # <label> <reason>
    SKIP=$((SKIP + 1))
    printf "  ${YELLOW}SKIP${NC}: %s\n" "$1"
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
# The check under test — a direct transcription of the documented heuristic.
# ---------------------------------------------------------------------------

# keep_collision <repo> -> the tracked paths that classify as KEEP (name
#   collision), newline-separated, in `git ls-files` order.
#
#   Mirrors the three conditions in tidy.md step 2's "KEEP (name collision)"
#   sub-case. All three are pure name arithmetic: no file is opened, and the
#   whole candidate AND sibling set come from `git ls-files`, so untracked and
#   gitignored files are structurally out of scope.
#
#     1. the basename carries the substring `backup` / `copy` / `orig` in the
#        STEM (everything before the final `.`), case-insensitively
#     2. the trailing extension has "real" siblings: some OTHER tracked file
#        ends in the same extension and carries no such marker — and the
#        extension does not itself carry a marker (`.orig`, `.backup-<ts>`)
#     3. stripping the trailing MARKER RUN off the stem leaves a non-empty
#        base that is itself tracked, in the same directory, with the same
#        extension — the file this one is a backup *of*
#
#   Condition 2 is what makes the extension list per-repo. A marker-shaped file
#   never counts as its own sibling, so a lone `notes_backup.kicad_sch` in a
#   repo with no real schematics is not a collision.
#
#   Condition 3 is what separates a provenance STAMP from a mere TOPIC. Without
#   it, conditions 1+2 flag any ordinary source file whose name contains the
#   word — `copyright.py`, `BackupManager.ts`, `copy_utils.ts`, `backup.py` —
#   and print a `git rm` recipe for each. See the "ordinary repo" fixture.
keep_collision() {
    local r="$1"
    git -C "$r" ls-files | awk '
        # A stem or an extension is "marked" when it carries one of the three
        # markers as a substring. Inputs are already lowercased, so this is the
        # case-insensitive match condition 1 documents.
        function marked(s) {
            return (index(s, "backup") || index(s, "copy") || index(s, "orig"))
        }
        # base_of(stem) -> the stem with a TRAILING marker run removed, or ""
        # when there is no such run. The run is the separator(s) in front of
        # the marker word, the marker word itself, and any timestamp or copy
        # index (digits and separators) behind it. A marker glued into a longer
        # word (copyright, backupmanager, deepcopy_helpers) is not a run; a
        # marker with nothing in front of it (backup.py, copy_utils.ts) leaves
        # no base. Both cases return "" and are therefore not collisions.
        function base_of(stem,   t) {
            t = stem
            if (sub(/[ ._-]+(backup|copy|orig)[0-9 ._-]*$/, "", t) && t != "")
                return t
            return ""
        }
        {
            path[NR] = $0
            n = split($0, seg, "/")
            base = tolower(seg[n])
            # Everything up to and including the final "/" — condition 3s base
            # sibling must live in the SAME directory.
            dir = tolower(substr($0, 1, length($0) - length(seg[n])))
            # Trailing extension = text after the LAST dot in the basename.
            dot = 0
            for (i = length(base); i > 0; i--)
                if (substr(base, i, 1) == ".") { dot = i; break }
            if (dot == 0) { ext[NR] = ""; stem = base }
            else { ext[NR] = substr(base, dot + 1); stem = substr(base, 1, dot - 1) }
            # Marker must live in the STEM, never in the trailing extension —
            # that is the whole inert-case discriminator.
            marker[NR] = marked(stem) ? 1 : 0
            # Condition 3s lookup key: <dir><base-stem>.<ext>.
            b = base_of(stem)
            sib[NR] = (b == "" || ext[NR] == "") ? "" : dir b "." ext[NR]
            tracked[dir base] = 1
            if (ext[NR] != "" && !marker[NR]) real[ext[NR]] = 1
            total = NR
        }
        END {
            for (i = 1; i <= total; i++)
                if (marker[i] && ext[i] != "" && !marked(ext[i]) \
                    && (ext[i] in real) \
                    && sib[i] != "" && (sib[i] in tracked))
                    print path[i]
        }
    '
}

# render_keep <generated-paths> <collision-paths> -> the KEEP report block.
#   Mirrors tidy.md step 3's sample output, including the rule that a sub-header
#   is printed only when it has entries. Deliberately renders STRINGS: nothing
#   in this function touches git or the filesystem, which is the property the
#   "printed, never executed" fixture below asserts.
render_keep() {
    local gen="$1" col="$2" out="" p
    [[ -z "$gen" && -z "$col" ]] && return 0
    out="KEEP (informational) — tracked files, never deleted by tidy (safety rule 1):"
    if [[ -n "$gen" ]]; then
        out+=$'\n'"  generated — committed build output; stop tracking it going forward:"
        while IFS= read -r p; do
            [[ -n "$p" ]] || continue
            out+=$'\n'"    $p      tracked but looks generated — see /repo:gitignore"
        done <<< "$gen"
    fi
    if [[ -n "$col" ]]; then
        out+=$'\n'"  name collision — tracked AND parsed as real source; gitignoring fixes nothing:"
        while IFS= read -r p; do
            [[ -n "$p" ]] || continue
            out+=$'\n'"    $p"
            out+=$'\n'"      run deliberately (tidy will not run this for you):"
            out+=$'\n'"        git rm $p"
        done <<< "$col"
    fi
    printf '%s\n' "$out"
}

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

# mkrepo <name> -> path to a fresh git repo with the given tracked files
mkrepo() {  # <name> <path>...
    local name="$1"; shift
    local r="$SCRATCH/$name"
    mkdir -p "$r"
    git -C "$r" init -q
    git -C "$r" config user.email t@example.com
    git -C "$r" config user.name Test
    local p
    for p in "$@"; do
        mkdir -p "$r/$(dirname "$p")"
        printf 'content\n' > "$r/$p"
    done
    git -C "$r" add -A >/dev/null 2>&1
    git -C "$r" commit -qm init >/dev/null 2>&1
    printf '%s' "$r"
}

echo "/repo:tidy KEEP sub-case test suite"
echo "=================================="

# ---------------------------------------------------------------------------
echo ""
echo "-- the motivating case: 3 parsed backups vs 8 inert ones (repo#120) --"
# ---------------------------------------------------------------------------
# The exact shape from the field report: 11 tracked schematic backups alongside
# real .kicad_sch sheets. Three carry the live extension; eight do not.
KICAD="$(mkrepo kicad \
    connectors.kicad_sch dac.kicad_sch power.kicad_sch top.kicad_pro \
    connectors_backup_20260427_163100.kicad_sch \
    connectors_backup_20260427_212114.kicad_sch \
    dac_backup_20260427_212043.kicad_sch \
    connectors.kicad_sch.backup-20260427_163100 \
    connectors.kicad_sch.backup-20260427_212114 \
    dac.kicad_sch.backup-20260427_212043 \
    power.kicad_sch.backup-20260427_212043 \
    top.kicad_sch.backup-20260426_090000 \
    a.kicad_sch.backup-20260425_090000 \
    b.kicad_sch.backup-20260424_090000 \
    c.kicad_sch.backup-20260423_090000)"

KICAD_HITS="$(keep_collision "$KICAD")"
assert_eq "exactly the 3 live-extension backups are collisions" "3" \
    "$(printf '%s\n' "$KICAD_HITS" | grep -c . )"
assert_contains "connectors_backup_...163100.kicad_sch is a collision" \
    "$KICAD_HITS" "connectors_backup_20260427_163100.kicad_sch"
assert_contains "connectors_backup_...212114.kicad_sch is a collision" \
    "$KICAD_HITS" "connectors_backup_20260427_212114.kicad_sch"
assert_contains "dac_backup_...212043.kicad_sch is a collision" \
    "$KICAD_HITS" "dac_backup_20260427_212043.kicad_sch"

# The eight inert files: the marker IS the trailing extension, so no
# extension-walking tool ever opens them. Flagging them would bury the signal.
assert_not_contains "inert .kicad_sch.backup-<ts> is NOT a collision" \
    "$KICAD_HITS" "connectors.kicad_sch.backup-20260427_163100"
assert_not_contains "inert dac.kicad_sch.backup-<ts> is NOT a collision" \
    "$KICAD_HITS" "dac.kicad_sch.backup-20260427_212043"
assert_eq "no inert .backup-<ts> file is flagged at all" "0" \
    "$(printf '%s\n' "$KICAD_HITS" | grep -c 'backup-2026' )"

# The real sheets themselves are never collisions — they are the siblings that
# make the extension live in the first place.
assert_eq "a real sheet is not a collision" "0" \
    "$(printf '%s\n' "$KICAD_HITS" | grep -cx 'connectors.kicad_sch')"
assert_eq "no unmarked tracked file is flagged" "0" \
    "$(printf '%s\n' "$KICAD_HITS" | grep -cvE 'backup|copy|\.orig\.' )"

# ---------------------------------------------------------------------------
echo ""
echo "-- condition 2: the extension list is derived, never hardcoded --"
# ---------------------------------------------------------------------------
# The SAME filename in a repo with no real .kicad_sch siblings is just a file.
# This is the property that forbids a global extension table.
LONELY="$(mkrepo lonely README.md src/main.rs \
    connectors_backup_20260427_163100.kicad_sch)"
assert_eq "no real sibling => not a collision" "" "$(keep_collision "$LONELY")"

# Add one real sibling and the same file becomes a collision — nothing else
# about the file changed.
printf 'content\n' > "$LONELY/connectors.kicad_sch"
git -C "$LONELY" add -A >/dev/null 2>&1
git -C "$LONELY" commit -qm sheet >/dev/null 2>&1
assert_eq "one real sibling flips the same file to a collision" \
    "connectors_backup_20260427_163100.kicad_sch" "$(keep_collision "$LONELY")"

# A marker-shaped file is never its own sibling: two backups and no real file
# still is not a collision.
PAIR="$(mkrepo pair README.md \
    sheet_backup_1.kicad_sch sheet_backup_2.kicad_sch)"
assert_eq "marker files do not make each other siblings" "" "$(keep_collision "$PAIR")"

# An extension entirely unknown to any global list still works, because the
# siblings are what define it.
CUSTOM="$(mkrepo custom README.md \
    board.wibble other.wibble board_backup_20260101.wibble)"
assert_eq "an arbitrary repo-local extension is derived correctly" \
    "board_backup_20260101.wibble" "$(keep_collision "$CUSTOM")"

# ---------------------------------------------------------------------------
echo ""
echo "-- condition 1: markers, case-insensitively, in the STEM only --"
# ---------------------------------------------------------------------------
# Every marked file here has its base sibling tracked alongside it
# (Connectors/SHEET/schematic/parser), which is condition 3 — the marker reads
# as a stamp on a file that exists.
#
# This fixture also depends on condition 3's base-sibling lookup being
# case-insensitive (tidy.md documents this explicitly; see keep_collision()
# above, which lowercases both the lookup key and the tracked[] set it is
# checked against): it pairs `Connectors.kicad_sch` / `SHEET.kicad_sch`
# against differently-cased marked files (`Connectors_BACKUP_20260427.kicad_sch`,
# `SHEET_Copy.kicad_sch`). A case-sensitive lookup would silently stop
# matching these pairs — this comment exists so that isn't a surprise later.
MARK="$(mkrepo markers \
    schematic.kicad_sch parser.rs lib.rs notes.md \
    Connectors.kicad_sch SHEET.kicad_sch \
    Connectors_BACKUP_20260427.kicad_sch \
    'schematic copy.kicad_sch' \
    SHEET_Copy.kicad_sch \
    parser.orig.rs)"
MARK_HITS="$(keep_collision "$MARK")"
assert_contains "uppercase BACKUP marker matches (case-insensitive)" \
    "$MARK_HITS" "Connectors_BACKUP_20260427.kicad_sch"
assert_contains "a 'copy' marker matches" "$MARK_HITS" "schematic copy.kicad_sch"
assert_contains "mixed-case 'Copy' matches" "$MARK_HITS" "SHEET_Copy.kicad_sch"
assert_contains "a .orig. component matches" "$MARK_HITS" "parser.orig.rs"
assert_eq "exactly the four marked files are collisions" "4" \
    "$(printf '%s\n' "$MARK_HITS" | grep -c . )"
assert_eq "an unmarked source file is untouched" "0" \
    "$(printf '%s\n' "$MARK_HITS" | grep -cx 'lib.rs')"

# A bare `*.orig` merge leftover is NOT a name collision: `orig` is its trailing
# extension, so nothing parses it as source. It belongs to the SAFE tier's
# merge-leftover rule, a different mechanism entirely.
ORIG="$(mkrepo origonly README.md src/parser.rs src/parser.rs.orig src/lib.rs.orig)"
assert_eq "a bare *.orig leftover is not a name collision" "" "$(keep_collision "$ORIG")"

# ...and that stays true even when `.orig` acquires "real" siblings of its own.
# Unmarked `*.rs.orig` leftovers would otherwise make `orig` look like a live
# source extension, handing `sheet_backup_<ts>.orig` to this rule while the SAFE
# tier's leftover rule already owns that shape. A marker-carrying extension is
# never live, which resolves the overlap in the SAFE tier's favour.
ORIGLIVE="$(mkrepo origlive README.md src/a.rs src/a.rs.orig src/b.rs.orig \
    src/sheet.orig src/sheet_backup_20260101.orig)"
assert_eq "a marker extension (.orig) never becomes a live source extension" "" \
    "$(keep_collision "$ORIGLIVE")"

# The marker must be in the stem of the file's OWN basename, not in a parent
# directory name — a directory called `backups/` does not make its contents
# collisions.
DIRMARK="$(mkrepo dirmark \
    src/sheet.kicad_sch backups/sheet.kicad_sch backups/other.kicad_sch)"
assert_eq "a 'backup' parent directory does not mark its contents" "" \
    "$(keep_collision "$DIRMARK")"

# ---------------------------------------------------------------------------
echo ""
echo "-- condition 3: the marker must be a provenance STAMP, not a topic --"
# ---------------------------------------------------------------------------
# The failure mode conditions 1+2 alone cannot see (judge review, PR #132):
# `backup` and `copy` name a *subject* at least as often as they stamp a copy.
# In this entirely ordinary repo — no backups anywhere in it — conditions 1+2
# flag 8 of 15 files and print a `git rm` recipe for each. Condition 3 requires
# the stem to strip to a tracked base sibling, and none of these do.
#
# The unmarked companions are adversarial on purpose: `utils.ts`, `Manager.ts`,
# `helpers.py` and `strategy.md` are exactly the base siblings a *naive* strip
# (delete the marker word, keep the rest) would find for `copy_utils.ts`,
# `BackupManager.ts`, `deepcopy_helpers.py` and `backup-strategy.md`.
ORD="$(mkrepo ordinary \
    src/main.py src/index.ts docs/readme.md \
    src/utils.ts src/Manager.ts src/helpers.py docs/strategy.md \
    src/backup.py src/copy.py src/copyright.py src/copy_utils.ts \
    src/BackupManager.ts src/useCopyToClipboard.ts src/deepcopy_helpers.py \
    docs/backup-strategy.md)"
ORD_HITS="$(keep_collision "$ORD")"
assert_eq "an ordinary repo with no backups flags nothing at all" "" "$ORD_HITS"
for f in src/backup.py src/copy.py src/copyright.py src/copy_utils.ts \
         src/BackupManager.ts src/useCopyToClipboard.ts \
         src/deepcopy_helpers.py docs/backup-strategy.md; do
    assert_not_contains "$f is a topic, not a stamp — not a collision" \
        "$ORD_HITS" "$f"
done

# The same repo, one real stamp added: it is the ONLY hit. The rule discriminates
# within a single tree rather than by refusing to fire.
printf 'content\n' > "$ORD/src/main_backup_20260101.py"
git -C "$ORD" add -A >/dev/null 2>&1
git -C "$ORD" commit -qm stamp >/dev/null 2>&1
assert_eq "a real stamp in the same repo is still flagged, and alone" \
    "src/main_backup_20260101.py" "$(keep_collision "$ORD")"

# Stamp shapes that DO strip to a base sibling, one per separator style.
STAMPS="$(mkrepo stamps \
    'sheet.kicad_sch' 'sheet - Copy 2.kicad_sch' \
    'board.kicad_sch' 'board.copy.kicad_sch' \
    'panel.kicad_sch' 'panel-backup-20260101.kicad_sch')"
assert_eq "space/hyphen/dot separators and a copy index all strip correctly" "3" \
    "$(keep_collision "$STAMPS" | grep -c . )"

# The base sibling must be in the SAME directory: a same-named file somewhere
# else in the tree is a coincidence, which is what condition 3 exists to reject.
CROSS="$(mkrepo crossdir \
    hw/sheet.kicad_sch hw/other.kicad_sch src/sheet_backup_20260101.kicad_sch)"
assert_eq "a base sibling in another directory does not count" "" \
    "$(keep_collision "$CROSS")"
printf 'content\n' > "$CROSS/src/sheet.kicad_sch"
git -C "$CROSS" add -A >/dev/null 2>&1
git -C "$CROSS" commit -qm sib >/dev/null 2>&1
assert_eq "the base sibling next to it does count" \
    "src/sheet_backup_20260101.kicad_sch" "$(keep_collision "$CROSS")"

# The documented false negative, pinned so it stays a deliberate trade rather
# than a surprise: delete the base file and the backup drops out of this
# sub-case (it stays reportable as `generated`, which needs no base sibling).
GONE="$(mkrepo basegone \
    src/sheet.kicad_sch src/other.kicad_sch src/sheet_backup_20260101.kicad_sch)"
assert_eq "with the base file present, the backup is a collision" \
    "src/sheet_backup_20260101.kicad_sch" "$(keep_collision "$GONE")"
git -C "$GONE" rm -q src/sheet.kicad_sch >/dev/null 2>&1
git -C "$GONE" commit -qm "drop base" >/dev/null 2>&1
assert_eq "with the base file gone, precision wins over recall" "" \
    "$(keep_collision "$GONE")"

# ---------------------------------------------------------------------------
echo ""
echo "-- scope: tracked files only --"
# ---------------------------------------------------------------------------
# An untracked collision-shaped file is another tier's problem (ASK), and an
# ignored one is CACHE/SAFE/ASK. Neither is KEEP, which is tracked-only.
SCOPE="$(mkrepo scope README.md sheet.kicad_sch .gitignore)"
printf 'ignored_backup.kicad_sch\n' > "$SCOPE/.gitignore"
git -C "$SCOPE" add -A >/dev/null 2>&1
git -C "$SCOPE" commit -qm ignore >/dev/null 2>&1
printf 'content\n' > "$SCOPE/untracked_backup.kicad_sch"
printf 'content\n' > "$SCOPE/ignored_backup.kicad_sch"
SCOPE_HITS="$(keep_collision "$SCOPE")"
assert_not_contains "an untracked collision-shaped file is not KEEP" \
    "$SCOPE_HITS" "untracked_backup.kicad_sch"
assert_not_contains "a gitignored collision-shaped file is not KEEP" \
    "$SCOPE_HITS" "ignored_backup.kicad_sch"
assert_eq "tracked-only scope yields nothing here" "" "$SCOPE_HITS"

# ---------------------------------------------------------------------------
echo ""
echo "-- report: two sub-cases, and no empty sub-header --"
# ---------------------------------------------------------------------------
BOTH="$(render_keep "assets/build.min.js" "connectors_backup_20260427_163100.kicad_sch")"
assert_contains "both-populated report names the generated sub-case" "$BOTH" "generated —"
assert_contains "generated sub-case points at /repo:gitignore" \
    "$BOTH" "see /repo:gitignore"
assert_contains "both-populated report names the collision sub-case" \
    "$BOTH" "name collision —"
assert_contains "collision sub-case states gitignoring fixes nothing" \
    "$BOTH" "gitignoring fixes nothing"
assert_contains "collision sub-case prints a literal git rm recipe" \
    "$BOTH" "git rm connectors_backup_20260427_163100.kicad_sch"
assert_contains "the recipe is framed as the operator's to run" \
    "$BOTH" "run deliberately (tidy will not run this for you)"
# The two remedies must be visually distinguishable, not one flat list.
assert_eq "the two sub-headers are separate lines" "2" \
    "$(printf '%s\n' "$BOTH" | grep -cE '^  (generated|name collision) —')"

# Empty-suppression, both directions.
GEN_ONLY="$(render_keep "assets/build.min.js" "")"
assert_contains "generated-only report still prints the generated block" \
    "$GEN_ONLY" "generated —"
assert_not_contains "generated-only report prints NO name-collision header" \
    "$GEN_ONLY" "name collision"
assert_not_contains "generated-only report prints no git rm line" \
    "$GEN_ONLY" "git rm"
COL_ONLY="$(render_keep "" "sheet_backup.kicad_sch")"
assert_contains "collision-only report prints the collision block" \
    "$COL_ONLY" "name collision —"
assert_not_contains "collision-only report prints NO generated header" \
    "$COL_ONLY" "generated —"
assert_eq "an empty KEEP tier prints nothing at all" "" "$(render_keep "" "")"

# ---------------------------------------------------------------------------
echo ""
echo "-- printed, never executed: the recipe does not remove anything --"
# ---------------------------------------------------------------------------
# Safety rule 1 in fixture form: rendering the report for a real repo leaves the
# flagged file present on disk AND still tracked. If a future change ever wires
# the recipe to an execution path, this is what fails.
EXEC="$(mkrepo execcheck sheet.kicad_sch sheet_backup_20260101.kicad_sch)"
EXEC_HITS="$(keep_collision "$EXEC")"
EXEC_REPORT="$(render_keep "" "$EXEC_HITS")"
assert_contains "the report contains the git rm string" \
    "$EXEC_REPORT" "git rm sheet_backup_20260101.kicad_sch"
assert_eq "the flagged file is still on disk after reporting" "present" \
    "$([[ -f "$EXEC/sheet_backup_20260101.kicad_sch" ]] && echo present || echo gone)"
assert_eq "the flagged file is still tracked after reporting" "tracked" \
    "$(git -C "$EXEC" ls-files --error-unmatch sheet_backup_20260101.kicad_sch \
        >/dev/null 2>&1 && echo tracked || echo untracked)"
assert_eq "reporting staged no deletion" "" "$(git -C "$EXEC" status --porcelain)"

# ---------------------------------------------------------------------------
echo ""
echo "-- doc drift: tidy.md still specifies what this suite implements --"
# ---------------------------------------------------------------------------
# Phrases are asserted against a whitespace-flattened copy, since the
# requirement is prose that wraps across lines.
flatten() { tr '\n' ' ' < "$1" | tr -s ' '; }
TIDY="$(flatten "$TIDY_MD")"

assert_contains "tidy.md names the KEEP (generated) sub-case" \
    "$TIDY" '**KEEP (generated)**'
assert_contains "tidy.md names the KEEP (name collision) sub-case" \
    "$TIDY" '**KEEP (name collision)**'
# The collapsed single-bullet form this issue replaced must not come back.
assert_not_contains "the collapsed one-bullet KEEP definition is gone" \
    "$TIDY" 'tracked files that look like they don'"'"'t belong (build output that got committed'
assert_contains "tidy.md says the two remedies are opposite" \
    "$TIDY" 'whose remedies are **opposite**'
assert_contains "the generated sub-case still points at gitignore" \
    "$TIDY" 'which is [[gitignore]]'"'"'s job — point there'
assert_contains "the collision sub-case says gitignore is the WRONG pointer" \
    "$TIDY" '[[gitignore]] is the **wrong** pointer for it'
assert_contains "tidy.md explains why an ignore rule cannot help" \
    "$TIDY" 'already tracked, already on disk, and already being parsed'
assert_contains "the collision remedy is a deliberate git rm" \
    "$TIDY" 'The only remedy is a deliberate `git rm`'

assert_contains "detection is a naming heuristic, not a content check" \
    "$TIDY" 'naming heuristic, not a content check'
assert_contains "detection is scoped to tracked files" \
    "$TIDY" 'It runs over **tracked files only**'
assert_contains "detection draws its sets from git ls-files" "$TIDY" 'git ls-files'
assert_contains "detection requires all three conditions" \
    "$TIDY" 'A tracked file is a name collision when **all three** conditions hold'
assert_contains "condition 1 requires the marker in the stem" \
    "$TIDY" 'backup/copy marker **in the stem — before the final `.`**'
assert_contains "condition 1 names the three markers" \
    "$TIDY" 'the substring `backup`, `copy`, or `orig`'
assert_contains "condition 1 is case-insensitive" "$TIDY" '**case-insensitively**'
assert_contains "condition 2 requires real siblings" \
    "$TIDY" 'Its trailing extension has **real siblings**'
assert_contains "condition 2 requires the sibling to be a DIFFERENT file" \
    "$TIDY" 'at least one *other* tracked file ends in the same'
assert_contains "the extension list is per-repo, never hardcoded" \
    "$TIDY" 'Never match against a hardcoded global extension list'
# A marker-carrying extension is never live — the tie-break that keeps this rule
# from claiming the SAFE tier's `*.orig` merge leftovers.
assert_contains "condition 2 excludes marker-carrying extensions" \
    "$TIDY" '**An extension that itself carries a marker is never live**'
assert_contains "the *.orig overlap is resolved in SAFE's favour" \
    "$TIDY" 'a `*.orig` merge leftover is the SAFE tier'"'"'s leftover rule, not this one'
# Condition 3: the stamp-vs-topic test.
assert_contains "condition 3 demands a provenance stamp on an existing file" \
    "$TIDY" 'The marker reads as a **provenance stamp on an existing file**'
assert_contains "condition 3 strips a marker run off the end of the stem" \
    "$TIDY" 'Strip the **marker run** off the *end* of the stem'
assert_contains "the marker run includes the separator and any timestamp" \
    "$TIDY" 'the separator run (space, `_`, `-`, `.`) in front of it, and any timestamp or copy index (digits and separators) behind it'
assert_contains "condition 3 requires a tracked base sibling in the same dir" \
    "$TIDY" 'another tracked file `<base>.<ext>`, same extension, **same directory**'
assert_contains "the base sibling is the file this one is a copy of" \
    "$TIDY" 'the file this one is a copy *of*; if it cannot be named, this is not a collision'
assert_contains "condition 3 is framed as stamp vs topic" \
    "$TIDY" 'Condition 3 is what tells a **stamp** from a **topic**'
assert_contains "tidy.md names backup.py / copy.py as non-collisions" \
    "$TIDY" '`src/backup.py` and `src/copy.py` strip to nothing'
assert_contains "tidy.md names the glued-word false positives" \
    "$TIDY" '`copyright.py`, `BackupManager.ts`, `useCopyToClipboard.ts` and `deepcopy_helpers.py` have no marker *run* at all'
assert_contains "tidy.md names the leading-marker false positive" \
    "$TIDY" '`copy_utils.ts` carries the marker at the **front**'
assert_contains "tidy.md states what a wrong git rm costs" \
    "$TIDY" 'the one recipe in `/repo:tidy` that costs a source file'
assert_contains "the recall trade is documented, not accidental" \
    "$TIDY" 'The trade is deliberate — precision bought with recall'
assert_contains "a stamp with no base sibling is not lost, only demoted" \
    "$TIDY" 'it stays in the **generated** sub-case with the [[gitignore]] pointer'
assert_contains "tidy.md names the inert shape as a non-collision" \
    "$TIDY" '`connectors.kicad_sch.backup-20260427_163100` does **not** collide'
assert_contains "tidy.md explains why the inert shape is inert" \
    "$TIDY" 'the marker *is* the extension rather than part of the stem'

assert_contains "the recipe is copy-pasteable and literal" \
    "$TIDY" 'copy-pasteable `git rm <path>` line'
assert_contains "the recipe carries a one-line reason" \
    "$TIDY" 'plus a one-line reason naming the tool'
# The reason may only restate what conditions 2 and 3 established — the guard
# against a templated `why:` line asserting something false about a file that
# is not a backup of anything.
assert_contains "the reason is written from conditions 2 and 3 only" \
    "$TIDY" 'The reason is only ever written from what conditions 2 and 3 established'
assert_contains "an unwritable reason means the file is not reported" \
    "$TIDY" 'the file is not a collision and must not be reported here**'
assert_contains "tidy may never claim an unnamed base file" \
    "$TIDY" 'never assert that a file is a backup of something tidy could not name'
assert_contains "the sample why: line names the base sibling" \
    "$TIDY" 'why: backup of connectors.kicad_sch'
assert_contains "tidy.md forbids running the recipe" \
    "$TIDY" 'it never runs `git rm`, never stages it, and never offers to run it'
assert_contains "the ban on running it covers every flag" \
    "$TIDY" 'not under `--ask`, `--apply`, or any other flag'
assert_contains "KEEP is excluded from the apply step" \
    "$TIDY" '**KEEP is never part of the apply step, under any flag.**'
assert_contains "empty sub-headers are suppressed" \
    "$TIDY" 'Print each sub-header **only when it has entries**'
assert_contains "the sample report shows the generated sub-block" \
    "$TIDY" 'generated — committed build output; stop tracking it going forward:'
assert_contains "the sample report shows the collision sub-block" \
    "$TIDY" 'name collision — tracked AND parsed as real source; gitignoring fixes nothing:'
assert_contains "the sample report shows the printed git rm line" \
    "$TIDY" 'git rm connectors_backup_20260427_163100.kicad_sch'
assert_contains "the sample report frames the recipe as the operator's" \
    "$TIDY" 'run deliberately (tidy will not run this for you)'
assert_contains "the sample report explains the distinct formatting" \
    "$TIDY" 'The two KEEP sub-blocks are formatted differently on purpose'

# Safety rule 1 must survive verbatim, on its own line — this issue changed how
# tracked files are REPORTED, never whether they are deleted.
assert_contains "safety rule 1 is unchanged verbatim" \
    "$(cat "$TIDY_MD")" \
    "1. **Never delete tracked files** — that's a git operation the user does deliberately"
# Scope guard mirrored from commands/repo/tests/test-verify-fix-persistence.sh:
# tidy writes no tracked-file state, so it has no verify-after-write step. A
# printed recipe does not change that; an executed one would.
assert_not_contains "tidy.md still has no verify-after-write step" \
    "$TIDY" '### Verify after write'

# ---------------------------------------------------------------------------
echo ""
echo "-- fence guard: no \`git rm\` is ever a shelled-out command --"
# ---------------------------------------------------------------------------
# The prose guards above are assertions about intent; this one is about
# mechanism. tidy.md's executable recipes live in ```bash fences and its sample
# output lives in unlabeled ``` fences. `git rm` may appear in the sample output
# and in prose, but a ```bash fence is the one place it would actually be run.
#
# Fences are matched after stripping leading indentation, since a fence nested
# inside a list item (the `git ls-files` block) is indented.
fence_lines() {  # <file> <language|"">
    awk -v want="$2" '
        {
            t = $0
            sub(/^[ \t]+/, "", t)
            sub(/[ \t]+$/, "", t)
            if (t ~ /^```/) {
                if (!inf) { inf = 1; lang = substr(t, 4); next }
                inf = 0; lang = ""; next
            }
            if (inf && lang == want) print
        }
    ' "$1"
}
BASH_FENCES="$(fence_lines "$TIDY_MD" bash)"
PLAIN_FENCES="$(fence_lines "$TIDY_MD" "")"

assert_eq "no \`\`\`bash fence in tidy.md contains 'git rm'" "0" \
    "$(printf '%s\n' "$BASH_FENCES" | grep -c 'git rm')"
assert_contains "the bash fences do contain the git ls-files detection source" \
    "$BASH_FENCES" "git ls-files"
assert_contains "the sample-output fence carries the printed recipe" \
    "$PLAIN_FENCES" "git rm connectors_backup_20260427_163100.kicad_sch"
# Every `git rm` in the file is therefore either sample output or prose.
assert_eq "every 'git rm' line is prose or sample output" "0" \
    "$(printf '%s\n' "$BASH_FENCES" | grep -c 'git rm')"

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

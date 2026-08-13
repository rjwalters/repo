#!/usr/bin/env bash
# Regression suite for the Codex-side skill surface (.agents/skills/repo/).
#
# Usage: ./hooks/repo/tests/test-install-codex-skill.sh
# Exit code 0 = all tests pass, 1 = failures detected.
#
# Structured like test-install-sidecar-untracking.sh next door: pure bash, no
# test framework, PASS/FAIL counters and a summary block, scratch git repos the
# real install.sh / uninstall.sh / resync-installed.sh are driven against.
#
# WHAT IS UNDER TEST (repo#285): install.sh packaged skills and commands for
# Claude Code only. Codex CLI discovers skills from a repo-scoped
# `.agents/skills/<name>/SKILL.md` in the open Agent Skills format — see
# lib/codex-skill.sh's header for the citations — so the installer now writes
# that surface too, the uninstaller removes it, and the C7 resync detects drift
# in it.
#
# The contract asserted below:
#   FORMAT     - the installed SKILL.md satisfies the parts of the Agent Skills
#                spec that are mechanically checkable: a lowercase-slug `name`
#                matching its parent directory, a non-empty `description` under
#                the length cap, and none of the Claude-Code-specific frontmatter
#                keys skills/README.md classifies as non-portable
#   NO DUPES   - the workflow body is the canonical skills/repo/SKILL.md body and
#                the per-verb procedures are the same commands/repo/*.md files,
#                not a second copy rewritten for Codex (#282's core criterion)
#   OWNERSHIP  - `.agents/skills/` is a shared namespace, so a hand-authored
#                `repo` skill is never overwritten by install nor deleted by
#                uninstall, and a sibling skill is untouched by either
#   LIFECYCLE  - install is idempotent, honors --skills= and --no-codex, is a
#                strict no-op under --dry-run, and uninstall prunes only the
#                directories it emptied
#   DRIFT      - resync-installed.sh reports and repairs drift in the Codex
#                surface, and never ADOPTS it into an install that declined it

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
UNINSTALL_SH="$REPO_ROOT/uninstall.sh"
SRC_SKILL="$REPO_ROOT/skills/repo/SKILL.md"

CODEX_REL=".agents/skills/repo"
CODEX_REFS_REL="$CODEX_REL/references"
MARKER='<!-- repo-skills:codex-managed -->'

PASS=0
FAIL=0
TOTAL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

for f in "$INSTALL_SH" "$UNINSTALL_SH" "$SRC_SKILL"; do
    if [[ ! -f "$f" ]]; then
        echo "FATAL: required file not found at $f" >&2
        exit 1
    fi
done

SCRATCH="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$SCRATCH"' EXIT
# install.sh's shell-wrapper step is a strict no-op under -y, but point HOME at
# the scratch tree anyway so a regression there cannot touch the developer's rc.
FAKE_HOME="$SCRATCH/home"
mkdir -p "$FAKE_HOME"

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
assert_file() {  # <label> <path>
    if [[ -f "$2" ]]; then ok "$1"; else no "$1" "no such file: $2"; fi
}
assert_absent() {  # <label> <path>
    if [[ ! -e "$2" ]]; then ok "$1"; else no "$1" "unexpectedly present: $2"; fi
}

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

g() {  # <repo> <git args...>
    local r="$1"; shift
    git -C "$r" -c user.email=test@example.com -c user.name='Repo Skills Test' \
        -c commit.gpgsign=false "$@"
}

new_target() {  # <name> -> prints the target path
    local t="$SCRATCH/$1"
    mkdir -p "$t"
    git init -q "$t" 2>/dev/null
    printf '%s\n' '# scratch' > "$t/README.md"
    g "$t" add README.md
    g "$t" commit -q -m "initial"
    printf '%s' "$t"
}

install_into() {  # <target> [extra install.sh args...] -> prints combined output
    local t="$1"; shift
    HOME="$FAKE_HOME" bash "$INSTALL_SH" -y "$@" "$t" 2>&1
}

# The value of a frontmatter key in a SKILL.md, double quotes stripped.
fm() {  # <file> <key>
    awk -v key="$2" '
        NR == 1 && $0 != "---" { exit }
        NR == 1 { next }
        $0 == "---" { exit }
        {
            i = index($0, ":")
            if (i > 0) {
                k = substr($0, 1, i - 1); v = substr($0, i + 1)
                gsub(/^[ \t]+|[ \t]+$/, "", k); gsub(/^[ \t]+|[ \t]+$/, "", v)
                if (k == key) {
                    if (length(v) > 1 && substr(v, 1, 1) == "\"" && substr(v, length(v), 1) == "\"")
                        v = substr(v, 2, length(v) - 2)
                    print v; exit
                }
            }
        }
    ' "$1"
}

# Everything after the leading frontmatter block, with leading blank lines and
# the generated provenance comments dropped, so two bodies can be compared.
body_of() {  # <file>
    awk 'seen == 2 { print } /^---$/ { seen++ }' "$1" \
        | grep -vF "$MARKER" \
        | grep -v '^<!-- Generated by Repo Skills install.sh' \
        | sed '/./,$!d'
}

# A tree manifest (path + content checksum + symlink targets) for the
# "changed nothing" assertions.
fingerprint() {  # <dir>
    [[ -d "$1" ]] || { echo "ABSENT"; return; }
    ( cd "$1" && find . \( -type f -o -type l \) | LC_ALL=C sort | while IFS= read -r f; do
        if [[ -L "$f" ]]; then printf '%s SYMLINK %s\n' "$f" "$(readlink "$f")"
        else printf '%s %s\n' "$f" "$(cksum <"$f")"; fi
      done )
}

# ===========================================================================
echo "install.sh Codex skill surface suite"
echo "===================================="

# ---------------------------------------------------------------------------
echo ""
echo "-- the installed SKILL.md conforms to the Agent Skills format --"

T1="$(new_target format)"
OUT1="$(install_into "$T1")"; RC1=$?

assert_eq   "install exits 0" "0" "$RC1"
assert_file "SKILL.md lands at the Codex-scanned path" "$T1/$CODEX_REL/SKILL.md"
assert_contains "install reports the Codex SKILL.md" "$OUT1" "Installed $CODEX_REL/SKILL.md"
assert_contains "install reports the command procedures" "$OUT1" "command procedures into $CODEX_REFS_REL/"

CODEX_MD="$T1/$CODEX_REL/SKILL.md"
NAME="$(fm "$CODEX_MD" name)"
DESC="$(fm "$CODEX_MD" description)"

# The spec's `name` rules: 1-64 chars, lowercase a-z0-9 and hyphens, no leading,
# trailing or consecutive hyphens, and it MUST equal the parent directory name.
if [[ "$NAME" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
    ok "name is a lowercase alphanumeric/hyphen slug"
else
    no "name is a lowercase alphanumeric/hyphen slug" "got [$NAME]"
fi
assert_not_contains "name has no consecutive hyphens" "$NAME" "--"
if [[ ${#NAME} -ge 1 && ${#NAME} -le 64 ]]; then
    ok "name is within the 64-character cap"
else
    no "name is within the 64-character cap" "length ${#NAME}"
fi
assert_eq "name equals the parent directory name" "$(basename "$T1/$CODEX_REL")" "$NAME"

# The source's own `name` is NOT a legal slug — that is precisely why the Codex
# copy is rendered rather than copied. Pin it so a future edit to the source
# frontmatter cannot make this adaptation look unnecessary without being noticed.
SRC_NAME="$(fm "$SRC_SKILL" name)"
if [[ ! "$SRC_NAME" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
    ok "the canonical source name is not a legal slug (so the render is load-bearing)"
else
    ok "the canonical source name is already a legal slug (render is a no-op adaptation)"
fi

assert_eq "description is copied verbatim from the canonical source" \
          "$(fm "$SRC_SKILL" description)" "$DESC"
if [[ -n "$DESC" && ${#DESC} -le 1024 ]]; then
    ok "description is non-empty and within the 1024-character cap"
else
    no "description is non-empty and within the 1024-character cap" "length ${#DESC}"
fi

CODEX_FM="$(awk 'NR > 1 && /^---$/ { exit } NR > 1 { print }' "$CODEX_MD")"
assert_not_contains "Claude-specific 'type' is not passed through"           "$CODEX_FM" "type:"
assert_not_contains "Claude-specific 'user-invocable' is not passed through" "$CODEX_FM" "user-invocable:"
assert_contains     "domain is carried forward under the spec's metadata map" "$CODEX_FM" "metadata:"
assert_contains     "domain value survives"                                   "$CODEX_FM" "domain: \"repo\""
assert_contains     "the ownership marker is written"  "$(cat "$CODEX_MD")" "$MARKER"

# ---------------------------------------------------------------------------
echo ""
echo "-- one canonical procedure body, packaged twice (not duplicated) --"

assert_eq "the Codex body is the canonical SKILL.md body" \
          "$(body_of "$T1/.claude/skills/repo/SKILL.md")" \
          "$(body_of "$CODEX_MD" | sed '/^## Command procedures$/,$d' | sed -e :a -e '/^$/{$d;N;ba' -e '}')"

REF_MISMATCH=""
for c in help tidy reset followups; do
    if ! cmp -s "$T1/$CODEX_REFS_REL/$c.md" "$T1/.claude/commands/repo/$c.md"; then
        REF_MISMATCH="$REF_MISMATCH $c"
    fi
done
assert_eq "reference procedures are byte-identical to the Claude command files" "" "$REF_MISMATCH"

# The reference files hold the procedures; SKILL.md points at them. If a verb's
# procedure text were inlined into SKILL.md too, that would be the duplication
# #282 exists to prevent.
TIDY_MARKER="$(grep -m1 '^## ' "$T1/.claude/commands/repo/tidy.md" | head -c 60)"
if [[ -n "$TIDY_MARKER" ]]; then
    assert_not_contains "a verb's procedure is not inlined into SKILL.md" \
                        "$(cat "$CODEX_MD")" "$TIDY_MARKER"
else
    no "a verb's procedure is not inlined into SKILL.md" "could not derive a probe line from tidy.md"
fi
assert_contains "SKILL.md points at the reference files instead" \
                "$(cat "$CODEX_MD")" '`references/tidy.md`'

CMD_COUNT="$(find "$REPO_ROOT/commands/repo" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')"
REF_COUNT="$(find "$T1/$CODEX_REFS_REL" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')"
assert_eq "every command ships a reference procedure" "$CMD_COUNT" "$REF_COUNT"

assert_file "the Codex surface carries its own tracked metadata" "$T1/$CODEX_REL/install-metadata.json"
META1="$(cat "$T1/$CODEX_REL/install-metadata.json" 2>/dev/null)"
assert_contains "metadata records the version"      "$META1" '"version"'
assert_contains "metadata records the layout"       "$META1" '"layout_version"'
assert_not_contains "metadata embeds no source path"  "$META1" '"source"'
assert_not_contains "metadata embeds no timestamp"    "$META1" '"installed_at"'
assert_absent "no second machine-local sidecar is written" "$T1/$CODEX_REL/.install-local.json"

# ---------------------------------------------------------------------------
echo ""
echo "-- re-installing is idempotent --"

FP_BEFORE="$(fingerprint "$T1/.agents")"
install_into "$T1" >/dev/null
assert_eq "a second install leaves the Codex surface byte-identical" \
          "$FP_BEFORE" "$(fingerprint "$T1/.agents")"

# ---------------------------------------------------------------------------
echo ""
echo "-- --skills= installs a subset, --no-codex installs none --"

T2="$(new_target filtered)"
install_into "$T2" --skills=tidy,reset >/dev/null
assert_file   "filtered: the selected verb ships"      "$T2/$CODEX_REFS_REL/tidy.md"
assert_file   "filtered: help always ships"            "$T2/$CODEX_REFS_REL/help.md"
assert_absent "filtered: an unselected verb does not"  "$T2/$CODEX_REFS_REL/followups.md"
assert_eq     "filtered: exactly the selected verbs" "3" \
              "$(find "$T2/$CODEX_REFS_REL" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')"
assert_not_contains "filtered: SKILL.md does not advertise an unselected verb" \
                    "$(cat "$T2/$CODEX_REL/SKILL.md")" '`references/followups.md`'

T3="$(new_target no-codex)"
OUT3="$(install_into "$T3" --no-codex)"
assert_absent   "--no-codex writes nothing under .agents/" "$T3/.agents"
assert_contains "--no-codex says so"                       "$OUT3" "Skipping the Codex skill surface"
assert_file     "--no-codex still installs the Claude surface" "$T3/.claude/skills/repo/SKILL.md"

# ---------------------------------------------------------------------------
echo ""
echo "-- --dry-run enumerates the Codex writes and performs none --"

T4="$(new_target dry-run)"
FP4="$(fingerprint "$T4")"
OUT4="$(HOME="$FAKE_HOME" bash "$INSTALL_SH" --dry-run "$T4" 2>&1)"; RC4=$?
assert_eq       "--dry-run exits 0" "0" "$RC4"
assert_contains "--dry-run names the SKILL.md destination"  "$OUT4" "$T4/$CODEX_REL/SKILL.md"
assert_contains "--dry-run names the metadata destination"  "$OUT4" "$T4/$CODEX_REL/install-metadata.json"
assert_contains "--dry-run names a reference destination"   "$OUT4" "$T4/$CODEX_REFS_REL/tidy.md"
assert_eq       "--dry-run leaves the target byte-identical" "$FP4" "$(fingerprint "$T4")"
assert_absent   "--dry-run creates no .agents directory"     "$T4/.agents"

OUT4B="$(HOME="$FAKE_HOME" bash "$INSTALL_SH" --dry-run --no-codex "$T4" 2>&1)"
assert_contains "--dry-run --no-codex says the surface is skipped" "$OUT4B" "--no-codex given"

# ---------------------------------------------------------------------------
echo ""
echo "-- ownership: a hand-authored 'repo' skill is never clobbered --"

T5="$(new_target foreign)"
mkdir -p "$T5/$CODEX_REL"
printf -- '---\nname: repo\ndescription: hand authored by the consumer\n---\n\nMY OWN CONTENT\n' \
    > "$T5/$CODEX_REL/SKILL.md"
FOREIGN_FP="$(fingerprint "$T5/.agents")"

OUT5="$(install_into "$T5")"; RC5=$?
assert_eq       "foreign: install still exits 0"             "0" "$RC5"
assert_eq       "foreign: the .agents tree is untouched"     "$FOREIGN_FP" "$(fingerprint "$T5/.agents")"
assert_contains "foreign: install explains the skip"         "$OUT5" "carries no Repo Skills marker"
assert_file     "foreign: the Claude surface installed anyway" "$T5/.claude/skills/repo/SKILL.md"
assert_absent   "foreign: no references directory was created" "$T5/$CODEX_REFS_REL"

OUT5B="$(HOME="$FAKE_HOME" bash "$UNINSTALL_SH" -y "$T5" 2>&1)"
assert_eq       "foreign: uninstall leaves the .agents tree untouched" \
                "$FOREIGN_FP" "$(fingerprint "$T5/.agents")"
assert_contains "foreign: uninstall says what it left"       "$OUT5B" "Left $CODEX_REL/ in place"

# ---------------------------------------------------------------------------
echo ""
echo "-- uninstall removes our skill, and only ours --"

T6="$(new_target uninstall-sibling)"
install_into "$T6" >/dev/null
mkdir -p "$T6/.agents/skills/other"
printf -- '---\nname: other\ndescription: someone else\n---\n\nOTHER\n' \
    > "$T6/.agents/skills/other/SKILL.md"
SIBLING_FP="$(fingerprint "$T6/.agents/skills/other")"

OUT6="$(HOME="$FAKE_HOME" bash "$UNINSTALL_SH" -y "$T6" 2>&1)"; RC6=$?
assert_eq       "uninstall exits 0"                       "0" "$RC6"
assert_contains "uninstall lists the Codex skill"         "$OUT6" "$CODEX_REL/"
assert_absent   "uninstall removed the Codex skill dir"   "$T6/$CODEX_REL"
assert_eq       "uninstall left the sibling skill intact" \
                "$SIBLING_FP" "$(fingerprint "$T6/.agents/skills/other")"
if [[ -d "$T6/.agents/skills" ]]; then
    ok "uninstall kept the shared .agents/skills/ directory (a sibling lives there)"
else
    no "uninstall kept the shared .agents/skills/ directory (a sibling lives there)"
fi

T7="$(new_target uninstall-prunes)"
install_into "$T7" >/dev/null
HOME="$FAKE_HOME" bash "$UNINSTALL_SH" -y "$T7" >/dev/null 2>&1
assert_absent "uninstall prunes .agents/ when it emptied it" "$T7/.agents"

# Uninstall must also work when ONLY the Codex surface is present (a Claude-side
# removal already happened, or someone deleted .claude/ by hand).
T8="$(new_target uninstall-codex-only)"
install_into "$T8" >/dev/null
rm -rf "$T8/.claude"
OUT8="$(HOME="$FAKE_HOME" bash "$UNINSTALL_SH" -y "$T8" 2>&1)"
assert_absent   "codex-only: the skill directory is removed" "$T8/$CODEX_REL"
assert_not_contains "codex-only: not reported as 'no install found'" "$OUT8" "No Repo Skills install found"

# ---------------------------------------------------------------------------
echo ""
echo "-- drift detection: the C7 resync covers the Codex surface --"

T9="$(new_target drift)"
install_into "$T9" >/dev/null
RESYNC="$T9/.claude/skills/repo/scripts/resync-installed.sh"

bash "$RESYNC" --dry-run --target "$T9" >/dev/null 2>&1
assert_eq "a fresh install reports no drift (exit 0)" "0" "$?"

printf '%s\n' 'drifted' >> "$T9/$CODEX_REL/SKILL.md"
rm -f "$T9/$CODEX_REFS_REL/tidy.md"
DRIFT_OUT="$(bash "$RESYNC" --dry-run --target "$T9" 2>&1)"; DRIFT_RC=$?
assert_eq       "--dry-run exits 2 when the Codex surface drifted" "2" "$DRIFT_RC"
assert_contains "--dry-run names the drifted SKILL.md"   "$DRIFT_OUT" "would sync $CODEX_REL/SKILL.md"
assert_contains "--dry-run names the missing reference"  "$DRIFT_OUT" "would add $CODEX_REFS_REL/tidy.md"
if grep -qF 'drifted' "$T9/$CODEX_REL/SKILL.md"; then
    ok "--dry-run repaired nothing"
else
    no "--dry-run repaired nothing" "the dry run wrote to the target"
fi

APPLY_OUT="$(bash "$RESYNC" --target "$T9" 2>&1)"; APPLY_RC=$?
assert_eq       "applying the resync exits 0"           "0" "$APPLY_RC"
assert_contains "the resync repaired the SKILL.md"      "$APPLY_OUT" "synced    $CODEX_REL/SKILL.md"
assert_contains "the resync restored the reference"     "$APPLY_OUT" "added     $CODEX_REFS_REL/tidy.md"
assert_not_contains "the repaired SKILL.md lost the drift" \
                    "$(cat "$T9/$CODEX_REL/SKILL.md")" "drifted"
bash "$RESYNC" --dry-run --target "$T9" >/dev/null 2>&1
assert_eq "the repaired install reports no drift" "0" "$?"

# A refresh must never ADOPT a surface the operator declined: resync refreshes
# what is installed, it is not a second, quieter installer.
T10="$(new_target drift-no-codex)"
install_into "$T10" --no-codex >/dev/null
bash "$T10/.claude/skills/repo/scripts/resync-installed.sh" --target "$T10" >/dev/null 2>&1
assert_absent "resync does not create a Codex surface the install declined" "$T10/.agents"

# Nor may it silently delete an unrelated file living beside our skill.
printf '%s\n' 'consumer note' > "$T9/$CODEX_REL/NOTES.md"
ORPHAN_OUT="$(bash "$RESYNC" --target "$T9" 2>&1)"
assert_contains "resync names a file it left alone under the Codex surface" \
                "$ORPHAN_OUT" "$CODEX_REL/NOTES.md"
assert_file     "resync left that file in place" "$T9/$CODEX_REL/NOTES.md"

# ---------------------------------------------------------------------------
echo ""
echo "-- --dev: SKILL.md is generated, references stay live symlinks --"

T11="$(new_target dev)"
OUT11="$(install_into "$T11" --dev)"; RC11=$?
assert_eq       "dev: install exits 0" "0" "$RC11"
assert_contains "dev: install reports the Codex SKILL.md" "$OUT11" "Installed $CODEX_REL/SKILL.md"
if [[ -f "$T11/$CODEX_REL/SKILL.md" && ! -L "$T11/$CODEX_REL/SKILL.md" ]]; then
    ok "dev: SKILL.md is generated, not symlinked (its frontmatter is rendered)"
else
    no "dev: SKILL.md is generated, not symlinked (its frontmatter is rendered)"
fi
if [[ -L "$T11/$CODEX_REFS_REL/tidy.md" ]]; then
    ok "dev: reference procedures are symlinks into the source clone"
else
    no "dev: reference procedures are symlinks into the source clone"
fi
assert_contains "dev: the machine-local Codex surface is gitignored" \
                "$(cat "$T11/.gitignore" 2>/dev/null)" "$CODEX_REL/"
install_into "$T11" --dev >/dev/null
assert_eq "dev: re-installing does not duplicate the .gitignore entry" \
          "1" "$(grep -cxF "$CODEX_REL/" "$T11/.gitignore")"

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

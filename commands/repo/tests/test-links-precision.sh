#!/usr/bin/env bash
# Test suite for /repo:links' precision rules — the two fixes that stand between
# "a useful cross-reference checker" and "30 findings, 0 real".
#
# Usage: ./commands/repo/tests/test-links-precision.sh
# Exit code 0 = all tests pass, 1 = failures detected.
#
# Structured like commands/repo/tests/test-scrub-contract.sh: pure bash, no test
# framework, PASS/FAIL/SKIP/TOTAL counters and a summary block. `pnpm test`
# delegates to this file via hooks/repo/tests/run.sh.
#
# WHY THIS FILE EXISTS (repo#190): a /repo:all run against a healthy 603-file
# repo reported 30 broken internal links, and every single one was a false
# positive. Two causes, neither of which the command's rules addressed:
#
#   1. Inline code spans were scanned as links, so the checker flagged the
#      sentences in links.md and audit.md that DESCRIBE what it looks for.
#   2. Links were resolved only against the containing file's directory. 28 of
#      the 30 were in .loom/CLAUDE.md, which writes root-relative paths — the
#      correct convention there, since a CLAUDE.md is loaded into an agent's
#      context and its paths read from the repo root.
#
# The second one is the dangerous half: links.md calls CLAUDE.md references
# CRITICAL severity, so the highest-severity class in the checker was the class
# most likely to be wrong.
#
# The cost is not the wasted minute. A check that returns 100% noise on a
# healthy repo teaches people to skim past its output, which is expensive the
# first time it is right — so "precision is itself a finding" is part of the
# contract, not a nicety.
#
# The contract under test:
#   1  fenced blocks and inline code spans are stripped before scanning
#   2  links resolve against BOTH the file's directory and the repo root, and a
#      finding requires failing both
#   3  CLAUDE.md's root-relative convention is named as correct, not a defect
#   4  vendored/installer-managed files are reported but never edited in place
#   5  a high false-positive rate is surfaced as its own finding
#   6  the two real-world false positives no longer match the documented scan
#   7  install-template trees resolve at their installed destination, declared
#      per-repo in .repo/link-roots.json, opt-in and reported
#   8  the documented forward/reverse mapping algorithm actually clears the
#      repo#208 false positive without suppressing a real one
#
# Contract 7/8 exist for repo#208: a /repo:audit run against rjwalters/loom
# reported 22 broken links, all 22 inside defaults/ — an install-template tree
# whose links are written to resolve at the DESTINATION (defaults/.loom/CLAUDE.md
# installs to <repo>/CLAUDE.md, defaults/docs/*.md to <repo>/.loom/docs/*.md).
# Resolved in place they are all broken; resolved through the install mapping
# they are all correct. A permanent 22-finding floor in the checker's own
# critical class is the "teaches people to skim" failure again, one layer up.
#
#   9  a relative link that resolves OUTSIDE the repo root — a citation into a
#      sibling repo in a multi-repo workspace — is checked against an opt-in
#      `.repo/link-siblings.json` declaration (parent + allowed sibling names)
#      before being reported, adding a fourth resolution base
#  10  the documented sibling-repo algorithm actually clears repo#268's worked
#      example: a working sibling link resolves, a broken one (sibling present,
#      file gone) is a real MISSING finding, and a link into a sibling that
#      isn't checked out locally at all is reported as its own distinct status
#      — "sibling repo not present — unverifiable" — never folded into MISSING
#
# Contract 9/10 exist for repo#268: in a multi-repo workspace where docs cite
# sibling-repo files by relative path (e.g. a strategy doc linking
# `../../notes/sessions/<date>.md`), those citations resolved outside the repo
# root and so were invisible to the two-base and install-mapping checks above
# — the load-bearing links were the least-checked ones. The fix mirrors the
# install-mapping precedent: opt-in, absent-by-default, additive, and every
# failure mode gets its own row rather than one bucket that hides which is
# which — same discipline [[update-tools]] uses for "source repo missing" vs.
# "sidecar missing".

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CMD_DIR="$REPO_ROOT/commands/repo"

LINKS_MD="$CMD_DIR/links.md"
AUDIT_MD="$CMD_DIR/audit.md"

PASS=0
FAIL=0
SKIP=0
TOTAL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

if [[ ! -f "$LINKS_MD" ]]; then
    echo "FATAL: links.md not found at $LINKS_MD" >&2
    exit 1
fi

LINKS="$(cat "$LINKS_MD")"

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
assert_eq() {  # <label> <expected> <actual>
    if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1" "expected [$2], got [$3]"; fi
}
assert_contains() {  # <label> <haystack> <needle>
    if [[ "$2" == *"$3"* ]]; then ok "$1"; else no "$1" "missing [$3]"; fi
}

# ---------------------------------------------------------------------------
echo "1. Code spans are stripped before scanning"
# ---------------------------------------------------------------------------

assert_contains "links.md requires stripping code before scanning" "$LINKS" \
    "Strip code before scanning"
assert_contains "fenced blocks are stripped" "$LINKS" '```.*?```'
assert_contains "inline spans are stripped" "$LINKS" '`[^`]*`'
assert_contains "the self-flagging failure is named" "$LINKS" \
    "flags the sentences in this very file"

# ---------------------------------------------------------------------------
echo ""
echo "2. Two-base resolution"
# ---------------------------------------------------------------------------

assert_contains "both bases documented" "$LINKS" \
    "Resolve against two bases"
assert_contains "a finding requires failing both" "$LINKS" \
    "missing under **both**"
assert_contains "the repo root is one of the bases" "$LINKS" "the repo root"
assert_contains "the resolving base is stated when non-obvious" "$LINKS" \
    "base resolved it when the answer"
assert_contains "the 28-finding incident is recorded" "$LINKS" \
    "28 wrong findings"

# ---------------------------------------------------------------------------
echo ""
echo "3. CLAUDE.md root-relative is correct, not a defect"
# ---------------------------------------------------------------------------

assert_contains "CLAUDE.md paths are read from the repo root" "$LINKS" \
    "loaded into an agent's context and its paths are read from the repo"
assert_contains "critical severity is tied to the resolution risk" "$LINKS" \
    "the one most likely to be wrong"
assert_contains "nested CLAUDE.md also uses two bases" "$LINKS" \
    "against that directory **and** the repo"

# ---------------------------------------------------------------------------
echo ""
echo "4. Vendored files reported, never edited"
# ---------------------------------------------------------------------------

assert_contains "vendored/installer-managed section exists" "$LINKS" \
    "Vendored and installer-managed files"
assert_contains "never edited in place" "$LINKS" "reported but never edited in"
assert_contains "the next install overwrites the edit" "$LINKS" \
    "install overwrites the edit"
assert_contains "the upstream owner is named in the report" "$LINKS" \
    "name the upstream repo that owns the file"

# ---------------------------------------------------------------------------
echo ""
echo "5. Precision is itself a finding"
# ---------------------------------------------------------------------------

assert_contains "precision section exists" "$LINKS" "Precision is itself a finding"
assert_contains "a noisy run is reported on its own line" "$LINKS" \
    "0 actionable"
assert_contains "the cost of noise is stated" "$LINKS" \
    "teaches people to skim past its output"

# ---------------------------------------------------------------------------
echo ""
echo "6. The two real false positives no longer match the documented scan"
# ---------------------------------------------------------------------------

# Reproduce the documented strip on the actual files that produced the two
# code-span false positives in repo#190, then confirm no bare `[text](path)`
# link survives on those lines. This is the regression itself, not a proxy.
strip_code() {  # <file> -> file text with fenced blocks and inline spans removed
    perl -0777 -pe 's/```.*?```//gs; s/`[^`]*`//g' "$1" 2>/dev/null
}

if ! command -v perl >/dev/null 2>&1; then
    skip "code-span stripping clears the links.md false positive" "perl not available"
    skip "code-span stripping clears the audit.md false positive" "perl not available"
else
    LINKS_STRIPPED="$(strip_code "$LINKS_MD")"
    # The literal that tripped the checker: `[text](path)` inside backticks.
    assert_eq "stripping clears the links.md '[text](path)' code span" "0" \
        "$(printf '%s\n' "$LINKS_STRIPPED" | grep -cF '[text](path)')"

    if [[ -f "$AUDIT_MD" ]]; then
        AUDIT_STRIPPED="$(strip_code "$AUDIT_MD")"
        assert_eq "stripping clears the audit.md '[text](path)' code span" "0" \
            "$(printf '%s\n' "$AUDIT_STRIPPED" | grep -cF '[text](path)')"
        # And confirm the span really is there pre-strip, or the test proves nothing.
        assert_eq "audit.md does carry the span pre-strip (test is meaningful)" "1" \
            "$(grep -cF '`[text](path)`' "$AUDIT_MD")"
    else
        skip "stripping clears the audit.md '[text](path)' code span" "audit.md not found"
        skip "audit.md does carry the span pre-strip (test is meaningful)" "audit.md not found"
    fi
fi

# ---------------------------------------------------------------------------
echo ""
echo "7. Install-template trees resolve at their destination"
# ---------------------------------------------------------------------------

assert_contains "install-template section exists" "$LINKS" \
    "## Install-template trees"
assert_contains "the mapping is declared per-repo, not hardcoded" "$LINKS" \
    '`.repo/link-roots.json`'
assert_contains "the declaration is a tree -> destination map" "$LINKS" \
    '"defaults/docs": ".loom/docs"'
assert_contains "an empty destination means the destination root" "$LINKS" \
    'where `""` means the destination root'
assert_contains "absent a declaration, resolution is unchanged" "$LINKS" \
    "nothing in this section runs and"
assert_contains "template trees are never inferred by name" "$LINKS" \
    "No tree is ever treated as a"
assert_contains "the forward step maps the linking file to its install path" \
    "$LINKS" "The file's installed path is"
assert_contains "the reverse step maps the target back to a source path" \
    "$LINKS" "map it back to"
assert_contains "reverse candidates are tried longest-destination-first" \
    "$LINKS" 'longest `D'"'"'` first'
assert_contains "the reverse step resolves on any existing candidate" "$LINKS" \
    "resolves if **any** candidate"
assert_contains "an absent reverse candidate is skipped, not fatal" "$LINKS" \
    "skipped and the search"
assert_contains "reverse-step ordering is scoped to attribution, not the verdict" \
    "$LINKS" "attribution** rule, not a"
assert_contains "the verdict-changing longest-prefix rule is the forward step's" \
    "$LINKS" "longest-prefix rule is the **forward** step's"
assert_contains "a link missing under all three bases is still reported" \
    "$LINKS" "It adds a base; it never deletes a finding"
assert_contains "the report names every base that was tried" "$LINKS" \
    "MISSING (in place, repo root, and via"
assert_contains "the mapping table is printed even with no findings" "$LINKS" \
    "whether or not there were findings"
assert_contains "a declared tree that resolved 0 links is itself a finding" \
    "$LINKS" "resolved **0** links"
assert_contains "mapping-resolved links are distinguishable from in-place" \
    "$LINKS" "resolved via install mapping"
assert_contains "the disclosure names the reverse candidate that was found" \
    "$LINKS" "source \`defaults/docs/troubleshooting.md\`"
assert_contains "the disclosure separates the forward mapping from the source" \
    "$LINKS" "The mapping named is the **forward** one"
assert_contains "a fix inside a template tree uses destination coordinates" \
    "$LINKS" "must be written in **destination**"
assert_contains "the 22-finding incident is recorded" "$LINKS" \
    "All 22 findings in that run"

if [[ -f "$AUDIT_MD" ]]; then
    AUDIT="$(cat "$AUDIT_MD")"
    assert_contains "audit.md folds in the mapping table" "$AUDIT" \
        "Fold [[links]]' mapping table"
    assert_contains "audit.md keeps unchanged behavior without a declaration" \
        "$AUDIT" "With no declaration, resolution is"
else
    skip "audit.md folds in the mapping table" "audit.md not found"
    skip "audit.md keeps unchanged behavior without a declaration" "audit.md not found"
fi

DOCS_MD="$CMD_DIR/docs.md"
if [[ -f "$DOCS_MD" ]]; then
    assert_contains "docs.md keeps the mapping annotation in its consolidated report" \
        "$(cat "$DOCS_MD")" "resolved via install mapping"
else
    skip "docs.md keeps the mapping annotation" "docs.md not found"
fi

# ---------------------------------------------------------------------------
echo ""
echo "8. The documented mapping algorithm, executed against a fixture"
# ---------------------------------------------------------------------------
#
# Not a grep: this implements links.md's three-base resolution exactly as
# written and runs it over a temp tree shaped like rjwalters/loom's defaults/,
# so the repo#208 false positive is reproduced and cleared for real.

DECL_KEYS=()
DECL_VALS=()

norm() {  # <path> -> lexically normalized (targets need not exist)
    local p="$1" part out=() parts
    IFS='/' read -ra parts <<< "$p"
    for part in "${parts[@]}"; do
        case "$part" in
            ''|'.') ;;
            '..') if ((${#out[@]})) && [[ "${out[$((${#out[@]} - 1))]}" != ".." ]]; then
                      out=("${out[@]:0:$((${#out[@]} - 1))}")
                  else out+=(".."); fi ;;
            *) out+=("$part") ;;
        esac
    done
    local IFS=/
    printf '%s' "${out[*]:-}"
}

load_decl() {  # <.repo/link-roots.json path> — absent file = no declaration
    DECL_KEYS=(); DECL_VALS=()
    [[ -f "$1" ]] || return 0
    local k v tab
    # A literal tab in the replacement, not `\t`: BSD/macOS sed emits a bare "t"
    # for `\t` there, which would silently defeat the IFS=$'\t' split below.
    tab=$'\t'
    while IFS="$tab" read -r k v; do
        DECL_KEYS+=("$k"); DECL_VALS+=("${v:-}")
    done < <(sed -n "s/.*\"\([^\"]*\)\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1${tab}\2/p" "$1")
}

rev_order() {  # <installed target> -> declaration indices, longest destination first
    local q="$1" i d out=()
    for i in "${!DECL_VALS[@]}"; do
        d="${DECL_VALS[$i]}"
        # `$q == $d` is deliberate: a link that points at a declared destination
        # directory itself maps back to the tree T' that installs it.
        if [[ -z "$d" || "$q" == "$d" || "$q" == "$d/"* ]]; then out+=("${#d}:$i"); fi
    done
    ((${#out[@]})) || return 0
    printf '%s\n' "${out[@]}" | sort -t: -k1,1nr | cut -d: -f2
}

# Set by resolve() to the repo-relative path that actually satisfied the link.
# Ordering in rev_order() is an attribution rule, so this — not resolve()'s own
# verdict string — is what a reverse-candidate ordering change is visible in.
RESOLVED_SRC=""

resolve() {  # <repo root> <file, repo-relative> <link target> -> base that resolved it
    local root="$1" f="$2" p="$3" dir c i best=-1 bestlen=-1 T D rel installed idir q j T2 D2 cand
    RESOLVED_SRC=""
    dir="$(dirname "$f")"; [[ "$dir" == "." ]] && dir=""
    c="$(norm "${dir:+$dir/}$p")";  [[ -e "$root/$c" ]] && { RESOLVED_SRC="$c"; printf 'in place';  return 0; }
    c="$(norm "$p")";               [[ -e "$root/$c" ]] && { RESOLVED_SRC="$c"; printf 'repo root'; return 0; }
    for i in "${!DECL_KEYS[@]}"; do
        T="${DECL_KEYS[$i]}"
        if [[ "$f" == "$T/"* ]] && ((${#T} > bestlen)); then best=$i; bestlen=${#T}; fi
    done
    ((best < 0)) && { printf 'MISSING'; return 1; }
    T="${DECL_KEYS[$best]}"; D="${DECL_VALS[$best]}"
    rel="${f#"$T"/}"
    installed="$(norm "${D:+$D/}$rel")"
    idir="$(dirname "$installed")"; [[ "$idir" == "." ]] && idir=""
    for q in "$(norm "${idir:+$idir/}$p")" "$(norm "$p")"; do
        [[ -e "$root/$q" ]] && { RESOLVED_SRC="$q"; printf 'mapping %s -> %s' "$T" "${D:-<dest root>}"; return 0; }
        while read -r j; do
            [[ -n "$j" ]] || continue
            T2="${DECL_KEYS[$j]}"; D2="${DECL_VALS[$j]}"
            if [[ -z "$D2" ]]; then cand="$(norm "$T2/$q")"
            elif [[ "$q" == "$D2" ]]; then cand="$T2"
            else cand="$(norm "$T2/${q#"$D2"/}")"; fi
            # Any existing candidate resolves: an absent one is skipped, and the
            # loop keeps going rather than ending the reverse step.
            [[ -e "$root/$cand" ]] && { RESOLVED_SRC="$cand"; printf 'mapping %s -> %s' "$T" "${D:-<dest root>}"; return 0; }
        done < <(rev_order "$q")
    done
    printf 'MISSING'
    return 1
}

resolve_src() {  # same args as resolve -> the path that satisfied the link
    resolve "$@" >/dev/null || true
    printf '%s' "$RESOLVED_SRC"
}

FIX="$(mktemp -d "${TMPDIR:-/tmp}/links-roots.XXXXXX")"
trap 'rm -rf "$FIX"' EXIT

mkdir -p "$FIX/defaults/.loom" "$FIX/defaults/docs" "$FIX/docs" "$FIX/.repo"
: > "$FIX/README.md"
: > "$FIX/defaults/.loom/CLAUDE.md"
: > "$FIX/defaults/docs/troubleshooting.md"
: > "$FIX/defaults/docs/guide.md"
: > "$FIX/docs/a.md"
: > "$FIX/docs/b.md"
# Two reverse candidates that BOTH exist, for the attribution assertions below:
# .loom/docs/deep -> defaults/elsewhere (longest) vs .loom/docs -> defaults/docs.
mkdir -p "$FIX/defaults/elsewhere" "$FIX/defaults/docs/deep"
: > "$FIX/defaults/elsewhere/x.md"
: > "$FIX/defaults/docs/deep/x.md"
# A declared tree nested inside another declared tree, for the forward-step
# longest-prefix assertion. Only the ""-mapping reverse candidate exists.
mkdir -p "$FIX/defaults/.loom/docs" "$FIX/defaults/.loom/.loom/nested"
: > "$FIX/defaults/.loom/docs/guide.md"
: > "$FIX/defaults/.loom/.loom/nested/page.md"
cat > "$FIX/.repo/link-roots.json" <<'JSON'
{
  "defaults/.loom": "",
  "defaults/docs": ".loom/docs",
  "defaults/.claude/commands/loom": ".claude/commands/loom",
  "defaults/.loom/docs": ".loom/nested",
  "defaults/elsewhere": ".loom/docs/deep"
}
JSON

# The declaration parses, including the empty ("destination root") value.
load_decl "$FIX/.repo/link-roots.json"
assert_eq "link-roots.json yields five mappings" "5" "${#DECL_KEYS[@]}"
assert_eq "an empty destination parses as the destination root" "" "${DECL_VALS[0]}"

# The repo#208 finding itself: correct at the destination, broken in place.
assert_eq "the fixture reproduces the false positive in place" "0" \
    "$([[ -e "$FIX/defaults/.loom/.loom/docs/troubleshooting.md" ]] && echo 1 || echo 0)"
assert_eq "defaults/.loom/CLAUDE.md -> .loom/docs/troubleshooting.md resolves via mapping" \
    "mapping defaults/.loom -> <dest root>" \
    "$(resolve "$FIX" "defaults/.loom/CLAUDE.md" ".loom/docs/troubleshooting.md")"

# Non-empty destination, resolved against the destination root.
assert_eq "defaults/docs/guide.md -> .loom/docs/troubleshooting.md resolves via mapping" \
    "mapping defaults/docs -> .loom/docs" \
    "$(resolve "$FIX" "defaults/docs/guide.md" ".loom/docs/troubleshooting.md")"

# Criterion 4: missing under BOTH in-place and mapped resolution is still a finding.
assert_eq "a template-tree link missing everywhere is still reported" "MISSING" \
    "$(resolve "$FIX" "defaults/.loom/CLAUDE.md" ".loom/docs/gone.md")"

# --- Reverse-step ordering: an ATTRIBUTION rule, executed, not asserted about --
#
# .loom/docs/deep/x.md has three reverse candidates: defaults/elsewhere/x.md
# (D'=".loom/docs/deep", exists), defaults/docs/deep/x.md (D'=".loom/docs",
# exists) and defaults/.loom/.loom/docs/deep/x.md (D'="", absent). Flipping
# rev_order's sort direction turns all three of the following red.
assert_eq "rev_order returns declarations longest-destination-first" "4 1 0" \
    "$(rev_order ".loom/docs/deep/x.md" | xargs)"
assert_eq "the most specific reverse candidate is the one credited" \
    "defaults/elsewhere/x.md" \
    "$(resolve_src "$FIX" "defaults/.loom/CLAUDE.md" ".loom/docs/deep/x.md")"
# ...and the verdict is the same either way, because any existing candidate
# resolves — the ordering cannot manufacture a MISSING.
assert_eq "an absent reverse candidate is skipped rather than ending the search" \
    "mapping defaults/.loom -> <dest root>" \
    "$(resolve "$FIX" "defaults/.loom/CLAUDE.md" ".loom/docs/deep/x.md")"

# A link whose target IS a declared destination directory maps back to the tree
# that installs it (rev_order's q == D' case).
assert_eq "a link to a declared destination directory resolves to its tree" \
    "defaults/docs" \
    "$(resolve_src "$FIX" "defaults/.loom/CLAUDE.md" ".loom/docs")"

# --- Forward step: the longest-prefix rule that DOES change the verdict -------
#
# defaults/.loom/docs/guide.md sits under two declared trees. Taking the longer
# (defaults/.loom/docs -> .loom/nested) installs it to .loom/nested/guide.md, so
# "page.md" resolves via defaults/.loom/.loom/nested/page.md. Taking the shorter
# (defaults/.loom -> "") installs it to docs/guide.md and the link is MISSING.
assert_eq "the forward step picks the longest declared tree containing the file" \
    "mapping defaults/.loom/docs -> .loom/nested" \
    "$(resolve "$FIX" "defaults/.loom/docs/guide.md" "page.md")"
assert_eq "the shorter-prefix forward candidate genuinely does not resolve" "0" \
    "$([[ -e "$FIX/defaults/.loom/docs/page.md" || -e "$FIX/docs/page.md" ]] && echo 1 || echo 0)"

# Criterion 3: a declared mapping must not change non-template resolution.
assert_eq "an in-place link outside any template tree still resolves in place" \
    "in place" "$(resolve "$FIX" "docs/a.md" "b.md")"
assert_eq "a root-relative link outside any template tree still resolves at the root" \
    "repo root" "$(resolve "$FIX" "docs/a.md" "README.md")"

# Criterion 3, the other half: with NO declaration, every verdict is unchanged.
load_decl "$FIX/.repo/does-not-exist.json"
assert_eq "no declaration loads no mappings" "0" "${#DECL_KEYS[@]}"
assert_eq "without a declaration the template link is reported, as before" "MISSING" \
    "$(resolve "$FIX" "defaults/.loom/CLAUDE.md" ".loom/docs/troubleshooting.md")"
assert_eq "without a declaration in-place resolution is unchanged" "in place" \
    "$(resolve "$FIX" "docs/a.md" "b.md")"
assert_eq "without a declaration root resolution is unchanged" "repo root" \
    "$(resolve "$FIX" "docs/a.md" "README.md")"

rm -rf "$FIX"
trap - EXIT

# ---------------------------------------------------------------------------
echo ""
echo "9. Sibling-repo relative links are documented"
# ---------------------------------------------------------------------------

assert_contains "sibling-repo section exists" "$LINKS" \
    "## Sibling-repo relative links"
assert_contains "out-of-repo resolution is described" "$LINKS" \
    "resolves **outside the repo root**"
assert_contains "the declaration file is named" "$LINKS" \
    '`.repo/link-siblings.json`'
assert_contains "the declaration file is distinct from link-roots.json" "$LINKS" \
    "a **different** file from"
assert_contains "the declaration shape is a parent + siblings list" "$LINKS" \
    '"siblings": ["notes", "kicad-tools", "anvil"]'
assert_contains "absent a declaration, behavior is unchanged" "$LINKS" \
    "out-of-repo links are handled exactly as they are today"
assert_contains "siblings are never inferred from directory name/shape" "$LINKS" \
    "No sibling is ever inferred from a directory"
assert_contains "a present, resolving sibling gets its own status" "$LINKS" \
    "resolved via sibling repo"
assert_contains "an absent sibling checkout gets its own distinct status" "$LINKS" \
    "sibling repo not present — unverifiable"
assert_contains "the distinct-row rationale cites update-tools' failure modes" "$LINKS" \
    "different failure modes"
assert_contains "update-tools is cited by name and step" "$LINKS" \
    "[[update-tools]] step 3"
assert_contains "folding sibling-absent into MISSING is named as the failure to avoid" \
    "$LINKS" '"sibling absent" into `MISSING`'
assert_contains "a present sibling with a missing target is still a real finding" \
    "$LINKS" "sibling \`notes\` present, file not found"
assert_contains "a link missing under every base is still reported" "$LINKS" \
    "Never fold the third row into the first two"
assert_contains "a declared-but-unused sibling is reported as a question" "$LINKS" \
    "as a question, not silently"
assert_contains "the repo#268 worked example is present" "$LINKS" \
    "### Worked example"
assert_contains "the worked example's unverifiable outcome is not a false positive" \
    "$LINKS" "not a false positive"

# ---------------------------------------------------------------------------
echo ""
echo "10. The documented sibling-repo algorithm, executed against a fixture"
# ---------------------------------------------------------------------------
#
# Not a grep: implements links.md's sibling-repo resolution exactly as written
# and runs it over a temp two-repo workspace shaped like the issue's worked
# example (`../../notes/sessions/<date>.md` citing a sibling repo), covering
# the three acceptance-criteria outcomes: working link, broken link (sibling
# present), unverifiable link (sibling absent).

SIB_PARENT=""
SIB_LIST=()

load_sib_decl() {  # <.repo/link-siblings.json path> — absent file = no declaration
    SIB_PARENT=""; SIB_LIST=()
    [[ -f "$1" ]] || return 0
    SIB_PARENT="$(sed -n 's/.*"parent"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" | head -1)"
    local raw
    raw="$(sed -n 's/.*"siblings"[[:space:]]*:[[:space:]]*\[\(.*\)\].*/\1/p' "$1" | head -1)"
    # Split a `"a", "b", "c"` fragment into array entries.
    while IFS= read -r entry; do
        entry="${entry//\"/}"; entry="$(echo "$entry" | xargs)"
        [[ -n "$entry" ]] && SIB_LIST+=("$entry")
    done < <(printf '%s\n' "$raw" | tr ',' '\n')
}

sib_is_declared() {  # <name> -> 0 if declared, 1 otherwise
    local n="$1" s
    for s in "${SIB_LIST[@]}"; do [[ "$s" == "$n" ]] && return 0; done
    return 1
}

# <repo root> <file, repo-relative> <link target> -> sibling-repo verdict.
# Assumes the caller already tried the two-base (and install-mapping) bases
# and they failed — this is purely the fourth base from links.md.
sib_resolve() {
    local root="$1" f="$2" p="$3" dir q sib rest
    dir="$(dirname "$f")"; [[ "$dir" == "." ]] && dir=""
    q="$(norm "${dir:+$dir/}$p")"
    [[ -n "$SIB_PARENT" ]] || { printf 'MISSING'; return 1; }
    local pnorm; pnorm="$(norm "$SIB_PARENT")"
    [[ "$q" == "$pnorm/"* ]] || { printf 'MISSING'; return 1; }
    rest="${q#"$pnorm"/}"
    sib="${rest%%/*}"
    sib_is_declared "$sib" || { printf 'MISSING'; return 1; }
    local subpath="${rest#*/}"
    if [[ -d "$root/$SIB_PARENT/$sib" ]]; then
        if [[ -e "$root/$SIB_PARENT/$sib/$subpath" ]]; then
            printf 'resolved via sibling repo %s' "$sib"; return 0
        else
            printf 'MISSING (sibling %s present, file not found)' "$sib"; return 1
        fi
    else
        printf 'sibling repo not present -- unverifiable (%s)' "$sib"; return 1
    fi
}

SFIX="$(mktemp -d "${TMPDIR:-/tmp}/links-siblings.XXXXXX")"
trap 'rm -rf "$SFIX"' EXIT

# workspace/
#   repo-a/docs/strategy.md          <- the file with the citations
#   repo-a/.repo/link-siblings.json  <- parent=.. siblings=[notes, kicad-tools]
#   notes/sessions/2026-07-30.md     <- exists: the working-link case
#   (notes/sessions/2026-06-01.md does NOT exist: the broken-link case)
#   (kicad-tools/ does NOT exist at all: the unverifiable case)
mkdir -p "$SFIX/repo-a/docs" "$SFIX/repo-a/.repo" "$SFIX/notes/sessions"
: > "$SFIX/notes/sessions/2026-07-30.md"
cat > "$SFIX/repo-a/.repo/link-siblings.json" <<'JSON'
{
  "parent": "..",
  "siblings": ["notes", "kicad-tools"]
}
JSON

load_sib_decl "$SFIX/repo-a/.repo/link-siblings.json"
assert_eq "link-siblings.json parses the declared parent" ".." "$SIB_PARENT"
assert_eq "link-siblings.json parses two declared siblings" "2" "${#SIB_LIST[@]}"

# (a) a working sibling-repo relative link.
assert_eq "a working sibling-repo link resolves" \
    "resolved via sibling repo notes" \
    "$(sib_resolve "$SFIX/repo-a" "docs/strategy.md" "../../notes/sessions/2026-07-30.md")"

# (b) a broken link to a sibling repo that IS checked out — a real finding,
#     not suppressed just because it crosses a repo boundary.
assert_eq "a broken link into a present sibling is a real MISSING finding" \
    "MISSING (sibling notes present, file not found)" \
    "$(sib_resolve "$SFIX/repo-a" "docs/strategy.md" "../../notes/sessions/2026-06-01.md")"

# (c) a link into a sibling repo that is NOT checked out — must be reported as
#     unverifiable, never as a false-positive MISSING.
assert_eq "a link into an absent sibling checkout is unverifiable, not MISSING" \
    "sibling repo not present -- unverifiable (kicad-tools)" \
    "$(sib_resolve "$SFIX/repo-a" "docs/strategy.md" "../../kicad-tools/docs/setup.md")"

# A sibling name that isn't declared is out of scope for this check entirely —
# still MISSING (unchanged two-base outcome), not a new unverifiable status.
mkdir -p "$SFIX/unrelated"
assert_eq "an undeclared sibling name is not treated as a workspace citation" \
    "MISSING" \
    "$(sib_resolve "$SFIX/repo-a" "docs/strategy.md" "../../unrelated/x.md")"

# Absent the declaration file, out-of-repo resolution is unchanged: MISSING,
# same as it is today with no sibling-repo awareness at all.
load_sib_decl "$SFIX/repo-a/.repo/does-not-exist.json"
assert_eq "no declaration loads no parent" "" "$SIB_PARENT"
assert_eq "no declaration loads no siblings" "0" "${#SIB_LIST[@]}"
assert_eq "without a declaration a sibling link reports MISSING, as before" \
    "MISSING" \
    "$(sib_resolve "$SFIX/repo-a" "docs/strategy.md" "../../notes/sessions/2026-07-30.md")"

rm -rf "$SFIX"
trap - EXIT

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

#!/usr/bin/env bash
# Test suite for /repo:scrub's documented contract, its integration into
# /repo:all, and the ASK-tier package-manager prune added to /repo:tidy.
#
# Usage: ./commands/repo/tests/test-scrub-contract.sh
# Exit code 0 = all tests pass, 1 = failures detected.
#
# Structured like commands/repo/tests/test-tidy-keep-tiers.sh: pure bash, no
# test framework, PASS/FAIL/SKIP/TOTAL counters and a summary block. `pnpm test`
# delegates to this file via hooks/repo/tests/run.sh.
#
# WHY THIS FILE EXISTS (repo#174, #186, #145): all three landed as prose
# contracts rather than code, and every one of them encodes a rule that is
# tempting to "simplify" into its own failure mode:
#
#   - Excluding vendored trees to cut noise is the reasoning that hid a real
#     address in 12 public repos already declared clean. The exclusion must
#     stay absent.
#   - Failing the run on history-only findings makes every repo fail forever
#     and the signal worthless — exit 1 is reserved for findings AT HEAD.
#   - Emitting low-severity findings on every /repo:all run is how the check
#     gets skimmed and then ignored; severity has to gate verbosity, so
#     /repo:all must run the default form only.
#   - Reporting "cleaned" after a history rewrite is actively false while PR
#     refs and forks still serve the original content.
#   - The prune tier is defensible only because the package manager decides
#     what is unreferenced. A raw `rm` inside node_modules/ forfeits that, so
#     no ```bash fence may contain one.
#
# The contract under test:
#   1  scrub.md exists, is user-invocable, and is report-only
#   2  exit codes 0/1/2, with 1 bound to findings AT HEAD specifically
#   3  all five detection classes are documented, topology behind --deep
#   4  all seven removability surfaces carry a class, PR/refs/forks/registries
#      classed permanent
#   5  vendored trees are scanned by default — no default-exclusion rule
#   6  /repo:all runs the default form only and never fails on findings
#   7  all.md stage numbering stayed contiguous through the insertion
#   8  tidy's prune is ASK-tier, runs via the package manager, never raw rm

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CMD_DIR="$REPO_ROOT/commands/repo"

SCRUB_MD="$CMD_DIR/scrub.md"
ALL_MD="$CMD_DIR/all.md"
TIDY_MD="$CMD_DIR/tidy.md"
SKILL_MD="$REPO_ROOT/skills/repo/SKILL.md"
README_MD="$REPO_ROOT/README.md"

PASS=0
FAIL=0
SKIP=0
TOTAL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

for f in "$SCRUB_MD" "$ALL_MD" "$TIDY_MD" "$SKILL_MD" "$README_MD"; do
    if [[ ! -f "$f" ]]; then
        echo "FATAL: required file not found at $f" >&2
        exit 1
    fi
done

SCRUB="$(cat "$SCRUB_MD")"
ALL="$(cat "$ALL_MD")"
TIDY="$(cat "$TIDY_MD")"

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
assert_matches() {  # <label> <haystack> <ere>
    if printf '%s\n' "$2" | grep -qE -- "$3"; then ok "$1"; else no "$1" "no match for /$3/"; fi
}

# ---------------------------------------------------------------------------
echo "1. Command surface and report-only posture"
# ---------------------------------------------------------------------------

assert_matches "scrub.md declares name: scrub" "$SCRUB" '^name: "scrub"'
assert_matches "scrub.md is user-invocable" "$SCRUB" '^user-invocable: true'
assert_matches "scrub.md declares type: command" "$SCRUB" '^type: command'
assert_contains "scrub.md states it never edits" "$SCRUB" "It never edits."
assert_contains "scrub.md names orphans as its posture precedent" "$SCRUB" "[[orphans]]"

# Report-only is the whole safety story: no fence may run a mutating git or gh
# verb. A tool that can rewrite history on its own findings is a different
# command with a different safety contract.
#
# Fence openers/closers are matched with optional leading whitespace, since a
# fence nested inside a numbered list item (as every step-by-step
# commands/repo/*.md writes fences) is indented. The opener and closer
# patterns are kept in sync (both indentation-tolerant) so an indented opener
# can't run unmatched against an anchored closer and swallow following prose.
SCRUB_BASH_FENCES="$(awk '/^[[:space:]]*```bash/{f=1;next} /^[[:space:]]*```/{f=0} f' "$SCRUB_MD")"
for verb in "filter-repo" "push --force" "gh issue delete" "gh issue edit" "gh pr edit" "git commit"; do
    assert_eq "no bash fence in scrub.md runs '$verb'" "0" \
        "$(printf '%s\n' "$SCRUB_BASH_FENCES" | grep -cF -- "$verb")"
done

# ---------------------------------------------------------------------------
echo ""
echo "2. Exit codes — 1 is bound to findings AT HEAD"
# ---------------------------------------------------------------------------

assert_contains "exit 0 documented as clean" "$SCRUB" '| `0` |'
assert_contains "exit 1 documented" "$SCRUB" '| `1` |'
assert_contains "exit 2 documented" "$SCRUB" '| `2` |'
assert_matches "exit 1 is scoped to findings at HEAD" "$SCRUB" '\| `1` \| Findings \*\*at HEAD\*\*'
assert_contains "history-only findings never set exit 1 on their own" "$SCRUB" \
    "History-only findings never set exit 1 on their own."
assert_contains "exit 2 is inconclusive, never reported as clean" "$SCRUB" \
    "must never be reported as clean"

# ---------------------------------------------------------------------------
echo ""
echo "3. Detection classes"
# ---------------------------------------------------------------------------

for class in "Credentials" "Cloud resource IDs" "Identity" "Affiliated entities" "Network topology"; do
    assert_contains "detection class documented: $class" "$SCRUB" "$class"
done
assert_contains "topology is --deep only" "$SCRUB" '| `--deep` only |'
assert_contains "32-hex ambiguity is triaged on context, not a bare regex" "$SCRUB" \
    "nearby-word context"
assert_contains "md5/checksum demote a 32-hex match" "$SCRUB" '`checksum`'
assert_contains "dashed-hostname IP form is covered alongside dotted" "$SCRUB" "ip-172-31-74-176"
assert_contains "placeholder emails are excluded" "$SCRUB" '`*.noreply.github.com`'
assert_contains "third-party addresses outrank the operator's own" "$SCRUB" \
    "ranks"
assert_contains "affiliated entities need alias expansion" "$SCRUB" "Alias expansion"
assert_contains "affiliated entities split substantive vs incidental" "$SCRUB" \
    "Substantive vs incidental"

# ---------------------------------------------------------------------------
echo ""
echo "4. Removability — every surface classed, permanence stated"
# ---------------------------------------------------------------------------

assert_contains "removability class is required on every finding" "$SCRUB" \
    "Every finding carries a **removability class**"
for surface in "Working tree" "Branch/tag history" "Issue body/comment" "PR body/comment" "Forks" "Published registries"; do
    assert_contains "removability row present: $surface" "$SCRUB" "$surface"
done
assert_contains "refs/pull row present" "$SCRUB" '`refs/pull/*`'
assert_contains "PR bodies are permanent" "$SCRUB" \
    "No delete endpoint exists for pull requests"
assert_contains "hidden refs refuse client rewrites" "$SCRUB" "deny updating a hidden ref"
assert_contains "issue edits leave userContentEdits" "$SCRUB" "userContentEdits"
assert_contains "unrecognized surface fails loudly" "$SCRUB" \
    "error, not a default"
assert_contains "'cleaned' is forbidden after a partial check" "$SCRUB" \
    "forbidden word unless every surface was checked"
assert_contains "rewrite-only reports name what was NOT checked" "$SCRUB" \
    "name the surfaces it did not check"
assert_contains "rotation is orthogonal to removability class" "$SCRUB" \
    "Don't conflate the two axes."
assert_contains "fresh-clone verification is required" "$SCRUB" \
    "Verify from a fresh clone of origin"
assert_contains "the report names which clone type was used" "$SCRUB" \
    "clones legitimately disagree"
assert_contains "local tags need --force on fetch" "$SCRUB" '`--force`'

# ---------------------------------------------------------------------------
echo ""
echo "5. Vendored trees are scanned by default"
# ---------------------------------------------------------------------------

assert_contains "vendored trees scanned by default" "$SCRUB" "Scan vendored trees by default"
assert_contains "the exclusion temptation is named and rejected" "$SCRUB" \
    "precisely backwards"
assert_contains "high volume means rank lower, never drop" "$SCRUB" \
    "never drop them"
assert_contains "vendored findings point upstream, not at a local edit" "$SCRUB" \
    "next reinstall overwrites the edit"
# The regression this guards: a default exclusion list is exactly the shape of
# the mistake. If one is ever added, each entry must be justified here.
assert_contains "any default exclusion list must be justified per entry" "$SCRUB" \
    "justify each entry against this failure mode"

# ---------------------------------------------------------------------------
echo ""
echo "6. Forge enumeration and visibility confirmation"
# ---------------------------------------------------------------------------

assert_contains "enumerates from the forge, not a manifest" "$SCRUB" \
    "never from a manifest"
assert_contains "manifest blind spots are quantified" "$SCRUB" "6 of 58"
assert_contains "authenticated search hits need visibility confirmed" "$SCRUB" \
    "Confirm visibility on every search hit"
assert_contains "fork sweep delegates to the existing script" "$SCRUB" \
    "repo-scrub-forks.sh"
assert_contains "warn-before-private is referenced" "$SCRUB" "warn-before-private"

FORKS_SH="$REPO_ROOT/scripts/repo/repo-scrub-forks.sh"
if [[ -f "$FORKS_SH" ]]; then
    ok "the delegated fork-sweep script exists at the referenced path"
else
    no "the delegated fork-sweep script exists at the referenced path" "missing $FORKS_SH"
fi

# ---------------------------------------------------------------------------
echo ""
echo "7. /repo:all integration — quiet by default, never fails the run"
# ---------------------------------------------------------------------------

assert_matches "all.md has a Scrub stage" "$ALL" '^### [0-9]+\. Scrub \(see \[\[scrub\]\]\)'
assert_contains "all.md runs the default form only" "$ALL" "Run the **default form only**"
for flag in "--deep" "--owner" "--forks"; do
    assert_contains "all.md explicitly withholds $flag" "$ALL" "$flag"
done
assert_contains "findings never fail the /repo:all run" "$ALL" \
    "**Findings never fail the run.**"
assert_contains "exit 2 reported as inconclusive, not clean" "$ALL" \
    "inconclusive, not clean"
assert_contains "scrub findings reach the final summary" "$ALL" "Scrub:"
assert_contains "the skipped line names the withheld scrub modes" "$ALL" \
    "scrub --deep/--owner/--forks"

# Stage numbering must be contiguous from 1 — the renumbering half of a stage
# insertion is exactly what gets forgotten.
STAGE_NUMS="$(grep -oE '^### [0-9]+\.' "$ALL_MD" | grep -oE '[0-9]+' | tr '\n' ' ')"
EXPECTED_NUMS=""
_n=1
for _ in $STAGE_NUMS; do EXPECTED_NUMS+="$_n "; _n=$((_n + 1)); done
assert_eq "all.md stage headings are numbered contiguously from 1" \
    "$EXPECTED_NUMS" "$STAGE_NUMS"

# Scrub is read-only, so it must sit before the stages that edit. Docs is the
# first mutating stage.
SCRUB_LN="$(grep -nE '^### [0-9]+\. Scrub' "$ALL_MD" | head -1 | cut -d: -f1)"
DOCS_LN="$(grep -nE '^### [0-9]+\. Docs' "$ALL_MD" | head -1 | cut -d: -f1)"
if [[ -n "$SCRUB_LN" && -n "$DOCS_LN" ]]; then
    assert_eq "the Scrub stage precedes the first mutating stage (Docs)" "yes" \
        "$([[ "$SCRUB_LN" -lt "$DOCS_LN" ]] && echo yes || echo no)"
else
    no "the Scrub stage precedes the first mutating stage (Docs)" \
        "scrub=$SCRUB_LN docs=$DOCS_LN"
fi

# ---------------------------------------------------------------------------
echo ""
echo "8. Command tables list scrub"
# ---------------------------------------------------------------------------

assert_contains "SKILL.md command table lists [[scrub]]" "$(cat "$SKILL_MD")" "| [[scrub]] |"
assert_contains "README command table lists /repo:scrub" "$(cat "$README_MD")" '| `/repo:scrub` |'

# ---------------------------------------------------------------------------
echo ""
echo "9. tidy prune tier (repo#145) — ASK, package-manager-native, never rm"
# ---------------------------------------------------------------------------

assert_contains "tidy.md detects a pnpm lockfile" "$TIDY" "pnpm-lock.yaml"
assert_contains "tidy.md detects an npm lockfile" "$TIDY" "package-lock.json"
assert_contains "the prune offer is ASK-tier, with rationale" "$TIDY" \
    "**ASK, not CACHE**"
assert_contains "--caches deliberately does not reach the prune" "$TIDY" \
    '`--caches` deliberately does'
assert_contains "the tier adds a tier and relaxes nothing" "$TIDY" \
    "adds a tier and relaxes nothing"
assert_contains "node_modules stays denylisted and ASK" "$TIDY" \
    "full-tree deletion stays denylisted"
assert_contains "prune runs the package manager's own verb" "$TIDY" \
    "runs the package manager's own verb"
assert_contains "pnpm is the real case, npm a near-no-op" "$TIDY" \
    "near-no-op"
assert_contains "pnpm workspaces need recursion" "$TIDY" '`-r`'
assert_contains "the pre-run size estimate is optional" "$TIDY" \
    "A pre-run size estimate is optional"
assert_contains "safety rule 10 covers the prune" "$TIDY" \
    "10. **Prune only through the package manager**"

# The core safety property: nothing in tidy.md may show an `rm` inside
# node_modules/, in any fence. The tier is defensible only because the package
# manager decides what is unreferenced.
#
# See the SCRUB_BASH_FENCES comment above: opener/closer are both
# indentation-tolerant so a fence nested in a list item (e.g. tidy.md's
# `git ls-files` block) is not skipped.
TIDY_BASH_FENCES="$(awk '/^[[:space:]]*```bash/{f=1;next} /^[[:space:]]*```/{f=0} f' "$TIDY_MD")"
assert_eq "no bash fence in tidy.md runs rm against node_modules" "0" \
    "$(printf '%s\n' "$TIDY_BASH_FENCES" | grep -cE 'rm .*node_modules')"
assert_eq "no bash fence in tidy.md hand-walks .pnpm" "0" \
    "$(printf '%s\n' "$TIDY_BASH_FENCES" | grep -cE 'rm .*\.pnpm')"
assert_eq "no bash fence in tidy.md runs git clean against node_modules" "0" \
    "$(printf '%s\n' "$TIDY_BASH_FENCES" | grep -cE 'git clean.*node_modules')"

# ---------------------------------------------------------------------------
echo ""
echo "10. Guard deferral claim (repo#168) is no longer unconditional"
# ---------------------------------------------------------------------------

README_TXT="$(cat "$README_MD")"
SKILL_TXT="$(cat "$SKILL_MD")"
assert_not_contains "README no longer claims Loom defers to this copy" "$README_TXT" \
    "Loom and other tooling defer to this copy rather than shipping their own"
assert_not_contains "SKILL.md no longer claims unconditional deferral" "$SKILL_TXT" \
    "Loom and other tooling defer to this copy instead"
assert_contains "README states the deferral now holds" "$README_TXT" \
    "it now holds"
assert_contains "README names the capability probe" "$README_TXT" \
    "worktree-write-confinement"
assert_contains "SKILL.md states deferral is conditional" "$SKILL_TXT" \
    "Deferral by other tooling is conditional"
assert_contains "SKILL.md records the single-marker hazard" "$SKILL_TXT" \
    "switches which guard runs entirely"
assert_contains "SKILL.md records the remaining deliberate divergence" "$SKILL_TXT" \
    "stricter on IAM deletion"

# The docs now claim the deferral HOLDS, which is only true while the guard
# actually emits the marker. If the marker is ever removed or renamed, the
# claim silently becomes false — this fails and names the files to correct.
# (Before repo#188 this assertion ran in the opposite direction, guarding the
# "does not currently hold" wording; it flipped when parity was reached.)
GUARD_SH="$REPO_ROOT/hooks/repo/guard-destructive.sh"
if [[ -f "$GUARD_SH" ]]; then
    if grep -q 'worktree-write-confinement' "$GUARD_SH"; then
        ok "docs match reality: guard emits the capability marker"
    else
        no "docs match reality: guard emits the capability marker" \
           "guard-destructive.sh no longer emits worktree-write-confinement, but README.md and skills/repo/SKILL.md still say Loom's dispatcher defers to it — restore the 'does not currently hold' qualifier in both"
    fi
else
    skip "docs match reality: guard emits the capability marker" "guard not found at $GUARD_SH"
fi

# Parity is the precondition for emitting that marker, so pin the two gaps the
# reconciliation closed. Each has a tempting "simplification" that reopens it.
assert_contains "guard covers git stash pop/drop/clear" "$(cat "$GUARD_SH")" \
    'stash[[:space:]]+(pop|drop|clear)'
assert_contains "stash guard is toggleable" "$(cat "$GUARD_SH")" \
    "REPO_GUARD_STASH_SCOPE"
# The four checks that must scan the literal-redacted copy, not the raw command.
GUARD_TXT="$(cat "$GUARD_SH")"
assert_contains "SQL DDL scans the redacted working copy" "$GUARD_TXT" \
    'echo "$COMMAND_ASK_SCAN" | grep -qiE "$SQL_DDL_PATTERN"'
assert_contains "cloud-CLI ask scans the redacted working copy" "$GUARD_TXT" \
    'echo "$COMMAND_ASK_SCAN" | grep -qE "$pattern" && cloud_guard_enabled'
assert_contains "force-op parse reads the redacted working copy" "$GUARD_TXT" \
    'parse_force_ops "$COMMAND_ASK_SCAN"'
# The symlinked-ancestor half of the #4495 class.
assert_contains "write confinement resolves a physical spelling" "$GUARD_TXT" \
    "_wt_physical_form"

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

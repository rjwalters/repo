#!/usr/bin/env bash
# Test suite for /repo:tidy's batched reference scans, its CACHE-tree exclusion
# from the ignored-file inventory, and the --fast/--deep cost dial (repo#533).
#
# Usage: ./commands/repo/tests/test-tidy-scan-batching.sh
# Exit code 0 = all tests pass, 1 = failures detected.
#
# Structured like commands/repo/tests/test-tidy-mcp-dist-demotion.sh next door:
# pure bash, no test framework, PASS/FAIL/SKIP/TOTAL counters and a summary
# block. `pnpm test` delegates to this file via hooks/repo/tests/run.sh.
#
# WHY THIS FILE EXISTS (repo#533): on a repo with tens of thousands of tracked
# files, a multi-gigabyte build cache inside the tree, and dozens of registered
# worktrees, step 1's inventory blew the five-minute command timeout and step
# 2's reference scan blew a further two minutes on six empty directories. The
# reference scan was written as a generic per-item instruction ("for any empty
# directory that clears the denylist check, run a cheap cross-reference scan"),
# so an agent following it literally ran one full-tree scan per candidate —
# twice per candidate, in fact, for the path and the basename. Nothing in the
# command bounded the cost in the NUMBER OF CANDIDATES, and there was no flag to
# opt out the way `--sizes` already gates the `du` walk.
#
# The contract under test:
#   1  the empty-directory reference scan is ONE batched pass: collect every
#      denylist-cleared candidate first, then scan once — never a scan per
#      candidate
#   2  batching is a traversal optimization ONLY: the batched pass and the
#      per-candidate (`--deep`) pass must demote exactly the same candidates,
#      with the same reason text ("referenced by N files")
#   3  an empty candidate set is a no-op, never a `git grep` with an empty
#      pattern file (which matches nothing or everything depending on version)
#   4  `git clean -ndX` excludes the CACHE-tier trees, which the cheap
#      directory-level `find` reports instead — and the two non-working
#      alternatives (`:(exclude)` pathspec magic, `-e`) are documented AS
#      non-working so nobody re-adds them
#   5  `--fast` / `--deep` are documented in the Usage block, neither is the
#      default, and `--fast` routes unscanned candidates to ASK — a check that
#      was not run is not a check that passed (safety rule 11)
#
# Two sections: a fixture section that runs both scan shapes (batched and
# per-candidate) against real git repositories and asserts they agree, and a
# doc-drift section asserting tidy.md still says what this suite implements.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CMD_DIR="$REPO_ROOT/commands/repo"

TIDY_MD="$CMD_DIR/tidy.md"

# Assertion helpers (ok/no/skip/assert_eq/assert_contains/assert_not_contains/
# assert_matches) plus the PASS/FAIL/SKIP/TOTAL counters and color vars are
# shared across the repo test suites — see lib/assert.sh (repo#307).
source "$(dirname "${BASH_SOURCE[0]}")/lib/assert.sh"
# Fixture hermeticity (repo#518): a Loom-dispatched session overrides
# core.hooksPath through GIT_CONFIG_* env pairs (loom-daemon's provenance
# hooks), which fixture repos inherit unless the override is scrubbed — see
# lib/git-fixture.sh.
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-fixture.sh"
git_fixture_scrub_env

if [[ ! -f "$TIDY_MD" ]]; then
    echo "FATAL: tidy.md not found at $TIDY_MD" >&2
    exit 1
fi

SCRATCH="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$SCRATCH"' EXIT

# ---------------------------------------------------------------------------
# The two scan shapes under test — direct transcriptions of tidy.md step 2.
# ---------------------------------------------------------------------------
# Both take a repo and a newline-separated candidate list (empty directories
# that already cleared the denylist) and emit one `<candidate>\treferenced by N
# files` line per DEMOTED candidate, in candidate order. A candidate with no
# hit emits nothing — it stays SAFE.
#
# scan_batched is the default documented shape: collect, then ONE
# `git grep -I -n -F -f <patterns>` pass for the whole set.
# scan_per_candidate is the `--deep` / pre-batching shape: one pass per
# candidate, for its path and for its basename.
#
# The suite's central assertion is that these two agree on every fixture. That
# is the invariant tidy.md states ("batching is a traversal optimization only
# and must never change what is reported"); if a future edit to the batched
# instruction breaks it, this is what fails.

# patterns_for <candidate> -> the fixed strings the scan searches for: the
#   candidate's repo-relative path, plus its bare leaf name. Shared by both
#   shapes so the two differ ONLY in how many passes they make.
patterns_for() {
    local c="${1%/}"
    printf '%s\n' "$c"
    printf '%s\n' "${c##*/}"
}

scan_batched() {  # <repo> <candidates-newline-separated>
    local r="$1" cands="$2" c
    local pat="$SCRATCH/patterns.$$"

    # Step 2 of the documented procedure: short-circuit on an empty candidate
    # set. An empty `-f` file is not portably "matches nothing", so the scan
    # must not be invoked at all.
    [[ -n "${cands//[[:space:]]/}" ]] || return 0

    : > "$pat"
    while IFS= read -r c; do
        [[ -n "$c" ]] || continue
        patterns_for "$c" >> "$pat"
    done <<< "$cands"

    # ONE pass over tracked files for every candidate at once.
    local hits
    hits="$(git -C "$r" grep -I -n -F -f "$pat" -- . 2>/dev/null)"
    rm -f "$pat"

    # Attribute each hit line back to its candidate, counting DISTINCT
    # referencing files per candidate.
    while IFS= read -r c; do
        [[ -n "$c" ]] || continue
        local n p files=""
        while IFS= read -r p; do
            [[ -n "$p" ]] || continue
            local file="${p%%:*}" rest="${p#*:}"
            rest="${rest#*:}"
            if [[ "$rest" == *"${c%/}"* || "$rest" == *"${c##*/}"* ]]; then
                files+="$file"$'\n'
            fi
        done <<< "$hits"
        n="$(printf '%s' "$files" | grep -c . )"
        [[ "$n" -gt 0 ]] && printf '%s\treferenced by %s files\n' "$c" "$n"
    done <<< "$cands"
}

scan_per_candidate() {  # <repo> <candidates-newline-separated>
    local r="$1" cands="$2" c
    while IFS= read -r c; do
        [[ -n "$c" ]] || continue
        # The pre-batching shape: a separate full-tree pass per pattern, so two
        # passes per candidate (path, then leaf name).
        local files n
        files="$( {
            git -C "$r" grep -I -l -F -e "${c%/}" -- . 2>/dev/null
            git -C "$r" grep -I -l -F -e "${c##*/}" -- . 2>/dev/null
        } | sort -u )"
        n="$(printf '%s' "$files" | grep -c . )"
        [[ "$n" -gt 0 ]] && printf '%s\treferenced by %s files\n' "$c" "$n"
    done <<< "$cands"
}

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

# mkrepo <name> <path>=<content>... -> path to a fresh git repo whose tracked
#   files carry the given contents (the contents are what the scan searches).
mkrepo() {
    local name="$1"; shift
    local r="$SCRATCH/$name"
    mkdir -p "$r"
    git_fixture_init "$r"
    git -C "$r" config user.email t@example.com
    git -C "$r" config user.name Test
    local spec p body
    for spec in "$@"; do
        p="${spec%%=*}"
        body="${spec#*=}"
        mkdir -p "$r/$(dirname "$p")"
        printf '%s\n' "$body" > "$r/$p"
    done
    git -C "$r" add -A >/dev/null 2>&1
    git -C "$r" commit -qm init >/dev/null 2>&1
    printf '%s' "$r"
}

echo "/repo:tidy batched reference-scan test suite"
echo "==========================================="

# ---------------------------------------------------------------------------
echo ""
echo "-- the motivating case: 6 candidates, one pass, same answer --"
# ---------------------------------------------------------------------------
# The reported shape: several empty directories clear the denylist at once. The
# pre-batching instruction meant 12 full-tree scans for these 6 candidates; the
# batched instruction means one. The demotions must be identical either way.
SIX="$(mkrepo six \
    'README.md=A repository.' \
    'scripts/deploy.sh=mkdir -p var/spool && cp out/* var/spool/' \
    'app/config.yaml=cache_dir: var/cache' \
    'docs/ops.md=Logs are written to var/log during a run.' \
    'src/main.py=print("hello")')"
SIX_CANDS='var/spool
var/cache
var/log
build
tmp/scratch
dist-empty'
SIX_BATCHED="$(scan_batched "$SIX" "$SIX_CANDS")"
SIX_DEEP="$(scan_per_candidate "$SIX" "$SIX_CANDS")"

assert_eq "the batched pass and the per-candidate pass agree exactly" \
    "$SIX_DEEP" "$SIX_BATCHED"
assert_contains "a referenced spool dir is demoted" "$SIX_BATCHED" \
    "var/spool	referenced by 1 files"
assert_contains "a referenced cache dir is demoted" "$SIX_BATCHED" \
    "var/cache	referenced by 1 files"
assert_contains "a referenced log dir is demoted" "$SIX_BATCHED" \
    "var/log	referenced by 1 files"
assert_not_contains "an unreferenced build/ stays SAFE" "$SIX_BATCHED" "build	"
assert_not_contains "an unreferenced tmp/scratch stays SAFE" \
    "$SIX_BATCHED" "tmp/scratch	"
assert_eq "exactly three of the six candidates demote" "3" \
    "$(printf '%s\n' "$SIX_BATCHED" | grep -c . )"

# ---------------------------------------------------------------------------
echo ""
echo "-- the reason text is unchanged by batching --"
# ---------------------------------------------------------------------------
# The reason string is the part an operator reads, and tidy.md pins it
# ("referenced by N files"). Batching must not reword or re-count it.
MULTI="$(mkrepo multi \
    'a.sh=cd var/spool' \
    'b.sh=rm -rf var/spool/*' \
    'c.md=var/spool holds the queue.' \
    'unrelated.txt=nothing here')"
MULTI_CANDS='var/spool'
assert_eq "a candidate referenced by 3 files reports 3, batched" \
    "var/spool	referenced by 3 files" "$(scan_batched "$MULTI" "$MULTI_CANDS")"
assert_eq "the per-candidate pass reports the same count" \
    "$(scan_per_candidate "$MULTI" "$MULTI_CANDS")" \
    "$(scan_batched "$MULTI" "$MULTI_CANDS")"

# ---------------------------------------------------------------------------
echo ""
echo "-- edge case: zero candidates is a no-op, not an empty-pattern scan --"
# ---------------------------------------------------------------------------
# tidy.md's short-circuit exists because `git grep -f <empty-file>` is not
# portably "matches nothing" — the failure mode is reporting EVERY candidate as
# referenced, or erroring out mid-step. With no candidates there is nothing to
# report either way, so the assertion is that it is silent and succeeds.
EMPTYSET="$(mkrepo emptyset 'README.md=nothing' 'src/app.py=pass')"
OUT_EMPTY="$(scan_batched "$EMPTYSET" "")"
EMPTY_RC=$?
assert_eq "an empty candidate set produces no output" "" "$OUT_EMPTY"
assert_eq "an empty candidate set does not fail the step" "0" "$EMPTY_RC"
assert_eq "a whitespace-only candidate set is also a no-op" "" \
    "$(scan_batched "$EMPTYSET" $'\n  \n')"

# A repo with no tracked file referencing anything: the scan runs, finds
# nothing, and demotes nothing. This is the common case and must stay silent.
assert_eq "candidates with no hits anywhere demote nothing" "" \
    "$(scan_batched "$EMPTYSET" $'build\ntmp/scratch')"

# ---------------------------------------------------------------------------
echo ""
echo "-- equivalence holds on the awkward shapes too --"
# ---------------------------------------------------------------------------
# A generic leaf name (`cache`) matched by basename, a path containing regex
# metacharacters (`.state`), and a candidate whose leaf name is a substring of
# another candidate's — the three shapes most likely to diverge between one
# batched pattern file and N separate passes.
AWK="$(mkrepo awkward \
    'Makefile=clean:\n\trm -rf cache' \
    'tool.cfg=state_dir = .state' \
    'notes.md=The cache-index file lives elsewhere.' \
    'src/lib.rs=fn main() {}')"
AWK_CANDS='cache
.state
cache-index
var/cache'
assert_eq "batched and per-candidate agree on generic/meta/substring leaves" \
    "$(scan_per_candidate "$AWK" "$AWK_CANDS")" \
    "$(scan_batched "$AWK" "$AWK_CANDS")"
# -F is load-bearing: `.state` must be a fixed string, not a regex whose `.`
# matches any character. A regex read would also match `xstate`, which no
# fixture file contains — so assert the hit count is the literal one.
assert_contains ".state is matched as a fixed string" \
    "$(scan_batched "$AWK" '.state')" ".state	referenced by 1 files"

# ---------------------------------------------------------------------------
echo ""
echo "-- verified: git clean does NOT honour :(exclude) pathspec magic --"
# ---------------------------------------------------------------------------
# tidy.md documents this as a negative result, with the git version it was
# checked on, precisely so a future editor does not "optimize" the step by
# adding an exclusion that silently is not one. This fixture is the check.
GC="$(mkrepo gcexclude '.gitignore=dist/' 'src/main.js=console.log(1)')"
mkdir -p "$GC/dist/sub"
printf 'x\n' > "$GC/dist/bundle.js"
printf 'x\n' > "$GC/dist/sub/chunk.js"
GC_PLAIN="$(git -C "$GC" clean -ndX 2>/dev/null)"
assert_contains "git clean -ndX reports the ignored dist/ tree" "$GC_PLAIN" "dist/"
for PS in ':(exclude)dist' ':!dist/' ':(exclude,glob)**/dist/**'; do
    GC_EX="$(git -C "$GC" clean -ndX -- . "$PS" 2>/dev/null)"
    assert_contains "pathspec $PS does NOT suppress dist/ (so it is not an exclusion)" \
        "$GC_EX" "dist/"
done
# ...and `-e` is the opposite lever: it ADDS to the ignore rules in effect, so
# under -X it makes MORE paths eligible for removal, never fewer.
printf 'keepme\n' > "$GC/notignored.txt"
GC_E="$(git -C "$GC" clean -ndX -e 'notignored.txt' 2>/dev/null)"
assert_contains "git clean -e widens -X rather than narrowing it" \
    "$GC_E" "notignored.txt"

# The documented cheap path: a pruned directory-level find reports each
# CACHE-tier tree as ONE line without descending into it.
mkdir -p "$GC/packages/ui/dist" "$GC/pkg/__pycache__" "$GC/node_modules/dep/dist"
printf 'x\n' > "$GC/packages/ui/dist/a.js"
printf 'x\n' > "$GC/pkg/__pycache__/x.pyc"
printf 'x\n' > "$GC/node_modules/dep/dist/y.js"
CACHE_DIRS="$(cd "$GC" && find . \( -name .git -o -name node_modules -o -name .venv \) -prune \
    -o -type d \( -name dist -o -name .turbo -o -name .astro \
                  -o -name __pycache__ -o -name .pytest_cache \
                  -o -name .mypy_cache -o -name .ruff_cache \
                  -o -name htmlcov \) -prune -print | sort)"
assert_contains "the directory-level find reports ./dist" "$CACHE_DIRS" "./dist"
assert_contains "the directory-level find reports a nested dist" \
    "$CACHE_DIRS" "./packages/ui/dist"
assert_contains "the directory-level find reports __pycache__" \
    "$CACHE_DIRS" "./pkg/__pycache__"
assert_not_contains "it does not descend into a reported dist/" \
    "$CACHE_DIRS" "dist/sub"
assert_not_contains "node_modules is still pruned before the match" \
    "$CACHE_DIRS" "node_modules"

# ---------------------------------------------------------------------------
echo ""
echo "-- doc drift: tidy.md still specifies what this suite implements --"
# ---------------------------------------------------------------------------
# Phrases are asserted against a whitespace-flattened copy, since the
# requirement is prose that wraps across lines. (flatten() is defined in
# lib/assert.sh)
TIDY="$(flatten "$TIDY_MD")"

# --- AC 1: the empty-directory scan is ONE batched pass ---
assert_contains "the empty-dir scan header says ONE batched pass per candidate set" \
    "$TIDY" 'ONE batched pass over every candidate, never one scan per directory'
assert_contains "the instruction is collect-first, scan-once" \
    "$TIDY" '**Collect the candidates first, then scan once**'
assert_contains "the cost is stated as independent of candidate count" \
    "$TIDY" 'one pass over the tree whatever the candidate count, not a pass per candidate'
assert_contains "step 1 of the procedure collects without scanning" \
    "$TIDY" '**Collect.** Build the candidate list'
assert_contains "the batched scan is a single git grep -F -f invocation" \
    "$TIDY" 'git grep -I -n -F -f "$PATTERNS" -- .'
assert_contains "the two patterns are two lines, not two scans" \
    "$TIDY" 'it is now two *lines*, not two *scans*'
assert_contains "hits are attributed back to candidates after the single pass" \
    "$TIDY" '**Attribute.** For each hit line'
assert_contains "a large candidate set is chunked, never unbatched" \
    "$TIDY" 'the bound is one pass per chunk, never one pass per candidate'
# The per-item wording this issue replaced must not come back.
assert_not_contains "the per-directory loop instruction is gone" \
    "$TIDY" 'For any empty directory that clears the denylist check, run a cheap cross-reference scan'
assert_not_contains "the per-directory grep -rl recipe is gone" \
    "$TIDY" '`grep -rl` its path (or just its dirname, for a generic name) across tracked files'

# --- AC 4: batching preserves today's semantics exactly ---
assert_contains "batching is declared a traversal optimization only" \
    "$TIDY" '**Batching is a traversal optimization only and must never change what is reported**'
assert_contains "the SAFE->ASK demotion reason text is unchanged" \
    "$TIDY" 'demotes it from SAFE to ASK, reported with its reason (e.g. "referenced by N files")'
assert_contains "an unhit candidate still remains SAFE" \
    "$TIDY" 'A directory with no reference hit and no denylist match remains SAFE'
assert_contains "the scan is still purely a demotion" \
    "$TIDY" 'it only ever demotes a would-be SAFE empty directory'
assert_contains "the CACHE scan reads each config source once per run" \
    "$TIDY" 'read each config source exactly once per run, never once per candidate'
assert_contains "the CACHE scan matches candidates against an in-memory set" \
    "$TIDY" 'read them once into a single set of referenced paths'
# The CACHE-side demotion contract (repo#410) must survive verbatim.
assert_contains "the CACHE->ASK reason wording is unchanged" \
    "$TIDY" '← live MCP bundle (referenced by <config-path>)'
assert_contains "an unhit CACHE entry still stays CACHE" \
    "$TIDY" 'a CACHE entry with no reference hit stays CACHE exactly as before'

# --- AC 3 (no-op edge case) ---
assert_contains "an empty candidate set short-circuits the scan" \
    "$TIDY" '**Short-circuit on empty.**'
assert_contains "tidy.md forbids scanning with an empty pattern file" \
    "$TIDY" 'Never invoke the scan with an empty pattern file'
assert_contains "tidy.md says why an empty pattern file is unsafe" \
    "$TIDY" 'an empty `-f` file is not portably "matches nothing"'

# --- AC 2: git clean -ndX excludes the CACHE-tier trees ---
assert_contains "step 1 states the CACHE trees are excluded from the ignored-file listing" \
    "$TIDY" '**The CACHE-tier trees are excluded from the ignored-file listing, because the directory-level `find` above already reports them.**'
assert_contains "step 1 names git clean -ndX as the expensive half" \
    "$TIDY" '`git clean -ndX` is the expensive half of this step'
for TREE in 'dist' '.turbo' '.astro' '__pycache__' '.pytest_cache' '.mypy_cache' '.ruff_cache'; do
    assert_contains "the excluded CACHE trees name $TREE" \
        "$TIDY" "\`$TREE\`"
done
assert_contains "the exclusion changes discovery, never the reported tier" \
    "$TIDY" 'changes **how** a CACHE tree is discovered, never **whether** it is reported or what tier it lands in'
assert_contains "the mechanism is bucket-as-you-stream plus the directory find" \
    "$TIDY" 'bucket-as-you-stream plus the directory-level `find`'
assert_contains "step 1 tells the reader to stream, not collect" \
    "$TIDY" 'STREAM this and bucket as you go — never collect the raw output'
assert_contains "the git clean walk is bounded by timeout like the du walk" \
    "$TIDY" 'timeout 120 git clean -ndX'
assert_contains "a tripped timeout degrades to a partial inventory" \
    "$TIDY" 'report the ignored-file inventory as **partial**'
# The verified negative results, so nobody re-adds a non-exclusion.
assert_contains "tidy.md records that pathspec exclude magic does not apply" \
    "$TIDY" '**Pathspec exclude magic does not apply.**'
assert_contains "the negative result carries the git version it was checked on" \
    "$TIDY" 'checked on git 2.55.0'
assert_contains "tidy.md forbids re-adding the fake exclusion" \
    "$TIDY" 'Do not "fix" this step by adding one; it reads as an exclusion and silently is not one'
assert_contains "tidy.md records that -e is the wrong direction" \
    "$TIDY" '**`-e <pattern>` is the wrong direction.**'
# The directory-level find must prune AT each match rather than descend.
assert_contains "the CACHE-tier find prunes at the match" \
    "$TIDY" 'stops the walk AT the match, so a 3 GB dist/ costs one stat, not a descent'
assert_contains "the prune-list note carves out the CACHE-tier walk" \
    "$TIDY" 'The CACHE-tier walk is deliberately **not** in that pair'

# --- AC 3: the expected-cost note and the --fast/--deep flag ---
assert_contains "step 1 carries an expected-cost note" \
    "$TIDY" '**Expected cost of this step, and where the reference scans fit.**'
assert_contains "the cost note explains what used to be unbounded" \
    "$TIDY" 'unbounded in the *number of candidates* rather than in repo size'
assert_contains "the cost note cites the two-minute overrun" \
    "$TIDY" 'blew a further two-minute budget on top of the inventory'
assert_contains "the cost note ties the flag to the --sizes/--caches precedent" \
    "$TIDY" 'the same call `--sizes` and `--caches` already make'

assert_contains "the Usage block documents --fast" \
    "$TIDY" '/repo:tidy --fast'
assert_contains "the Usage block documents --deep" \
    "$TIDY" '/repo:tidy --deep'
assert_contains "the Usage line for --fast states the ASK routing" \
    "$TIDY" 'Skip the reference scans entirely; unscanned candidates land in ASK, not SAFE'
assert_contains "the Usage line for --deep states it is per-candidate and audit-only" \
    "$TIDY" 'One reference scan per candidate instead of one batched pass (audit only)'
assert_contains "neither flag is the default" \
    "$TIDY" '**`--fast` / `--deep` are the two ends of the reference-scan cost dial, and neither is the default.**'
assert_contains "the default is stated as the batched pass" \
    "$TIDY" 'The default is **one batched reference pass** over the whole candidate set'
assert_contains "--deep is an audit, not a second answer" \
    "$TIDY" 'It exists to **audit** the batched pass, not to get a different answer'
assert_contains "a --deep/default disagreement is a bug in the batched pass" \
    "$TIDY" 'that is a bug in the batched pass and not a feature of `--deep`'
assert_contains "the two flags are mutually exclusive with --fast winning" \
    "$TIDY" 'If both are passed, `--fast` wins'

# --- --fast may only ever shrink the auto-delete set ---
assert_contains "a skipped check is not a passed check" \
    "$TIDY" 'a check that was not run is not a check that passed'
assert_contains "the ASK tier lists the --fast skip as a source" \
    "$TIDY" '**Any candidate whose reference scan was skipped because `--fast` was passed**'
assert_contains "the skip reason text is pinned" \
    "$TIDY" 'reference scan skipped (--fast)'
assert_contains "the apply step states --fast deletes a subset" \
    "$TIDY" '`--fast` can only ever delete less, never more or something different'
assert_contains "--fast shrinks what --caches clears, never grows it" \
    "$TIDY" 'under `--fast`, `--caches` clears strictly less than it would by default, never more'
assert_contains "safety rule 11 exists and is named for the asymmetry" \
    "$TIDY" '11. **A skipped check never widens what is deleted**'
assert_contains "safety rule 11 generalizes to future cost flags" \
    "$TIDY" 'making tidy cheaper may shrink the auto-delete set, never grow it'
assert_contains "the report shows a --fast ASK line with the skip reason" \
    "$TIDY" 'build/ empty ← reference scan skipped (--fast)'

# Invariants this change must not touch: the tier contracts and the safety
# rules that predate it.
assert_contains "safety rule 6 (gitignored != safe) is unchanged" \
    "$(cat "$TIDY_MD")" '6. **Gitignored ≠ safe to delete**'
assert_contains "safety rule 7 (caches are opt-in) is unchanged" \
    "$(cat "$TIDY_MD")" '7. **Caches are opt-in**'
assert_contains "safety rule 8 (empty != abandoned) is unchanged" \
    "$(cat "$TIDY_MD")" '8. **Empty ≠ abandoned**'
assert_contains "the denylist still wins over both allowlists" \
    "$TIDY" 'denylist first, then the SAFE and CACHE allowlists, then fall through to ASK'
# --fast/--deep are cost dials, not deletion widening: ASK stays never-automatic.
assert_contains "ASK remains never-automatic under any flag" \
    "$TIDY" 'Never auto-delete anything in ASK, no matter the flags'

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

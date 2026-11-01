#!/usr/bin/env bash
# Test suite for /repo:deps' CI value `none` and the uv ecosystem row
# (repo#731, repo#730).
#
# Usage: ./commands/repo/tests/test-deps-no-ci.sh
# Exit code 0 = all tests pass, 1 = failures detected.
#
# Structured like commands/repo/tests/test-deps-security-updates-paused.sh:
# pure bash, no test framework, PASS/FAIL/SKIP/TOTAL counters and a summary
# block. `pnpm test` delegates to this file via hooks/repo/tests/run.sh.
#
# WHY THIS FILE EXISTS (repo#731): steps 8 and 9 classified and merged bot PRs
# on CI status alone — green merges, red or pending never does — and a repo
# with NO workflows produced none of those states. Every bot PR there showed
# "no checks reported", the agent had to improvise a local build, and the
# summary read as if the PRs were plain green. On the run behind the issue,
# one of three first-scan majors did not compile, which only a local check
# caught. The ways this can silently rot back:
#
#   - `none` gets folded into `pending` (never resolves) or `green` (nothing
#     passed), and the merge rule in step 9 goes back to reading only
#     red/pending.
#   - The local-check substitute loses its CI-column format, so a checked PR
#     and an unchecked one render identically.
#   - /repo:all's `Deps:` line drops the `no CI` clause, so a bare PR count
#     reads as checked PRs on a repo with no checks.
#
# And repo#730, pinned here because it lands in the same file: step 2 mapped
# `pyproject.toml` to `pip` only, so a project locked with `uv.lock` was
# scaffolded against an ecosystem that does not update its lockfile.
#
# The contract under test:
#   1  step 8 names `none` as a fourth CI value, distinct from `pending`
#   2  the local-check substitute exists, with the `none; local <command>
#      ok|failed` column format and per-ecosystem commands (cargo, uv, npm)
#   3  step 9 forbids merging a `none` PR on its title alone; majors still
#      need their own confirmation; the report recommends adding CI
#   4  /repo:all's `Deps:` line carries `no CI`, with an example line
#   5  step 2 has a `uv` row, the probe includes uv.lock, step 2a's example
#      labels uv.lock as uv, and step 4 shows a uv scaffold entry

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
DEPS_MD="$REPO_ROOT/commands/repo/deps.md"
ALL_MD="$REPO_ROOT/commands/repo/all.md"

# Assertion helpers plus the PASS/FAIL/SKIP/TOTAL counters and color vars are
# shared across the repo test suites — see lib/assert.sh (repo#307).
source "$(dirname "${BASH_SOURCE[0]}")/lib/assert.sh"

for f in "$DEPS_MD" "$ALL_MD"; do
    if [[ ! -f "$f" ]]; then
        echo "FATAL: required file not found at $f" >&2
        exit 1
    fi
done

DEPS="$(cat "$DEPS_MD")"
DEPS_FLAT="$(flatten "$DEPS_MD")"
ALL="$(cat "$ALL_MD")"
ALL_FLAT="$(flatten "$ALL_MD")"

# Isolate a step's body by its heading and the next step's heading.
section() {  # <file> <start-ere> <end-ere>
    local from to
    from="$(grep -nE "$2" "$1" | head -1 | cut -d: -f1)"
    to="$(grep -nE "$3" "$1" | head -1 | cut -d: -f1)"
    if [[ -n "$from" && -n "$to" && "$from" -lt "$to" ]]; then
        sed -n "${from},${to}p" "$1"
    fi
}
STEP2="$(section "$DEPS_MD" '^### 2\. Detect the ecosystems' '^### 3\. Validate every label')"
STEP4="$(section "$DEPS_MD" '^### 4\. Offer to scaffold' '^### 5\. Offer to enable')"
STEP8="$(section "$DEPS_MD" '^### 8\. Classify each PR' '^### 9\. Offer to merge')"
STEP9="$(section "$DEPS_MD" '^### 9\. Offer to merge' '^#### A lockfile-bearing ecosystem')"
STEP8_FLAT="$(printf '%s\n' "$STEP8" | tr '\n' ' ' | tr -s ' ')"
STEP9_FLAT="$(printf '%s\n' "$STEP9" | tr '\n' ' ' | tr -s ' ')"
STEP2_FLAT="$(printf '%s\n' "$STEP2" | tr '\n' ' ' | tr -s ' ')"

# ---------------------------------------------------------------------------
echo "1. Step 8 names \`none\` as a fourth CI value, distinct from pending"
# ---------------------------------------------------------------------------

assert_matches "deps.md declares name: deps" "$DEPS" '^name: "deps"'
[[ -n "$STEP8" ]] && ok "step 8 ('Classify each PR') is locatable" \
    || no "step 8 ('Classify each PR') is locatable" "heading renamed or reordered?"
assert_contains "the four CI values are enumerated at the report site" "$STEP8_FLAT" \
    'one of `green`, `red`, `pending`, or `none`'
assert_matches "a dedicated CI none sub-step exists" "$STEP8" \
    '^#### CI `none` — the repo has no workflows at all$'
assert_contains "none is distinguished from pending by what it waits for" "$STEP8_FLAT" \
    "there are no checks to wait for"
assert_contains "none is detected from the empty workflows probe" "$STEP8_FLAT" \
    "git ls-files '.github/workflows/*'"
assert_contains "none is never rendered as green" "$STEP8_FLAT" \
    'never as `green`'
assert_contains "none is never rendered as pending" "$STEP8_FLAT" \
    'never as `pending`'
assert_contains "none is a fourth value, not one of the three" "$STEP8_FLAT" \
    "fourth value"

# ---------------------------------------------------------------------------
echo ""
echo "2. The local-check substitute, its column format, and its commands"
# ---------------------------------------------------------------------------

assert_contains "the substitute is a local check of the PR head" "$STEP8_FLAT" \
    "local check of the PR head"
assert_contains "only step 9's merge candidates are checked, not the whole queue" "$STEP8_FLAT" \
    "only those, not the whole queue"
assert_matches "the PR head is fetched into a temporary worktree" "$STEP8" \
    '^git worktree add "\$SCRATCH/deps-pr-<N>" "deps-pr-<N>"$'
assert_contains "the ok column format is named" "$STEP8_FLAT" \
    '`none; local <command> ok`'
assert_contains "the failed column format is named" "$STEP8_FLAT" \
    '`none; local <command> failed`'
assert_matches "cargo has a local check" "$STEP8" \
    '^\| `cargo` \| `cargo check --locked`'
assert_matches "uv has a local check" "$STEP8" \
    '^\| `uv` \| `uv sync --locked'
assert_matches "npm has a local check" "$STEP8" \
    '^\| `npm` \| `npm ci && npm run build`'
assert_matches "ecosystems with nothing to run record unverified, not ok" "$STEP8" \
    '^\| `github-actions`, `docker` \|.*`none; unverified`'
assert_matches "the example table shows a failed local check in the CI column" "$STEP8" \
    '\| MAJOR \| none; local cargo check failed'
assert_matches "the example table shows a passing local check in the CI column" "$STEP8" \
    '\| MAJOR \| none; local cargo check ok'
assert_contains "a failed local check is handled like red CI" "$STEP8_FLAT" \
    'is handled exactly like red CI in step 9'
assert_matches "the summary split carries the no CI clause" "$STEP8" \
    '^3 open, 2 majors, no CI — local checks substituted; add a workflow$'
assert_contains "the report recommends adding CI and names the ecosystems" "$STEP8_FLAT" \
    "recommend adding CI in the report, naming the ecosystems"
assert_contains "writing the workflow is explicitly not this step's job" "$STEP8_FLAT" \
    "never something this step scaffolds"

# ---------------------------------------------------------------------------
echo ""
echo "3. Step 9 never merges a none PR on its title alone"
# ---------------------------------------------------------------------------

[[ -n "$STEP9" ]] && ok "step 9 ('Offer to merge the safe ones') is locatable" \
    || no "step 9 ('Offer to merge the safe ones') is locatable" "heading renamed or reordered?"
assert_contains "a none PR is never merged on its title alone" "$STEP9_FLAT" \
    'A PR whose CI is `none` is never merged on its title alone'
assert_contains "a passing local check is the minimum" "$STEP9_FLAT" \
    "The minimum is a passing local check of its head"
assert_contains "failed is red and unverified is pending — neither merges" "$STEP9_FLAT" \
    "neither merges"
assert_contains "majors keep their separate confirmation" "$STEP9_FLAT" \
    "A major still gets its own separate confirmation"
assert_contains "the proposal says the evidence is a local check, not CI" "$STEP9_FLAT" \
    "the evidence is a local check rather than CI"
assert_contains "the merge rule still refuses red or pending CI" "$STEP9_FLAT" \
    "never merge a PR whose CI is red or pending"
assert_contains "safety rule 6 carries the none rule" "$DEPS_FLAT" \
    'a PR with no CI at all (`none`) is never merged on its title alone'

# ---------------------------------------------------------------------------
echo ""
echo "4. /repo:all's Deps: line carries no CI"
# ---------------------------------------------------------------------------

assert_contains "all.md says a no-workflows repo gets a no CI clause" "$ALL_FLAT" \
    'A repo with no workflows gets a `no CI` clause on the line, not a bare PR count'
assert_contains "all.md names the failure it prevents" "$ALL_FLAT" \
    "passed checks the repo does not have"
assert_matches "all.md shows an example Deps: line with the clause" "$ALL" \
    '^Deps: +…, 3 open PRs \(2 majors, no CI — local checks substituted; add a workflow\)$'
# The open-alert clause forms (repo#551) must survive beside the new one.
assert_matches "the UNKNOWN open-alert form is still shown" "$ALL" \
    '^Deps: +…, alerts ON, open alerts UNKNOWN'

# ---------------------------------------------------------------------------
echo ""
echo "5. The uv ecosystem row (repo#730)"
# ---------------------------------------------------------------------------

[[ -n "$STEP2" ]] && ok "step 2 ('Detect the ecosystems') is locatable" \
    || no "step 2 ('Detect the ecosystems') is locatable" "heading renamed or reordered?"
assert_matches "step 2's table has a uv row detected via uv.lock" "$STEP2" \
    '^\| `uv` \| `uv.lock` beside a `pyproject.toml`'
assert_matches "step 2's pip row applies only without uv.lock" "$STEP2" \
    '^\| `pip` \|.*with \*\*no\*\* `uv.lock` beside it'
assert_contains "the git ls-files probe includes uv.lock" "$STEP2_FLAT" \
    "'*uv.lock'"
assert_contains "uv wins over pip for a directory holding both" "$STEP2_FLAT" \
    'is one `uv` directory, not a `pip` entry plus a `uv` entry'
assert_contains "pyproject.toml alone stays pip" "$STEP2_FLAT" \
    'with no `uv.lock` beside it stays `pip`'
assert_matches "step 2a's example labels .anvil/uv.lock as uv" "$STEP2" \
    '^\| \.anvil/uv\.lock +\| uv +\|'
assert_not_contains "no example row labels uv.lock as pip any more" "$STEP2_FLAT" \
    '.anvil/uv.lock | pip'
assert_matches "step 4 shows a uv scaffold entry" "$STEP4" \
    '^  - package-ecosystem: "uv"'
assert_matches "the uv entry keeps the cooldown" "$STEP4" \
    '^      uv-minor-patch:$'
assert_contains "the package-ecosystem policy row names uv" "$STEP4" \
    'package ecosystems (`npm`, `cargo`, `pip`, `uv`, …)'

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

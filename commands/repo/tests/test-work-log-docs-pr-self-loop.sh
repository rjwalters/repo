#!/usr/bin/env bash
# Test suite asserting WORK_LOG.md never records a Guide document-maintenance
# PR — the artifact-side contract behind the self-referential docs-PR loop
# (repo#151, repo#263).
#
# Usage: ./commands/repo/tests/test-work-log-docs-pr-self-loop.sh
# Exit code 0 = all tests pass, 1 = failures detected.
#
# Structured like commands/repo/tests/test-readme-layout-block.sh: pure bash, no
# test framework, PASS/FAIL/SKIP/TOTAL counters and a summary block.
# `pnpm test` delegates to this file via hooks/repo/tests/run.sh.
#
# WHY THIS FILE EXISTS
# ====================
# The Guide role's document-maintenance phase opens a
# `docs: Guide document maintenance update` PR whenever it finds merged PRs or
# closed issues that WORK_LOG.md does not yet record. Its own PRs are merged
# PRs, so if one is ever allowed into that "new content" scan, merging PR N
# manufactures the very signal that justifies PR N+1 and the phase emits a
# content-free PR forever. repo#151 observed the loop; loom's #153/#5454 fixed
# it inside `.loom/roles/guide.md` by excluding docs PRs from the candidate
# query (`GUIDE_DOCS_PR_EXCLUDE`).
#
# repo#263: the loop recurred anyway — PRs #259, #260, #261, #262 merged inside
# two hours on 2026-08-11, #260/#261/#262 each carrying a single WORK_LOG.md
# line recording the immediately-prior docs PR. The investigation found the
# exclusion filter was NOT missing, reverted, or wrong:
#
#   * `GUIDE_DOCS_PR_EXCLUDE` was present and wired into `update_work_log()` at
#     PR #259's exact base commit (3e1f544) and has been continuously since
#     949c483 — before, not after, the 0.18.13 resync the issue first blamed.
#   * Re-running the documented candidate query against live data (133 merged
#     PRs in the 30-day window) excludes all four loop PRs and keeps every real
#     one. The expression works.
#   * PR #259's diff nonetheless ADDS six historical docs-maintenance entries
#     (#150, #155, #157, #160, #162, #172) that the filter excludes and that no
#     earlier tick had ever recorded. Under the documented query those could
#     never have been candidates — so the tick that produced #259 did not run
#     the documented query at all.
#   * loom#5615's cross-host lock gap is ruled out as the mechanism: that
#     failure shape is two docs PRs open CONCURRENTLY (loom#5571/#5572, 49s
#     apart). #259-#262 were strictly sequential, each created 8-52 minutes
#     after its predecessor merged, never two open at once.
#
# So the defect is agent execution fidelity, not file content: `guide.md` is a
# natural-language prompt, its bash is guidance the Guide agent is expected to
# re-type, and the phase's only protection lived in a `jq` clause inside that
# guidance. The same file hands the agent several UNFILTERED merged-PR listings
# in earlier triage phases (`gh pr list --state merged --limit 10|20`), so an
# agent that already has a merged-PR list in context can satisfy "append newly
# merged PRs" from it without ever composing the filtered query. Nothing
# downstream disagreed: CI was green on all four PRs, because nothing anywhere
# inspected what the docs PR actually proposed to write.
#
# THIS FILE IS THAT CHECK. It asserts against the produced ARTIFACT
# (WORK_LOG.md), not against prompt text, so it fires on the agent's actual
# output regardless of which query the agent ran or whether it ran one at all.
# It runs in this repo's own CI on every PR, and `merge-pr.sh` treats a red
# check as a stop signal — so the next occurrence is blocked at the merge gate
# instead of relying on an agent reading a comment correctly.
#
# WHY IT LIVES HERE AND NOT IN `.loom/`
# ------------------------------------
# `.loom/` is installed/vendored from rjwalters/loom and is overwritten
# wholesale by `chore(loom): resync installed Loom surfaces` commits, so a fix
# parked there cannot be relied on to survive. Worse, loom's own regression
# test for this contract — `.loom/scripts/tests/test-guide-work-log-self-loop.sh`
# — cannot run in an installed repo at all: it hardcodes
# `defaults/.claude/commands/loom/guide.md`, a path that only exists in the loom
# SOURCE tree, and exits `FATAL: guide.md not found` here. This repo's `pnpm
# test` never invoked `.loom/scripts/tests/` either. The contract therefore had
# zero automated coverage in this repo when the loop recurred. A repo-owned
# suite is immune to both problems.
#
# The prompt-side fix (have the Guide invoke a checked-in wrapper script instead
# of hand-composing the `jq` filter inline) belongs upstream in rjwalters/loom,
# where `guide.md` is actually maintained; it is deliberately NOT attempted by
# editing the vendored copy here, which the next resync would revert.
#
# KNOWN LIMITATION: detection keys on the docs-maintenance title as it appears
# in a WORK_LOG entry. A docs PR recorded under some other title would not be
# caught — the same blind spot `GUIDE_DOCS_PR_EXCLUDE`'s title arm has, which is
# why that expression also matches on the `docs/guide-update` branch prefix.
# Section 3 pins that second arm.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WORK_LOG="$REPO_ROOT/WORK_LOG.md"
GUIDE_MD="$REPO_ROOT/.loom/roles/guide.md"

# Assertion helpers (ok/no/skip/assert_eq/assert_contains/assert_not_contains/
# assert_matches) plus the PASS/FAIL/SKIP/TOTAL counters and color vars are
# shared across the repo test suites — see lib/assert.sh (repo#307).
source "$(dirname "${BASH_SOURCE[0]}")/lib/assert.sh"

if [[ ! -f "$WORK_LOG" ]]; then
    echo "FATAL: WORK_LOG.md not found at $WORK_LOG" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# The historical self-referential entries, pinned.
#
# repo#263 acceptance criteria: these are left in place as historical record and
# are NOT retroactively scrubbed. They are listed here so that everything OUTSIDE
# this set is a new occurrence of the loop.
#
# #146-#150 predate loom#153's exclusion filter. #155/#157/#160/#162/#172 were
# backfilled by PR #259 (see the header above — the diff that proves the tick ran
# an unfiltered query). #259/#260/#261 are the loop this test exists to stop
# recurring; #262 recorded #261 and was itself never recorded, which is where the
# chain stopped.
#
# THIS LIST IS NOT MEANT TO GROW. Adding a number to it whitelists a fresh
# occurrence of the exact bug the suite guards. If a check here fails, the
# correct response is to remove the offending WORK_LOG entry from the proposed
# docs PR, not to extend this baseline.
# ---------------------------------------------------------------------------
HISTORICAL_DOCS_PRS=(146 147 148 149 150 155 157 160 162 172 259 260 261)

# The exact entry shape the Guide writes for a merged PR:
#   - **PR #261**: docs: Guide document maintenance update
DOCS_ENTRY_RE='^- \*\*PR #([0-9]+)\*\*: docs: Guide document maintenance'

# docs_entry_numbers <work-log-path> -> one PR number per line, for every
# WORK_LOG entry recording a Guide document-maintenance PR. Factored out so
# section 4 can run the identical detection against a fault-injected fixture.
docs_entry_numbers() {
    sed -nE "s/${DOCS_ENTRY_RE}.*/\1/p" "$1"
}

in_baseline() {  # <number>
    local n
    for n in "${HISTORICAL_DOCS_PRS[@]}"; do
        [[ "$n" == "$1" ]] && return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
echo "1. WORK_LOG.md records no NEW Guide document-maintenance PR"
# ---------------------------------------------------------------------------
# The load-bearing assertion. A docs PR whose diff adds one of these lines turns
# this red on its own CI run, before it can be merged and become the "new
# content" that justifies the next one.

FOUND_NUMBERS=()
while IFS= read -r n; do
    [[ -z "$n" ]] && continue
    FOUND_NUMBERS+=("$n")
done < <(docs_entry_numbers "$WORK_LOG")

NEW_OCCURRENCES=()
for n in ${FOUND_NUMBERS[@]+"${FOUND_NUMBERS[@]}"}; do
    in_baseline "$n" || NEW_OCCURRENCES+=("$n")
done

if (( ${#NEW_OCCURRENCES[@]} == 0 )); then
    ok "no docs-maintenance PR outside the pinned historical baseline (${#FOUND_NUMBERS[@]} historical entries)"
else
    no "no docs-maintenance PR outside the pinned historical baseline" \
        "WORK_LOG.md records PR(s) ${NEW_OCCURRENCES[*]} as 'docs: Guide document maintenance update'. The Guide's document-maintenance phase must never record its OWN PRs (repo#151, repo#263): doing so manufactures the 'new content' signal that justifies the next docs PR, forever. Drop the offending line(s) from this change rather than extending HISTORICAL_DOCS_PRS in $SCRIPT_DIR/$(basename "$0")."
fi

# ---------------------------------------------------------------------------
echo ""
echo "2. The historical entries are preserved, not retroactively scrubbed"
# ---------------------------------------------------------------------------
# repo#263 explicitly scopes the fix to preventing recurrence, not backfilling
# history. Pinning the baseline in both directions also stops the list being
# quietly emptied to make section 1 vacuous.

for n in "${HISTORICAL_DOCS_PRS[@]}"; do
    if printf '%s\n' ${FOUND_NUMBERS[@]+"${FOUND_NUMBERS[@]}"} | grep -qx "$n"; then
        ok "historical entry for PR #$n is still recorded"
    else
        no "historical entry for PR #$n is still recorded" \
            "PR #$n is in HISTORICAL_DOCS_PRS but no longer appears in WORK_LOG.md. repo#263 keeps these as historical record; if the removal is deliberate, drop #$n from the baseline in the same change."
    fi
done

# ---------------------------------------------------------------------------
echo ""
echo "3. The vendored Guide prompt still carries a working exclusion filter"
# ---------------------------------------------------------------------------
# Restores, repo-side, the coverage `.loom/scripts/tests/test-guide-work-log-self-loop.sh`
# is supposed to provide but cannot here (it hardcodes a loom-SOURCE path and
# exits FATAL in an installed repo). Section 1 is what actually stops the loop;
# this section catches the narrower regression of a resync landing a guide.md
# whose filter is gone or broken, which would silently raise the odds again.

if [[ ! -f "$GUIDE_MD" ]]; then
    skip "GUIDE_DOCS_PR_EXCLUDE excludes docs PRs and keeps real ones" \
        "no vendored Guide role at $GUIDE_MD (Loom not installed here)"
    skip "update_work_log() applies GUIDE_DOCS_PR_EXCLUDE to its candidate query" \
        "no vendored Guide role at $GUIDE_MD (Loom not installed here)"
elif ! command -v jq >/dev/null 2>&1; then
    skip "GUIDE_DOCS_PR_EXCLUDE excludes docs PRs and keeps real ones" "jq not available"
    skip "update_work_log() applies GUIDE_DOCS_PR_EXCLUDE to its candidate query" "jq not available"
else
    # Extract the single-line assignment. guide.md documents that this line is
    # kept assignable-as-written precisely so a test can lift it out.
    EXCLUDE_EXPR="$(sed -nE "s/^GUIDE_DOCS_PR_EXCLUDE='(.*)'$/\1/p" "$GUIDE_MD" | head -1)"

    if [[ -z "$EXCLUDE_EXPR" ]]; then
        no "GUIDE_DOCS_PR_EXCLUDE excludes docs PRs and keeps real ones" \
            "no single-line GUIDE_DOCS_PR_EXCLUDE='...' assignment found in $GUIDE_MD"
    else
        # Fixtures modeled on the real records of the repo#263 loop, plus a real
        # feature PR that must survive the filter, plus a docs PR that was
        # retitled (branch arm must still catch it) and one landed from an
        # off-prefix branch (title arm must still catch it).
        FIXTURE_JSON='[
          {"number":259,"title":"docs: Guide document maintenance update","headRefName":"docs/guide-update-20260811-triage"},
          {"number":260,"title":"docs: Guide document maintenance update","headRefName":"docs/guide-update-20260811-093418"},
          {"number":261,"title":"docs: Guide document maintenance update","headRefName":"docs/guide-update-20260811-103731"},
          {"number":262,"title":"docs: Guide document maintenance update","headRefName":"docs/guide-update-20260811-105650"},
          {"number":901,"title":"docs: Guide document maintenance update","headRefName":"chore/some-other-branch"},
          {"number":902,"title":"docs: retitled guide sweep","headRefName":"docs/guide-update-20260811-999999"},
          {"number":256,"title":"test(repo): pin sudo.md'"'"'s guard note against the guard it describes","headRefName":"feature/issue-249"},
          {"number":254,"title":"fix(repo): match indented bash fences in test-scrub-contract.sh","headRefName":"feature/issue-251"}
        ]'

        KEPT="$(printf '%s' "$FIXTURE_JSON" \
            | jq -r "[.[] | select((($EXCLUDE_EXPR) | not)) | .number] | sort | join(\",\")" 2>/dev/null)"

        if [[ -z "$KEPT" && $? -ne 0 ]]; then
            no "GUIDE_DOCS_PR_EXCLUDE excludes docs PRs and keeps real ones" \
                "the extracted expression is not valid jq: $EXCLUDE_EXPR"
        elif [[ "$KEPT" == "254,256" ]]; then
            ok "GUIDE_DOCS_PR_EXCLUDE drops all six docs-PR shapes and keeps both real PRs"
        else
            no "GUIDE_DOCS_PR_EXCLUDE excludes docs PRs and keeps real ones" \
                "expected the filter to keep exactly PRs 254,256 — it kept: ${KEPT:-<none>}"
        fi
    fi

    # The expression is inert unless update_work_log()'s candidate query
    # actually applies it AND asks gh for headRefName (jq cannot filter on a
    # field gh was not asked to return; .headRefName would be null and the
    # branch arm would silently never match).
    #
    # #391: the `gh pr list` call that supplies those candidates is NOT always
    # inline in update_work_log() anymore — loom 0.18.96's guide.md moved the
    # fetch into a helper (`fetch_merged_prs_complete()`, which carries its own
    # "`headRefName` MUST stay in the --json field list" comment) that
    # update_work_log() calls. Grepping only update_work_log()'s own body
    # therefore reported a false regression on a guide.md whose behavior was
    # correct. Follow one level of the call chain instead: append the body of
    # every column-0 helper function defined in guide.md that update_work_log()
    # actually calls, and assert the field is requested somewhere in that
    # combined fetch path. The assertion's intent (the branch-prefix arm of
    # GUIDE_DOCS_PR_EXCLUDE can actually match) is unchanged; only the window
    # it searches widened to match where the call really lives.
    extract_fn_body() { # <function-name>
        awk -v fn="$1" '$0 ~ "^" fn "\\(\\) \\{" {f=1} f{print} f && /^\}/{exit}' "$GUIDE_MD"
    }

    QUERY_BLOCK="$(extract_fn_body update_work_log)"
    if [[ -n "$QUERY_BLOCK" ]]; then
        while IFS= read -r helper; do
            [[ -z "$helper" || "$helper" == "update_work_log" ]] && continue
            grep -qE "(^|[^A-Za-z0-9_])${helper}([^A-Za-z0-9_]|\$)" <<< "$QUERY_BLOCK" || continue
            QUERY_BLOCK+=$'\n'"$(extract_fn_body "$helper")"
        done < <(sed -nE 's/^([a-zA-Z_][a-zA-Z0-9_]*)\(\) \{$/\1/p' "$GUIDE_MD" | sort -u)
    fi

    # Widening the search window must not weaken the assertion: it is not
    # enough for `headRefName` to appear SOMEWHERE in the combined block (a
    # sibling helper's unrelated query would satisfy that). Every `gh pr list`
    # in the fetch path must request it. Continuation lines are joined first
    # so a `--json ...` split across a `\` newline is still one logical query.
    # Issue queries are deliberately not checked — `gh issue list` has no
    # headRefName field.
    PR_QUERY_LINES="$(printf '%s\n' "$QUERY_BLOCK" | awk '
        { line = $0
          if (buf != "") { line = buf line }
          if (line ~ /\\$/) { sub(/\\$/, "", line); buf = line; next }
          print line; buf = "" }
        END { if (buf != "") print buf }' | grep -F 'pr list')"
    MISSING_FIELD_QUERY=""
    while IFS= read -r pr_query; do
        [[ "$pr_query" == *"--json"* ]] || continue
        [[ "$pr_query" == *headRefName* ]] && continue
        MISSING_FIELD_QUERY="$pr_query"
        break
    done <<< "$PR_QUERY_LINES"

    if [[ -z "$QUERY_BLOCK" ]]; then
        no "update_work_log() applies GUIDE_DOCS_PR_EXCLUDE to its candidate query" \
            "no update_work_log() body found in $GUIDE_MD"
    elif ! grep -q 'GUIDE_DOCS_PR_EXCLUDE' <<< "$QUERY_BLOCK"; then
        no "update_work_log() applies GUIDE_DOCS_PR_EXCLUDE to its candidate query" \
            "update_work_log() body does not reference GUIDE_DOCS_PR_EXCLUDE at all"
    elif ! grep -q 'headRefName' <<< "$QUERY_BLOCK"; then
        no "update_work_log() applies GUIDE_DOCS_PR_EXCLUDE to its candidate query" \
            "neither update_work_log() nor any helper it calls requests headRefName from gh, so the branch-prefix arm can never match"
    elif [[ -n "$MISSING_FIELD_QUERY" ]]; then
        no "update_work_log() applies GUIDE_DOCS_PR_EXCLUDE to its candidate query" \
            "a gh pr list in the candidate-fetch path omits headRefName from --json, so the branch-prefix arm can never match for it: ${MISSING_FIELD_QUERY}"
    else
        ok "update_work_log() applies GUIDE_DOCS_PR_EXCLUDE and requests headRefName"
    fi
fi

# ---------------------------------------------------------------------------
echo ""
echo "4. Fault injection: the detection actually fires on a fresh occurrence"
# ---------------------------------------------------------------------------
# Section 1 passing is only meaningful if it would have failed on the real
# regression. Run the identical detection against a fixture shaped like PR
# #260's merged diff (one appended line recording the previous docs PR) and
# assert the new number is reported.

FIXTURE_LOG="$(mktemp)"
PREFLIGHT_SANDBOX="$(mktemp -d)"
trap 'rm -f "$FIXTURE_LOG"; rm -rf "$PREFLIGHT_SANDBOX"' EXIT
cat > "$FIXTURE_LOG" <<'FIXTURE'
# Work Log

### 2026-08-11

- **PR #999**: docs: Guide document maintenance update
- **PR #259**: docs: Guide document maintenance update
- **PR #256**: test(repo): pin sudo.md's guard note against the guard it describes
FIXTURE

INJECTED=()
while IFS= read -r n; do
    [[ -z "$n" ]] && continue
    in_baseline "$n" || INJECTED+=("$n")
done < <(docs_entry_numbers "$FIXTURE_LOG")

if [[ "${INJECTED[*]-}" == "999" ]]; then
    ok "an injected 'PR #999: docs: Guide document maintenance update' entry is flagged"
else
    no "an injected 'PR #999: docs: Guide document maintenance update' entry is flagged" \
        "expected the detection to report exactly 999; it reported: ${INJECTED[*]:-<none>}"
fi

# And the converse: a normal feature PR entry must NOT be flagged, so the check
# cannot regress into failing every docs PR that records real work.
CLEAN_HITS="$(docs_entry_numbers "$FIXTURE_LOG" | grep -cx 256)"
if [[ "$CLEAN_HITS" -eq 0 ]]; then
    ok "a normal feature-PR entry is not flagged"
else
    no "a normal feature-PR entry is not flagged" \
        "the detection matched PR #256, which is an ordinary merged PR"
fi

# ---------------------------------------------------------------------------
echo ""
echo "5. Pre-flight freshness check refreshes a stale GUIDE_DOCS_PR_EXCLUDE (#279)"
# ---------------------------------------------------------------------------
# #279: PR #278's first commit recorded a WORK_LOG entry for #277 (a Guide
# docs-maintenance PR) even though GUIDE_DOCS_PR_EXCLUDE, applied correctly,
# excludes it — the leading hypothesis is a STALE local guide.md was loaded
# for that session. guide.md now calls `refresh_docs_pr_exclude_from_origin()`
# right after the GUIDE_DOCS_PR_EXCLUDE assignment (upstream loom#6627, which
# absorbed this repo's earlier local `preflight_refresh_docs_pr_exclude()`
# patch from #280), to re-verify the locally-loaded expression against
# origin/main's current copy of this file and prefer origin's value on
# mismatch. The upstream shape reads and rewrites the GUIDE_DOCS_PR_EXCLUDE
# variable in place (no positional argument, nothing on stdout) and fails
# open silently when origin is unreachable. This section extracts that
# function VERBATIM from the vendored guide.md and exercises its fetch/diff
# logic directly against hermetic local git fixtures (no real network) —
# independent of a live Guide session, per #279's Test Plan.

if [[ ! -f "$GUIDE_MD" ]]; then
    skip "pre-flight check no-ops when local already matches origin" \
        "no vendored Guide role at $GUIDE_MD (Loom not installed here)"
    skip "pre-flight check prefers origin's value on mismatch" \
        "no vendored Guide role at $GUIDE_MD (Loom not installed here)"
    skip "pre-flight check fails safe when origin is unreachable" \
        "no vendored Guide role at $GUIDE_MD (Loom not installed here)"
elif ! command -v git >/dev/null 2>&1; then
    skip "pre-flight check no-ops when local already matches origin" "git not available"
    skip "pre-flight check prefers origin's value on mismatch" "git not available"
    skip "pre-flight check fails safe when origin is unreachable" "git not available"
else
    # Extract the function body verbatim (single level of {}, no nested braces
    # at column 0) — the same awk shape already used for update_work_log().
    PREFLIGHT_FUNC="$(awk '/^refresh_docs_pr_exclude_from_origin\(\) \{/{f=1} f{print} f && /^\}/{exit}' "$GUIDE_MD")"

    if [[ -z "$PREFLIGHT_FUNC" ]]; then
        no "pre-flight check no-ops when local already matches origin" \
            "no refresh_docs_pr_exclude_from_origin() function found in $GUIDE_MD"
        no "pre-flight check prefers origin's value on mismatch" \
            "no refresh_docs_pr_exclude_from_origin() function found in $GUIDE_MD"
        no "pre-flight check fails safe when origin is unreachable" \
            "no refresh_docs_pr_exclude_from_origin() function found in $GUIDE_MD"
    else
        FUNC_FILE="$PREFLIGHT_SANDBOX/preflight_func.sh"
        printf '%s\n' "$PREFLIGHT_FUNC" > "$FUNC_FILE"

        # A real (but fully local/hermetic) "origin" — a bare repo seeded with
        # a fixture guide.md carrying its own GUIDE_DOCS_PR_EXCLUDE line, plus
        # a "local" working repo whose only remote is that bare repo. No
        # network call ever leaves the sandbox.
        ORIGIN_BARE="$PREFLIGHT_SANDBOX/origin.git"
        SEED_DIR="$PREFLIGHT_SANDBOX/seed"
        LOCAL_DIR="$PREFLIGHT_SANDBOX/local"

        seed_origin() { # <origin-exclude-expr>
            rm -rf "$ORIGIN_BARE" "$SEED_DIR"
            git init -q --bare "$ORIGIN_BARE"
            git init -q "$SEED_DIR"
            mkdir -p "$SEED_DIR/.loom/roles"
            {
                printf "GUIDE_DOCS_PR_EXCLUDE='%s'\n" "$1"
            } > "$SEED_DIR/.loom/roles/guide.md"
            git -C "$SEED_DIR" -c user.email=test@example.com -c user.name=test add -A
            git -C "$SEED_DIR" -c user.email=test@example.com -c user.name=test commit -q -m seed
            git -C "$SEED_DIR" branch -M main
            git -C "$SEED_DIR" push -q "$ORIGIN_BARE" main
        }

        run_preflight() { # <loaded-value> <origin-remote-url>
            # Prints the post-check value of GUIDE_DOCS_PR_EXCLUDE on stdout.
            # The function resolves the INSTALLED role path relative to cwd
            # and no-ops if none exists, so the local fixture repo needs a
            # (content-irrelevant) .loom/roles/guide.md on disk.
            rm -rf "$LOCAL_DIR"
            git init -q "$LOCAL_DIR"
            git -C "$LOCAL_DIR" remote add origin "$2"
            mkdir -p "$LOCAL_DIR/.loom/roles"
            : > "$LOCAL_DIR/.loom/roles/guide.md"
            (cd "$LOCAL_DIR" \
                && GUIDE_DOCS_PR_EXCLUDE="$1" \
                && source "$FUNC_FILE" \
                && refresh_docs_pr_exclude_from_origin \
                && printf '%s' "$GUIDE_DOCS_PR_EXCLUDE")
        }

        SAME_EXPR="expr-unchanged"
        DIFFERENT_EXPR="expr-from-origin-updated"

        # --- Case A: local already matches origin -> silent no-op ----------
        seed_origin "$SAME_EXPR"
        A_STDOUT="$(run_preflight "$SAME_EXPR" "$ORIGIN_BARE" 2>"$PREFLIGHT_SANDBOX/a.stderr")"
        A_STDERR="$(cat "$PREFLIGHT_SANDBOX/a.stderr")"
        if [[ "$A_STDOUT" == "$SAME_EXPR" && -z "$A_STDERR" ]]; then
            ok "pre-flight check no-ops when local already matches origin"
        else
            no "pre-flight check no-ops when local already matches origin" \
                "expected stdout='$SAME_EXPR' with no stderr; got stdout='$A_STDOUT' stderr='$A_STDERR'"
        fi

        # --- Case B: local is stale -> origin's value wins, with a warning --
        seed_origin "$DIFFERENT_EXPR"
        B_STDOUT="$(run_preflight "$SAME_EXPR" "$ORIGIN_BARE" 2>"$PREFLIGHT_SANDBOX/b.stderr")"
        B_STDERR="$(cat "$PREFLIGHT_SANDBOX/b.stderr")"
        if [[ "$B_STDOUT" == "$DIFFERENT_EXPR" ]] && grep -q 'WARNING' <<<"$B_STDERR"; then
            ok "pre-flight check prefers origin's value on mismatch"
        else
            no "pre-flight check prefers origin's value on mismatch" \
                "expected stdout='$DIFFERENT_EXPR' with a WARNING on stderr; got stdout='$B_STDOUT' stderr='$B_STDERR'"
        fi

        # --- Case C: origin unreachable -> fail safe, keep the loaded value --
        # A local filesystem path that does not exist fails fast (no real
        # network round-trip) and leaves no refs/remotes/origin/main behind,
        # exercising the exact "offline" fallback path. The upstream shape
        # fails OPEN silently (bounded fetch, `|| return 0`), so the contract
        # is: value unchanged, exit 0, and no WARNING on stderr.
        C_STDOUT="$(run_preflight "$SAME_EXPR" "$PREFLIGHT_SANDBOX/does-not-exist.git" 2>"$PREFLIGHT_SANDBOX/c.stderr")"
        C_EXIT=$?
        C_STDERR="$(cat "$PREFLIGHT_SANDBOX/c.stderr")"
        if [[ "$C_STDOUT" == "$SAME_EXPR" && "$C_EXIT" -eq 0 ]] && ! grep -q 'WARNING' <<<"$C_STDERR"; then
            ok "pre-flight check fails safe when origin is unreachable"
        else
            no "pre-flight check fails safe when origin is unreachable" \
                "expected stdout='$SAME_EXPR', exit 0, and no WARNING on stderr; got stdout='$C_STDOUT' exit=$C_EXIT stderr='$C_STDERR'"
        fi
    fi
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

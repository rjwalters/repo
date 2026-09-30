#!/usr/bin/env bash
# Test suite for scripts/version.sh — this repo's single source of truth for
# VERSION, exercised via a scratch git fixture (#387).
#
# scripts/version.sh resolves its own root from $0's location
# ("$(dirname "$0")/..") rather than cwd, so each case copies the real script
# into a throwaway scratch repo at the same scripts/version.sh relative path
# and invokes the COPY — never the real repo's VERSION/package.json.
#
# Structured like commands/repo/tests/test-check-label-descriptions.sh: pure
# bash, no test framework, PASS/FAIL/TOTAL counters via lib/assert.sh, and a
# scratch-git fixture harness. `pnpm test` delegates to this file via
# hooks/repo/tests/run.sh.
#
# Usage: ./commands/repo/tests/test-version-script.sh
# Exit code 0 = all tests pass, 1 = failures detected.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SOURCE_SCRIPT="$REPO_ROOT/scripts/version.sh"

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

if [[ ! -f "$SOURCE_SCRIPT" ]]; then
    echo "FATAL: version.sh not found at $SOURCE_SCRIPT" >&2
    exit 1
fi

SCRATCH="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$SCRATCH" 2>/dev/null || true' EXIT

export GIT_AUTHOR_NAME="test" GIT_AUTHOR_EMAIL="test@example.com"
export GIT_COMMITTER_NAME="test" GIT_COMMITTER_EMAIL="test@example.com"

# build_repo <name> <version> [with-package-json] -> sets REPO and VS
# (the copied scripts/version.sh inside REPO).
build_repo() {
    local root="$SCRATCH/$1" ver="$2" with_pkg="${3:-yes}"
    rm -rf "$root"
    mkdir -p "$root/scripts"
    cp "$SOURCE_SCRIPT" "$root/scripts/version.sh"
    chmod +x "$root/scripts/version.sh"
    printf '%s\n' "$ver" > "$root/VERSION"
    if [[ "$with_pkg" == "yes" ]]; then
        printf '{\n  "name": "fixture",\n  "version": "%s"\n}\n' "$ver" > "$root/package.json"
    fi
    git_fixture_init "$root"
    git -C "$root" checkout -q -b main
    git -C "$root" add -A
    git -C "$root" commit -q -m "base"
    REPO="$root"
    VS="$root/scripts/version.sh"
}

# seed_conflict <repo>: leave <repo> with two divergent commits that conflict on
# conflict.txt — `main` at "main change", branch `side` at "side change". Driving
# a real conflicted merge / rebase / cherry-pick off this pair is what actually
# puts MERGE_HEAD / rebase-merge / CHERRY_PICK_HEAD on disk, which is the state
# version.sh's skip-commit detection reads (#536). Hand-creating those files
# would test the assertion instead of the condition.
seed_conflict() {  # <repo>
    local repo="$1"
    git -C "$repo" checkout -q -b side
    printf 'side\n' > "$repo/conflict.txt"
    git -C "$repo" add conflict.txt
    git -C "$repo" commit -q -m "side change"
    git -C "$repo" checkout -q main
    printf 'main\n' > "$repo/conflict.txt"
    git -C "$repo" add conflict.txt
    git -C "$repo" commit -q -m "main change"
}

head_subject() { git -C "$1" log -1 --format=%s; }
commit_count() { git -C "$1" rev-list --count HEAD; }
staged_files() { git -C "$1" diff --cached --name-only; }

# run_vs <repo> <args...>: run the fixture's version.sh, capturing stdout in
# RUN_OUT, stderr in RUN_ERR and the exit status in RUN_RC. Both streams are
# needed together throughout the skip-commit cases: the new behavior announces
# itself on stderr while the version still goes to stdout.
run_vs() {  # <repo> <args...>
    local repo="$1"; shift
    local errfile="$SCRATCH/last-stderr.txt"
    RUN_RC=0
    RUN_OUT="$(cd "$repo" && "$repo/scripts/version.sh" "$@" 2>"$errfile")" || RUN_RC=$?
    RUN_ERR="$(cat "$errfile")"
}

echo "version.sh test suite"
echo "======================"
echo ""

# ---------------------------------------------------------------------------
echo "-- case 1: print (default / explicit) --"
# ---------------------------------------------------------------------------
build_repo "case1" "1.2.3"
OUT="$(cd "$REPO" && "$VS")"
assert_eq "no-arg print reports the version" "1.2.3" "$OUT"
OUT="$(cd "$REPO" && "$VS" print)"
assert_eq "explicit print reports the version" "1.2.3" "$OUT"

# ---------------------------------------------------------------------------
echo ""
echo "-- case 2: check --"
# ---------------------------------------------------------------------------
build_repo "case2-ok" "1.2.3"
OUT="$(cd "$REPO" && "$VS" check 2>&1)"
STATUS=$?
assert_eq "matching VERSION/package.json passes (exit 0)" "0" "$STATUS"
assert_contains "check reports ok with the version" "$OUT" "ok: 1.2.3"

build_repo "case2-drift" "1.2.3"
printf '{\n  "name": "fixture",\n  "version": "9.9.9"\n}\n' > "$REPO/package.json"
RC=0
OUT="$(cd "$REPO" && "$VS" check 2>&1)" || RC=$?
assert_eq "mismatched package.json fails (exit 1)" "1" "$RC"
assert_contains "drift output names both versions" "$OUT" "VERSION=1.2.3"
assert_contains "drift output names both versions (package.json side)" "$OUT" "package.json=9.9.9"

build_repo "case2-no-field" "1.2.3"
printf '{\n  "name": "fixture"\n}\n' > "$REPO/package.json"
RC=0
OUT="$(cd "$REPO" && "$VS" check 2>&1)" || RC=$?
assert_eq "package.json missing a version field fails (exit 1)" "1" "$RC"
assert_contains "no-field output flags the absent field, not silent agreement" "$OUT" "no version field"

# ---------------------------------------------------------------------------
echo ""
echo "-- case 3: bump --"
# ---------------------------------------------------------------------------
build_repo "case3-patch" "1.2.3"
OUT="$(cd "$REPO" && "$VS" bump patch)"
assert_eq "bump patch prints the new version" "1.2.4" "$OUT"
assert_eq "bump patch writes VERSION" "1.2.4" "$(cat "$REPO/VERSION")"
assert_contains "bump patch syncs package.json" "$(cat "$REPO/package.json")" '"version": "1.2.4"'
assert_contains "bump patch commits with the expected message" \
    "$(git -C "$REPO" log -1 --format=%s)" "chore: bump version to 1.2.4"

build_repo "case3-minor" "1.2.3"
OUT="$(cd "$REPO" && "$VS" bump minor)"
assert_eq "bump minor resets patch" "1.3.0" "$OUT"

build_repo "case3-major" "1.2.3"
OUT="$(cd "$REPO" && "$VS" bump major)"
assert_eq "bump major resets minor and patch" "2.0.0" "$OUT"

build_repo "case3-tag" "1.2.3"
(cd "$REPO" && "$VS" bump patch --tag >/dev/null)
TAGS="$(git -C "$REPO" tag -l)"
assert_contains "bump --tag creates an annotated tag" "$TAGS" "v1.2.4"

build_repo "case3-badlevel" "1.2.3"
RC=0
(cd "$REPO" && "$VS" bump bogus >/dev/null 2>&1) || RC=$?
assert_eq "bump with an invalid level exits 2" "2" "$RC"

# ---------------------------------------------------------------------------
echo ""
echo "-- case 4: set --"
# ---------------------------------------------------------------------------
build_repo "case4-set" "1.2.3"
OUT="$(cd "$REPO" && "$VS" set 5.0.0)"
assert_eq "set prints the new version" "5.0.0" "$OUT"
assert_eq "set writes VERSION" "5.0.0" "$(cat "$REPO/VERSION")"
assert_contains "set syncs package.json" "$(cat "$REPO/package.json")" '"version": "5.0.0"'
assert_contains "set commits with the expected message" \
    "$(git -C "$REPO" log -1 --format=%s)" "chore: set version to 5.0.0"

build_repo "case4-set-tag" "1.2.3"
(cd "$REPO" && "$VS" set 5.0.0 --tag >/dev/null)
TAGS="$(git -C "$REPO" tag -l)"
assert_contains "set --tag creates an annotated tag" "$TAGS" "v5.0.0"

build_repo "case4-set-invalid" "1.2.3"
RC=0
(cd "$REPO" && "$VS" set not-a-version >/dev/null 2>&1) || RC=$?
assert_eq "set with a malformed version exits 2" "2" "$RC"
BEFORE="$(cat "$REPO/VERSION")"
assert_eq "a rejected set leaves VERSION unchanged" "1.2.3" "$BEFORE"

build_repo "case4-set-missing-arg" "1.2.3"
RC=0
(cd "$REPO" && "$VS" set >/dev/null 2>&1) || RC=$?
assert_eq "set with no argument exits 2" "2" "$RC"

# ---------------------------------------------------------------------------
echo ""
echo "-- case 5: no package.json is a no-op for check, not an error --"
# ---------------------------------------------------------------------------
# This repo always ships a root package.json (mirrored by bump/set), so this
# case only pins `check`'s documented behavior when there is nothing to
# compare against — it does not exercise bump/set in a package.json-less
# tree, which is not a configuration this repo actually has.
build_repo "case5" "1.2.3" "no"
OUT="$(cd "$REPO" && "$VS" check 2>&1)"
STATUS=$?
assert_eq "check passes with no package.json to compare against" "0" "$STATUS"

# ---------------------------------------------------------------------------
echo ""
echo "-- case 6: unknown subcommand usage --"
# ---------------------------------------------------------------------------
build_repo "case6" "1.2.3"
RC=0
(cd "$REPO" && "$VS" bogus-command >/dev/null 2>&1) || RC=$?
assert_eq "an unknown subcommand exits 2" "2" "$RC"

# ---------------------------------------------------------------------------
echo ""
echo "-- case 7: clean tree with no flag still auto-commits (regression guard) --"
# ---------------------------------------------------------------------------
# The whole point of #536's change is that it is conditional. These two cases
# pin the unchanged path: outside a merge/rebase/cherry-pick and without
# --no-commit, bump and set each still create exactly one commit and leave
# nothing staged behind.
for sub in bump set; do
    build_repo "case7-$sub" "1.2.3"
    BEFORE_COUNT="$(commit_count "$REPO")"
    if [[ "$sub" == "bump" ]]; then
        run_vs "$REPO" bump patch
        EXPECT_SUBJECT="chore: bump version to 1.2.4"
        EXPECT_VERSION="1.2.4"
    else
        run_vs "$REPO" set 5.0.0
        EXPECT_SUBJECT="chore: set version to 5.0.0"
        EXPECT_VERSION="5.0.0"
    fi
    assert_eq "$sub on a clean tree exits 0" "0" "$RUN_RC"
    assert_eq "$sub on a clean tree prints the new version" "$EXPECT_VERSION" "$RUN_OUT"
    assert_eq "$sub on a clean tree adds exactly one commit" \
        "$((BEFORE_COUNT + 1))" "$(commit_count "$REPO")"
    assert_eq "$sub on a clean tree commits with the expected subject" \
        "$EXPECT_SUBJECT" "$(head_subject "$REPO")"
    assert_eq "$sub on a clean tree leaves nothing staged" "" "$(staged_files "$REPO")"
    assert_not_contains "$sub on a clean tree prints no skip notice" "$RUN_ERR" "not committed"
done

# ---------------------------------------------------------------------------
echo ""
echo "-- case 8: --no-commit stages without committing --"
# ---------------------------------------------------------------------------
build_repo "case8-bump" "1.2.3"
BEFORE_SUBJECT="$(head_subject "$REPO")"
BEFORE_COUNT="$(commit_count "$REPO")"
run_vs "$REPO" bump patch --no-commit
assert_eq "bump --no-commit exits 0" "0" "$RUN_RC"
assert_eq "bump --no-commit still prints the new version" "1.2.4" "$RUN_OUT"
assert_eq "bump --no-commit writes VERSION" "1.2.4" "$(cat "$REPO/VERSION")"
assert_contains "bump --no-commit syncs package.json" "$(cat "$REPO/package.json")" '"version": "1.2.4"'
assert_contains "bump --no-commit stages VERSION" "$(staged_files "$REPO")" "VERSION"
assert_contains "bump --no-commit stages package.json" "$(staged_files "$REPO")" "package.json"
assert_eq "bump --no-commit creates no commit" "$BEFORE_COUNT" "$(commit_count "$REPO")"
assert_eq "bump --no-commit leaves HEAD where it was" "$BEFORE_SUBJECT" "$(head_subject "$REPO")"
assert_contains "bump --no-commit says why on stderr" "$RUN_ERR" "--no-commit requested"
assert_contains "bump --no-commit says the files are staged, not committed" "$RUN_ERR" "not committed"

build_repo "case8-set" "1.2.3"
BEFORE_COUNT="$(commit_count "$REPO")"
run_vs "$REPO" set 5.0.0 --no-commit
assert_eq "set --no-commit exits 0" "0" "$RUN_RC"
assert_eq "set --no-commit writes VERSION" "5.0.0" "$(cat "$REPO/VERSION")"
assert_contains "set --no-commit stages VERSION" "$(staged_files "$REPO")" "VERSION"
assert_eq "set --no-commit creates no commit" "$BEFORE_COUNT" "$(commit_count "$REPO")"
assert_contains "set --no-commit says why on stderr" "$RUN_ERR" "--no-commit requested"

# ---------------------------------------------------------------------------
echo ""
echo "-- case 9: an in-progress merge skips the commit --"
# ---------------------------------------------------------------------------
# The reported incident: an agent resolving a VERSION conflict mid-merge ran
# `set`, and version.sh's own commit consumed the merge the agent was about to
# write, dropping its provenance trailers.
for sub in bump set; do
    build_repo "case9-$sub" "1.2.3"
    seed_conflict "$REPO"
    git -C "$REPO" merge side >/dev/null 2>&1 || true
    MERGE_HEAD_PRESENT=no
    git -C "$REPO" rev-parse --quiet --verify MERGE_HEAD >/dev/null 2>&1 && MERGE_HEAD_PRESENT=yes
    assert_eq "$sub fixture: the merge really is in progress" "yes" "$MERGE_HEAD_PRESENT"
    BEFORE_COUNT="$(commit_count "$REPO")"
    if [[ "$sub" == "bump" ]]; then
        run_vs "$REPO" bump patch
        EXPECT_VERSION="1.2.4"
    else
        run_vs "$REPO" set 5.0.0
        EXPECT_VERSION="5.0.0"
    fi
    assert_eq "$sub mid-merge exits 0" "0" "$RUN_RC"
    assert_eq "$sub mid-merge still writes VERSION" "$EXPECT_VERSION" "$(cat "$REPO/VERSION")"
    assert_contains "$sub mid-merge stages VERSION" "$(staged_files "$REPO")" "VERSION"
    assert_eq "$sub mid-merge creates no commit" "$BEFORE_COUNT" "$(commit_count "$REPO")"
    assert_eq "$sub mid-merge leaves HEAD at the pre-merge tip" "main change" "$(head_subject "$REPO")"
    MERGE_HEAD_STILL=no
    git -C "$REPO" rev-parse --quiet --verify MERGE_HEAD >/dev/null 2>&1 && MERGE_HEAD_STILL=yes
    assert_eq "$sub mid-merge leaves the merge still in progress" "yes" "$MERGE_HEAD_STILL"
    assert_contains "$sub mid-merge names the merge on stderr" "$RUN_ERR" "merge in progress"
    assert_contains "$sub mid-merge says the files are staged, not committed" "$RUN_ERR" "not committed"
done

# ---------------------------------------------------------------------------
echo ""
echo "-- case 10: an in-progress rebase skips the commit --"
# ---------------------------------------------------------------------------
for sub in bump set; do
    build_repo "case10-$sub" "1.2.3"
    seed_conflict "$REPO"
    git -C "$REPO" checkout -q side
    git -C "$REPO" rebase main >/dev/null 2>&1 || true
    GITDIR="$(git -C "$REPO" rev-parse --absolute-git-dir)"
    REBASE_PRESENT=no
    { [[ -d "$GITDIR/rebase-merge" ]] || [[ -d "$GITDIR/rebase-apply" ]]; } && REBASE_PRESENT=yes
    assert_eq "$sub fixture: the rebase really is in progress" "yes" "$REBASE_PRESENT"
    BEFORE_COUNT="$(commit_count "$REPO")"
    if [[ "$sub" == "bump" ]]; then
        run_vs "$REPO" bump patch
        EXPECT_VERSION="1.2.4"
    else
        run_vs "$REPO" set 5.0.0
        EXPECT_VERSION="5.0.0"
    fi
    assert_eq "$sub mid-rebase exits 0" "0" "$RUN_RC"
    assert_eq "$sub mid-rebase still writes VERSION" "$EXPECT_VERSION" "$(cat "$REPO/VERSION")"
    assert_contains "$sub mid-rebase stages VERSION" "$(staged_files "$REPO")" "VERSION"
    assert_eq "$sub mid-rebase creates no commit" "$BEFORE_COUNT" "$(commit_count "$REPO")"
    REBASE_STILL=no
    { [[ -d "$GITDIR/rebase-merge" ]] || [[ -d "$GITDIR/rebase-apply" ]]; } && REBASE_STILL=yes
    assert_eq "$sub mid-rebase leaves the rebase still in progress" "yes" "$REBASE_STILL"
    assert_contains "$sub mid-rebase names the rebase on stderr" "$RUN_ERR" "rebase in progress"
done

# ---------------------------------------------------------------------------
echo ""
echo "-- case 11: an in-progress cherry-pick skips the commit --"
# ---------------------------------------------------------------------------
for sub in bump set; do
    build_repo "case11-$sub" "1.2.3"
    seed_conflict "$REPO"
    git -C "$REPO" cherry-pick side >/dev/null 2>&1 || true
    CP_PRESENT=no
    git -C "$REPO" rev-parse --quiet --verify CHERRY_PICK_HEAD >/dev/null 2>&1 && CP_PRESENT=yes
    assert_eq "$sub fixture: the cherry-pick really is in progress" "yes" "$CP_PRESENT"
    BEFORE_COUNT="$(commit_count "$REPO")"
    if [[ "$sub" == "bump" ]]; then
        run_vs "$REPO" bump patch
        EXPECT_VERSION="1.2.4"
    else
        run_vs "$REPO" set 5.0.0
        EXPECT_VERSION="5.0.0"
    fi
    assert_eq "$sub mid-cherry-pick exits 0" "0" "$RUN_RC"
    assert_eq "$sub mid-cherry-pick still writes VERSION" "$EXPECT_VERSION" "$(cat "$REPO/VERSION")"
    assert_contains "$sub mid-cherry-pick stages VERSION" "$(staged_files "$REPO")" "VERSION"
    assert_eq "$sub mid-cherry-pick creates no commit" "$BEFORE_COUNT" "$(commit_count "$REPO")"
    CP_STILL=no
    git -C "$REPO" rev-parse --quiet --verify CHERRY_PICK_HEAD >/dev/null 2>&1 && CP_STILL=yes
    assert_eq "$sub mid-cherry-pick leaves the cherry-pick still in progress" "yes" "$CP_STILL"
    assert_contains "$sub mid-cherry-pick names the cherry-pick on stderr" "$RUN_ERR" "cherry-pick in progress"
done

# ---------------------------------------------------------------------------
echo ""
echo "-- case 12: --tag is refused when there is no commit to tag --"
# ---------------------------------------------------------------------------
# Tagging an uncommitted bump would put v<new> on the PREVIOUS commit, naming a
# version that commit does not contain. The refusal happens before anything is
# written, so the tree is left exactly as it was.
build_repo "case12-no-commit" "1.2.3"
run_vs "$REPO" bump patch --tag --no-commit
assert_eq "bump --tag --no-commit exits 2" "2" "$RUN_RC"
assert_contains "bump --tag --no-commit explains the refusal" "$RUN_ERR" "refusing --tag"
assert_eq "a refused --tag leaves VERSION unchanged" "1.2.3" "$(cat "$REPO/VERSION")"
assert_eq "a refused --tag stages nothing" "" "$(staged_files "$REPO")"
assert_eq "a refused --tag creates no tag" "" "$(git -C "$REPO" tag -l)"

build_repo "case12-set-no-commit" "1.2.3"
run_vs "$REPO" set 5.0.0 --tag --no-commit
assert_eq "set --tag --no-commit exits 2" "2" "$RUN_RC"
assert_eq "a refused set --tag leaves VERSION unchanged" "1.2.3" "$(cat "$REPO/VERSION")"

build_repo "case12-merge" "1.2.3"
seed_conflict "$REPO"
git -C "$REPO" merge side >/dev/null 2>&1 || true
run_vs "$REPO" set 5.0.0 --tag
assert_eq "set --tag mid-merge exits 2" "2" "$RUN_RC"
assert_contains "set --tag mid-merge names the merge as the reason" "$RUN_ERR" "merge in progress"
assert_eq "set --tag mid-merge leaves VERSION unchanged" "1.2.3" "$(cat "$REPO/VERSION")"
assert_eq "set --tag mid-merge creates no tag" "" "$(git -C "$REPO" tag -l)"

# ---------------------------------------------------------------------------
echo ""
echo "-- case 13: flag order and unknown flags --"
# ---------------------------------------------------------------------------
build_repo "case13-order" "1.2.3"
run_vs "$REPO" bump patch --no-commit
assert_eq "bump accepts --no-commit after the level" "0" "$RUN_RC"

build_repo "case13-tag-then-nothing" "1.2.3"
run_vs "$REPO" bump patch --tag
assert_eq "bump --tag on a clean tree still tags" "0" "$RUN_RC"
assert_contains "bump --tag on a clean tree creates the tag" "$(git -C "$REPO" tag -l)" "v1.2.4"

build_repo "case13-unknown" "1.2.3"
run_vs "$REPO" bump patch --bogus
assert_eq "bump with an unknown flag exits 2" "2" "$RUN_RC"
assert_eq "an unknown flag leaves VERSION unchanged" "1.2.3" "$(cat "$REPO/VERSION")"
run_vs "$REPO" set 5.0.0 --bogus
assert_eq "set with an unknown flag exits 2" "2" "$RUN_RC"

# ---------------------------------------------------------------------------
echo ""
echo "-- case 14: the usage header documents the new behavior --"
# ---------------------------------------------------------------------------
# The header comment is the only usage text a reader of the script sees; a
# behavior this surprising has to be written down next to the flag that drives
# it (#536).
HEADER="$(sed -n '1,40p' "$SOURCE_SCRIPT")"
assert_contains "usage documents --no-commit for bump" "$HEADER" "bump <level> [--tag] [--no-commit]"
assert_contains "usage documents --no-commit for set" "$HEADER" "set <version> [--tag] [--no-commit]"
assert_contains "usage documents the auto-detected skip" "$HEADER" "merge, rebase or cherry-pick is in progress"
assert_contains "usage documents the --tag refusal" "$HEADER" "REJECTED"

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

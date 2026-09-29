#!/usr/bin/env bash
# Test suite for commands/repo/tests/lib/git-fixture.sh — the shared helpers
# that keep this repo's throwaway git fixtures hermetic against the OUTER
# environment's hook configuration.
#
# Usage: ./commands/repo/tests/test-git-fixture-hermeticity.sh
# Exit code 0 = all tests pass, 1 = failures detected.
#
# WHY THIS FILE EXISTS (repo#518): test-changelog-merged-work-check.sh failed
# 1 of its 19 cases whenever it ran from a Loom-dispatched agent session, and
# only from one. A dispatched session exports `core.hooksPath` via
# `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_<n>`/`GIT_CONFIG_VALUE_<n>` pointing at
# loom-daemon's provenance hooks, so the fixture repos that suite builds
# inherited a `commit-msg` hook that appended `Loom-Story: <repo>#<N>` trailers
# — injecting a `#N` into a fixture commit that the test had deliberately
# written WITHOUT one. CI was green throughout: the bug was invisible to every
# environment except the one the agents run in.
#
# So the fix needs a test that can see the leak from a clean shell too. Every
# hermeticity assertion below is paired with a CONTROL case that performs the
# same steps WITHOUT the helper and asserts the trailer DOES appear — if a
# future git/config change makes the simulated leak stop leaking, the controls
# fail and say so, rather than the hermeticity cases passing vacuously.
#
# This suite deliberately does NOT call git_fixture_scrub_env at top level: it
# sets and clears the override itself, per case, in subshells.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TESTS_DIR="$SCRIPT_DIR"

source "$SCRIPT_DIR/lib/assert.sh"
source "$SCRIPT_DIR/lib/git-fixture.sh"

SCRATCH="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$SCRATCH"' EXIT

TRAILER='Loom-Story: rjwalters/repo#4242'

# A stand-in for loom-daemon's provenance hooks dir: a commit-msg hook that
# appends a trailer carrying a #N, which is the exact shape that broke
# check_merged_work_coverage()'s `grep -oE '#[0-9]+'` over %B.
HOOKS="$SCRATCH/fake-provenance-hooks"
mkdir -p "$HOOKS"
cat > "$HOOKS/commit-msg" <<'EOF'
#!/usr/bin/env bash
printf '\nLoom-Story: rjwalters/repo#4242\n' >> "$1"
EOF
chmod +x "$HOOKS/commit-msg"

# A stand-in for an ordinary `core.hooksPath` in the user's GLOBAL config (a
# config FILE, not an env override — a different leak with a different fix).
GLOBAL_CFG="$SCRATCH/global-gitconfig"
printf '[core]\n\thooksPath = %s\n' "$HOOKS" > "$GLOBAL_CFG"

# identify <dir>: give a fixture repo a committer so `git commit` works even
# when the outer global config has been replaced.
identify() { git -C "$1" config user.email "test@example.invalid"; git -C "$1" config user.name "Fixture Hermeticity Test"; }

body_of() { git -C "$1" log -1 --format='%B'; }

echo "lib/git-fixture.sh hermeticity test suite"
echo "=========================================="
echo ""

# ---------------------------------------------------------------------------
echo "-- leak source 1: core.hooksPath via GIT_CONFIG_* env pairs --"
# ---------------------------------------------------------------------------

# CONTROL: a raw `git init` fixture under the env override DOES inherit the
# hook. If this ever stops being true the hermeticity case below is vacuous.
(
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$HOOKS"
    git init -q -b main "$SCRATCH/env-control"
    identify "$SCRATCH/env-control"
    git -C "$SCRATCH/env-control" commit -q --allow-empty -m "fix: no number here"
) >/dev/null 2>&1
assert_contains "CONTROL: a raw git-init fixture DOES inherit the env-override hook" \
    "$(body_of "$SCRATCH/env-control")" "$TRAILER"

(
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$HOOKS"
    git_fixture_init "$SCRATCH/env-fixed" -b main
    identify "$SCRATCH/env-fixed"
    git -C "$SCRATCH/env-fixed" commit -q --allow-empty -m "fix: no number here"
) >/dev/null 2>&1
assert_not_contains "git_fixture_init: no trailer under a GIT_CONFIG_* hooksPath override" \
    "$(body_of "$SCRATCH/env-fixed")" "$TRAILER"
assert_contains "git_fixture_init: the commit subject itself is untouched" \
    "$(body_of "$SCRATCH/env-fixed")" "fix: no number here"

# The override must stay neutralized for LATER commits too — the whole point of
# scrubbing the environment rather than passing `-c core.hooksPath=…` to one
# commit: fixture suites commit many times, and some commits are made by the
# script under test rather than by the test itself.
(
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$HOOKS"
    git_fixture_init "$SCRATCH/env-later" -b main
    identify "$SCRATCH/env-later"
    git -C "$SCRATCH/env-later" commit -q --allow-empty -m "first"
    git -C "$SCRATCH/env-later" commit -q --allow-empty -m "fix: a much later commit"
) >/dev/null 2>&1
assert_not_contains "git_fixture_init: later commits in the same suite are also hook-free" \
    "$(body_of "$SCRATCH/env-later")" "$TRAILER"

# ---------------------------------------------------------------------------
echo ""
echo "-- leak source 2: core.hooksPath from an ordinary config FILE (global) --"
# ---------------------------------------------------------------------------

# CONTROL: the simulated global config really does install the hook.
(
    export GIT_CONFIG_GLOBAL="$GLOBAL_CFG"
    unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
    git init -q -b main "$SCRATCH/global-control"
    identify "$SCRATCH/global-control"
    git -C "$SCRATCH/global-control" commit -q --allow-empty -m "fix: no number here"
) >/dev/null 2>&1
assert_contains "CONTROL: a raw git-init fixture DOES inherit a global-config hooksPath" \
    "$(body_of "$SCRATCH/global-control")" "$TRAILER"

(
    export GIT_CONFIG_GLOBAL="$GLOBAL_CFG"
    unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
    git_fixture_init "$SCRATCH/global-fixed" -b main
    identify "$SCRATCH/global-fixed"
    git -C "$SCRATCH/global-fixed" commit -q --allow-empty -m "fix: no number here"
) >/dev/null 2>&1
assert_not_contains "git_fixture_init: no trailer under a global-config hooksPath" \
    "$(body_of "$SCRATCH/global-fixed")" "$TRAILER"

# Both leaks at once — env override AND a config file — is the real dispatched
# case on a developer machine that also configures its own hooks.
(
    export GIT_CONFIG_GLOBAL="$GLOBAL_CFG"
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$HOOKS"
    git_fixture_init "$SCRATCH/both-fixed" -b main
    identify "$SCRATCH/both-fixed"
    git -C "$SCRATCH/both-fixed" commit -q --allow-empty -m "fix: no number here"
) >/dev/null 2>&1
assert_not_contains "git_fixture_init: no trailer when BOTH leak sources are active" \
    "$(body_of "$SCRATCH/both-fixed")" "$TRAILER"

# ---------------------------------------------------------------------------
echo ""
echo "-- git_fixture_scrub_env() semantics --"
# ---------------------------------------------------------------------------

SCRUBBED="$(
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$HOOKS"
    # A pair ABOVE the declared count: git ignores it today, but leaving it
    # behind would arm a leak the moment anything raised GIT_CONFIG_COUNT.
    export GIT_CONFIG_KEY_1=core.hooksPath GIT_CONFIG_VALUE_1="$HOOKS"
    git_fixture_scrub_env
    env | grep -cE '^GIT_CONFIG_(COUNT|KEY_[0-9]+|VALUE_[0-9]+)=' || true
)"
assert_eq "scrub_env unsets COUNT and every KEY_<n>/VALUE_<n> pair, above the count too" \
    "0" "$SCRUBBED"

GLOBAL_KEPT="$(
    export GIT_CONFIG_GLOBAL="$GLOBAL_CFG" GIT_CONFIG_SYSTEM=/dev/null
    git_fixture_scrub_env
    printf '%s|%s' "${GIT_CONFIG_GLOBAL:-unset}" "${GIT_CONFIG_SYSTEM:-unset}"
)"
assert_eq "scrub_env leaves GIT_CONFIG_GLOBAL/SYSTEM alone (unsetting them re-enables config files)" \
    "$GLOBAL_CFG|/dev/null" "$GLOBAL_KEPT"

if env -u GIT_CONFIG_COUNT -u GIT_CONFIG_KEY_0 -u GIT_CONFIG_VALUE_0 \
       bash -c "set -u; source '$SCRIPT_DIR/lib/git-fixture.sh'; git_fixture_scrub_env; git_fixture_scrub_env" \
       >/dev/null 2>&1; then NOOP_RC=0; else NOOP_RC=1; fi
assert_eq "scrub_env is a no-op (and set -u clean, and idempotent) when nothing is set" "0" "$NOOP_RC"

# ---------------------------------------------------------------------------
echo ""
echo "-- git_fixture_init()/git_fixture_harden() mechanics --"
# ---------------------------------------------------------------------------

git_fixture_init "$SCRATCH/flags" -b trunk >/dev/null 2>&1
assert_eq "git_fixture_init passes flags through to git init (-b trunk)" \
    "trunk" "$(git -C "$SCRATCH/flags" symbolic-ref --short HEAD 2>/dev/null)"

git_fixture_init "$SCRATCH/bare.git" --bare >/dev/null 2>&1
assert_eq "git_fixture_init supports bare fixtures (--bare)" \
    "true" "$(git -C "$SCRATCH/bare.git" rev-parse --is-bare-repository 2>/dev/null)"
assert_eq "a bare fixture is hardened too" \
    "$SCRATCH/bare.git/loom-test-no-hooks" \
    "$(git -C "$SCRATCH/bare.git" config --get core.hooksPath 2>/dev/null)"

assert_eq "a non-bare fixture's hooksPath points inside its own .git dir" \
    "$SCRATCH/flags/.git/loom-test-no-hooks" \
    "$(git -C "$SCRATCH/flags" config --get core.hooksPath 2>/dev/null)"
assert_eq "…and that directory exists and is empty" \
    "0" "$(find "$SCRATCH/flags/.git/loom-test-no-hooks" -type f 2>/dev/null | wc -l | tr -d ' ')"

# harden() applied to a repo someone else created (e.g. a clone, or a repo a
# script under test made) has the same effect.
git init -q -b main "$SCRATCH/adopted" >/dev/null 2>&1
git_fixture_harden "$SCRATCH/adopted"
identify "$SCRATCH/adopted"
(
    export GIT_CONFIG_GLOBAL="$GLOBAL_CFG"
    unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
    git -C "$SCRATCH/adopted" commit -q --allow-empty -m "fix: no number here"
) >/dev/null 2>&1
assert_not_contains "git_fixture_harden: an already-created repo is protected from a config-file hooksPath" \
    "$(body_of "$SCRATCH/adopted")" "$TRAILER"

if git_fixture_harden "$SCRATCH/not-a-repo-at-all" >/dev/null 2>&1; then
    HARDEN_RC=0
else
    HARDEN_RC=1
fi
assert_eq "git_fixture_harden fails loudly (non-zero) on a path that is not a repo" \
    "1" "$HARDEN_RC"

# ---------------------------------------------------------------------------
echo ""
echo "-- adoption drift: no suite under commands/repo/tests/ builds a raw fixture --"
# ---------------------------------------------------------------------------
# The structural half of the fix: a new suite that calls `git init` directly is
# exposed to the same leak all over again, silently, and only under dispatch.
# Two files are exempt: lib/git-fixture.sh (it IS the wrapper) and this file
# (its CONTROL cases must build un-hardened fixtures on purpose, to prove the
# simulated leak still leaks).
RAW_INIT="$(
    grep -rn -E '(^|[;&|(]|[[:space:]])git init([[:space:]]|$)' "$TESTS_DIR" \
        --include='*.sh' 2>/dev/null \
        | grep -v '/lib/git-fixture\.sh:' \
        | grep -v '/test-git-fixture-hermeticity\.sh:' \
        | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
        || true
)"
assert_eq "every fixture-building suite here goes through git_fixture_init" "" "$RAW_INIT"

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

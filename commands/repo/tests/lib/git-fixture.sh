#!/usr/bin/env bash
# Shared git-fixture hermeticity helpers for the repo test suites.
#
# WHY THIS FILE EXISTS (repo#518): many suites build throwaway git repos
# (`mktemp -d` + `git init`) and then assert on what those fixture commits
# look like. Those fixtures are
# only hermetic if the *outer* environment cannot reach into them — and under a
# Loom-dispatched agent session it can:
#
#   $ env | grep GIT_CONFIG
#   GIT_CONFIG_COUNT=1
#   GIT_CONFIG_KEY_0=core.hooksPath
#   GIT_CONFIG_VALUE_0=/…/.loom/logs/provenance-hooks/v1
#
# `loom-daemon` installs its provenance hooks (loom#9027) by overriding
# `core.hooksPath` through `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_<n>`/
# `GIT_CONFIG_VALUE_<n>` in the *environment*, so the override is inherited by
# every `git` invocation in the session — including the `git commit` calls a
# test makes inside its own fixture repo. The `commit-msg` hook then appends
# `Loom-Story:`/`Loom-Trace-Id:`/`Loom-Build:` trailers to fixture commits, and
# any assertion over `%B` sees a `#N` (the dispatching agent's own issue) that
# the test never wrote. That is what made
# test-changelog-merged-work-check.sh's case 5 fail 1/19 under dispatch while
# staying green in CI and in a clean shell.
#
# Two independent leaks have to be closed, because they are not the same leak:
#
#   1. The `GIT_CONFIG_*` env pairs. These "override values in configuration
#      files" (git-config(1)), so a fixture repo CANNOT out-configure them —
#      setting `core.hooksPath` in the fixture's own config loses to the
#      environment. They must be unset from the environment
#      (`git_fixture_scrub_env`), which also protects commits made by a script
#      *under test* rather than by the test itself.
#   2. An ordinary `core.hooksPath` in the outer user's global/system config.
#      That one is a config file, so the fixture's own repo-local config does
#      beat it (`git_fixture_harden` points the fixture at an empty hooks dir).
#
# Note `--no-verify` is NOT a fix for either: it skips the `pre-commit` and
# `commit-msg` stages for the commit you pass it to, but it does not change
# which hooks directory git resolves, it does not affect `prepare-commit-msg`,
# and it would have to be threaded through every commit call site (including
# ones inside scripts under test) to help at all.
#
# Usage (from commands/repo/tests/):
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/git-fixture.sh"
#   git_fixture_scrub_env                 # once, near the top of the suite
#   git_fixture_init "$SCRATCH/case1" -b main
#
# ADOPTION STATUS — do not read this file as a claim of repo-wide coverage.
# Every fixture-building suite under commands/repo/tests/ is adopted, and
# test-git-fixture-hermeticity.sh's drift case mechanically enforces that it
# stays that way (it greps for both raw spellings, `git init …` and
# `git -C <path> init …`). Suites under hooks/repo/tests/ are NOT adopted and
# are NOT covered by that drift case — tracked separately as repo#524. They
# can source the helper the same way when that lands:
#   source "$(dirname "${BASH_SOURCE[0]}")/../../../commands/repo/tests/lib/git-fixture.sh"
#
# This file defines functions only — it does not mutate the environment when
# sourced, so sourcing it is always safe. `git_fixture_scrub_env` is the call
# that does mutate (unsets) the caller's environment, deliberately.

# git_fixture_scrub_env: drop any `GIT_CONFIG_*` config-override pairs from the
# environment so fixture repos see only their own config files.
#
# Idempotent and safe to call when nothing is set. Unsets every
# `GIT_CONFIG_KEY_<n>`/`GIT_CONFIG_VALUE_<n>` pair present in the environment
# (not just the first `GIT_CONFIG_COUNT` of them — a stale pair left behind
# above the count would otherwise be picked up if something later raised
# `GIT_CONFIG_COUNT`). Also clears the loom provenance-hook pointer so a hook
# that did somehow run has nothing to resolve.
git_fixture_scrub_env() {
    local var
    # `${!GIT_CONFIG_@}` is bash prefix expansion over variable NAMES; it is
    # empty-safe under `set -u`. Matched names are filtered so this only ever
    # drops the override trio — notably NOT GIT_CONFIG_GLOBAL/SYSTEM, where
    # unsetting a deliberate `=/dev/null` would re-enable the very config files
    # a caller had already suppressed.
    for var in ${!GIT_CONFIG_@}; do
        case "$var" in
            GIT_CONFIG_COUNT|GIT_CONFIG_KEY_*|GIT_CONFIG_VALUE_*) unset "$var" ;;
        esac
    done
    unset LOOM_PROVENANCE_HOOKS_DIR
}

# git_fixture_harden <dir>: neutralize inherited hooks and inherited global
# excludes for an ALREADY-created fixture repo (works for bare repos too).
# Points the repo's own `core.hooksPath` at an empty directory inside its git
# dir, which beats any `core.hooksPath` in the outer global/system config, and
# pins `core.excludesFile` to `/dev/null` for the same reason (repo#535): a host
# global excludes file covering, say, `.vscode` or `*.log` silently changes what
# `git check-ignore` / `git ls-files --exclude-standard` answer inside a fixture,
# flipping any ignore-status assertion the suite makes. A case that deliberately
# wants a global exclude (test-gitignore-anchoring.sh's masking control) just
# sets `core.excludesFile` again after init — repo-local config, last write wins.
git_fixture_harden() {  # <dir>
    local dir="${1:?git_fixture_harden: <dir> required}" gitdir
    gitdir="$(git -C "$dir" rev-parse --absolute-git-dir)" || return 1
    mkdir -p "$gitdir/loom-test-no-hooks"
    git -C "$dir" config core.hooksPath "$gitdir/loom-test-no-hooks"
    git -C "$dir" config core.excludesFile /dev/null
}

# git_fixture_init <dir> [extra git-init flags...]: create a hermetic fixture
# repo. Equivalent to `git init -q <flags> <dir>` plus the two hermeticity
# steps above, so every later `git -C <dir> commit …` in the suite (and every
# commit made by a script under test inside <dir>) is hook-free without having
# to touch each commit call site.
#
# Flags follow the directory in the argument list (`git_fixture_init "$d" -b
# main --bare`) because <dir> is the one required argument; they are passed
# through to `git init` unchanged.
git_fixture_init() {  # <dir> [git-init flags...]
    local dir="${1:?git_fixture_init: <dir> required}"; shift
    git_fixture_scrub_env
    git init -q "$@" "$dir" || return 1
    git_fixture_harden "$dir"
}

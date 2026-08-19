#!/bin/bash
# loom-tools.sh - repo-root helper + retired-entry-point shim.
#
# ZERO PYTHON as of epic #4081 Phase 4 (#4557).
#
# This library used to locate the Python `loom-tools` package (source checkout,
# `.venv/`, or a pip/pipx-installed console script) and dispatch into it via
# `run_loom_tool <cli> <module>` — an exec of `python3 -m loom_tools.<module>`
# with a PYTHONPATH pointing at `loom-tools/src`, falling back to an
# editable-install instruction when nothing was found.
#
# That package is retired. Everything it provided is now either:
#   - a native `loom-daemon` subcommand (tokens, clean, cleanup, forge, claim,
#     checkpoint, agent-spawn, agent-wait, status, stats, usage, resolve-model,
#     validate-phase, recover-orphans, …) — the thin bash stubs for those live
#     in defaults/scripts/ and source lib/script-helper.sh, NOT this file; or
#   - deleted outright as a no-op / unreferenced module.
#
# The last surviving Python module, the opt-in `loom-search` semantic-search
# feature, was itself retired in #4970 (see defaults/docs/semantic-search.md)
# per the operator's RETIRE decision on #4608 — there is no Python left in
# this repo at all now.
#
# What is still live here: `_find_repo_root`, used by agent-spawn.sh and
# agent-wait.sh. `run_loom_tool` survives only as a loud, non-silent failure
# shim so an out-of-tree script in a repo carrying an older Loom install gets an
# actionable "use loom-daemon <cmd>" message instead of an opaque
# `python3: No module named loom_tools`.
#
# See docs/adr/0013-loom-tools-python-retirement.md.

# Find the repository root from the script location.
#
# `_find_repo_root` used to carry its own (buggy — #375) copy of this walk.
# It now delegates to lib/script-helper.sh's `_lsh_find_repo_root`, the
# canonical, worktree-aware implementation — see that function's header
# comment for why the check ordering matters. Both libs live in the same
# `lib/` directory, so this source is always resolvable without needing a
# repo root first.
# shellcheck source=./script-helper.sh
source "$(dirname "${BASH_SOURCE[0]}")/script-helper.sh"
_find_repo_root() {
    _lsh_find_repo_root "$@"
}

# Retired dispatcher. Prints a migration message and exits 1 — it never looks
# for, or runs, Python.
#
# Arguments (kept for signature compatibility with the pre-#4557 callers):
#   $1 - former CLI suffix (e.g. "tokens" for the old `loom-tokens`)
#   $2 - former Python module path (e.g. "tokens.cli"); unused
run_loom_tool() {
    local cli_name="${1:-}"

    echo "[ERROR] run_loom_tool is retired (epic #4081 Phase 4, #4557)." >&2
    echo "" >&2
    echo "The Python 'loom-tools' package no longer exists. Loom's orchestration" >&2
    echo "layer is the native 'loom-daemon' binary plus bash scripts." >&2
    echo "" >&2
    if [[ -n "$cli_name" ]]; then
        echo "  was:  loom-${cli_name} ..." >&2
        echo "  now:  loom-daemon ${cli_name} ...   (see 'loom-daemon --help')" >&2
    else
        echo "  Run 'loom-daemon --help' for the native subcommand list." >&2
    fi
    echo "" >&2
    echo "If stale 'loom-*' console scripts from an old editable install are still" >&2
    echo "on PATH, remove them — they shadow the real binary (incident #4079)." >&2
    echo "'.loom/scripts/cli/loom-daemon-update.sh' warns about them, and" >&2
    echo "'loom-daemon --version' reports which binary you actually have." >&2

    exit 1
}

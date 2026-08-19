#!/usr/bin/env bash
# Thin wrapper — delegates to the Loom CLI (.loom/bin/loom stop).
# Kept for backwards compatibility with the legacy ./loom.sh entry point.
#
# The historical daemon.sh was removed in #3432; `.loom/bin/loom stop`
# (tmux agent pool graceful shutdown) is the working replacement.

# Find the repository root: canonical, worktree-aware implementation (#375).
# shellcheck source=lib/script-helper.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/script-helper.sh"
find_repo_root() { _lsh_find_repo_root "$@"; }

REPO_ROOT=$(find_repo_root)
LOOM_BIN="$REPO_ROOT/.loom/bin/loom"

if [[ -z "$REPO_ROOT" || ! -x "$LOOM_BIN" ]]; then
    echo "Error: Loom CLI not found (expected at .loom/bin/loom)" >&2
    echo "Is Loom installed in this repository?" >&2
    exit 1
fi

exec "$LOOM_BIN" stop "$@"

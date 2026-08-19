#!/usr/bin/env bash
# Thin wrapper — delegates to the Loom CLI (.loom/bin/loom).
# Kept for backwards compatibility with the legacy ./loom.sh entry point.
#
# The historical daemon.sh was removed in #3432; the working agent-pool
# surface is `.loom/bin/loom start|status|stop` (tmux pool). This wrapper
# maps the legacy flags onto those subcommands.

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

# Map legacy flags to loom subcommands
for arg in "$@"; do
    case "$arg" in
        --status) exec "$LOOM_BIN" status;;
        --stop)   exec "$LOOM_BIN" stop;;
    esac
done

exec "$LOOM_BIN" start "$@"

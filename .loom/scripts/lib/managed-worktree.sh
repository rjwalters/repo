#!/usr/bin/env bash
# managed-worktree.sh — Shared "create a Loom-managed worktree" primitives:
# the repo-global concurrency lock, the `.loom-managed` sentinel writer, and
# the `.mcp.json` symlink + git-exclude bookkeeping (issue #304).
#
# Source this file (do not exec). Extracted verbatim (behavior-preserving)
# from worktree.sh, which historically was the only one of the three
# "create a managed worktree" scripts to have all three pieces. pr-worktree.sh
# and docs-worktree.sh each hand-rolled their own copy of the sentinel write
# and the `.mcp.json` symlink, but had NO concurrency lock at all around their
# `git worktree add` calls — confirmed missing by grep before this extraction.
# That is not cosmetic: `git worktree add` mutates the repo-global
# `.git/config.lock`, so concurrent invocations (a Doctor/Judge PR checkout
# landing alongside a Guide docs-worktree tick, or two of either) can race on
# it and hang for 10-20 minutes holding an `index.lock` a peer process never
# releases (issue #3380, originally fixed only in worktree.sh). Sourcing this
# file gives every "managed worktree" creator the SAME lock, the same
# sentinel format, and the same exclude-file bookkeeping instead of three
# independently-drifting copies.
#
# Public functions:
#   loom_wt_locks_dir                                  -> echoes the repo-global lock base dir
#   loom_wt_lock_path                                  -> echoes the `git worktree add` lock dir
#   loom_wt_acquire_lock <owner-label> <script> [json]  -> 0 on acquire, 1 on timeout
#   loom_wt_release_lock                                -> always succeeds (idempotent)
#   loom_wt_write_sentinel <worktree-path> <script> [metadata-lines] [footer-lines]
#   loom_wt_append_exclude <worktree-path> <entry>      -> idempotent info/exclude append
#   loom_wt_symlink_mcp_json <main-workspace-dir> <worktree-path> -> 0 on symlink/no-op, 1 on failure
#
# Globals (env-overridable, same names/semantics worktree.sh has always used):
#   LOOM_WORKTREE_LOCK_TIMEOUT       — seconds to wait for the lock (default 600)
#   LOOM_WORKTREE_LOCK_POLL_INTERVAL — seconds between poll attempts (default 2)
#   WORKTREE_LOCK_HOLDER_PID         — set by loom_wt_acquire_lock on timeout, so
#                                      the caller can surface the holder's PID.
#
# Callers are expected to already define print_error/print_warning (worktree.sh,
# pr-worktree.sh, and docs-worktree.sh all do). A minimal stderr-only fallback
# is defined below so this file also works standalone (e.g. sourced directly
# from a test) without requiring the caller's color-coded helpers.

if ! declare -F print_warning >/dev/null 2>&1; then
    print_warning() { echo "WARNING: $*" >&2; }
fi
if ! declare -F print_error >/dev/null 2>&1; then
    print_error() { echo "ERROR: $*" >&2; }
fi

# --------------------------------------------------------------------------
# Concurrency lock (issue #3380)
# --------------------------------------------------------------------------
#
# `git worktree add` is not safe to run concurrently against the same repo —
# parallel invocations contend on the per-worktree administrative dir
# (`.git/worktrees/<id>/`) and on git's repo-global locks. The observed
# failure mode in busy shepherd sessions is multi-minute hangs (10-20 min)
# while a peer process holds an `index.lock` it will never release.
#
# We use a POSIX-atomic `mkdir`-based lock primitive — `flock` is not
# available on stock macOS, so `mkdir` is the only portable atomic
# file-system operation we can rely on.
#
# Lock scope is **repo-global** (`.loom/locks/worktree-add/`), shared by every
# caller of this file (worktree.sh, pr-worktree.sh, docs-worktree.sh) — NOT
# per-issue / per-PR / per-slot. `git worktree add` mutates the repo-global
# `.git/config.lock` (writing the new branch's upstream configuration), and
# concurrent processes race with the diagnostic:
#
#   error: could not lock config file .git/config: File exists
#   error: unable to write upstream branch configuration
#
# A repo-global lock serializes the entire `git worktree add` call so this
# race cannot happen. The cost — two callers (any mix of Builder issue
# worktrees, PR worktrees, and the docs worktree) no longer parallelize
# through `git worktree add` itself — is acceptable because (a) that call is
# short relative to the rest of an issue's/PR's/tick's lifecycle, and (b)
# parallel hangs that hold an `index.lock` for 10-20 minutes are the very
# problem this lock fixes.

LOOM_WORKTREE_LOCK_TIMEOUT="${LOOM_WORKTREE_LOCK_TIMEOUT:-600}"
LOOM_WORKTREE_LOCK_POLL_INTERVAL="${LOOM_WORKTREE_LOCK_POLL_INTERVAL:-2}"

# Resolve the locks directory to the canonical git common dir so worktrees
# and the main workspace all share the same lock namespace. Falls back to the
# current dir for the rare case where we're not yet inside a repo (tests).
loom_wt_locks_dir() {
    local common
    common=$(git rev-parse --git-common-dir 2>/dev/null || true)
    if [[ -n "$common" ]]; then
        # git-common-dir may be returned as a relative path; resolve it.
        local abs_common
        abs_common=$(cd "$common" 2>/dev/null && pwd) || abs_common="$common"
        echo "$(dirname "$abs_common")/.loom/locks"
    else
        echo ".loom/locks"
    fi
}

loom_wt_lock_path() {
    echo "$(loom_wt_locks_dir)/worktree-add"
}

# Set by loom_wt_acquire_lock on timeout failure so the caller can include it
# in error output.
WORKTREE_LOCK_HOLDER_PID=""

# loom_wt_acquire_lock <owner-label> <script-name> [json-mode]
#
#   owner-label  — free-form identifier recorded in the lock's owner.json for
#                  debugging (issue number, "pr-<N>", "docs-guide", ...).
#   script-name  — the caller's script name (worktree.sh / pr-worktree.sh /
#                  docs-worktree.sh), also recorded for debugging.
#   json-mode    — "true" suppresses the human-readable stale-lock warning
#                  (matches the caller's own --json convention); default false.
#
# Returns 0 if the lock was acquired, 1 on timeout (WORKTREE_LOCK_HOLDER_PID
# is set in that case).
loom_wt_acquire_lock() {
    local owner="$1" script="${2:-unknown}" json_mode="${3:-false}"
    local lock
    lock="$(loom_wt_lock_path)"
    local locks_dir
    locks_dir="$(loom_wt_locks_dir)"

    mkdir -p "$locks_dir" 2>/dev/null || true

    local deadline=$(( $(date +%s) + LOOM_WORKTREE_LOCK_TIMEOUT ))
    local stale_retry_done=0

    while true; do
        if mkdir "$lock" 2>/dev/null; then
            # Lock acquired; record owner metadata for debugging.
            cat > "$lock/owner.json" <<EOF
{
  "owner": "$owner",
  "owner_pid": $$,
  "script": "$script",
  "acquired_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
            return 0
        fi

        # Lock exists. Check whether the owner is still alive; if not, clear
        # it once and retry (stale-lock recovery).
        local owner_pid=""
        if [[ -f "$lock/owner.json" ]]; then
            owner_pid=$(awk -F'[ ,]+' '/owner_pid/ {gsub(/[^0-9]/,"",$3); print $3; exit}' "$lock/owner.json" 2>/dev/null)
        fi

        if [[ -n "$owner_pid" ]] && [[ "$stale_retry_done" -eq 0 ]] && ! kill -0 "$owner_pid" 2>/dev/null; then
            if [[ "$json_mode" != "true" ]]; then
                print_warning "Stale worktree lock from dead PID $owner_pid — cleaning up"
            fi
            rm -rf "$lock" 2>/dev/null || true
            stale_retry_done=1
            continue
        fi

        if [[ $(date +%s) -ge $deadline ]]; then
            # shellcheck disable=SC2034  # read by callers (worktree.sh's
            # timeout error output, pr-worktree.sh, docs-worktree.sh) after
            # this function returns — shellcheck only sees this one file.
            WORKTREE_LOCK_HOLDER_PID="$owner_pid"
            return 1
        fi

        sleep "$LOOM_WORKTREE_LOCK_POLL_INTERVAL"
    done
}

# loom_wt_release_lock — always succeeds (idempotent no-op if the lock dir is
# already gone). Takes no arguments: the lock is repo-global, not per-owner.
loom_wt_release_lock() {
    local lock
    lock="$(loom_wt_lock_path)"
    [[ -d "$lock" ]] || return 0
    rm -rf "$lock" 2>/dev/null || true
}

# --------------------------------------------------------------------------
# Loom-managed sentinel (issue #3548, extended by #304)
# --------------------------------------------------------------------------
#
# Write the `.loom-managed` marker that authorizes cleanup tooling
# (merge-pr.sh, agent-destroy.sh, loom-clean, worktree.sh remove) to remove a
# worktree. A worktree lacking this file is treated as user-owned and never
# touched by Loom (see issue #3334).
#
# This MUST be called on every code path that leaves a usable Loom worktree
# behind — not just first-creation — so a re-invocation against an existing
# worktree never strands it sentinel-less (see #3548). The write is a plain
# overwrite, so it is idempotent and self-heals a worktree whose sentinel was
# deleted.
#
# loom_wt_write_sentinel <worktree-path> <script-name> [metadata] [footer]
#
#   metadata — optional literal text (already formatted, e.g. "# Issue: 42")
#              inserted between the header and the standard warning footer.
#              May be multi-line (embedded newlines render as separate lines).
#   footer   — optional literal text appended AFTER the standard warning
#              footer, for a caller-specific extra note.
loom_wt_write_sentinel() {
    local wt="$1" script="$2" metadata="${3:-}" footer="${4:-}"
    {
        echo "# Loom-managed worktree marker"
        echo "# Created by .loom/scripts/$script"
        [[ -n "$metadata" ]] && printf '%s\n' "$metadata"
        echo "# Removing this file makes Loom treat the worktree as user-owned and refuse"
        echo "# to clean it up automatically."
        if [[ -n "$footer" ]]; then
            printf '%s\n' "$footer"
        fi
    } > "$wt/.loom-managed"
    return 0
}

# --------------------------------------------------------------------------
# .mcp.json symlink + git-exclude bookkeeping (issue #3528, extended by #304)
# --------------------------------------------------------------------------
#
# `.mcp.json` is gitignored so it's invisible from a worktree's own git root,
# which would otherwise prevent Claude Code from discovering MCP server
# config inside a freshly created worktree. Symlinking it in from the main
# workspace fixes discovery; recording the symlink in the worktree's
# `info/exclude` keeps `git add -A` from ever staging it even when the
# consumer repo's `.gitignore` doesn't happen to match a symlink (the classic
# `node_modules/`-trailing-slash-vs-symlink hazard from #3528/#5474).

# loom_wt_append_exclude <worktree-path> <entry>
#
# Idempotently append a path to the given worktree's info/exclude file.
# Resolves the exclude path fresh on every call (via `git rev-parse
# --git-path info/exclude`, which is correct across worktree layouts) —
# cheap relative to a `git worktree add`, so no caching is needed here.
# Best-effort: a missing exclude file just means git tracked the ignore
# elsewhere; never fails the caller.
loom_wt_append_exclude() {
    local wt="$1" entry="$2"
    local exclude_path
    exclude_path=$(cd "$wt" 2>/dev/null && git rev-parse --git-path info/exclude 2>/dev/null)
    [[ -n "$exclude_path" ]] || return 0
    if [[ "$exclude_path" != /* ]]; then
        # git rev-parse may return a path relative to the worktree cwd; anchor it.
        exclude_path="$wt/$exclude_path"
    fi
    mkdir -p "$(dirname "$exclude_path")" 2>/dev/null || true
    grep -qxF "$entry" "$exclude_path" 2>/dev/null \
        || echo "$entry" >> "$exclude_path" 2>/dev/null || true
}

# loom_wt_symlink_mcp_json <main-workspace-dir> <worktree-path>
#
# Symlinks .mcp.json from the main workspace into the worktree and records
# the symlink in the worktree's info/exclude. Idempotent + best-effort:
#   - no main .mcp.json                -> silent no-op, returns 0
#   - worktree already has a .mcp.json -> silent no-op, returns 0
#   - `ln -s` fails                    -> returns 1 (caller decides how loud)
loom_wt_symlink_mcp_json() {
    local main_ws="$1" wt="$2"
    local main_mcp="$main_ws/.mcp.json"
    local wt_mcp="$wt/.mcp.json"

    [[ -f "$main_mcp" ]] || return 0
    [[ -e "$wt_mcp" ]] && return 0

    if ln -s "$main_mcp" "$wt_mcp" 2>/dev/null; then
        loom_wt_append_exclude "$wt" ".mcp.json"
        return 0
    fi
    return 1
}

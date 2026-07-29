# Repo

**General-purpose repository skills for Claude Code.**

Repo is a collection of skills for keeping any git repository healthy and productive — auditing hygiene, tidying clutter, and launching cloud dev sessions with the repo ready to go. Skills install into a target repository (the consumer repo) and are invoked from Claude Code as `/repo:<command>`.

**Sibling projects:** [Loom](https://github.com/rjwalters/loom) orchestrates AI development workers around a forge. [Anvil](https://github.com/rjwalters/anvil) orchestrates long-form artifact creation. Repo is the toolbox both of them assume: generic repository hygiene and environment skills that work in any repo. All three can be installed side by side.

## Skills

| Command | What it does |
|---|---|
| `/repo:help` | Explain the installed `/repo:*` commands — what each does, where to start |
| `/repo:all` | The whole hygiene pass in order — audit, docs, tidy, update-tools, reset — safe fixes by default, destructive steps gated |
| `/repo:audit` | Full health sweep — runs every check below, produces one summary report |
| `/repo:reset` | Back to baseline — review stale worktrees/branches/stashes, sync with remote, return to main |
| `/repo:handoff` | Roll the session safely — file follow-ups, reset, check for a CLI update, write a handoff note the next session reads first |
| `/repo:tidy` | Tidy up — build artifacts, caches, temp files, empty dirs |
| `/repo:release` | Cut a release — pre-flight checks, semver decision, CHANGELOG, version bump, tag, GitHub Release |
| `/repo:remote` | Launch a cloud dev session (GCP or AWS) with the repo ready to go, then open an SSH session |
| `/repo:host-optimize` | Prepare a Mac (or Linux box) for heavy Loom/agent build use — audit Gatekeeper churn, backup-agent interference, build-tree bloat; apply safe fixes, gate consequential ones |
| `/repo:update-tools` | Check installed tool packages (Loom, Anvil, …) against their sources and offer updates |
| `/repo:followups` | Capture follow-on work from this session and file it as issues — here or in upstream tool repos, always confirmed first |
| `/repo:branches` | Branch & worktree hygiene — merged PRs, orphaned worktree branches, stale worktrees |
| `/repo:gitignore` | Gitignore audit — over-ignored files, under-ignored build artifacts, stale rules |
| `/repo:docs` | Documentation health — content accuracy, README structure, and cross-references (canonical docs command) |
| `/repo:links` | Validate internal cross-references — markdown links, CLAUDE.md paths, skill graphs |
| `/repo:orphans` | Find unreferenced files — dead scripts, stale data, outputs without sources |
| `/repo:readme` | Check README accuracy against actual directory contents |

Hygiene skills **apply their safe, reversible fixes by default** and report each change; add `--ask` to review findings and confirm first. Irreversible actions (deleting branches, worktrees, stashes, untracked files) are never automatic — they require an explicit opt-in and pass a permanent-loss check. Commands whose only action is consequential (`orphans`, `update-tools`, `followups`, `release`, `remote`) always confirm first.

## Destructive-command protection

Installing Repo Skills also wires a **PreToolUse safety hook** (`guard-destructive.sh`) into the target repo's `.claude/settings.json`. This is the **canonical generic destructive-command guard** — Loom and other tooling defer to this copy rather than shipping their own. It runs before every agent `Bash` command and **blocks** catastrophic operations (`rm -rf /` or `$HOME` or outside-repo targets, force-push to `main`, fork bombs, piping a download into a shell, `gh repo delete`, cloud/stack/IAM destruction, `DROP TABLE`, `DELETE` without `WHERE`, …) and **asks** for confirmation on risky-but-legitimate ones (force ops, mutating cloud verbs, `kubectl delete`, credential reads). Read-only commands take a zero-fork fast path; scoped deletes like `rm -rf node_modules` are allowed; quote-aware parsing and literal-text redaction keep prose, commit messages, and issue bodies from tripping it.

Every category is configurable per repo (`REPO_GUARD_*`/`REPO_*` env vars or `guards.*` config keys, with legacy `LOOM_*` names honored). See [`skills/repo/SKILL.md`](skills/repo/SKILL.md#destructive-command-guard-pretooluse-hook) for the toggle table and resolution order. If the target already has a compatible guard wired (e.g. a pre-consolidation Loom install), the installer defers to it rather than adding a duplicate.

## Handoff notes at session start

Installing Repo Skills also wires a **SessionStart hook** (`session-start-handoff.sh`). When `/repo:handoff` has left a note at `.claude/handoff.md`, the hook surfaces it as session context on startup and resume — path, age, a section outline, and a staleness warning once the note passes seven days — so a rolled session opens already knowing what the last one left behind.

It is strictly read-only: it never writes or deletes the note (absorbing it and removing it is `/repo:handoff`'s own one-shot contract), it stays silent when no note exists, and it fails open, so a hook error can never block session start. It deliberately does not fire on `/clear`, which is not a process relaunch.

## Installation

The installer copies the skill files into a target repository's `.claude/` directory, wires the guard hook into `.claude/settings.json`, and appends a marker-bounded section to its `CLAUDE.md`.

```bash
# Install everything into the current directory
./install.sh .

# Install into another repo
./install.sh ~/projects/my-app

# Install only specific skills
./install.sh --skills=reset,remote ~/projects/my-app

# Preview without writing
./install.sh --dry-run ~/projects/my-app

# Non-interactive
./install.sh -y ~/projects/my-app

# Dev mode: symlink source files for live editing (dogfooding)
./install.sh --dev .
```

To remove: `./uninstall.sh /path/to/target-repo`.

### Write footprint

The installer is designed to coexist with whatever already lives in the consumer repo (including Anvil and Loom installs):

- `.claude/skills/repo/` — the domain skill file plus install metadata
- `.claude/skills/repo/hooks/guard-destructive.sh` — the PreToolUse guard hook (colocated under the skill dir; removed with it on uninstall)
- `.claude/skills/repo/hooks/session-start-handoff.sh` — the SessionStart handoff-note hook (same colocation, same uninstall behavior)
- `.claude/skills/repo/scripts/repo-remote.sh` — the headless provisioning entry point for `/repo:remote` (the interactive skill delegates to it; a caller such as loom's `fleet add-worker` invokes it directly). Same colocation, removed with the skill dir on uninstall
- `.claude/commands/repo/` — one file per command, namespaced under `repo/` so nothing else is touched
- `.claude/settings.json` — a single `PreToolUse` → `Bash` hook entry is **merged in** (never wholesale-copied): existing hooks, permissions, and unrelated entries are preserved, re-installs don't duplicate, and if another guard is already wired the installer defers instead. `uninstall.sh` removes only the entry it owns and prunes empty containers
- `.claude/settings.json` — two `SessionStart` entries (`startup` and `resume`) are merged the same way for the handoff-note hook. A pre-existing `SessionStart` hook from another tool is preserved rather than clobbered, and uninstall removes only the two entries it owns
- `CLAUDE.md` — one lightweight marker-bounded block (`<!-- BEGIN REPO-SKILLS --> … <!-- END REPO-SKILLS -->`) appended after your existing content; re-installs replace it in place. The block is deliberately just a pointer to `/repo:help` and `.claude/skills/repo/SKILL.md` — it does not inline the command list, so it never goes stale

Nothing else in the target repository is read or modified.

## Repository layout

```
skills/repo/SKILL.md         Domain overview installed to .claude/skills/repo/
commands/repo/*.md           Command files installed to .claude/commands/repo/
scripts/repo/repo-remote.sh  Headless /repo:remote provisioning entry point, installed to .claude/skills/repo/scripts/
hooks/repo/guard-destructive.sh  PreToolUse guard hook installed to .claude/skills/repo/hooks/
hooks/repo/session-start-handoff.sh  SessionStart handoff-note hook installed to the same place
hooks/repo/tests/run.sh      Smoke suite covering both hooks (bash, no framework needed)
hooks/repo/tests/test-guard-destructive.sh  Full guard regression suite (ported from Loom)
hooks/repo/tests/test-session-start-handoff.sh  Handoff-hook suite (run.sh delegates to it)
hooks/repo/tests/test-install-claude-md-markers.sh  CLAUDE.md marker-block regression suite
commands/repo/tests/test-branches-loss-check.sh  branches.md permanent-loss check suite (run.sh delegates)
commands/repo/tests/test-repo-remote.sh  repo-remote.sh provisioning-contract suite (run.sh delegates)
install.sh                   Installer
uninstall.sh                 Uninstaller
lib/claude-md-block.sh       Marker-bounded CLAUDE.md surgery shared by install.sh/uninstall.sh
```

## Adding a skill

1. Create `commands/repo/<name>.md` with the standard frontmatter (`name`, `description`, `domain: repo`, `type: command`, `user-invocable: true`).
2. Add a `[[<name>]]` row to the commands table in `skills/repo/SKILL.md`.
3. Add a row to the Skills table in this README.
4. Keep it **general**: no org-specific hostnames, project names, branch names, or infrastructure paths. If a check needs configuration, read it from the consumer repo (e.g. its `.env` or `CLAUDE.md`), never hardcode it.

## License

MIT

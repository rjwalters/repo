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
| `/repo:tidy` | Tidy up — build artifacts, caches, temp files, empty dirs |
| `/repo:release` | Cut a release — pre-flight checks, semver decision, CHANGELOG, version bump, tag, GitHub Release |
| `/repo:remote` | Launch a cloud dev session (GCP or AWS) with the repo ready to go, then open an SSH session |
| `/repo:update-tools` | Check installed tool packages (Loom, Anvil, …) against their sources and offer updates |
| `/repo:branches` | Branch & worktree hygiene — merged PRs, orphaned worktree branches, stale worktrees |
| `/repo:gitignore` | Gitignore audit — over-ignored files, under-ignored build artifacts, stale rules |
| `/repo:docs` | Documentation health — content accuracy, README structure, and cross-references (canonical docs command) |
| `/repo:links` | Validate internal cross-references — markdown links, CLAUDE.md paths, skill graphs |
| `/repo:orphans` | Find unreferenced files — dead scripts, stale data, outputs without sources |
| `/repo:readme` | Check README accuracy against actual directory contents |

Hygiene skills **apply their safe, reversible fixes by default** and report each change; add `--ask` to review findings and confirm first. Irreversible actions (deleting branches, worktrees, stashes, untracked files) are never automatic — they require an explicit opt-in and pass a permanent-loss check. Commands whose only action is consequential (`orphans`, `update-tools`, `release`, `remote`) always confirm first.

## Destructive-command protection

Installing Repo Skills also wires a **PreToolUse safety hook** (`guard-destructive.sh`) into the target repo's `.claude/settings.json`. It runs before every agent `Bash` command and **blocks** catastrophic operations (`rm -rf /` or `$HOME`, force-push to `main`, fork bombs, `curl … | sh`, `gh repo delete`, cloud/stack/IAM destruction, `DROP TABLE`, `DELETE` without `WHERE`, …) and **asks** for confirmation on reversible-but-risky ones (`git reset --hard`, `kubectl delete`, `docker rm`, credential reads). Scoped deletes like `rm -rf node_modules` are allowed.

Two categories are opt-out per repo for repos where they don't apply — SQL (`REPO_GUARD_SQL` / `guards.sqlDdl`) and cloud CLIs (`REPO_GUARD_CLOUD` / `guards.cloudCli`). See [`skills/repo/SKILL.md`](skills/repo/SKILL.md#destructive-command-guard-pretooluse-hook) for the full pattern list and resolution order. If the target already has a compatible guard wired (e.g. Loom's), the installer defers to it rather than adding a duplicate.

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
- `.claude/commands/repo/` — one file per command, namespaced under `repo/` so nothing else is touched
- `.claude/settings.json` — a single `PreToolUse` → `Bash` hook entry is **merged in** (never wholesale-copied): existing hooks, permissions, and unrelated entries are preserved, re-installs don't duplicate, and if another guard is already wired the installer defers instead. `uninstall.sh` removes only the entry it owns and prunes empty containers
- `CLAUDE.md` — one lightweight marker-bounded block (`<!-- BEGIN REPO-SKILLS --> … <!-- END REPO-SKILLS -->`) appended after your existing content; re-installs replace it in place. The block is deliberately just a pointer to `/repo:help` and `.claude/skills/repo/SKILL.md` — it does not inline the command list, so it never goes stale

Nothing else in the target repository is read or modified.

## Repository layout

```
skills/repo/SKILL.md         Domain overview installed to .claude/skills/repo/
commands/repo/*.md           Command files installed to .claude/commands/repo/
hooks/repo/guard-destructive.sh  PreToolUse guard hook installed to .claude/skills/repo/hooks/
hooks/repo/tests/run.sh      Test harness for the guard hook (bash, no framework needed)
install.sh                   Installer
uninstall.sh                 Uninstaller
```

## Adding a skill

1. Create `commands/repo/<name>.md` with the standard frontmatter (`name`, `description`, `domain: repo`, `type: command`, `user-invocable: true`).
2. Add a `[[<name>]]` row to the commands table in `skills/repo/SKILL.md`.
3. Add a row to the Skills table in this README.
4. Keep it **general**: no org-specific hostnames, project names, branch names, or infrastructure paths. If a check needs configuration, read it from the consumer repo (e.g. its `.env` or `CLAUDE.md`), never hardcode it.

## License

MIT

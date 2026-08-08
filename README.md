# Repo

**General-purpose repository skills for Claude Code.**

Repo is a collection of skills for keeping any git repository healthy and productive — auditing hygiene, tidying clutter, and launching cloud dev sessions with the repo ready to go. Skills install into a target repository (the consumer repo) and are invoked from Claude Code as `/repo:<command>`.

**Sibling projects:** [Loom](https://github.com/rjwalters/loom) orchestrates AI development workers around a forge. [Anvil](https://github.com/rjwalters/anvil) orchestrates long-form artifact creation. Repo is the toolbox both of them assume: generic repository hygiene and environment skills that work in any repo. All three can be installed side by side.

## Skills

| Command | What it does |
|---|---|
| `/repo:help` | Explain the installed `/repo:*` commands — what each does, where to start |
| `/repo:all` | The whole hygiene pass in order — audit, scrub, docs, tidy, update-tools, reset — safe fixes by default, destructive steps gated |
| `/repo:audit` | Full health sweep — runs every check below, produces one summary report |
| `/repo:scrub` | Public-surface scrub — scan code, history, issues, PRs (and forks) for sensitive identifiers, and report which findings can actually be removed. Report-only |
| `/repo:reset` | Back to baseline — review stale worktrees/branches/stashes, sync with remote, return to main |
| `/repo:handoff` | Roll the session safely — file follow-ups, reset, check for a CLI update, write a handoff note the next session reads first |
| `/repo:tidy` | Tidy up — build artifacts, caches, temp files, empty dirs |
| `/repo:release` | Cut a release — pre-flight checks, semver decision, CHANGELOG, version bump, tag, GitHub Release. Supports per-project release policy via named phase-boundary seams in `.repo/release-policy.md` |
| `/repo:remote` | Launch a cloud dev session (GCP or AWS) with the repo ready to go, then open an SSH session |
| `/repo:sudo` | Opt-in passwordless-sudo setup for a dev machine — install a `visudo`-validated `/etc/sudoers.d` drop-in (blanket `ALL` or a scoped command list) so an agent over SSH isn't blocked on password prompts; always confirmed, validated with rollback on failure |
| `/repo:host-optimize` | Prepare a Mac (or Linux box) for heavy Loom/agent build use — audit Gatekeeper churn, backup-agent interference, build-tree bloat; apply safe fixes, gate consequential ones |
| `/repo:update-tools` | Check installed tool packages (Loom, Anvil, …) against their sources and offer updates |
| `/repo:deps` | Third-party dependency currency — verify/scaffold Dependabot (config *and* the repo-level security flag) and triage open Dependabot PRs, always confirmed first |
| `/repo:followups` | Capture follow-on work from this session and file it as issues — here or in upstream tool repos, always confirmed first |
| `/repo:branches` | Branch & worktree hygiene — merged PRs, orphaned worktree branches, stale worktrees |
| `/repo:gitignore` | Gitignore audit — over-ignored files, under-ignored build artifacts, stale rules |
| `/repo:docs` | Documentation health — content accuracy, README structure, and cross-references (canonical docs command) |
| `/repo:links` | Validate internal cross-references — markdown links, CLAUDE.md paths, skill graphs |
| `/repo:orphans` | Find unreferenced files — dead scripts, stale data, outputs without sources |
| `/repo:readme` | Check README accuracy against actual directory contents |

Hygiene skills **apply their safe, reversible fixes by default** and report each change; add `--ask` to review findings and confirm first. Irreversible actions (deleting branches, worktrees, stashes, untracked files) are never automatic — they require an explicit opt-in and pass a permanent-loss check. Commands whose only action is consequential (`orphans`, `update-tools`, `deps`, `followups`, `release`, `remote`, `sudo`) always confirm first.

## Destructive-command protection

Installing Repo Skills also wires a **PreToolUse safety hook** (`guard-destructive.sh`) into the target repo's `.claude/settings.json`. This is the **canonical generic destructive-command guard**. It runs before every agent `Bash` command and **blocks** catastrophic operations (`rm -rf /` or `$HOME` or outside-repo targets, force-push to `main`, fork bombs, piping a download into a shell, `gh repo delete`, cloud/stack/IAM destruction, `DROP TABLE`, `DELETE` without `WHERE`, …) and **asks** for confirmation on risky-but-legitimate ones (force ops, mutating cloud verbs, `kubectl delete`, credential reads). Read-only commands take a zero-fork fast path; scoped deletes like `rm -rf node_modules` are allowed; quote-aware parsing and literal-text redaction keep prose, commit messages, and issue bodies from tripping it.

Every category is configurable per repo (`REPO_GUARD_*`/`REPO_*` env vars or `guards.*` config keys, with legacy `LOOM_*` names honored). See [`skills/repo/SKILL.md`](skills/repo/SKILL.md#destructive-command-guard-pretooluse-hook) for the toggle table and resolution order. If the target already has a compatible guard wired (e.g. a pre-consolidation Loom install), the installer defers to it rather than adding a duplicate.

**In a Loom-managed repo, this guard does not currently run.** Loom wires its own `.loom/hooks/guard-destructive.sh`, which is a dispatcher: it execs this canonical guard only when that copy passes **both** a version probe and a capability probe for **Bash-tool write confinement** (grepping for the `worktree-write-confinement` marker). This guard does not implement that category yet, so the capability probe fails and the dispatcher runs Loom's own vendored `guard-destructive-generic.sh` instead. Nothing is unguarded — the vendored guard carries write confinement and does run — but do not read an upgrade of Repo Skills as a change to destructive-command protection in a repo Loom manages, because it is not one. What an upgrade delivers there is the `/repo:*` command surface. The deferral is designed to become real automatically: Loom's probe is already written so that the moment this guard implements write confinement and emits that marker, the dispatcher starts preferring it with no change on Loom's side.

## Handoff notes at session start

Installing Repo Skills also wires a **SessionStart hook** (`session-start-handoff.sh`). When `/repo:handoff` has left a note at `.claude/handoff.md`, the hook surfaces it as session context on startup and resume — path, age, a staleness warning once the note passes seven days, and the note itself: the full body inlined when it is small (at or under a 10 KB cap), or a header outline plus an oversize warning when it is larger — so a rolled session opens already knowing what the last one left behind.

It is strictly read-only: it never writes or deletes the note (absorbing it and removing it is `/repo:handoff`'s own one-shot contract), it stays silent when no note exists, and it fails open, so a hook error can never block session start. It deliberately does not fire on `/clear`, which is not a process relaunch.

### Optional: surface the note to the human too (`--shell-wrapper`)

The `SessionStart` hook above gets the note into **Claude's** context. It shows the **human** nothing before the session starts — you quit, relaunch, and there's no visible signal that the previous session left instructions. Pass `--shell-wrapper` to `install.sh` to also opt into a shell `claude` wrapper that prints a compact banner (note path, age, a `##`-header outline, and a STALE warning past seven days) *before* Claude starts.

This is the **one thing the installer writes outside the target repo** — it edits your shell rc (`~/.zshrc` or `~/.bashrc`, detected from `$SHELL`/`$ZSH_VERSION`/`$BASH_VERSION`; fish isn't supported yet and is skipped with a clear message rather than half-supported) — so it is treated with more care than everything else installed:

- **Off by default.** `--yes`/non-interactive installs are a **strict no-op** for this feature unless `--shell-wrapper` is also passed — the rc file is neither read nor written. An interactive install without the flag still *offers* it via a confirm (default **N**), always showing the exact pending diff first.
- **Marker-bounded and idempotent**, same convention as the `CLAUDE.md` block (`# BEGIN REPO-SKILLS CLAUDE WRAPPER` / `# END …`) — re-running `--shell-wrapper` replaces the block in place rather than duplicating it.
- **Backed up before every edit.** The path is reported after install/uninstall.
- **Preserves an existing `claude` alias.** If your rc already has `alias claude='command claude --dangerously-skip-permissions'` (or similar), its flags are folded into the new function and `unalias claude` runs ahead of the function definition so the two don't fight over which wins. Your original alias line is left untouched outside the markers. Anything outside that common single-line form is left alone with a message rather than guessed at.
- **Never recurses and never breaks non-interactive invocations.** The function always calls `command claude`, and always falls through to it unmodified — the banner helper is skipped (not fatal) if it's ever missing, so scripted calls like `claude mcp list` behave exactly like the real binary.

```bash
./install.sh --shell-wrapper ~/projects/my-app       # interactive: offers a confirm either way
./install.sh -y --shell-wrapper ~/projects/my-app    # non-interactive opt-in, no prompt
```

`uninstall.sh` removes the block (from both `~/.zshrc` and `~/.bashrc`, whichever has it) automatically, with the same backup discipline, and is a no-op if it was never installed.

### Optional: Codex operator wrapper (`--shell-wrapper`)

The same `--shell-wrapper` opt-in installs a **second**, independent marker-bounded block (`# BEGIN REPO-SKILLS CODEX WRAPPER` / `# END …`) that defines two Codex entry points, mirroring the hand-rolled convention many operators already keep in their rc:

- **`codex`** — the interactive-operator default. It injects `--dangerously-bypass-approvals-and-sandbox` so a human driving a full session isn't stopped by repeated approval prompts. It adds that flag **exactly once, and only when you haven't already chosen a posture**: if your argv already carries `--sandbox`/`-s`, `--ask-for-approval`/`-a`, or the bypass flag itself (in either `--flag value` or `--flag=value` form), your choice is respected and nothing is injected. Non-session utility subcommands (`codex doctor`, `codex update`, `codex mcp …`) pass straight through, unmodified.
- **`codex-safe`** — runs `command codex` with your argv byte-for-byte, no injection. Use it for read-only / review work.

> **Security boundary — read before opting in.** The `codex` default is an **explicit, interactive operator opt-in for a human at a keyboard**. It is deliberately dangerous (it bypasses Codex's approval prompts *and* its sandbox), and it is **not** the sandbox policy for unattended or daemon-dispatched workers. Automated/worker contexts must set their own posture explicitly (or use `codex-safe`) — never rely on this convenience default in a headless pipeline. The wrapper's argv scan errs on the safe side: if it can't tell whether you passed an explicit posture flag, it declines to inject the dangerous default rather than risk overriding a safer choice you made.

Both blocks are installed, previewed, backed up, and removed together under the single `--shell-wrapper` opt-in — same idempotency and backup discipline as the `claude` wrapper above. `uninstall.sh` removes the Codex block too.

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

# Opt into the shell `claude` wrapper (see "Optional: surface the note to the
# human too" above) — off by default, edits your shell rc
./install.sh --shell-wrapper ~/projects/my-app
```

To remove: `./uninstall.sh /path/to/target-repo`.

### Updating an existing install

Installed surfaces are **copies**, so a fix merged here does not reach a repo
that already installed. Refresh one from its recorded source clone without
re-running the installer:

```bash
# From inside the consumer repo
.claude/skills/repo/scripts/resync-installed.sh --dry-run   # report drift, write nothing
.claude/skills/repo/scripts/resync-installed.sh             # apply
```

It is idempotent, reports per-file created/updated/unchanged/skipped, skips
symlinked (`--dev`) destinations, and **never removes a file** — a file with no
source counterpart is named and left alone. Exit status is `0` in sync, `2` from
`--dry-run` when drift was found, `1` on error. Add `--quiet` for a one-line
summary (what a fleet-wide driver wants).

This is requirement C7 of [`INSTALLER-CONTRACT.md`](INSTALLER-CONTRACT.md), the
normative installer contract this repo owns for the whole tool-package family
(Loom, Anvil, Repo Skills, squad).

### Write footprint

The installer is designed to coexist with whatever already lives in the consumer repo (including Anvil and Loom installs):

- `.claude/skills/repo/` — the domain skill file plus install metadata
- `.claude/skills/repo/hooks/guard-destructive.sh` — the PreToolUse guard hook (colocated under the skill dir; removed with it on uninstall)
- `.claude/skills/repo/hooks/session-start-handoff.sh` — the SessionStart handoff-note hook (same colocation, same uninstall behavior)
- `.claude/skills/repo/scripts/repo-remote.sh` — the headless provisioning entry point for `/repo:remote` (the interactive skill delegates to it; a caller such as loom's `fleet add-worker` invokes it directly). Same colocation, removed with the skill dir on uninstall
- `.claude/skills/repo/scripts/resync-installed.sh` — the consumer-side resync (see "Updating an existing install" above). Same colocation, removed with the skill dir on uninstall
- `.claude/commands/repo/` — one file per command, namespaced under `repo/` so nothing else is touched
- `.claude/settings.json` — a single `PreToolUse` → `Bash` hook entry is **merged in** (never wholesale-copied): existing hooks, permissions, and unrelated entries are preserved, re-installs don't duplicate, and if another guard is already wired the installer defers instead. `uninstall.sh` removes only the entry it owns and prunes empty containers
- `.claude/settings.json` — two `SessionStart` entries (`startup` and `resume`) are merged the same way for the handoff-note hook. A pre-existing `SessionStart` hook from another tool is preserved rather than clobbered, and uninstall removes only the two entries it owns
- `CLAUDE.md` — one lightweight marker-bounded block (`<!-- BEGIN REPO-SKILLS --> … <!-- END REPO-SKILLS -->`) appended after your existing content; re-installs replace it in place. The block is deliberately just a pointer to `/repo:help` and `.claude/skills/repo/SKILL.md` — it does not inline the command list, so it never goes stale

Nothing else in the target repository is read or modified.

Opt-in only, and outside the target repository: with `--shell-wrapper`, your shell rc (`~/.zshrc` or `~/.bashrc`) gains two marker-bounded blocks (`# BEGIN REPO-SKILLS CLAUDE WRAPPER` / `# END …` and `# BEGIN REPO-SKILLS CODEX WRAPPER` / `# END …`), backed up first — see "Optional: surface the note to the human too" and "Optional: Codex operator wrapper" above.

## Repository layout

```
skills/repo/SKILL.md         Domain overview installed to .claude/skills/repo/
commands/repo/*.md           Command files installed to .claude/commands/repo/
scripts/repo/repo-remote.sh  Headless /repo:remote provisioning entry point, installed to .claude/skills/repo/scripts/
scripts/repo/resync-installed.sh  Consumer-side resync (contract C7), installed to .claude/skills/repo/scripts/
hooks/repo/guard-destructive.sh  PreToolUse guard hook installed to .claude/skills/repo/hooks/
hooks/repo/session-start-handoff.sh  SessionStart handoff-note hook installed to the same place
hooks/repo/tests/run.sh      Smoke suite covering both hooks (bash, no framework needed)
hooks/repo/tests/test-guard-destructive.sh  Full guard regression suite (ported from Loom)
hooks/repo/tests/test-session-start-handoff.sh  Handoff-hook suite (run.sh delegates to it)
hooks/repo/tests/test-install-claude-md-markers.sh  CLAUDE.md marker-block regression suite
hooks/repo/tests/test-shell-wrapper.sh  claude + codex shell wrapper suite (run.sh delegates to it)
commands/repo/tests/test-branches-loss-check.sh  branches.md permanent-loss check suite (run.sh delegates)
commands/repo/tests/test-repo-remote.sh  repo-remote.sh provisioning-contract suite (run.sh delegates)
commands/repo/tests/test-verify-fix-persistence.sh  verify-after-write contract suite (run.sh delegates)
commands/repo/tests/test-resync-installed.sh  resync-installed.sh suite (run.sh delegates)
commands/repo/tests/test-installer-contract.sh  INSTALLER-CONTRACT.md C1-C8 conformance (run.sh delegates)
INSTALLER-CONTRACT.md        Normative tool-package installer contract (C1-C8), owned by this repo
install.sh                   Installer
uninstall.sh                 Uninstaller
lib/claude-md-block.sh       Marker-bounded CLAUDE.md surgery shared by install.sh/uninstall.sh
lib/render.sh                Template-variable rendering shared by install.sh/resync-installed.sh
lib/metadata.sh              The C5/C6 tracked-vs-sidecar metadata shape, same two callers
lib/shell-wrapper.sh         Opt-in claude + codex shell wrappers (--shell-wrapper): detection, alias parsing, runtime posture-flag dedup, marker-bounded rc surgery
```

## Adding a skill

1. Create `commands/repo/<name>.md` with the standard frontmatter (`name`, `description`, `domain: repo`, `type: command`, `user-invocable: true`).
2. Add a `[[<name>]]` row to the commands table in `skills/repo/SKILL.md`.
3. Add a row to the Skills table in this README.
4. Keep it **general**: no org-specific hostnames, project names, branch names, or infrastructure paths. If a check needs configuration, read it from the consumer repo (e.g. its `.env` or `CLAUDE.md`), never hardcode it.

## License

MIT

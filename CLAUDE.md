# Repo — development guide

This is the **source repo** for Repo Skills: general-purpose repository skills
for Claude Code, installed into consumer repos via `./install.sh`. Sibling
projects [Loom](https://github.com/rjwalters/loom) and
[Anvil](https://github.com/rjwalters/anvil) follow the same install pattern.

## Layout

- `skills/repo/SKILL.md` — domain overview, installed to `.claude/skills/repo/`
- `commands/repo/<name>.md` — one file per command, installed to
  `.claude/commands/repo/`, invoked as `/repo:<name>`
- `install.sh` / `uninstall.sh` — consumer-repo installer/uninstaller
- `VERSION` — single source of truth for the release version

## Conventions

Every command file starts with this frontmatter:

```yaml
---
name: "<command>"
description: "<one line, shown in tables and the installed CLAUDE.md block>"
domain: repo
type: command
user-invocable: true
---
```

Command files are prompts, not code: they instruct Claude step by step, with
runnable shell snippets where exactness matters.

### Template variables

`install.sh` renders a small set of `{{PLACEHOLDER}}` variables into every
installed SKILL.md and command file (the Loom pattern), and **fails the install
if a known placeholder survives** the copy. Available placeholders:

| Placeholder | Value at install time |
|-------------|-----------------------|
| `{{REPO_OWNER}}` | Consumer repo owner (from its `origin` remote; `OWNER` if none) |
| `{{REPO_NAME}}` | Consumer repo name (remote, else target dir name) |
| `{{REPO_SKILLS_VERSION}}` | This package's `VERSION` |
| `{{REPO_SKILLS_COMMIT}}` | This package's short commit |
| `{{INSTALL_DATE}}` | Install date (UTC, `YYYY-MM-DD`) |

Prefer reading repo-specific facts at runtime (principle 1) over baking them in.
Reach for a placeholder only when a value must be fixed at install time. When
porting a Loom skill, replace its `{{workspace}}` with `{{REPO_NAME}}` — or,
better, reword to read the context at runtime.

Rules for every skill:

1. **General by design.** No org names, project names, hostnames, branch
   lists, or infrastructure paths. Repo-specific knowledge is read from the
   consumer repo at runtime (its CLAUDE.md, `.claude/remote.json`, …).
2. **Apply safe fixes, gate destructive ones.** Fix-capable hygiene commands
   apply their safe, reversible fixes by default and report each change; they
   accept `--ask` to restore review-and-confirm. Anything irreversible —
   deleting branches, worktrees, stashes, or untracked files, or
   creating/destroying resources — is never automatic: show the exact plan (and
   cost, for cloud resources), run a permanent-loss check, and act only on
   explicit opt-in. Commands whose only action is consequential (`orphans`,
   `update-tools`, `release`, `remote`) confirm first by nature.
3. **Wire it up.** A new command needs: the command file, a `[[wikilink]]` row
   in `skills/repo/SKILL.md`, and a row in README.md's Skills table. Do **not**
   add it to the installed CLAUDE.md block — that block is a fixed-size pointer
   to `/repo:help` and SKILL.md by design (matching Loom/Anvil), so it never
   goes stale as commands are added.

## Testing the installer

```bash
tmp=$(mktemp -d) && git -C "$tmp" init -q
./install.sh -y "$tmp"          # then inspect $tmp/.claude and $tmp/CLAUDE.md
./install.sh -y "$tmp"          # idempotency: block replaced, not duplicated
./uninstall.sh -y "$tmp"        # everything gone, CLAUDE.md block removed
```

## Dogfooding

Run this repo's own `/repo:*` commands against itself with `--dev`:

```bash
./install.sh --dev -y .         # symlinks source files into .claude/, live edits
```

`--dev` symlinks each command/SKILL file (rather than render-copying) so edits to
`commands/repo/*.md` are immediately live — no re-install. It's the only mode
allowed to target the source repo itself. Because the symlinks are absolute and
machine-local, dev mode gitignores `.claude/` and leaves this dev-guide CLAUDE.md
untouched (no consumer-facing REPO-SKILLS block). `./uninstall.sh -y .` removes
the symlinks without touching the source. The same pattern applies to sibling
tool repos (Loom, Anvil).

## Releasing

Bump `VERSION`, add a CHANGELOG.md entry, tag `v<version>`.

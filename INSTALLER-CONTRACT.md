# Tool-Package Installer Contract

**Status:** normative, v1 · **Owner:** [Repo Skills](https://github.com/rjwalters/repo) · **Applies to:** Loom, Anvil, Repo Skills, squad, kicad-tools, and any future tool package

A **tool package** is a repo that *copies* agent-facing surfaces — skills,
commands, agents, hooks, scripts — into a **consumer repo**. This document
specifies what such a package's installer MUST provide. It is the single
normative source for the rules that `/repo:update-tools` and `/repo:followups`
depend on; those commands link here rather than restating them.

Key words (**MUST**, **MUST NOT**, **SHOULD**, **MAY**) are used as in RFC 2119.

## Why a contract rather than a convention

These are **copy** installers: a fix merged to a tool's `main` does not reach
the repos that installed it. Something has to push those fixes across the
fleet, and that something can only be generic if every tool exposes the same
handful of entry points. Today it is not generic —
`2am/scripts/fleet-resync.sh` can drive **Loom** and nothing else, because C7
is the mechanism it calls and Loom was the only tool that shipped one. Every
other tool's update path was "re-run the installer by hand, per repo."

The metadata half is not cosmetic either. A *tracked* file that holds a
machine-local value is wrong on every machine except the one that wrote it, and
untracking it later is worse than leaving it: git represents "no longer
tracked" as a **deletion**, so the commit that fixes it deletes the working-tree
copy in every other checkout on pull (repo#96). C5 and C6 exist to keep that
value out of tracked history in the first place.

## Definitions

| Term | Meaning |
|---|---|
| **source repo** | The tool's own clone — where `install.sh` and the payload live. |
| **consumer repo** | The repo being installed into (the *target*). |
| **tool root** | The tool's directory inside the consumer repo: `.loom/` for Loom, `.anvil/` for Anvil, `.claude/skills/repo/` for Repo Skills. |
| **copied surface** | Any file the installer writes into the consumer repo from the source payload. |

## The requirements

### C1 — Entry point

The source repo **MUST** expose an executable `install.sh` at its root.

A three-line shim that delegates to `scripts/install-<tool>.sh` satisfies this:
the point is that a caller need not know the tool's internal layout to install
it. A driver that has to special-case each tool's installer path is not a
driver.

> Spot-check: `test -x <source>/install.sh`

### C2 — Target argument

The consumer repo **MUST** be a trailing **positional** argument, defaulting to
`.` when omitted.

Positional (not `--target=`) so that `install.sh <repo>` reads the same for
every tool, and defaulting to `.` so an operator standing in the consumer repo
can just run it.

> Spot-check: `<source>/install.sh --dry-run /tmp/scratch` names paths under
> `/tmp/scratch`, and `cd <consumer> && <source>/install.sh --dry-run` names
> paths under the consumer.

### C3 — Non-interactive mode

The installer **MUST** accept `-y` / `--yes` and complete without reading from
a TTY when given it.

Anything a driver runs headless — CI, a sweep, `fleet-resync.sh` — has no stdin
to answer a prompt with. An installer that blocks on a confirm in that context
does not fail: it hangs.

The installer **MUST NOT** treat `-y` as consent for anything *outside* the
consumer repo. Writes outside the target (a shell rc, a user-scope config)
**MUST** stay behind their own explicit opt-in flag and **MUST** be a strict
no-op under `-y` alone.

> Spot-check: `<source>/install.sh -y /tmp/scratch </dev/null` exits 0.

### C4 — Plan-only mode

The installer **MUST** accept `--dry-run`: print the planned writes, change
nothing anywhere on disk, and exit 0.

"Change nothing" is literal and includes the consumer's `.gitignore`,
`CLAUDE.md`, and `settings.json` — not just the payload. `--dry-run` is what
makes an update reviewable before it happens, and a dry run with side effects
is worse than none, because it is trusted.

The planned-writes list **SHOULD** be derived from the same constants the real
run uses, so the two cannot drift.

> Spot-check: fingerprint the target, run `--dry-run`, fingerprint again, and
> require the two to be identical.

### C5 — Tracked metadata

The installer **MUST** write `<tool-root>/install-metadata.json` containing at
least:

| Field | Type | Meaning |
|---|---|---|
| `version` | string | The source's `VERSION` at install time (see C8). |
| `commit` | string | The source's commit at install time. |
| `layout_version` | number | Bumped when the on-disk layout changes in a way a consumer must notice — a moved destination, a renamed or re-meaning'd field. Additive fields do **not** bump it. |

This file is **committed** to the consumer repo, and **MUST** be byte-identical
on every machine that installs the same version, commit, and options. It
therefore **MUST NOT** contain an absolute path, a hostname, a username, or a
timestamp — those go in the sidecar (C6).

Additional fields are permitted as long as they preserve that property (Repo
Skills also records `dev`, `filtered`, and the selected `commands`).

> Spot-check: `jq -e '.version and .commit and .layout_version' <tool-root>/install-metadata.json`
> and `jq -e 'has("source") or has("installed_at") | not' <tool-root>/install-metadata.json`

### C6 — Machine-local sidecar

The absolute path of the source clone and the install timestamp **MUST** be
written to a **gitignored** sidecar, never to the tracked metadata. The
installer **MUST** ensure the sidecar is gitignored in the consumer repo (and
**SHOULD** stage `git rm --cached` for a sidecar it finds already tracked,
warning that committing that untracking will delete the file in other
checkouts — repo#96).

Consumers resolve the source clone in this order, treating every step's failure
as "source unknown" rather than an error:

1. **Sidecar first** — `<tool-root>/.install-local.json` (`source`,
   `installed_at`). Loom's equivalent is the plain-text
   `.loom/loom-source-path`. A sidecar is gitignored, so it exists only on the
   machine that ran the install; a fresh clone elsewhere legitimately has none.
2. **Legacy inline fallback** — pre-split installs embedded `source` /
   `installed_at` directly in `install-metadata.json`. Read them from there so
   existing installs keep their fast path.
3. **Unknown** — neither yields a usable path. Normal on a fresh clone; not a
   failure.

**The repo#96 signature.** Step 3 collapses two different situations. When
`install-metadata.json` exists (proof an install once ran *here*) but there is
no sidecar **and** no legacy inline fields, that is also exactly what a
previously-*tracked* sidecar leaves behind once it is untracked upstream and
this checkout pulls that commit. Report "source unknown" either way, but append
the distinct suggestion:

```
sidecar missing but install-metadata.json present — if this was previously
installed, re-run <tool>'s installer to regenerate the sidecar.
```

A genuinely fresh clone (no `install-metadata.json` at all) gets no such
suggestion — it was simply never installed here.

> Spot-check: `git -C <consumer> check-ignore -q <tool-root>/.install-local.json`

### C7 — Consumer-side resync

The installer **MUST** ship `<tool-root>/scripts/resync-installed.sh` into the
consumer repo. It refreshes the copied surfaces from the recorded source clone
and:

- **MUST** support `--dry-run` (report drift, write nothing) and `--quiet`
  (warnings, errors, and a one-line summary only);
- **MUST** be idempotent — a second run reports no writes;
- **MUST** report per-file outcomes (created / updated / unchanged / skipped);
- **MUST NOT** clobber a symlinked destination (a `--dev`-style live-edit install);
- **MUST** leave alone any file under the installed surfaces with no source
  counterpart, and **SHOULD** name what it left alone;
- **MUST** fail loudly, changing nothing, when the target has no install or the
  source clone cannot be resolved — never silently create a partial install;
- **MUST NOT** uninstall. Removing installed surfaces is the uninstaller's job
  and stays a separate, explicit action. **A refresh that can delete is not a
  refresh.**
- **SHOULD** restamp the tool's own version token wherever consumer-facing
  prose states it (a `CLAUDE.md`/`AGENTS.md` pointer block, a README badge
  written at install time, etc.), even though that file's *installer-managed
  boilerplate* otherwise belongs to the installer. This is a narrow,
  targeted field edit — not a license to rewrite the surrounding block — and
  it exists because C5/C6 already keep `install-metadata.json`'s version
  field current on every resync; a prose copy of the same number that resync
  does not also restamp silently drifts from it (repo#407). Both tools that
  currently implement C7 take this exception: Loom's
  `.loom/scripts/resync-installed.sh` restamps the `**Loom Version**` header
  in `.loom/CLAUDE.md` (loom#5559), and Repo Skills' restamps the `v<version>`
  token in the REPO-SKILLS marker block via `lib/claude-md-block.sh`
  (repo#407). A tool with no such prose pointer has nothing to restamp here.

Exit status **MUST** be: `0` in sync (or successfully applied), `2` from
`--dry-run` when drift was found, `1` on error. A driver can then branch on one
convention for every tool.

Writes **SHOULD** be atomic (stage beside the destination, `rename(2)` into
place). This is not fastidiousness: the resync script is itself one of the files
it refreshes, and an in-place rewrite of a running script makes `bash` resume
reading at a meaningless offset mid-run.

Reinstalling via `install.sh -y <consumer>` is **not** a substitute. It is a
full installer invocation driven from outside, it touches surfaces a refresh
must not (`CLAUDE.md`'s boilerplate prose beyond the version-token exception
above, `.gitignore`, `settings.json`), and on some tools it refuses to run
non-interactively over an existing install at all.

> Spot-check: `<tool-root>/scripts/resync-installed.sh --dry-run` exits 0 or 2
> and leaves the target's fingerprint unchanged.

### C8 — Honest source version

The source repo **MUST** carry a populated `VERSION` file at its root, and that
file **MUST** be the single source of truth for the tool's version.

No scraping a version out of prose (a heading, a changelog line, a README
badge), and no empty `VERSION` that a reader will mistake for authoritative. An
empty or scraped version is worse than none: the whole point of C5's `version`
field is that a consumer can compare it against the source and decide whether
it is stale.

> Spot-check: `test -s <source>/VERSION`

### C9 — Post-install gitignore sweep

After writing its payload, the installer **MUST** check every file it just
wrote against the consumer repo's `.gitignore` and **warn** — never fail —
about any that are hidden. The warning **MUST** name each ignored path and the
`.gitignore` rule that matches it (`git check-ignore -v`), so the operator can
find and fix the offending rule without guessing. The same sweep **SHOULD**
run again at the end of a C7 resync, since a consumer editing `.gitignore`
after install can introduce the condition without a fresh installer run.

This is a **warning**, not a failure: it MUST NOT abort or roll back an
otherwise-successful install, and it MUST NOT change the installer's exit
status. A consumer repo's pre-existing `.gitignore` can carry a broad,
unrelated rule (a heritage `*.css` glob, a catch-all `*.md`) that happens to
also match paths inside a tool's installed surface. Without this check the
installer succeeds, the files exist on disk, and they are silently
untracked — no error, no signal, nothing in `git status` unless the operator
already knows to look. That already happened in production: six
Anvil-installed CSS assets sat untracked for months in a consumer repo
because of one unrelated legacy `*.css` rule (repo#385), and because Anvil
had neither C4 (`--dry-run`) nor C7 (resync) implemented at the time, nothing
downstream could have caught it either.

The check MUST NOT warn about files the installer itself deliberately
gitignores (the C6 sidecar, for instance) — only about **payload** files a
consumer is expected to be able to track.

> Spot-check: add a `.gitignore` rule in a scratch consumer repo that
> incidentally matches a file inside the installed surface, run the installer,
> and confirm it warns, names the exact path, and names the matching rule —
> while still exiting 0 and leaving every other file installed.

## Conformance

`repo` is the only column below this repo can verify mechanically, and it does:
`commands/repo/tests/test-installer-contract.sh` re-derives every `repo` cell
from the working tree on each `pnpm test` run **and asserts it matches the cell
printed here**, so this column cannot go stale without turning the suite red.
The other three columns are point-in-time observations — each carries the
tool's tracking issue, and each requirement above carries a spot-check command
you can run against that tool's clone to re-derive its row in seconds.

Other tools' columns observed 2026-08-06 (repo#156); `repo` column verified on
every test run.

| # | loom | anvil | repo | squad |
|---|---|---|---|---|
| C1 entry point | ✅ | ❌ `scripts/install-anvil.sh` only | ✅ | ✅ |
| C2 target arg | ✅ | ✅ | ✅ | ✅ |
| C3 `-y` | ✅ | ✅ | ✅ | ✅ |
| C4 `--dry-run` | ❌ | ✅ | ✅ | ❌ |
| C5 tracked metadata | ✅ | ✅ | ✅ | ❌ none |
| C6 gitignored sidecar | ✅ | ❌ inline (legacy) | ✅ | ❌ |
| C7 consumer resync | ✅ | ❌ | ✅ | ❌ |
| C8 honest `VERSION` | ❌ empty | ❌ scraped from prose | ✅ | ❌ empty |
| C9 gitignore sweep | ❌ not yet checked (repo#385) | ❌ not yet checked (repo#385) | ✅ | ❌ not yet checked (repo#385) |

Conformance work is tracked per tool: Loom
[rjwalters/loom#5517](https://github.com/rjwalters/loom/issues/5517), Anvil
[rjwalters/anvil#894](https://github.com/rjwalters/anvil/issues/894), squad
[rjwalters/squad#4](https://github.com/rjwalters/squad/issues/4).

### Adding a tool to the table

1. Run each requirement's spot-check against that tool's clone and a scratch
   consumer repo.
2. Add a column with the result, and a row link to its tracking issue.
3. Do **not** add prose claims that no command can re-derive — a cell that
   cannot be re-checked in seconds is the failure mode this section exists to
   avoid.

## How Repo Skills implements this

| # | Where |
|---|---|
| C1 | [`install.sh`](install.sh) |
| C2 | `install.sh` — trailing positional, `TARGET="."` default |
| C3 | `install.sh -y`; `--shell-wrapper` is the separate opt-in for the one write outside the target |
| C4 | `install.sh --dry-run`, enumerated from the same constants the real run uses |
| C5 | `.claude/skills/repo/install-metadata.json`, emitted by [`lib/metadata.sh`](lib/metadata.sh). The Codex surface added by repo#285 carries a second copy at `.agents/skills/repo/install-metadata.json` from the same emitter, so each install destination is self-describing; both satisfy the "byte-identical on every machine" property, and the resync re-stamps both |
| C6 | `.claude/skills/repo/.install-local.json`, gitignored by `install.sh`, same emitter. Deliberately **not** duplicated for the Codex surface: the sidecar's only job is to point at the source clone, one pointer per install is enough, and a second gitignored-and-possibly-tracked file would double the repo#96 bookkeeping for no added information |
| C7 | [`scripts/repo/resync-installed.sh`](scripts/repo/resync-installed.sh) → installed to `.claude/skills/repo/scripts/` |
| C8 | [`VERSION`](VERSION) |
| C9 | [`lib/gitignore-check.sh`](lib/gitignore-check.sh)'s `warn_gitignored_payload`, called by both `install.sh` (generalizing the older single-path `dest_is_gitignored()` check) and `scripts/repo/resync-installed.sh` |

The C5/C6 split has exactly one emitter (`lib/metadata.sh`) and the rendering
of copied surfaces exactly one implementation (`lib/render.sh`), shared by the
installer and the resync — because two writers of the same on-disk shape
eventually disagree, and the disagreement is invisible until it reaches a
consumer.

Behavioral coverage lives in
[`commands/repo/tests/test-resync-installed.sh`](commands/repo/tests/test-resync-installed.sh)
(C7's properties) and
[`commands/repo/tests/test-installer-contract.sh`](commands/repo/tests/test-installer-contract.sh)
(the C1–C8 spot-checks and the conformance-table cross-check). Both run under
`pnpm test`.

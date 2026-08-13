# `skills/` — canonical workflow sources

This directory holds the **canonical, runtime-neutral source** for every Repo
Skills workflow. `install.sh` copies each `skills/<domain>/SKILL.md` verbatim
into a consumer repo's `.claude/skills/<domain>/SKILL.md` — today that is the
only runtime it packages for. Part of the dual-runtime Claude/Codex packaging
work tracked in [#282](https://github.com/rjwalters/repo/issues/282) needs a
Codex-side install path to package the *same* canonical source for a second
runtime, without forking workflow semantics. This doc is the contract that
work builds against: which parts of a `SKILL.md` are safe to assume are
portable to any runtime, and which parts are specific to how Claude Code
happens to consume this repo today.

Everything below is verified against `origin/main` @ `d2dd71d`, 2026-08-13. Two
sanity checks worth re-running before relying on any claim here, since the
family this repo belongs to is under active packaging work:

```bash
git ls-files '*SKILL.md'          # confirm this is still the only SKILL.md
ls commands/repo/                 # confirm the command roster hasn't shifted
```

## Frontmatter field reference

Every `SKILL.md` and `commands/<domain>/*.md` file in this repo opens with the
same five-key YAML frontmatter block. `skills/repo/SKILL.md`'s block, as of the
commit above, is:

```yaml
name: "Repo Skills"
description: "General repository hygiene and environment tools — audits, cleanup, branch/worktree pruning, link checking, and cloud dev sessions"
domain: repo
type: skill
user-invocable: false
```

Every file under `commands/repo/*.md` carries the same four keys with
`type: command` and `user-invocable: true` instead (verified: all 19 command
files use exactly this five-key shape — `name`, `description`, `domain`,
`type`, `user-invocable` — no file in this repo adds or omits a key).

**Mechanism check first, before classifying anything**: `install.sh` copies
these files **byte-for-byte** — it does not parse, branch on, or template any
frontmatter key (confirmed by inspection: no `install.sh`/`lib/*.sh` grep hit
for `domain`, `type`, or `user-invocable` outside this repo's own self-tests,
`commands/repo/tests/test-scrub-contract.sh` and
`commands/repo/tests/test-resync-installed.sh`, which assert the convention as
documentation, not runtime behavior). So today, the only consumer that reads
any of these fields at all is **Claude Code itself**, at skill/command
discovery time. "Runtime-neutral vs. Claude-specific" below means: would a
second runtime's own discovery mechanism plausibly need or use this field, or
does it exist purely to satisfy a Claude-Code-specific discovery contract?

| Field | Values seen | Classification | Why |
|---|---|---|---|
| `name` | `"Repo Skills"` (skill); the verb, e.g. `"followups"` (commands) | **Runtime-neutral** | A human-readable identifier for the workflow. Any runtime's own catalog/registration format needs *some* label field to show a user or route on; nothing about this key's meaning depends on Claude Code specifically. |
| `description` | One-line summary of what the workflow does and when to use it | **Runtime-neutral** | This is the field Claude Code's own Skill-discovery matches against to decide when to invoke a skill automatically. Any runtime that wants equivalent auto-discovery (routing a natural-language request to the right workflow) needs the same semantic content — the *purpose* this field serves is inherently cross-runtime, not a Claude Code artifact. |
| `domain` | `repo` (only value in this repo; other tool packages, e.g. Loom/Anvil, would use their own) | **Runtime-neutral, but repo-authored convention, not a runtime contract** | This key groups all of one tool package's skill + command files under one namespace tag. Neither Claude Code's nor (so far as verified here) Codex's discovery mechanism reads `domain` — it exists so this repo's own docs and tests can group files programmatically. Safe to carry forward into a Codex adapter unchanged, but don't assume Codex parses it; it is metadata this repo invented, not a key either runtime's spec defines. |
| `type` | `skill` (the one `SKILL.md`) / `command` (every `commands/repo/*.md` file) | **Claude-specific, as currently encoded** | The two values name **Claude Code's own install-target split**: `type: skill` marks a file destined for `.claude/skills/<domain>/SKILL.md` (Claude's automatic, model-triggered Skill-discovery surface); `type: command` marks a file destined for `.claude/commands/<domain>/<verb>.md` (Claude's explicit `/domain:verb` slash-command surface). The *distinction* this key is standing in for — "one canonical, domain-wide workflow description" vs. "a single, explicitly user-invocable verb" — is plausibly a concept a Codex adapter would also need to express. But the two literal values (`skill`, `command`) are Claude Code vocabulary, not a runtime-neutral enum; a Codex adapter should not assume `type: command` means anything to Codex's own registration format without translating it first. |
| `user-invocable` | `false` (the `SKILL.md`) / `true` (every command file) | **Claude-specific, as currently encoded** | Distinguishes Claude Code's two discovery paths: `false` means this file is discovered and triggered automatically by Claude Code's own Skill-matching (nothing types `/repo` to invoke it); `true` means the file registers an explicit `/repo:<verb>` slash command a user types directly. The underlying concept — "invoked automatically by the agent's own routing" vs. "invoked explicitly by the user" — may have a Codex equivalent, but nothing in this repo enforces or reads this key outside one self-test (`test-scrub-contract.sh` asserting `scrub.md` is `user-invocable: true`) and doc convention. Treat the *boolean value* as Claude-Code-specific until a Codex adapter defines its own equivalent, rather than assuming it round-trips. |

**Bottom line for a Codex adapter**: `name` and `description` are safe to
reuse as-is — they carry the actual semantic content a second runtime's
discovery needs. `domain` is safe to carry forward as an inert grouping tag.
`type` and `user-invocable` encode Claude Code's own two discovery surfaces
specifically; a Codex adapter needs its own equivalent concept (if any) rather
than assuming these values mean the same thing to Codex, or mean anything to
Codex's discovery mechanism at all.

## The "canonical source, thin per-runtime alias" pattern

`skills/repo/SKILL.md` and `commands/repo/*.md` are the reference example
[#282](https://github.com/rjwalters/repo/issues/282) asks other repos to
replicate. Read literally, "thin alias" can suggest the command files are
short stub files that merely forward to `SKILL.md`'s body — **that is not
what's in this tree**, and the more precise shape below is what actually
generalizes to a second runtime:

- **`skills/repo/SKILL.md` is the canonical, domain-wide index.** It holds the
  one-line command table (a `[[verb]]` row per command, each just the verb's
  `description`), the shared principles, and cross-cutting documentation that
  applies to every command and would otherwise have to be repeated per file or
  per runtime (the destructive-command guard hook, the handoff-note hook,
  configuration toggles). This content exists exactly once in the whole repo.
- **Each `commands/repo/<verb>.md` holds that one verb's actual procedure** —
  e.g. `commands/repo/followups.md` is 289 lines of concrete steps, not a
  pointer. It is still the "thin" half of the pair, but "thin" describes its
  *reason for existing*, not its length: Claude Code's slash-command discovery
  requires a dedicated file at a fixed path
  (`.claude/commands/<domain>/<verb>.md`) for `/repo:<verb>` to be a
  discoverable, explicitly-invocable command at all. Strip the frontmatter
  Claude Code needs to register that path (`name`, `description`, `domain`,
  `type: command`, `user-invocable: true`) and what's left is the verb's real
  content — nothing in `SKILL.md` repeats it, and nothing in the command file
  repeats `SKILL.md`'s domain-wide material.
- **No workflow semantics are duplicated between the two.** `SKILL.md`'s
  per-command table row and a command file's frontmatter `description` are
  intentionally the same one-line summary (compare `SKILL.md`'s `[[followups]]`
  row against `commands/repo/followups.md`'s `description:` key) — that
  redundancy is a single sentence, not a second copy of the procedure. This is
  what #282's acceptance criterion ("install discoverable Claude and Codex
  forms without duplicating the workflow semantics") is protecting: one body
  of procedural content per workflow, however many runtime-registration files
  point at it.

**What a Codex adapter should replicate**: leave `skills/<domain>/SKILL.md`
and `commands/<domain>/*.md` exactly as they are — neither is Claude-specific
in *content* (only parts of their frontmatter are, per the table above) — and
add Codex's own thin registration artifact(s) that point Codex's discovery
mechanism at this same content, in whatever shape Codex's own contract
requires (one file per verb, a single manifest, etc. — that shape is
[#285](https://github.com/rjwalters/repo/issues/285)'s job to determine, not
this doc's). The shape this doc fixes is: **one canonical procedure body per
workflow, N thin runtime-registration wrappers around it — never N full
copies of the workflow.**

## For downstream consumers

Repos consuming this contract as a dependency
([squad#26](https://github.com/rjwalters/squad/issues/26),
[lean-genius#43706](https://github.com/rjwalters/lean-genius/issues/43706),
[loom#4167](https://github.com/rjwalters/loom/issues/4167)) can build a Codex
(or any other runtime's) registration layer against:

1. `name` + `description` as the portable, meaningful content of a workflow's
   frontmatter — reuse them as-is in a new runtime's own catalog format.
2. `domain` as an inert grouping tag, safe to carry forward but not to assume
   any runtime parses.
3. `type` + `user-invocable` as **Claude Code's own vocabulary** for "is this
   the domain-wide canonical index or a single invocable verb" and "is this
   auto-discovered or explicitly user-invoked" — translate the underlying
   distinction into whatever concepts the new runtime actually has, rather
   than copying the literal values.
4. The `SKILL.md` (canonical index) / `commands/<domain>/*.md` (per-verb
   procedure) split itself as the thing to package for a second runtime, not
   to reimplement — see the pattern above.

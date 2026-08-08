---
name: "links"
description: "Validate internal cross-references — markdown links, CLAUDE.md paths, skill graph edges"
domain: repo
type: command
user-invocable: true
---

# /repo:links — Link Checker

Validate that internal cross-references across the repo actually resolve.
Catches broken links from reorganization, renames, and deletions.

This is the cross-reference layer of [[docs]]. Use it directly when that's all
you want to check; use [[docs]] for the full documentation sweep.

## Usage

```
/repo:links                    # Full repo — fix unambiguous links, report as you go
/repo:links CLAUDE.md          # Check one file
/repo:links .claude/           # Check skill/command files
/repo:links --ask              # Review findings and confirm before fixing
```

## What It Checks

### 1. Markdown Links
Scan all `.md` files for `[text](path)` links where `path` is a relative file
path (not a URL). Verify the target exists on disk.

**Strip code before scanning.** Remove fenced blocks and inline code spans from
the text first — a `[text](path)` inside backticks is a description of a link,
not a link:

```python
text = re.sub(r'```.*?```', '', text, flags=re.S)   # fenced blocks
text = re.sub(r'`[^`]*`', '', text)                  # inline spans
```

Without this the checker flags the sentences in this very file, and in
[[audit]], that explain what it looks for. A checker that reports its own
documentation as broken is not a checker anyone keeps running.

Skip:
- External URLs (http://, https://)
- Anchor-only links (#section)
- Image URLs from external services

**Resolve against two bases, and only report a link that fails both.** A
relative path can legitimately be written against either the file's own
directory or the repo root, and both conventions are in active use:

1. the directory of the file containing the link
2. the repo root

Report the link only when the target is missing under **both**. State which
base resolved it when the answer is not the file's own directory, so a reader
can tell a convention from a coincidence. Silently assuming the file's own
directory is what produced 28 wrong findings in a single run against
`.loom/CLAUDE.md`, whose links are root-relative and all correct.

### 2. CLAUDE.md File References
CLAUDE.md files typically list key file paths (reference tables, "see X"
pointers). Verify every path mentioned resolves. This is **critical**
severity — these are the primary navigation paths for agents.

Critical severity is exactly why the two-base rule above matters most here. **A
CLAUDE.md is loaded into an agent's context and its paths are read from the repo
root**, not from wherever the file happens to sit, so root-relative is the
correct convention in one — not a defect. Resolving a CLAUDE.md link only
against its own directory turns the highest-severity class in this checker into
the one most likely to be wrong.

### 3. Skill/Command Cross-References
If the repo has `.claude/skills/` and `.claude/commands/`:
- Every `[[wikilink]]` in a SKILL.md has a corresponding command `.md` file
  in the same domain
- If a `.claude/skill-graph.json` exists: every node references a file that
  exists, and every edge connects two valid nodes

### 4. Nested CLAUDE.md References
Subdirectory CLAUDE.md files often list key files relative to their own
directory. Verify those paths resolve — against that directory **and** the repo
root, per the two-base rule. Both conventions appear in nested files, and which
one a given file uses is not knowable from its location.

### 5. Vendored and installer-managed files
A file under a tool's dot-directory (`.loom/CLAUDE.md`, `.anvil/CLAUDE.md`, and
anything else written by an installer) is **reported but never edited in
place**, even when the fix is unambiguous and `--ask` is not in play. The next
install overwrites the edit, so a fix there is silently temporary and the
finding returns.

Report these in their own group, name the upstream repo that owns the file, and
say the fix belongs there. Same reasoning as [[scrub]]'s handling of findings
inside vendored trees.

## Interaction

Group findings by source file:

```
## CLAUDE.md — 2 broken links

| Line | Target | Status |
|------|--------|--------|
| 42 | docs/setup.md | MISSING (removed?) |
| 87 | legacy/MIGRATION.md | MISSING (renamed?) |

## packages/core/CLAUDE.md — 1 broken link
...
```

For each broken link, find the most likely correct target (fuzzy match on
filename). When there's a single confident match, fix the link and report it;
when the match is ambiguous or no target exists, report it for a human call.
Under `--ask`, propose every fix and confirm before editing.

### Precision is itself a finding

When a run produces many findings and few actionable ones, **say so on its own
line** rather than printing the list and moving on:

```
30 findings, 0 actionable — 2 were code spans, 28 resolve from the repo root.
Check the resolution rules before acting on this report.
```

A high false-positive rate is a defect in the checker, not a property of the
repo, and it is the more useful signal of the two. The cost of a noisy run is
not the wasted minute — it is that a check returning 100% noise on a healthy
repo teaches people to skim past its output, which is expensive the first time
it is right.

### Verify after write

Fixing a link is not proof the fix survived. A concurrent writer — another
agent working in the same clone, a background `git stash` or `git checkout --`,
a pre-commit hook, a Loom sweep quarantining the primary clone's working tree —
can revert a file between the moment you fix it and the moment you report it,
leaving this command claiming a fix that is no longer on disk.

So immediately after applying each fix, and **before counting it as applied**,
re-read the changed region of the file and confirm your specific edit is
present. `git diff -- <path>` / `git status --porcelain -- <path>` is a cheap
first pass, but only proves the path differs from HEAD — it cannot distinguish
your edit from someone else's, so it must not be the sole check when the file
may carry other uncommitted changes.

This check is **unconditional** — run it whether or not you have any reason to
suspect a concurrent writer. Detecting a daemon first would be racy (one can
start right after the check), and in a repo with no concurrent writer the check
always finds the edit still applied, so nothing about the reported output
changes.

If a fix is gone on re-check, report it on its own line as **reverted after
apply — needs re-run**. Do not silently re-apply it, and do not count it in the
fixed total — that total must only ever include edits confirmed still on disk.

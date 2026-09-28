---
name: "handoff"
description: "Roll the Claude session safely — file follow-ups, reset to baseline, check for a CLI update, and write a handoff note the next session reads first"
domain: repo
type: command
user-invocable: true
---

# /repo:handoff — Roll the Session Safely

Rolling a Claude Code session — quitting the CLI and starting fresh — is the
moment a session's most valuable output is most likely to be lost, because what
is worth carrying forward is exactly what exists *only* in the session's
context: in-flight state, settled decisions, and empirically-discovered traps.
This command makes the roll a repeatable ritual instead of an ad-hoc scramble.

It **composes** the existing commands rather than reimplementing them —
[[followups]] to capture deferred work, [[reset]] to reach a clean git baseline
— and adds only what does not exist yet: the CLI version check, the handoff
note, and exact restart instructions.

**Relationship to `/compact`:** compaction handles the *soft* boundary —
context pressure within a continuous session. `/repo:handoff` handles the
*hard* boundary: process restart, CLI upgrade, or a deliberate fresh start. If
the version check below finds no update and the only pressure is context size,
say so — a `/compact` may be all that's needed.

## Usage

```
/repo:handoff                  # Run the ritual end-to-end, confirmations as usual
/repo:handoff --dry-run        # Preview the note and proposed actions; file, prune, and write nothing
/repo:handoff --prune          # Pass --prune through to the reset stage
/repo:handoff --force          # Proceed even when the step-0 preflight fails
```

## Steps — ordering is load-bearing

Run the stages in exactly this order. Each later stage depends on the earlier
ones having actually happened.

### 0. Preflight — confirm something will actually read the note

Run this **before** followups and reset, and stop on failure. Everything below
produces a note; this step establishes that the note has a reader. A handoff
nobody reads is worse than no handoff, and the failure is silent at the worst
possible moment — the operator quits the CLI on this command's own
instructions and never learns the note was orphaned.

The reader is the `session-start-handoff.sh` **SessionStart hook**, and it has
two halves that `install.sh` writes to paths with *different git
dispositions*. Check both — neither substitutes for the other:

```bash
# Half 1 — the script exists and is executable.
test -x .claude/skills/repo/hooks/session-start-handoff.sh

# Half 2 — it is wired for BOTH sources Claude Code will fire.
jq -e --arg c '${CLAUDE_PROJECT_DIR}/.claude/skills/repo/hooks/session-start-handoff.sh' '
      (.hooks.SessionStart // []) as $ss |
      (["startup","resume"] | all(. as $m | $ss | any(.[]?;
        (.matcher == $m) and ((.hooks // []) | any(.[]?; .command == $c)))))
    ' .claude/settings.json
```

Those are deliberately the same predicates `install.sh`'s
`merge_settings_sessionstart_hook` uses for its idempotency test, so the
writer and the installer cannot drift in what "wired" means. A **partial**
wiring — one matcher but not the other — is a failure here, exactly as the
installer treats it as incomplete and finishes it.

**Half 1 is the load-bearing check, and inspecting `settings.json` cannot
replace it.** Consumers commonly track `.claude/settings.json` while
gitignoring `.claude/skills/`, so the wiring propagates through `git pull` to
every clone and the script it points at travels with none of them. That repo
looks correctly configured to anyone who reads its settings by eye, and
Claude Code invokes a missing command on every launch. A fresh clone of such
a consumer starts in that state before it has drifted at all (observed in
`rjwalters/loom`: wiring from 0.14.x, installed script from 0.6.1, which
predates the hook entirely).

While `.gitignore` is already open, check the third thing the note depends on:

```bash
git check-ignore -q .claude/handoff.md   # the note must never be committable
```

Step 4 has always been responsible for ensuring this, but discovering it there
means discovering it *after* followups has filed and reset has pruned. Finding
it here costs nothing.

**On failure, stop and report which half is missing** — the two have different
repairs, and saying "the hook is broken" sends the operator to the wrong one:

| Failing check | Repair |
|---|---|
| Script absent or not executable | `./install.sh <repo>` — re-copies it |
| Wiring absent or partial | `./install.sh <repo>` — merges it, idempotent |
| Script present but stale vs. source | `/repo:update-tools` |
| `.claude/handoff.md` not gitignored | Add the entry (step 4 would have) |

Offer to run the repair, then re-run the preflight. `--force` proceeds anyway
and must say plainly, in the step-5 restart block, that the note will **not**
be announced on restart and has to be read by hand.

Two advisory notes that never block:

- If `REPO_HANDOFF_SIBLING_ROOT` is unset, say so once. It is the opt-in
  fallback that reports a pending note in a *sibling* checkout (path and age
  only), and it is the only thing standing between "no note in this repo" and
  "no note anywhere" — a distinction that has already cost a real handoff.
- Under `--dry-run`, run the preflight for real and report the verdict. It is
  read-only, and knowing the reader is missing is the single most useful thing
  a dry run can tell you.

### 1. File follow-ups first (see [[followups]])

Run the full [[followups]] flow — mine the session, propose, confirm, file.
This must precede reset because [[reset]] prunes branches, worktrees, and
stashes that a follow-up may need to reference, and filing wants the git state
reset is about to remove. Record the issue URLs actually filed (and anything
proposed-but-declined) — the note needs them.

Under `--dry-run`, run followups in its own `--dry-run` mode: propose, file
nothing.

### 2. Reset to baseline (see [[reset]])

Run the full [[reset]] ritual: working-tree safety check, stash review, branch
& worktree review, remote sync, land on the default branch. Pass `--prune`
through if given. All of reset's gates apply unchanged — nothing irreversible
happens without explicit approval, and a dirty working tree stops the ritual
until the user decides (commit / stash / abort). Record what reset actually
did and what it intentionally left behind.

Under `--dry-run`, report what reset *would* do without acting.

### 3. Check the CLI version — before recommending a restart

Best-effort, never blocking:

```bash
claude --version                 # what this session is running
npm view @anthropic-ai/claude-code version 2>/dev/null   # latest, if npm is available
```

Report one of: **update available** (restart is worth it — note both versions),
**current** (a restart gains nothing; if the motive was context pressure,
suggest `/compact` instead), or **unknown** (say so plainly — do not guess).

### 4. Write the handoff note last

Written last because it must record what followups actually filed and what
reset actually did — any earlier and it is speculative.

**Where it lives (both halves required):**

1. `.claude/handoff.md` in this repo — repo-scoped and discoverable. Ensure
   it is gitignored (step 0 already checked this; add a `.claude/handoff.md`
   entry if not already covered) — the note is session state, never a commit.
2. A pointer in the agent's auto-memory index (`MEMORY.md` in the memory
   directory, when one exists): a single line —
   `- Handoff note at .claude/handoff.md — READ FIRST, then delete note + this line.`
   The memory index is read automatically at session start, but it arrives as
   passive background context, not an instruction — so the pointer is a
   *best-effort backup*, not a guarantee the note is read (a live handoff has
   been observed to slip past it). The mechanism that actively announces the
   note is the `session-start-handoff.sh` **SessionStart hook** — whose
   presence and wiring step 0 has already verified rather than assumed —
   which surfaces the note as session context on startup and resume — the full body inlined when the note is small, a header outline plus
   an oversize warning when it is large.

**Both halves are repo-scoped, and that is the point** — a note belongs to the
repo it was written in, and is invisible from any other one. The cost is that
"no note in this repo" and "no note anywhere" look identical at session start,
which has already lost a real handoff (a note in a sibling checkout, found only
after minutes of searching). The optional remedy is an environment variable read
by the same hook:

```bash
export REPO_HANDOFF_SIBLING_ROOT="$HOME/GitHub"   # where your checkouts live
```

Unset (the default) nothing changes. Set, and **only when the current repo has
no note of its own**, the hook additionally lists which repos directly under
that root do have one — **path and age only, never the body**, because a note is
one-shot for the repo it belongs to. Absorb it by starting a session there; the
scan is read-only, single-level, and capped at 64 directories.

**What goes in — only what is not recoverable from the repo:**

- **In-flight state** — open PRs and what they await, running background work,
  anything mid-flight.
- **Decisions and their rationale** — settled questions the next session must
  not relitigate.
- **Empirically-discovered traps** — "this command hangs", "this flag silently
  no-ops": findings that cost real time and are invisible in the code.
- **The precise next action** — one concrete step, not a roadmap.

Deliberately **exclude** anything readable from git history, the issue
tracker, or `CLAUDE.md` — the exclusion discipline is what keeps the note
short enough to be read.

**Honesty constraint:** every item carries a verification status —
`[verified]` (done and checked), `[believed-done]` (done, not re-checked), or
`[attempted]` (tried, outcome uncertain). A handoff that overstates completion
is worse than none, because the next session builds on it.

**One-shot contract:** the note describes a single moment. The next session
reads it, absorbs it, then deletes both the note and the memory pointer —
promoting anything durable into real memory files or issues. A stale handoff
lying around is a trap of its own.

Under `--dry-run`, print the note to the conversation instead of writing it.

### 5. Emit the restart block — and stop

The agent cannot quit, upgrade, or relaunch its own process. Do not pretend
to. End by printing an exact, copy-pasteable block for the human, e.g.:

```
# In this terminal:
#   1. Quit this session (Ctrl+C or /exit)
#   2. If an update was available:
claude update
#   3. Relaunch in this repo:
cd <repo-root> && claude
# The SessionStart hook announces the handoff note to the new session
# (the memory-index pointer is a best-effort backup).
```

Under `--force` past a failed step-0 preflight, replace those last two
comment lines with the truth — the note will not be announced, and the
operator has to open it by hand:

```
# NO SessionStart hook is wired in this repo: the note will NOT be announced.
# After relaunching, read it yourself:  cat .claude/handoff.md
```

Then stop. The ritual is complete when the note is durable and the
instructions are on screen — the restart itself belongs to the human.

## Principles

Same as every hygiene command: **apply safe fixes, gate destructive ones** —
this command adds no gates of its own but inherits every gate of the commands
it composes ([[followups]] always confirms before filing; [[reset]] never
destroys without opt-in). **Don't be noisy**: the note's value comes from what
it excludes.

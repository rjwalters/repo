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

The reader is a `session-start-handoff.sh` **SessionStart hook**, and it has
two halves that `install.sh` writes to paths with *different git
dispositions*. Check both — neither substitutes for the other.

**Half 1 — a hook script exists and is executable.** Normally the installed
copy:

```bash
test -x .claude/skills/repo/hooks/session-start-handoff.sh
```

**Half 2 — a hook is wired for BOTH sources Claude Code will fire.** Mirror
`install.sh`'s `merge_settings_sessionstart_hook`, which has **two**
predicates, not one. Check them in the same order the installer does:

```bash
HOOK='${CLAUDE_PROJECT_DIR}/.claude/skills/repo/hooks/session-start-handoff.sh'

# 2a. Our exact command, under every matcher we manage — install.sh's
#     idempotency test (its "already wired, no change" branch), verbatim.
jq -e --arg c "$HOOK" '
      (.hooks.SessionStart // []) as $ss |
      (["startup","resume"] | all(. as $m | $ss | any(.[]?;
        (.matcher == $m) and ((.hooks // []) | any(.[]?; .command == $c)))))
    ' .claude/settings.json

# 2b. If 2a fails: a DIFFERENT session-start-handoff.sh may already be wired
#     (a copy at another path). install.sh DEFERS to it rather than adding a
#     duplicate, so this is a satisfied reader, not a missing one.
jq -e --arg c "$HOOK" '
      (.hooks.SessionStart // []) | any(.[]?;
        (.hooks // []) | any(.[]?;
          ((.command // "") | test("session-start-handoff\\.sh")) and (.command != $c)))
    ' .claude/settings.json
```

**2b is not optional, and omitting it produces a false block.** When a
foreign-pathed hook is wired, `install.sh` returns early and will *never*
wire the command 2a tests for — so a preflight that checks only 2a fails,
sends the operator to `install.sh`, and `install.sh` defers again. The
operator loops, while a reader was present the whole time. That branch has
existed since the hook's first commit (#34); it is a supported terminal
state, not a leftover. On 2b, report the foreign path as **information** and
continue — and point half 1 at *that* script rather than the installed path,
since it is the one that will run. If *that* script is missing or not
executable, `./install.sh` is the wrong repair: it only ever copies to
`.claude/skills/repo/hooks/`, and 2b makes it defer on the wiring, so a
re-install leaves the dangling entry exactly as it was. Fix or delete the
foreign entry in `.claude/settings.json` by hand first — then `install.sh`
can wire ours.

A **partial** wiring — one matcher but not the other, with no foreign hook —
is a failure, exactly as the installer treats it as incomplete and finishes it.

Both predicates are `jq -e`, so an **absent** `.claude/settings.json` and a
malformed `.claude/settings.json` both fail them exactly the way a
valid-but-unwired one does. Three states, and they do **not** share a repair.
Separate them before reaching for the table below, in the order the installer
resolves them:

```bash
test -f .claude/settings.json              # absent, or present?
jq -e . .claude/settings.json >/dev/null   # malformed, or genuinely unwired?
```

**Absent is fully repaired by `install.sh`** — do not send it to a by-hand
fix. `merge_settings_sessionstart_hook` creates an empty `{}` settings file
*before* its invalid-JSON guard runs, so a missing file is created, both
matchers are wired, and the script is copied, all in one re-install. This
state is reachable, not theoretical: a repo that tracks `.claude/commands/`
through a `!` negation while gitignoring the rest of `.claude/` has the
`/repo:handoff` command and no settings file at all on every fresh clone or
`git clean -xdf`.

**Malformed is not repairable by `install.sh`.** That same guard refuses to
touch invalid JSON and returns having wired nothing, so a re-install changes
nothing and reports the same warning each time.

`test-handoff-preflight.sh` extracts the jq programs from this file and from
`install.sh` and asserts they are equal after normalization, so the two cannot
drift silently. Keep them copy-paste identical; if the installer's predicates
change, that test fails and this block must follow.

**Half 1 is load-bearing, and inspecting `settings.json` cannot replace it.**
Where a consumer tracks `.claude/settings.json` while gitignoring
`.claude/skills/`, the wiring propagates through `git pull` to every clone and
the script it points at travels with none of them. That repo looks correctly
configured to anyone who reads its settings by eye, and Claude Code invokes a
missing command on every launch. A fresh clone of such a consumer starts in
that state before it has drifted at all. `rjwalters/loom` has exactly this
shape — `.claude/settings.json` tracked, `.claude/skills` in `.gitignore` — so
its wiring reaches every clone and the script it names reaches none of them.
How common the split is across consumers is not established; it needs to occur
only once to lose a handoff.

While `.gitignore` is already open, check the third thing the note depends on:

```bash
git check-ignore -q .claude/handoff.md   # the note must never be committable
```

This one **auto-fixes** rather than blocks: adding a `.claude/handoff.md`
entry is the archetypal safe fix, step 4 would have done it anyway, and doing
it here just moves it off the critical path. Say that it was added. Under
`--dry-run`, report that it is missing and add nothing — the flag's contract
is that the run writes nothing at all.

**On a blocking failure, stop and report which half failed** — they have
different repairs, and one merged "the hook is broken" sends the operator to
the wrong one:

| Failing check | Repair |
|---|---|
| No script at the installed path, or not executable | `install.sh` re-copies it |
| 2b matched, but the *foreign* script is missing or not executable | By hand (above) |
| No `.claude/settings.json` at all | `install.sh` creates and wires one |
| No wiring at all (2a and 2b both fail) | `install.sh` merges it |
| Partial wiring, no foreign hook | `install.sh` completes it |
| `.claude/settings.json` is not valid JSON | By hand — `install.sh` wires nothing |

`install.sh` in that table means re-running the Repo Skills installer against
this repo — `./install.sh <repo>` from a Repo Skills checkout.

It has one further terminal state no check above can see in advance: if its
rewrite `jq` fails (a full disk, a `mktemp` failure), it warns `Failed to
update .claude/settings.json — left unchanged` and wires nothing. So an
`install.sh` row that leaves this preflight *still* failing, with that warning
in the installer's output, is not the wrong row — it is that state. It is
self-diagnosing but not self-repairing: clear the underlying cause and re-run,
or wire the two matchers by hand. Re-running the preflight after every repair
is what surfaces it.

Offer to run the repair, then re-run the preflight. `--force` proceeds anyway
and must say plainly, in the step-5 restart block, that the note will **not**
be announced on restart and has to be read by hand.

Three advisory notes that never block:

- If `REPO_HANDOFF_SIBLING_ROOT` is unset, say so once. It is the opt-in
  fallback that reports a pending note in a *sibling* checkout (path and age
  only), and it is the only thing standing between "no note in this repo" and
  "no note anywhere" — a distinction that has already cost a real handoff.
- Step 0 **does not check** whether the installed script is *stale* relative
  to the Repo Skills source. `test -x` cannot see staleness, and the source
  checkout is not reachable from every consumer, so there is no probe here to
  fail — this is why staleness is not a row in the table above. A wired,
  executable hook that predates a fix in
  `hooks/repo/session-start-handoff.sh` still runs and still announces the
  note, so mention `/repo:update-tools` as a follow-up if the version matters
  and move on.
- Under `--dry-run`, run every check for real and report the verdict, but
  apply no repair — not even the gitignore one. The checks are read-only, and
  knowing the reader is missing is the single most useful thing a dry run can
  tell you.

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
   which surfaces the note as session context on startup and resume — the
   full body inlined when the note is small, a header outline plus an
   oversize warning when it is large.

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

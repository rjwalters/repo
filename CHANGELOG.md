# Changelog

## Unreleased

- **`--shell-wrapper` now also installs `codex` and `codex-safe` shell functions alongside the `claude` wrapper (#80).** `codex()` is the interactive-operator default: it injects `--dangerously-bypass-approvals-and-sandbox` so a human driving a full session isn't stopped by repeated approval prompts, but only for a session-starting invocation and only when the caller hasn't already chosen a posture — an argv scan recognizes `--sandbox`/`-s`, `--ask-for-approval`/`-a`, and the bypass flag itself in both `--flag value` and `--flag=value` forms and, if any is present, respects it untouched (the scan errs safe: an ambiguous match declines the dangerous default rather than risk overriding a safer explicit choice). Non-session utility subcommands (`codex doctor`/`update`/`mcp …`) pass straight through, mirroring `claude()`'s `_repo_claude_is_session` precedent. `codex-safe()` forwards argv byte-for-byte with no injection, for read-only/review work. The Codex block is a **second, independent** marker-bounded block (`# BEGIN/END REPO-SKILLS CODEX WRAPPER`) implemented in parallel to the already-shipped Claude wrapper rather than by generalizing it — the shared, security-adjacent install engine's Claude call sites are provably untouched — and it is installed, previewed, backed up, and uninstalled together under the same single `--shell-wrapper` opt-in. README documents the security boundary: the dangerous `codex` default is an explicit interactive-operator opt-in for a human at a keyboard, **not** the unattended/daemon worker sandbox policy. New fixture coverage in `hooks/repo/tests/test-shell-wrapper.sh` exercises the posture-flag dedup matrix (`--sandbox=workspace-write`, `--sandbox workspace-write`, `-s workspace-write`, `--ask-for-approval never`, and combinations), non-session passthrough, `codex-safe` byte-for-byte forwarding, install idempotency, and uninstall of only Repo-owned markers.
- **`/repo:release` gains a `## version-source` declaration so repos can release versions kept in arbitrary source constants (#81).** No Phase 2 heuristic can discover a version stored in a language-specific source constant — a Swift `AppVersion.current` assignment, a `CFBundle*` string in a build script, a module-level `__version__` — so such a repo detected `<none>`, fell to the `[m]` manual path every release, and rediscovered the source from scratch each time (the reported field case kept its version in a Swift constant plus two CFBundle strings while a Loom workspace-scaffold `package.json` sat at the root). `.repo/release-policy.md` now carries an optional `## version-source` section — **data, not a `## seam:` hook** — with two backtick-fenced shell one-liners: `read:` (prints the current version) and `bump:` (rewrites it in place, new version arriving as `$1`). Phase 0 parses and validates the block, warning on an **asymmetric** declaration (only `read:` or only `bump:`) exactly as it warns on an unknown seam. Phase 2 selects `VERSION_TOOL="declared-policy"` when both lines are present, which **outranks every heuristic** (even `scripts/version.sh`, though that pairing warns as a likely stale leftover) since a repo-authored declaration is ground truth, not a guess. Phase 3 reads the current version via `sh -c "$VS_READ"`; Phase 5's apply dispatch adds a `declared-policy)` case that runs the declared bump via `sh -c "$VS_BUMP" _ "$NEW"` and joins the same stage-with-`CHANGELOG.md` / commit / tag path as the other non-self-committing tools (the declaration owns only the in-file edit, never the git plumbing). The multi-source drift gate is a documented no-op for a single declared source. Finally the `[m]` manual path now **records** the source: after the operator supplies the version by hand, `/repo:release` offers to write the `## version-source` block so the next release detects it automatically — closing the rediscovery loop. Documented in the extension-points section as a declaration distinct from a seam, preserving the single-`.repo/release-policy.md` design. Complements #83's npm tightening, which already resolved this issue's original scaffold-`package.json`-misdirects-npm symptom from the other direction.
- **`/repo:release` detects PEP 621 `pyproject.toml` `[project].version` ahead of the npm fallback, and no longer matches `npm` on a version-less `package.json` (#83).** Phase 2's detection chain had no branch for the modern uv/hatchling/flit/setuptools standard — only `[tool.poetry]` — so a Python repo whose version lives in `[project]` fell through to `npm` on the mere *presence* of `package.json`. In the reported field case that `package.json` was a Loom workspace scaffold (`"private": true`, **no** `version` field), so a blind `npm version` would have invented a `0.0.1` in the wrong file while the real version went stale. Two fixes: a new `pyproject` branch ordered between `poetry` and `npm` (poetry still wins when both markers are present, since modern poetry files also carry a `[project]` table and `poetry version` remains the right apply path), and the `npm` condition now additionally requires `grep -q '"version"' package.json` so a version-less scaffold falls through the chain instead of misdirecting the bump. The PEP 621 check scopes its `version =` grep to the lines *inside* `[project]` via an `awk` block-extractor, so a `version =` in an unrelated table like `[tool.poetry.dependencies]` can't false-positive it. Phase 3 gains a `pyproject` "read the current version" example and Phase 5 a `pyproject)` apply branch that rewrites only the `[project]` version line, **fails loudly** when no such key exists (rather than no-op-bumping and tagging anyway), and regenerates `uv.lock` when the repo has one so `uv sync --locked` CI doesn't go stale. Related to #81, which reports the same npm-misdirection symptom from the disjoint direction of versions kept in arbitrary source constants; the shared `npm` tightening lands here.
- **`guard-destructive.sh`'s shared segmentation lexer is now heredoc-aware, so heredoc body lines stop being read as commands (#84).** `ml_segment()` (`_ML_QSPLIT_AWK`, shared by `parse_force_ops()`, `lifecycle_or_cloud_reason()` and `extract_rm_targets()` since #71/#76) tracked quote state but had no concept of heredoc syntax, so it fell through to its "a raw newline splits" rule and turned every heredoc **body** line into a phantom top-level segment whose first word was read as a command word. `gh issue create --body "$(cat <<'EOF' … EOF)"` with a body line beginning `shutdown`/`halt`/`reboot`/`poweroff` was therefore hard-denied as a system-lifecycle command — the false positive that blocked filing this very bug report, and that forced an agent to reword the engineering term "shutdown current" in a spec issue. The lexer now recognizes heredoc openers (`<<WORD`, `<<-WORD` with tab-stripped terminators, `<<'WORD'`/`<<"WORD"`/`<<\WORD`, several openers on one line, and unterminated heredocs), keeps segmenting the **rest** of the opener line normally (so `cat <<EOF | grep x` still splits at the pipe), and skips the body through its terminator so it contributes no segment at all. Safety floor unchanged and newly covered by tests: the raw `ALWAYS_BLOCK_PATTERNS` catastrophic scan never runs through `ml_segment()` (a `$(…)`/backtick-smuggled payload in a body still denies), a real command after the terminator or after a pipe on the opener line is still a real segment, a **bare** (expansion-capable) delimiter whose body carries a command substitution reverts to the legacy separator-active treatment, `<<<` is treated as a here-string rather than an opener, and `<<` inside an arithmetic expansion stays a left shift. Two further non-operator carve-outs keep the change from ever widening a deny into an allow: a `<<` inside a shell **comment** (`echo hi # <<EOF`) does not open a heredoc, so the unterminated-heredoc rule can no longer swallow a real command on the next line (only the opener *probe* is suppressed — the characters still segment normally, so a trailing `; <cmd>` after a `#` inside a command-substitution-bearing quoted span is still seen); and a newline preceded by an **odd** number of backslashes is a line continuation, so the logical opener line has not ended and the bodies start only at the first non-continued newline (`cat <<EOF \` + `&& <cmd>` really does run `<cmd>`). 35 new cases in `hooks/repo/tests/test-guard-destructive.sh`.
- **`/repo:followups` now reaches the forge over REST instead of GraphQL-backed `gh` subcommands (#87).** Step 3's dedup swaps `gh issue list --search` for `gh api "search/issues?q=repo:<slug>+state:open+<terms>"` (whose result items already carry `number`/`title`/`html_url`), and step 5's filing swaps `gh issue create --body "$(cat <<'EOF' …)"` for a file-written body fed through `jq --rawfile` into `gh api --method POST repos/<slug>/issues --input payload.json`; the near-match comment path moves to `POST …/issues/<n>/comments` for the same reason. `gh issue list`/`create` go through GraphQL, whose rate-limit bucket is exhausted on exactly the busy multi-agent repos this command targets — observed filing failures with `core` at 19/5000 and `graphql` already over. The `--input` payload also keeps issue bodies out of the shell's parser entirely, so a body line containing `>=` or backticks can no longer trip content-matching guards, and its `labels` array preserves atomic label-on-create. New safety rule 5 records the constraint.
- **Commands that edit tracked files now verify their fixes are still on disk before reporting them applied (#89).** `/repo:docs`, `/repo:readme`, `/repo:gitignore`, and `/repo:links` each gained an unconditional verify-after-write step: re-read the change immediately after applying it, and report anything gone as "reverted after apply — needs re-run" on its own line rather than folding it into the fixed count. `/repo:all` re-verifies each stage's edits immediately before the consolidated summary prints. This closes a silent-loss window observed in a Loom-managed repo, where a concurrent sweep quarantined the working tree and three reported doc fixes were no longer on disk. Verification is unconditional rather than gated on daemon detection (which is inherently racy); with no concurrent writer, output is unchanged. Covered by the new `commands/repo/tests/test-verify-fix-persistence.sh` (79 cases, wired into `pnpm test`).
- **`/repo:all` now runs the reversible half of `/repo:reset` before its Docs stage when the working branch is fully pushed and behind the default branch (#82).** Reset-last assumes the working branch is where the later stages should be looking, which only holds when it carries unpushed work; on a fully-pushed PR branch that is behind `main`, the Docs and Tidy stages compared prose against a stale checkout — reporting drift already fixed upstream, and editing a copy that both polluted the open PR's diff and blocked the branch switch Reset performs at the end (observed in a consumer repo: every content fix had to be deferred and re-done after Reset ran). A new stage 2 checks eligibility — on a non-default branch, `origin/HEAD` resolves, working tree clean, branch **has an upstream** and is 0 commits ahead of it, and behind `origin/<default>` by at least one commit — and, only then, runs `git fetch --all --prune` + `checkout <default>` + `pull --ff-only` so Docs/Tidy/Update-tools operate on a fresh checkout. Being ahead of the *default* branch is not disqualifying (a pushed PR branch normally is); "never pushed" (no upstream) is treated as ineligible, not as fully pushed. The **pruning half** (stash review, branch/worktree deletion) still runs last with its existing gates and the [[branches]] permanent-loss check, and the summary's `Reset:` line still carries its output while noting an early switch only once. Ineligible runs — unpushed WIP, a dirty tree, already on the default branch — are byte-for-byte unchanged. Deliberate scope narrowing from the issue's "clean or safely-carryable tree": a dirty tree falls back to the old order rather than stashing to enable the switch, since a run that ends on the default branch has no natural point to pop that stash back. `/repo:reset` standalone is unaffected; it gains only a section naming the sync-and-switch / pruning split. Orthogonal to the verify-after-write machinery from #89 — that protects an applied edit from a concurrent writer, this prevents editing the wrong checkout in the first place. Covered by the new `commands/repo/tests/test-early-sync-switch.sh` (68 cases against real git remotes, wired into `pnpm test`).
- **New command `/repo:deps` — third-party dependency currency (#90).** Verifies Dependabot's config file and the repo-level security-updates flag as *distinct* items (UNKNOWN, not `disabled`, when the token lacks admin), offers to scaffold a config from the ecosystems actually detected with per-ecosystem grouping (Actions grouped including majors; package majors ungrouped, risk-bearing deps excluded from groups), validates candidate labels by *description* (refuses any reserved with `Applied by: humans`, never creates one), and triages open `app/dependabot` PRs with update type, CI status, and — for Actions bumps — which deprecation annotations the bump clears. Documents that Dependabot PRs are inert to Loom automation by default. Deliberately a separate command from `/repo:update-tools`, whose "installed package vs. local source clone" model does not apply.
- **`/repo:tidy` no longer auto-deletes empty tool-scaffolding directories (#88, PR #91).** The empty-directory SAFE rule was an independent classifier that fired before the denylist/ASK fall-through, so an empty `.loom/locks/`, `.loom/worktrees/`, `.loom/sweep-run/`, `.loom/sweep-checkpoint/`, or `.wrangler/tmp/` was swept with no human gate. The rule is now explicitly denylist-gated, tool-scaffolding runtime roots (`.loom/`, `.anvil/`, `.wrangler/`, matched by parent-tool-directory prefix) are named in the never-delete denylist, and a new safety rule 8 records why: for a lock or coordination directory, empty is the normal operating state, not clutter.
- **`/repo:tidy`'s inventory `find` walks now `-prune` heavy trees instead of filtering them with `-not -path` (#85).** `-not -path` only suppresses printing — `find` still descended into `.git/`, `node_modules/`, and every other excluded directory, so on a large working tree (the reported case: ~87 GB with a 24 GB Rust `target/` and ~30 live agent worktrees) the inventory blew past a 120-second timeout and the Tidy stage stalled exactly where it is most useful. Both the empty-directory and >10 MB-file walks now prune `./.git`, `node_modules`, `target`, `dist`, and `.venv` before the print term. Secondary fix: the pruned entries are matched by `-name` rather than `-path`, so *nested* `node_modules/` (e.g. `packages/foo/node_modules/`) are covered — the old `-not -path './node_modules/*'` only ever matched a top-level one. Reporting is otherwise unchanged (junk outside the pruned trees is listed identically, `git clean -ndX` is unaffected), and coordination roots (`.loom/`, `.anvil/`, `.wrangler/`) are deliberately left unpruned so step 2 can still route their empty directories to ASK.
- **`/repo:tidy` now names git worktree roots in the never-delete denylist and reports them (#86, PR #101).** The tool-scaffolding prefixes added in #88 (PR #91) protect `.loom/worktrees/` but reach nothing else, so `.claude/worktrees/`, a sibling `../repo-wt-fix123`, and worktrees under `/private/tmp/` had no worktree-*specific* protection — and worktrees outside the repo root were invisible to the inventory entirely. Step 1 now runs `git worktree list --porcelain` and **retains** the path set (rather than printing it for the `/repo:reset` pointer and discarding it); a new denylist bullet routes any of those paths — or any directory whose `.git` is a **file** matching `gitdir: …/.git/worktrees/…` — to ASK, never SAFE or CACHE, independent of gitignore status or which dot-directory (if any) it lives under. New safety rule 9 records the reasoning. The report gains a distinct `WORKTREES` inventory block listing every root, printed even on an otherwise-clean run, so tidy can no longer report "nothing to do" on a 94 GB tree holding 66 GB of worktrees; where the repo documents its own worktree tooling, the block points at it. Per-root sizes are **opt-in** behind a new `--sizes` flag and bounded by `timeout 20 du -sh` per root (summed separately from the SAFE/CACHE/ASK totals): `du` has no `-prune`, so sizing the roots re-enters the same `node_modules/`/`target/`/`dist/`/`.venv/` trees #85's prune work removed from the inventory walks — on the motivating repo that is ~70% of a whole-tree `du`, in the step that already has a recorded 120-second timeout. The count and paths carry the "where did the space go" signal on their own and are free; the sizes only quantify it, so they follow the same present-don't-perform rule as `--caches`. Worktree paths are extracted with `sed -n 's/^worktree //p'` and read whole, since `awk '{print $2}'` truncates any path containing a space. Still strictly report-only — deciding which worktrees are stale remains `/repo:reset`'s job.
- **`/repo:remote` idle-shutdown guard gains an idle-exit marker contract and daemon-host guidance (#78, PR #79).** `scripts/repo/repo-remote.sh`'s on-host guard now honors `REPO_REMOTE_IDLE_MARKER` — a file whose mtime is an authoritative "idle since" timestamp that replaces the local countdown when present — with an active-SSH/CPU-load veto still winning first, and clock-skew / stale-marker safety. The contract is self-contained (works standalone before any daemon writes the marker) so this repo's half doesn't block on upstream `loom#4467`.
- **`scripts/version.sh` makes `VERSION` the authoritative version source (build tooling).** `/repo:release` detects it ahead of npm, so a vestigial `package.json` can no longer make the release mis-detect `npm` and bump the wrong file; the script mirrors `package.json`'s version to `VERSION` on every bump. `package.json` was aligned to `0.7.0`.
- **Docs: `/repo:release` per-project-seam description synced across README, SKILL.md, and help.md; redundant `.gitignore` carve-out removed** (now covered by the Loom-managed block).

## 0.7.0 (2026-07-29)

New commands and installer features:

- **`/repo:host-optimize` — audit and prepare a Mac (or Linux box) for heavy Loom/agent build use (#50, PR #63).** Reports host-readiness across 8 checks and applies consequence-tiered fixes; SIP/Gatekeeper actions are print-only, sudo setup delegates to `/repo:sudo`.
- **`/repo:sudo` — opt-in passwordless-sudo setup via a validated `sudoers.d` drop-in (#49, PR #67).** `--scoped`/`--status`/`--remove`, always-confirm, and a validate-in-isolation-before-install sequence so a bad drop-in can never lock you out of root.
- **`/repo:release` now supports per-project release policy at named phase boundaries (#43, PR #68).** A repo can inject procedural steps via a single `.repo/release-policy.md` with `## seam: <name>` sections (seven seams; augment by default, `(replace)` to substitute). Phase 0 warns before Phase 1 on any seam that binds to nothing, closing the silent-failure mode for policy migrating off Loom's removed `/loom:release` (all five old seam names carry over).
- **`/repo:release` now folds an existing `## Unreleased` CHANGELOG section into the version entry at draft time (#70, PR #75).** Opt-in on the heading's presence; deduplicates against git-log-derived bullets by issue/PR number.
- **Headless `scripts/repo/repo-remote.sh` provisioning entry point for `/repo:remote` (#52, PR #57).** `up`/`status`/`down` with a cost-consent gate preserved under `--yes` (missing cost-relevant config is a loud `exit 2`, never a silent default); consumed by `loom fleet add-worker`.
- **Optional install-time shell `claude` wrapper that surfaces a pending `/repo:handoff` note to the human (#35, PR #65).** Behind `--shell-wrapper`; strict no-op without it, always diff-then-confirm, backup-before-edit, marker-bounded and idempotent, fail-transparent by construction.
- **SessionStart hook that surfaces a pending `/repo:handoff` note to the next Claude session (#34, PR #34/#47).** Documented, with the matcher rationale corrected.

CI and test coverage:

- **New GitHub Actions workflow runs the full ~530-case suite on every PR and push to `main` (#48, PR #55);** `package.json`'s `check:ci`/`check:all` stubs are repointed at `pnpm test`. A companion decision was recorded (#73, PR #74) to deliberately not require the check on `main` yet, with a note that any future enable must use classic branch protection (not a ruleset) so `merge-pr.sh` detects it.
- **The full guard-destructive and delegated suites now fold into `pnpm test` at real case counts (#40, #44 PR #56),** with a breakdown-sums-to-headline drift self-check; the branches loss-check suite skips merge-tree assertions on git < 2.38 and covers the degraded fallback (#46, PR #64).

`guard-destructive.sh` correctness (the destructive-command guard):

- **Dangerous strings quoted as `echo`/`printf` data no longer false-block (#53, PR #58)** — the guard's own piped self-tests and issue-filing were being blocked by their own payloads.
- **`extract_rm_targets()` is now quote-aware across newlines (#60, PR #69),** and the same whole-command lexer is shared via `ml_segment()` so `parse_force_ops()` and `lifecycle_or_cloud_reason()` stop false-blocking multi-line quoted data (#71, PR #76).
- **Command-word substitutions resolving to `rm` are now caught (#72, PR #77)** — `$(which rm) -rf /`, the backtick form, `env`/`sudo` wrappers, and `~`/`$HOME` targets now deny like their literal counterparts, closing a deny-floor false negative. The safety floor (command-substitution smuggling, `bash -c`/`sh -c`, pipe-to-shell) is unchanged.

Installer and hygiene fixes:

- **CLAUDE.md marker surgery is anchored to the marker string, closing a data-loss bug (#38, PR #42).** `install.sh`/`uninstall.sh` previously bounded the REPO-SKILLS block by whole physical lines, so a shared line with an adjacent tool's marker could delete that neighbour's block. Removal now anchors to the marker substring and a validation guard (`claude_md_block_validate`) gates every rewrite, refusing (and in `install.sh`, exiting non-zero) on an unresolvable layout: BEGIN count ≠ 1, END count ≠ 1, or END before BEGIN. Known limitation — quoting the markers as prose/in a code fence now counts as a duplicate and triggers the refusal (fence-aware detection is intentionally not implemented); a `reconcile_orphaned_block` refusal leaves a partial install (fix the markers to one ordered pair and re-run). Announced in the changelog for consumers (#45, PR #62).
- **`install.sh` gates the CLAUDE.md pointer on the commands/ ignore state alone (#51, PR #61),** so a mixed gitignore state (`skills/` ignored, `commands/` tracked via a `!` negation) no longer wrongly skips the pointer block.
- **The `/repo:handoff` note body is inlined under the size cap in the SessionStart hook (#33, PR #54).**
- **`node_modules` is correctly ignored in issue worktrees (#59, PR #66)** — the directory-only `node_modules/` pattern missed the worktree symlink; dropping the trailing slash matches both.
- **`/repo:branches` permanent-loss check: corrected the `--not` toggle and made it content-aware (#41, PR #41),** so a branch with commits found nowhere else is never auto-pruned.

Tooling:

- Loom updated to v0.16.0; daemon roleRunner + champion-on-idle enabled for this workspace; `pnpm-lock.yaml` is now tracked.

## 0.6.1 (2026-07-27)

- **`install.sh` now reconciles an orphaned CLAUDE.md pointer block (#31).**
  When an earlier install committed the REPO-SKILLS pointer and the destination
  later became gitignored (or dev-symlinked), every subsequent install skipped
  CLAUDE.md entirely — leaving a committed block that claims "Managed by
  `install.sh`" while its version drifts stale forever. Both skip paths now
  detect the orphan, warn that it can no longer be maintained, and offer to
  remove it (default Yes; auto-accepted under `--yes`), reusing
  `uninstall.sh`'s marker-bounded removal so surrounding CLAUDE.md content
  survives intact. `--dry-run` surfaces the condition (`existing REPO-SKILLS
  block is orphaned/stale — would offer removal`) instead of reporting a
  plain skip.

## 0.6.0 (2026-07-27)

- **`guard-destructive.sh` is now the canonical generic destructive-command
  guard (#30).** The full precision lineage developed in rjwalters/loom's copy
  is ported here — quote-aware command segmentation, literal-text redaction of
  `--body`/`-m`/`--title`/`--notes`/`--comment` values, comment stripping, the
  structural read-only fast path, branch-aware force-op scoping
  (`guards.forceScope`), repo-scoped `rm` protection (`guards.rmScope`, default
  `repo`), the un-isolated `git read-tree` ask, verb-narrowed cloud asks,
  opt-in reversible-GitHub asks (`guards.reversibleGh`), and the opt-in JSONL
  decision-telemetry log (`guards.decisionLog`) — along with Loom's ~440-case
  regression suite (`hooks/repo/tests/test-guard-destructive.sh`). Every
  toggle resolves `REPO_*` env → legacy `LOOM_*` env →
  `.claude/skills/repo/config.json` → legacy `.loom/config.json` → default;
  the legacy Loom surfaces (env names, config path, `.loom/worktrees`
  allowlist) are a permanent part of the guard's stable interface, which is
  now documented in the hook header. **Downstream installers (Loom's
  consolidation, rjwalters/loom#4041) should gate on repo-skills ≥ 0.6.0 when
  deciding to skip their own generic guard.**
- **Pipe-to-shell false positives fixed (#29).** The `curl … | sh` block now
  fires only when the piped-to *command* is actually a shell (optionally
  sudo-/path-prefixed `sh`/`bash`/`zsh`/`dash`/`ksh`/`csh`/`tcsh`/`fish`/
  `pwsh`) — piping a download to `sudo tee /usr/share/…`, `shasum`, or any
  path containing `sh` no longer denies, and quoting such a pipeline in an
  issue body no longer blocks the `gh` command carrying it. Multi-stage
  pipelines (`curl … | gunzip | sh`) and `bash -c` payloads still deny.
- **Behavior changes vs the 0.5.0 guard**, inherited from Loom's precision
  work: outside-repo `rm -rf` targets are now denied by default (opt out with
  `guards.rmScope:"off"`); `gh pr close` / `gh issue close` / `gh label
  delete` no longer ask by default (trivially reversible; opt back in with
  `guards.reversibleGh:true`); read-only cloud calls (`aws … describe*`,
  `aws s3 ls`) no longer prompt; `aws ec2 terminate-instances` is a
  toggle-gated ask instead of a hard deny. The Repo Skills refinement gating
  `az`/`gcloud … delete` denies behind `guards.cloudCli` is preserved.

## 0.5.0 (2026-07-27)

- **New command: `/repo:handoff` — roll the Claude session safely (#28).** A
  composed ritual for the hard session boundary (restart, CLI upgrade, fresh
  start): `followups` first (before reset prunes state a follow-up may
  reference), `reset` second, a best-effort CLI version check third, and last a
  handoff note scoped to what only the session knows — in-flight state,
  decisions with rationale, empirically-discovered traps, and the precise next
  action, each tagged `[verified]` / `[believed-done]` / `[attempted]`. The
  note lives at gitignored `.claude/handoff.md` with a READ-FIRST pointer in
  the agent's auto-memory index; both are one-shot and deleted by the next
  session after absorbing. Ends with copy-pasteable restart instructions — it
  never pretends to drive the restart itself. `--dry-run` previews everything
  and writes nothing.

- **`install.sh` fails loudly instead of silently when it can't prompt (#27).**
  Without a TTY and without `--yes`, the confirmation prompts previously died on
  a failed `read` with exit 1 and no output. Both prompts now go through a
  `confirm()` helper: no TTY (or a closed stdin) produces a clear error telling
  you to re-run with `--yes`, and `--yes` skips confirmation as before.

- **`repo:update-tools` lands confirmed updates on the default branch (#26).**
  A confirmed tool bump is now committed per-tool
  (`chore(tooling): update <tool> <old>→<new>`) and fast-forwarded onto the
  default branch instead of being left staged; `--no-commit`/`--stage-only`
  restores the old leave-it-for-review behavior. Never pushes.

## 0.4.3 (2026-07-19)

- **`repo:tidy`: regenerable caches are no longer auto-deleted by default.**
  Compilation/tool/build output (`__pycache__/`, `*.pyc`, `.pytest_cache/`,
  `.mypy_cache/`, `.ruff_cache/`, `dist/`, `.turbo/`, `.astro/`, coverage) moves
  out of the auto-deleted SAFE tier into a new **CACHE** tier that is kept by
  default and cleared only with the new `--caches` flag — deleting a cache is
  safe but forces a costly rebuild, so it is opt-in. The default `tidy` now
  auto-deletes pure junk only (OS/editor droppings, merge/patch leftovers, empty
  dirs). `node_modules/` joins the virtualenv denylist (always ASK, never a
  `--caches` target). `repo:all` keeps caches by default in its Tidy stage and
  forwards `--caches` when the operator passes it.

## 0.4.2 (2026-07-19)

- **Add a destructive-command PreToolUse guard hook (#19).** Installing Repo
  Skills now wires `guard-destructive.sh` into the target repo's
  `.claude/settings.json` (merged in, never wholesale-copied). It runs before
  every agent `Bash` command and **blocks** catastrophic operations (`rm -rf /`
  or `$HOME`, force-push to `main`, fork bombs, `curl … | sh`, `gh repo delete`,
  cloud/stack/IAM destruction, `DROP TABLE`, `DELETE` without `WHERE`) and
  **asks** on reversible-but-risky ones (`git reset --hard`, `kubectl delete`,
  `docker rm`, credential reads); scoped deletes like `rm -rf node_modules` are
  allowed. The SQL and cloud-CLI categories are opt-out per repo
  (`REPO_GUARD_SQL` / `REPO_GUARD_CLOUD`). If the target already has a compatible
  guard wired (e.g. Loom's), the installer defers instead of adding a duplicate;
  `uninstall.sh` removes only the entry it owns.
- **Add `repo:followups` — capture session follow-on work as issues (#20).**
  Files follow-on work discovered during a session as GitHub issues, either here
  or in upstream tool repos, always confirmed first.
- **`repo:remote`: load shared cloud credentials from `~/.config/repo/remote.env`
  (#10).** Provisioning credentials resolve from a shared user-level env file,
  layered under the per-repo `.env`.
- **`repo:remote`: dogfood dev environment (#11).** The cloud session comes up
  with Claude Code, a multi-account token pool, and `gh` label auth ready to use.
- **Fix: keep machine-local install state out of tracked metadata (#17).** The
  install's source path and timestamp move from the tracked
  `install-metadata.json` into a gitignored `.install-local.json` sidecar, so a
  committed install no longer carries another machine's local path.

## 0.4.1 (2026-07-16)

- **Fix `install.sh` (non-dev): skip the tracked `CLAUDE.md` pointer when the
  install destination is gitignored (#4, #5).** Installing into a repo that
  gitignores `.claude/commands` / `.claude/skills` (e.g. a Loom workspace) no
  longer appends a committed `/repo:*` pointer to `CLAUDE.md` that would point
  at uncommitted, machine-local files. The non-dev path now probes each
  destination with `git check-ignore` and, when ignored, prints a notice and
  skips the block — mirroring the existing dev-mode behavior.

## 0.4.0 (2026-07-15)

- Rework `repo:remote` around the target repo's **`.env`** (retiring
  `.claude/remote.json`): namespaced `REPO_REMOTE_*` settings plus standard
  cloud-cred vars. Provisioning credentials drive the cloud CLI locally and are
  never copied to the VM. Adds `--configure` (guided `.env` setup wizard) and
  pinned `REPO_REMOTE_INSTANCE_ID` reuse with write-back on create. The SSH
  session lands in the synced repo (or the dev container), ready to run `claude`.
- **GPU support in `repo:remote` (closes #1).** Hardware is chosen by instance
  type (GPU family inferred); the environment by an optional checked-in
  Dockerfile (`REPO_REMOTE_DOCKERFILE`) run with `--gpus all`. On AWS, GPU hosts
  default to the *Deep Learning Base OSS Nvidia Driver GPU AMI* (driver + Docker
  + `nvidia-container-toolkit`), so `nvidia-smi` and `docker run --gpus all` work
  out of the box; a post-boot `nvidia-smi` sanity check surfaces GPU liveness,
  and a `VcpuLimitExceeded` launch failure prints the exact quota remediation
  (Service Quotas → EC2 → `L-DB2E81BA`).
- Add `repo:docs` — the canonical documentation-health command. Adds a content-
  accuracy layer (prose, feature/command tables, CHANGELOG currency, code
  examples vs the real tree) on top of, and subsuming, `repo:readme` (structure)
  and `repo:links` (cross-references), which remain callable on their own.
  `repo:all` now runs an explicit **Docs** stage (audit → docs → tidy →
  update-tools → reset).
- **Behavior change — apply safe fixes by default.** Fix-capable hygiene
  commands now apply their safe, reversible fixes (doc/link/gitignore edits,
  `tidy`'s regenerable SAFE clutter) automatically and report each change,
  instead of only reporting. Run any of them with `--ask` to restore the
  old review-and-confirm flow. Irreversible removals stay gated behind an
  explicit opt-in (`--prune`); `tidy`'s old `--apply` is now the default (kept
  as an alias).
- Add a **permanent-loss check** before any branch or worktree deletion
  (`repo:branches`, `repo:reset`): a branch with commits found nowhere else, or
  a worktree with uncommitted changes, is never removed automatically —
  regardless of `--prune`.
- `repo:readme` now flags missing READMEs by *browsability* — top-level and
  significant subdirectories within two levels of the repo root get one so
  GitHub renders docs at each level a visitor navigates to — with tiered
  severity to stay quiet on trivial leaf dirs.
- Add `install.sh --dev` — symlinks source command/SKILL files into the target's
  `.claude/` instead of render-copying, so edits are live with no re-install. It
  is the only mode allowed to target the source repo itself (dogfooding), and it
  gitignores the machine-local `.claude/` symlinks while leaving CLAUDE.md
  untouched. The same pattern applies to sibling tool repos (Loom, Anvil).

## 0.3.0 (2026-07-15)

- Add `repo:release` — interactive release flow (pre-flight checks, CHANGELOG
  completeness + version-drift gates, semver decision, CHANGELOG draft, version
  bump, tag, GitHub Release). Discovers the version tool at release time
  (`scripts/version.sh`, cargo, bumpversion, poetry, npm) and adds a plain
  `VERSION`-file tier. Ported and generalized from Loom's release skill, which
  will be retired in favor of this one.
- `install.sh` now renders `{{PLACEHOLDER}}` template variables into installed
  files at copy time (`{{REPO_OWNER}}`, `{{REPO_NAME}}`, `{{REPO_SKILLS_VERSION}}`,
  `{{REPO_SKILLS_COMMIT}}`, `{{INSTALL_DATE}}`), following the Loom pattern, and
  fails fast if a known placeholder survives into an installed file.

## 0.2.0 (2026-07-15)

- Add `repo:all` — umbrella command that runs the full hygiene pass in order
  (audit → tidy → update-tools → reset), each stage report-first. Excludes
  `repo:remote` since it provisions paid infrastructure.

## 0.1.0 (2026-07-14)

Initial release.

- Skills: `repo:help`, `repo:audit`, `repo:reset`, `repo:tidy`, `repo:remote`,
  `repo:update-tools`, `repo:branches`, `repo:gitignore`, `repo:links`,
  `repo:orphans`, `repo:readme`
- `install.sh` / `uninstall.sh` following the Anvil/Loom consumer-repo pattern
  (namespaced `.claude/` copies, marker-bounded CLAUDE.md block, install metadata)
- Hygiene skills ported from an internal monorepo and generalized to work in
  any git repository

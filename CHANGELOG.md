# Changelog

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

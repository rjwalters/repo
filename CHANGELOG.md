# Changelog

## Unreleased

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

# Changelog

## Unreleased

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

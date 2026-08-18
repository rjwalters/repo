<!-- BEGIN LOOM ORCHESTRATION -->
This repository uses [Loom](https://github.com/rjwalters/loom) for AI-powered development orchestration — see the Loom repository for the full guide (roles, labels, worktrees, configuration). When installed, Loom also writes a locally-substituted copy of that guide to `.loom/CLAUDE.md`.
<!-- END LOOM ORCHESTRATION -->

## Contributing: VERSION is the release on `main`

`install.sh` copies `commands/`, `skills/`, `hooks/`, `lib/`, `install.sh`, and
`uninstall.sh` into every consumer repo, and every "am I current?" check a
consumer runs (`install-metadata.json`, `/repo:update-tools`, downstream
compute-drift tooling) compares against `VERSION`. That signal is only honest
if `VERSION` moves whenever this surface does.

**Before opening a PR, ask: does this change touch the installed surface
above?**
- **Yes, and it changes installed behavior** → bump the version:
  `./scripts/version.sh bump patch` (or `minor`/`major` for a larger change).
- **Yes, but it does not change installed behavior** (a comment, a test-only
  edit, a typo fix) → add this exact marker to the PR body or a commit
  message instead of bumping: `<!-- loom:no-surface-change -->`
- **No** (e.g. only `.loom/`, docs, or tests outside the installed surface) →
  nothing to do.

CI enforces this via `scripts/check-installed-surface-version-bump.sh`, run as
the `consumer-visible changes require a VERSION bump` job — a thin local
wrapper around the same contract as the vendored
`.loom/scripts/check-defaults-version-bump.sh` (loom's own `defaults/` gate,
loom#5874), scoped to this repo's actual installed surface since it has no
`defaults/` tree. This check is a visible, non-required status — see the
comment above the `test` job in `.github/workflows/ci.yml` for why (issue
#73) — so a red run is a strong signal to fix, not a hard merge block.
# Work Plan

Prioritized roadmap generated from current GitHub label state, maintained automatically by the Guide triage agent. Regenerated whenever label state changes; do not hand-edit the generated region below.

<!-- guide:plan-body:start -->
## Operator Attention: Merge-Risk-Hold Pileup

Judge-approved PRs stuck under a `loom:operator` merge-risk hold — implementation work is done, only a human merge decision is missing.

- **#560**: feat(install): persisted --no-guard opt-out for destructive guard hook
- **#611**: guard: cwd trackers see a cd behind a leading redirection and cd options (#604)

## Operator Priority

Issues the operator starred (`loom:operator-priority`); land these first.

_None._

## Ready

Human-approved issues ready for implementation (`loom:issue`).

- **#612**: guard: quoted git subcommand/flags and --git-dir/--work-tree hide force ops from parse_force_ops

## In Progress

Issues currently being built (`loom:building`).

- **#608**: guard: git -C with a whitespace path fails open for force ops under forceScope: protected

## PRs Awaiting Review

PRs waiting on Judge (`loom:review-requested`).

_None._

## Approved (Awaiting Merge)

PRs that passed review and are queued for Champion auto-merge (`loom:pr`).

- **#560**: feat(install): persisted --no-guard opt-out for destructive guard hook
- **#611**: guard: cwd trackers see a cd behind a leading redirection and cd options (#604)

## Proposed

Issues carrying `loom:curated`.

- **#557**: install.sh: per-repo opt-out so a reinstall does not re-wire the guard-destructive PreToolUse hook *(curated)*
- **#565**: repo:remote: support short-lived or brokered GitHub credentials instead of a long-lived PAT on the VM *(curated)*
- **#579**: Guard: upstream Loom's vendored-only guard functions so Loom can re-vendor in full and pick up the tmpfs refusal *(curated)*
- **#604**: guard: cwd trackers miss a cd behind a leading redirection (>/dev/null cd X) and cd options (cd -P/-- X) *(curated)*
- **#608**: guard: git -C with a whitespace path fails open for force ops under forceScope: protected *(curated)*
- **#612**: guard: quoted git subcommand/flags and --git-dir/--work-tree hide force ops from parse_force_ops *(curated)*

## Proposed (Architect / Hermit)

_None._

## Epics

- **#579**: Guard: upstream Loom's vendored-only guard functions so Loom can re-vendor in full and pick up the tmpfs refusal

## Backlog Balance

| Tier | Count |
|------|-------|
| Operator merge-risk holds | 2 |
| Operator priority | 0 |
| Ready (`loom:issue`) | 1 |
| In Progress (`loom:building`) | 1 |
| PRs awaiting review | 0 |
| Approved PRs awaiting merge | 2 |
| Curated | 6 |
| Architect / Hermit proposals | 0 |
| Active epics | 1 |
<!-- guide:plan-body:end -->

# Work Plan

Prioritized roadmap generated from current GitHub label state, maintained automatically by the Guide triage agent. Regenerated whenever label state changes; do not hand-edit the generated region below.

<!-- guide:plan-body:start -->
## Operator Attention: Merge-Risk-Hold Pileup

Judge-approved PRs stuck under a `loom:operator` merge-risk hold — implementation work is done, only a human merge decision is missing.

- **#667**: fix(install): rewrite a symlinked CLAUDE.md through the link, not over it

## Very Important

`loom:very-important` (one counts per workspace); every stage takes these first.

_None._

## Important

`loom:important`; taken before unlabelled work.

_None._

## Ready

Human-approved issues ready for implementation (`loom:issue`).

- **#669**: VERSION has moved to 0.24.x but there are no tags or releases since v0.16.1

## In Progress

Issues currently being built (`loom:building`).

- **#670**: Installing over a legacy .agents mirror layout gives a non-canonical tree and leaves .install-local.json un-ignored

## PRs Awaiting Review

PRs waiting on Judge (`loom:review-requested`).

- **#671**: feat: tag and release each VERSION bump on main, record tag in install metadata
- **#672**: fix(install): warn on legacy .agents mirror and ignore its sidecar

## Approved (Awaiting Merge)

PRs that passed review and are queued for Champion auto-merge (`loom:pr`).

- **#667**: fix(install): rewrite a symlinked CLAUDE.md through the link, not over it

## Proposed

Issues carrying `loom:curated`.

- **#565**: repo:remote: support short-lived or brokered GitHub credentials instead of a long-lived PAT on the VM *(curated)*
- **#638**: Repo Skills: make Dependabot (with cooldown) the default provider again; Renovate becomes opt-in (2am#4351) *(curated)*
- **#669**: VERSION has moved to 0.24.x but there are no tags or releases since v0.16.1 *(curated)*
- **#670**: Installing over a legacy .agents mirror layout gives a non-canonical tree and leaves .install-local.json un-ignored *(curated)*

## Proposed (Architect / Hermit)

_None._

## Epics

_None._

## Backlog Balance

| Bucket | Count |
|------|-------|
| Operator merge-risk holds | 1 |
| Very important | 0 |
| Important | 0 |
| Ready (`loom:issue`) | 1 |
| In Progress (`loom:building`) | 1 |
| PRs awaiting review | 2 |
| Approved PRs awaiting merge | 1 |
| Curated | 4 |
| Architect / Hermit proposals | 0 |
| Active epics | 0 |
<!-- guide:plan-body:end -->

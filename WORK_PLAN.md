# Work Plan

Prioritized roadmap generated from current GitHub label state, maintained automatically by the Guide triage agent. Regenerated whenever label state changes; do not hand-edit the generated region below.

<!-- guide:plan-body:start -->
## Operator Attention: Merge-Risk-Hold Pileup

Judge-approved PRs under a hold (`loom:blocked` or `loom:operator`) — only a human merge decision is missing.

- **#672**: fix(install): warn on legacy .agents mirror and ignore its sidecar
- **#677**: feat(codex): install each command as its own repo-<verb> skill
- **#679**: docs(gitignore): explain tracked files matching an ignore rule
- **#685**: fix(repo): treat a failed git status as unknown, not clean
- **#689**: chore(deps): bump actions/checkout from 4 to 7 in the github-actions group across 1 directory

## Very Important

`loom:very-important` (one counts per workspace); every stage takes these first.

_None._

## Important

`loom:important`; taken before unlabelled work.

_None._

## Ready

Human-approved issues ready for implementation (`loom:issue`).

_None._

## In Progress

Issues currently being built (`loom:building`).

- **#670**: Installing over a legacy .agents mirror layout gives a non-canonical tree and leaves .install-local.json un-ignored
- **#676**: Codex: register each repo command as a discoverable native skill
- **#678**: audit/gitignore: 'tracked files match an ignore rule' advice recommends dropping rules that only hide new untracked files
- **#684**: branches: a failed git status (e.g. broken submodule gitfile) reads as a clean worktree
- **#692**: Review dated guard-confinement evidence and owner-specific cases from gf180-opamp #214

## PRs Awaiting Review

PRs waiting on Judge (`loom:review-requested`).

- **#695**: docs: record owner review of guard-confinement evidence cases

## Approved (Awaiting Merge)

PRs that passed review and are queued for Champion auto-merge (`loom:pr`).

- **#672**: fix(install): warn on legacy .agents mirror and ignore its sidecar
- **#677**: feat(codex): install each command as its own repo-<verb> skill
- **#679**: docs(gitignore): explain tracked files matching an ignore rule
- **#685**: fix(repo): treat a failed git status as unknown, not clean
- **#689**: chore(deps): bump actions/checkout from 4 to 7 in the github-actions group across 1 directory

## Proposed

Issues carrying `loom:curated`.

- **#565**: repo:remote: support short-lived or brokered GitHub credentials instead of a long-lived PAT on the VM *(curated)*
- **#638**: Repo Skills: make Dependabot (with cooldown) the default provider again; Renovate becomes opt-in (2am#4351) *(curated)*
- **#670**: Installing over a legacy .agents mirror layout gives a non-canonical tree and leaves .install-local.json un-ignored *(curated)*
- **#676**: Codex: register each repo command as a discoverable native skill *(curated)*
- **#678**: audit/gitignore: 'tracked files match an ignore rule' advice recommends dropping rules that only hide new untracked files *(curated)*
- **#684**: branches: a failed git status (e.g. broken submodule gitfile) reads as a clean worktree *(curated)*
- **#692**: Review dated guard-confinement evidence and owner-specific cases from gf180-opamp #214 *(curated)*

## Proposed (Architect / Hermit)

_None._

## Epics

_None._

## Backlog Balance

| Bucket | Count |
|------|-------|
| Operator merge-risk holds | 5 |
| Very important | 0 |
| Important | 0 |
| Ready (`loom:issue`) | 0 |
| In Progress (`loom:building`) | 5 |
| PRs awaiting review | 1 |
| Approved PRs awaiting merge | 5 |
| Curated | 7 |
| Architect / Hermit proposals | 0 |
| Active epics | 0 |
<!-- guide:plan-body:end -->

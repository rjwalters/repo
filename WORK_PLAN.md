# Work Plan

Prioritized roadmap generated from current GitHub label state, maintained automatically by the Guide triage agent. Regenerated whenever label state changes; do not hand-edit the generated region below.

<!-- guide:plan-body:start -->
## Operator Attention: Merge-Risk-Hold Pileup

Judge-approved PRs under a hold (`loom:blocked` or `loom:operator`) — only a human merge decision is missing.

- **#770**: fix: cut CHANGELOG version headings on bump and gate on a matching heading
- **#800**: fix: match quoted guard-destructive.sh hook entry in installer and uninstaller

## Very Important

`loom:very-important` (one counts per workspace); every stage takes these first.

_None._

## Important

`loom:important`; taken before unlabelled work.

_None._

## Ready

Human-approved issues ready for implementation (`loom:issue`).

- **#765**: Remove /repo:remote (cloud dev-VM command) from Repo Skills

## In Progress

Issues currently being built (`loom:building`).

- **#798**: 0.26.1 installer leaves the quoted guard-destructive.sh entry in .claude/settings.json after deleting the script

## PRs Awaiting Review

PRs waiting on Judge (`loom:review-requested`).

_None._

## Approved (Awaiting Merge)

PRs that passed review and are queued for Champion auto-merge (`loom:pr`).

- **#770**: fix: cut CHANGELOG version headings on bump and gate on a matching heading
- **#800**: fix: match quoted guard-destructive.sh hook entry in installer and uninstaller

## Proposed

Issues carrying `loom:curated`.

- **#478**: Live-verify org-policy's absent/inaccessible heuristic against a real organization *(curated)*
- **#565**: repo:remote: support short-lived or brokered GitHub credentials instead of a long-lived PAT on the VM *(curated)*
- **#638**: Repo Skills: make Dependabot (with cooldown) the default provider again; Renovate becomes opt-in (2am#4351) *(curated)*
- **#765**: Remove /repo:remote (cloud dev-VM command) from Repo Skills *(curated)*
- **#769**: CHANGELOG has no version headings since 0.16.2; tagged bumps never cut one *(curated)*
- **#798**: 0.26.1 installer leaves the quoted guard-destructive.sh entry in .claude/settings.json after deleting the script *(curated)*

## Proposed (Architect / Hermit)

_None._

## Epics

_None._

## Backlog Balance

| Bucket | Count |
|------|-------|
| Operator merge-risk holds | 2 |
| Very important | 0 |
| Important | 0 |
| Ready (`loom:issue`) | 1 |
| In Progress (`loom:building`) | 1 |
| PRs awaiting review | 0 |
| Approved PRs awaiting merge | 2 |
| Curated | 6 |
| Architect / Hermit proposals | 0 |
| Active epics | 0 |
<!-- guide:plan-body:end -->

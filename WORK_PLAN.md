# Work Plan

Prioritized roadmap generated from current GitHub label state, maintained automatically by the Guide triage agent. Regenerated whenever label state changes; do not hand-edit the generated region below.

<!-- guide:plan-body:start -->
## Operator Attention: Merge-Risk-Hold Pileup

Judge-approved PRs under a hold (`loom:blocked` or `loom:operator`) — only a human merge decision is missing.

- **#728**: feat(codex): make $repo a thin router and migrate away umbrella references/

## Very Important

`loom:very-important` (one counts per workspace); every stage takes these first.

_None._

## Important

`loom:important`; taken before unlabelled work.

_None._

## Ready

Human-approved issues ready for implementation (`loom:issue`).

- **#722**: worktree-isolation guard blocks a stdin heredoc whose only writes are outside the repository, reporting a write to the repo root

## In Progress

Issues currently being built (`loom:building`).

- **#676**: Codex: register each repo command as a discoverable native skill
- **#684**: branches: a failed git status (e.g. broken submodule gitfile) reads as a clean worktree

## PRs Awaiting Review

PRs waiting on Judge (`loom:review-requested`).

- **#685**: fix(repo): treat a failed git status as unknown, not clean
- **#725**: fix(guard): accurate deny for opaque interpreter-heredoc writes (#722)

## Approved (Awaiting Merge)

PRs that passed review and are queued for Champion auto-merge (`loom:pr`).

- **#728**: feat(codex): make $repo a thin router and migrate away umbrella references/

## Proposed

Issues carrying `loom:curated`.

- **#565**: repo:remote: support short-lived or brokered GitHub credentials instead of a long-lived PAT on the VM *(curated)*
- **#638**: Repo Skills: make Dependabot (with cooldown) the default provider again; Renovate becomes opt-in (2am#4351) *(curated)*
- **#676**: Codex: register each repo command as a discoverable native skill *(curated)*
- **#684**: branches: a failed git status (e.g. broken submodule gitfile) reads as a clean worktree *(curated)*
- **#703**: repo-remote: SSH ingress flip-flops between a host's two egress IPs (revokes the other as 'stale'), leaving boxes unreachable *(curated)*
- **#722**: worktree-isolation guard blocks a stdin heredoc whose only writes are outside the repository, reporting a write to the repo root *(curated)*

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
| In Progress (`loom:building`) | 2 |
| PRs awaiting review | 2 |
| Approved PRs awaiting merge | 1 |
| Curated | 6 |
| Architect / Hermit proposals | 0 |
| Active epics | 0 |
<!-- guide:plan-body:end -->

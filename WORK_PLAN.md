# Work Plan

Prioritized roadmap generated from current GitHub label state, maintained automatically by the Guide triage agent. Regenerated whenever label state changes; do not hand-edit the generated region below.

<!-- guide:plan-body:start -->
## Operator Attention: Merge-Risk-Hold Pileup

Judge-approved PRs stuck under a `loom:operator` merge-risk hold — implementation work is done, only a human merge decision is missing.

- **#297**: fix(guard): resolve quoted $VAR write targets to same-command static literals
- **#288**: feat(install): package skills for Codex CLI at .agents/skills/repo/

## Urgent

Issues flagged as highest priority (`loom:urgent`).

_None._

## Ready

Human-approved issues ready for implementation (`loom:issue`).

- **#293**: worktree-write-confinement-unresolved-var denies writes via a variable holding a statically-resolvable worktree-scoped literal
- **#285**: Add Codex-side install/uninstall/drift-detection path for Repo Skills

## In Progress

Issues currently being built (`loom:building`).

- **#305**: Guard dispatcher probe (c) permanently inert (#5916), so the vendored guard still hits the #53 echo/printf false-positive
- **#304**: Consolidate worktree-creation logic: docs-worktree.sh and pr-worktree.sh silently lack worktree.sh's concurrency lock

## PRs Awaiting Review

PRs waiting on Judge (`loom:review-requested`).

_None._

## Approved (Awaiting Merge)

PRs that passed review and are queued for Champion auto-merge (`loom:pr`).

- **#297**: fix(guard): resolve quoted $VAR write targets to same-command static literals
- **#288**: feat(install): package skills for Codex CLI at .agents/skills/repo/

## Proposed

Issues carrying `loom:curated`.

- **#293**: worktree-write-confinement-unresolved-var denies writes via a variable holding a statically-resolvable worktree-scoped literal *(curated)*
- **#285**: Add Codex-side install/uninstall/drift-detection path for Repo Skills *(curated)*
- **#282**: Add dual-runtime Claude and Codex packaging for Repo Skills *(curated)*
- **#257**: Handoff note in another repo is invisible from the repo you start in *(curated)*

## Proposed (Architect / Hermit)

_None._

## Epics

_None._

## Backlog Balance

| Tier | Count |
|------|-------|
| Operator merge-risk holds | 2 |
| Urgent | 0 |
| Ready (`loom:issue`) | 2 |
| In Progress (`loom:building`) | 2 |
| PRs awaiting review | 0 |
| Approved PRs awaiting merge | 2 |
| Curated | 4 |
| Architect / Hermit proposals | 0 |
| Active epics | 0 |
<!-- guide:plan-body:end -->

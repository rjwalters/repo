# Work Plan

Prioritized roadmap generated from current GitHub label state, maintained automatically by the Guide triage agent. Regenerated whenever label state changes; do not hand-edit the generated region below.

<!-- guide:plan-body:start -->
## Operator Attention: Merge-Risk-Hold Pileup

Judge-approved PRs stuck under a `loom:operator` merge-risk hold — implementation work is done, only a human merge decision is missing.

- **#433**: fix(guard): a backslash-escaped backtick no longer vetoes span masking
- **#442**: fix(guard): reach into a quoted single-command $( ) for write-target extraction
- **#461**: feat(guard): deny a build/scratch dir that resolves onto a tmpfs mount

## Operator Priority

Issues the operator starred (`loom:operator-priority`); land these first.

_None._

## Ready

Human-approved issues ready for implementation (`loom:issue`).

_None._

## In Progress

Issues currently being built (`loom:building`).

- **#518**: test-changelog-merged-work-check.sh fails under Loom dispatch: provenance-hook trailers leak into fixture commits

## PRs Awaiting Review

PRs waiting on Judge (`loom:review-requested`).

_None._

## Approved (Awaiting Merge)

PRs that passed review and are queued for Champion auto-merge (`loom:pr`).

- **#433**: fix(guard): a backslash-escaped backtick no longer vetoes span masking
- **#442**: fix(guard): reach into a quoted single-command $( ) for write-target extraction
- **#461**: feat(guard): deny a build/scratch dir that resolves onto a tmpfs mount

## Proposed

Issues carrying `loom:curated`.

- **#439**: Worktree-write-confinement: a quoted single-command $( ) substitution writes into the main checkout in both guards *(curated)*
- **#447**: Upstream the repo#443 single-quoted-span inertness fix to Loom's vendored guard *(curated)*
- **#454**: Guard: refuse a build/scratch dir assignment that resolves onto a tmpfs mount *(curated)*
- **#518**: test-changelog-merged-work-check.sh fails under Loom dispatch: provenance-hook trailers leak into fixture commits *(curated)*

## Proposed (Architect / Hermit)

_None._

## Epics

_None._

## Backlog Balance

| Tier | Count |
|------|-------|
| Operator merge-risk holds | 3 |
| Operator priority | 0 |
| Ready (`loom:issue`) | 0 |
| In Progress (`loom:building`) | 1 |
| PRs awaiting review | 0 |
| Approved PRs awaiting merge | 3 |
| Curated | 4 |
| Architect / Hermit proposals | 0 |
| Active epics | 0 |
<!-- guide:plan-body:end -->

# Work Plan

Prioritized roadmap generated from current GitHub label state, maintained automatically by the Guide triage agent. Regenerated whenever label state changes; do not hand-edit the generated region below.

<!-- guide:plan-body:start -->
## Operator Attention: Merge-Risk-Hold Pileup

Judge-approved PRs under a hold (`loom:blocked` or `loom:operator`) — only a human merge decision is missing.

- **#728**: feat(codex): make $repo a thin router and migrate away umbrella references/
- **#736**: fix: unwire our own guard entry when install defers to another guard
- **#751**: feat(guard): add guards.rmAllowDirs (#747)
- **#753**: chore(loom): resync installed Loom to v0.19.1263

## Very Important

`loom:very-important` (one counts per workspace); every stage takes these first.

_None._

## Important

`loom:important`; taken before unlabelled work.

- **#754**: repo-remote prune --yes empties the whole SSH config on macOS when removing 2+ aliases (BSD awk rejects newline in -v)

## Ready

Human-approved issues ready for implementation (`loom:issue`).

- **#676**: Codex: register each repo command as a discoverable native skill

## In Progress

Issues currently being built (`loom:building`).

- **#733**: install.sh: deferring to another guard leaves Repo Skills' own guard hook wired but unrefreshed, and records guardHookInstalled=false against a tree that still runs it
- **#747**: guard-destructive.sh: allow cleanup outside the repo, and stop parsing quoted/heredoc text as write targets
- **#754**: repo-remote prune --yes empties the whole SSH config on macOS when removing 2+ aliases (BSD awk rejects newline in -v)
- **#755**: test-guard-destructive.sh: three #722 opaque-heredoc cases fail on macOS (target= logical vs physical /private/var path)
- **#758**: docs/: add a README indexing the design/review records
- **#765**: Remove /repo:remote (cloud dev-VM command) from Repo Skills

## PRs Awaiting Review

PRs waiting on Judge (`loom:review-requested`).

- **#752**: chore: repo hygiene fixes (2026-11-04)
- **#762**: fix(repo-remote): stop prune emptying ssh config under BSD awk
- **#766**: feat: remove /repo:remote and retire its installed files on reinstall/resync

## Approved (Awaiting Merge)

PRs that passed review and are queued for Champion auto-merge (`loom:pr`).

- **#728**: feat(codex): make $repo a thin router and migrate away umbrella references/
- **#736**: fix: unwire our own guard entry when install defers to another guard
- **#751**: feat(guard): add guards.rmAllowDirs (#747)
- **#753**: chore(loom): resync installed Loom to v0.19.1263
- **#760**: docs: add docs/ index and link design records from README
- **#763**: fix(tests): make #722 opaque-heredoc target assertion macOS-portable

## Proposed

Issues carrying `loom:curated`.

- **#478**: Live-verify org-policy's absent/inaccessible heuristic against a real organization *(curated)*
- **#565**: repo:remote: support short-lived or brokered GitHub credentials instead of a long-lived PAT on the VM *(curated)*
- **#638**: Repo Skills: make Dependabot (with cooldown) the default provider again; Renovate becomes opt-in (2am#4351) *(curated)*
- **#676**: Codex: register each repo command as a discoverable native skill *(curated)*
- **#733**: install.sh: deferring to another guard leaves Repo Skills' own guard hook wired but unrefreshed, and records guardHookInstalled=false against a tree that still runs it *(curated)*
- **#747**: guard-destructive.sh: allow cleanup outside the repo, and stop parsing quoted/heredoc text as write targets *(curated)*
- **#754**: repo-remote prune --yes empties the whole SSH config on macOS when removing 2+ aliases (BSD awk rejects newline in -v) *(curated)*
- **#755**: test-guard-destructive.sh: three #722 opaque-heredoc cases fail on macOS (target= logical vs physical /private/var path) *(curated)*
- **#758**: docs/: add a README indexing the design/review records *(curated)*
- **#759**: .loom/resync-ignore: guard-destructive-generic.sh pin no longer matches anything (resync warns 'pin had no effect') *(curated)*
- **#765**: Remove /repo:remote (cloud dev-VM command) from Repo Skills *(curated)*
- **#767**: package.json: drop dangling worktree:return script after Loom resync removed worktree-return.sh *(curated)*

## Proposed (Architect / Hermit)

_None._

## Epics

_None._

## Backlog Balance

| Bucket | Count |
|------|-------|
| Operator merge-risk holds | 4 |
| Very important | 0 |
| Important | 1 |
| Ready (`loom:issue`) | 1 |
| In Progress (`loom:building`) | 6 |
| PRs awaiting review | 3 |
| Approved PRs awaiting merge | 6 |
| Curated | 12 |
| Architect / Hermit proposals | 0 |
| Active epics | 0 |
<!-- guide:plan-body:end -->

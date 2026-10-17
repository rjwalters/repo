# Remote-exec provenance: requirement → owner → gap map

Tracking doc for [#681](https://github.com/rjwalters/repo/issues/681). It maps
each provenance requirement of that issue to the repository that owns it, the
evidence found today, the gap, and a proposed increment.

**Nothing in this document authorizes a consumer switch, install, deployment,
launch or spend.** It is a mapping and preparation artifact only. Increments for
repositories other than this one are proposals; no issue, PR or comment is filed
in another repository by this work.

## Decision recorded

The operator selected **2run** as the top-level entrypoint that everything is
called through; remote execution is a subcall of 2run, not a sibling tool
([issue comment](https://github.com/rjwalters/repo/issues/681#issuecomment-6228626687)).
The provenance guarantee therefore belongs at the 2run layer, and "always use
2run" is the guarantee. This repository owns `/repo:remote`; it does not own
2run or `remote-run`. #680 (`remote-run` dirty-refuse and SHA stamp) stays the
separate interim path and is not changed by this doc.

## Evidence base

| Source | Pinned at | Verified how |
| --- | --- | --- |
| This repo, `commands/repo/remote.md` § "5. Get the repo onto the instance" (L1641-1660) | `rjwalters/repo@b7e03ab`, checked 2026-10-17 | Read the section; `grep -nE 'git clone\|git checkout\|rsync' commands/repo/remote.md` |
| This repo, `scripts/repo/repo-remote.sh` (4011 lines) | `rjwalters/repo@b7e03ab`, checked 2026-10-17 | `grep -nE 'rsync\|git clone'` finds only comments (L112, L233, L528); no code path syncs or pins code |
| This repo, any mention of 2run | `rjwalters/repo@b7e03ab`, checked 2026-10-17 | `git grep -il 2run` matches nothing; `remote-run` is not in this repo |
| 2run README | [`2AMLogic/2run@a5d744f`](https://github.com/2AMLogic/2run/blob/a5d744f99248764dd12e6817331b7f9025d82ca0/README.md) (commit dated 2026-10-17, README status dated 2026-10-12) | Read the README only. The crates, `docs/` and `2run.yaml` handling were **not verified** |
| #680 | Open as of 2026-10-17 | `gh issue view 680` |

## Gaps found

1. **This repo, `/repo:remote` step 5.** It runs `git clone … && git -C … checkout <branch>`,
   then `rsync -az --delete` of the working tree. It pins no SHA (a branch name
   is resolved at clone time), does not refuse a dirty tree, does not verify the
   box matches anything, and stamps nothing into outputs or telemetry.
2. **2run, uncommitted snapshots.** The README says every run records an "exact
   source snapshot (including uncommitted changes)". Capturing a dirty tree
   faithfully is good provenance but is not a refusal: a clean-tree refusal is
   **not native** and must be mapped as a gap. Whether the snapshot record
   carries a commit SHA, a dirty flag, a version or a data identity is **not
   verified**.
3. **2run, live deployment.** The README status lists live deployment,
   migrations and cross-environment acceptance (#25-#30) as "NOT STARTED" and
   states no live Kubernetes acceptance evidence exists (status dated
   2026-10-12). Repository existence is not evidence of installation, live
   adoption or that the provenance contract is met. Current deployment state
   is **not verified**.

## Requirement map

Status values: `proposed` (increment described, not filed) or `not started`.

| # | Requirement (from #681) | Owning repo | Current evidence | Gap | Proposed increment | Status |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | Require an explicit ref, or pin to a verified local SHA | `2AMLogic/2run` (top-level entrypoint); `rjwalters/repo` for `/repo:remote` | repo: step 5 takes `<branch>` and resolves it at clone time ([`remote.md`@b7e03ab](https://github.com/rjwalters/repo/blob/b7e03ab/commands/repo/remote.md)). 2run: snapshot is of the working tree per the [README@a5d744f](https://github.com/2AMLogic/2run/blob/a5d744f99248764dd12e6817331b7f9025d82ca0/README.md); ref handling not verified | repo: no SHA pin. 2run: whether a ref/SHA is required is not verified | 2run (proposal): require `--ref` or resolve and record `HEAD` SHA before submit. repo (proposal): see Follow-up A | `proposed` |
| 2 | Force/verify the box is at exactly that SHA (or the exact tracked tree) | `2AMLogic/2run`; `rjwalters/repo` for `/repo:remote` | repo: clone plus `rsync --delete` makes the tree match the local working tree but never checks or records a SHA. 2run: immutable source snapshots (#7 in README status), digest semantics not verified | repo: no verification step. 2run: verification of snapshot against a SHA not verified | 2run (proposal): compare snapshot's base SHA with the requested ref and fail on mismatch. repo (proposal): Follow-up A | `proposed` |
| 3 | Refuse a dirty tree | `2AMLogic/2run`; `remote-run` (interim, #680); `rjwalters/repo` for `/repo:remote` | 2run records uncommitted changes rather than refusing (README policy section). repo: step 5 explicitly syncs uncommitted work. #680 covers `remote-run` only | Not native in 2run; not present in `/repo:remote`, whose step 5 intends to sync uncommitted work | 2run (proposal): a per-task or per-invocation `require_clean` option that refuses a dirty tracked tree. repo (proposal): Follow-up A, opt-in. `remote-run`: stays #680 | `proposed` |
| 4 | Stamp SHA + version + data identity into outputs | `2AMLogic/2run` | README: run record holds source snapshot, configuration, execution location, cache provenance, logs, outputs, exit status. Whether SHA, tool version or data identity are fields in the record or in declared outputs is not verified | Presence of SHA/version/data-identity fields unconfirmed; consumers (loom-ui fits) would also need to write them into their own result files | 2run (proposal): surface SHA and version in `2run outputs` metadata; data identity declared per task. Consumer side: row 7 | `proposed` |
| 5 | Same stamps in `loom.*` telemetry (trace-identity policy) | `2AMLogic/2run`; Loom daemon owners (`rjwalters/loom`) for the `loom.*` namespace | 2run has traceable run IDs per README; mapping onto `loom.*` attributes not verified. The trace-identity policy text was not read for this doc | Mapping from 2run run record to `loom.*` attributes undefined | 2run (proposal): emit SHA/version as span attributes under agreed `loom.*` names, once the names are confirmed with the policy owner | `not started` |
| 6 | Consumer migration: loom-ui ETA fits | `2AMLogic/loom-ui` ([loom-ui#4951](https://github.com/2AMLogic/loom-ui/issues/4951), not read for this doc) | The original problem report; the hand-managed `~/build/<repo>-fitN` clone drifted via `git fetch origin main` then `reset --hard origin/main` | Blocked on rows 1-4 and on 2run live deployment (gap 3) | loom-ui (proposal): once 2run is live and accepted, replace the ssh + rsync + `git reset` flow with a 2run invocation and have the fit write the stamp into its result | `not started` |
| 7 | Consumer migration: loom builds/tests | `rjwalters/loom` and the 2AMLogic CI owners | 2run README: CI "still drives cargo directly on shared runners" (status 2026-10-12) | Blocked on 2run live deployment (gap 3); owner-specific list of build and test entry points not compiled here | loom (proposal): inventory the build/test entry points that currently run on boxes, then migrate one at a time after 2run acceptance | `not started` |
| 8 | Deprecate hand-managed box clones | `rjwalters/repo` (`/repo:remote` step 5 guidance); `2AMLogic/loom-ui` and other consumers | step 5 itself instructs a hand-managed clone plus rsync | The sanctioned path today is the hand-managed one | repo (proposal): after Follow-up A and 2run acceptance, mark the step 5 clone-and-rsync flow as the legacy path and point at 2run. Consumers delete their ad-hoc scripts last | `not started` |

## Follow-ups (proposals only, not implemented here)

- **Follow-up A, `/repo:remote` (this repo).** Pin to a verified SHA, refuse a
  dirty *tracked* tree (opt-in, because step 5 deliberately supports syncing
  uncommitted work), and record the SHA on the box. This changes installed
  behavior (`commands/repo/remote.md`, and possibly `scripts/repo/repo-remote.sh`),
  so it needs its own issue, tests and a `VERSION` bump. It is not part of this
  PR.
- **#680 (`remote-run`).** Remains the interim path for dirty-refuse and SHA
  stamp. Unchanged by this doc.
- **2run increments (rows 1-5).** Written here as proposals for the 2run owners
  to accept or reject; nothing is filed in `2AMLogic/2run`.
- **loom-ui and loom increments (rows 6-8).** Proposals for those repos' owners;
  nothing is filed there.

## Not verified

- Anything in 2run beyond its README at `a5d744f`: the snapshot record's
  fields, CLI flags, `2run.yaml` schema, and `docs/`.
- Whether 2run is installed or deployed anywhere, and its current status after
  2026-10-12.
- The contents of loom-ui#4951 and the `loom.*` trace-identity policy.
- Whether any other code in `scripts/repo/repo-remote.sh` syncs code by means
  other than `rsync` or `git clone` (the grep found only comments).

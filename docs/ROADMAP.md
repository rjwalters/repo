# Roadmap

Repo Skills is a toolbox of general repository-hygiene and environment commands
(`/repo:<verb>` in Claude Code, `$repo-<verb>` in Codex CLI) plus the installer,
guard hook and installer contract that deliver them into consumer repos.

Status as of 2026-11-13, `main` @ `c77d1ba`, `VERSION` 0.26.1 (tag `v0.26.1`).

The label-by-label queue is [`WORK_PLAN.md`](../WORK_PLAN.md) and the merge
history is [`WORK_LOG.md`](../WORK_LOG.md); both are generated, not repeated here.

## Where it stands

Done and evidenced on `main`:

- **24 commands** in `commands/repo/*.md`, each listed in the README Skills
  table and in `skills/repo/SKILL.md`; the tables are checked against disk by
  `commands/repo/tests/test-skill-commands-table.sh` and
  `test-readme-layout-block.sh`.
- **Installer contract C1-C10** (`INSTALLER-CONTRACT.md`) is normative and this
  repo's own column of its conformance table is verified on every test run
  (`commands/repo/tests/test-installer-contract.sh`).
- **Codex packaging.** Every command is its own native skill and `$repo` is a
  thin router with no `references/` copies (#676; PR #728 merged).
- **Destructive-command guard** (`hooks/repo/guard-destructive.sh`): worktree
  write-confinement covers `mkdir`/`touch`/`ln`/`install` (#693),
  `guards.rmAllowDirs` (#747, PR #751), process substitution no longer misread
  as a write (#785, PR #786). The owner review of an external evidence set is
  recorded in [`guard-confinement-review.md`](guard-confinement-review.md).
- **Dependabot-first organization policy.** All five phases of #638
  (#652-#656) are closed; `policies/default.json` is the canonical source that
  `/repo:org-policy` reads.
- **Resync and handoff fixes in 0.26.1:** resync from a linked worktree (#793,
  PR #794), handoff preflight hook spellings (#789, PR #791), staging-mode
  guidance in `/repo:update-tools` (#792, PR #795).
- **Release mechanics.** `scripts/version.sh` is the single source of
  `VERSION`; tags are cut on each bump (#669); CI runs the
  installed-surface version-bump gate as a visible, non-required check.
- **Tests.** `pnpm test` runs `hooks/repo/tests/run.sh` on Linux and fails on
  any undelegated suite (#774, PR #776); one suite (`test-repo-remote.sh`)
  also runs on macOS with BSD awk and bash 3.2 (#771, PR #772).

Known drift: `CHANGELOG.md` has no version heading newer than `0.16.2`;
everything since sits under `Unreleased` (#769, fix in PR #770, held).

## Now

Can start today. Every merge in this repo currently needs a human (see
"Blocked and waiting"), so "start" means build and review, not land.

1. **Bring PR #766 back to mergeable** (#765, remove `/repo:remote`). The PR
   conflicts with `main` and carries `loom:changes-requested` +
   `loom:merge-conflict`. Done when: #766 merges cleanly against `main`,
   `pnpm test` passes, and install/resync remove a retired command's installed
   files as #765 requires.
2. **Name a 403 on the policy repository in `/repo:org-policy`.**
   `scripts/repo/repo-org-policy.py` treats only `HTTP 404` as "missing"; a
   403 on `repos/OWNER/.github` surfaces as a raw `GitHub GET ... failed`
   error before `classify_absence()` runs (the case #478 calls out as
   unanticipated). Done when: a stubbed 403 on the target produces a message
   that says the repository exists or is hidden and that access was refused,
   with a test in `commands/repo/tests/test_org_policy.py`. No issue yet.
3. **Re-observe the other tools' columns of the conformance table.**
   `INSTALLER-CONTRACT.md` says the loom/anvil/squad columns were observed
   2026-08-06 (C10 on 2026-09-29) and its C9 row still reads "not yet checked
   (repo#385)" for all three. Done when: each cell of every column whose
   clone the builder can read is re-derived with the section's own spot-check
   commands and the observation date is updated. No issue yet.
4. **Run the full suite on macOS in CI.** The `test-macos` job runs only
   `test-repo-remote.sh` and states the full `pnpm test` suite is out of
   scope; #754 and #755 were both macOS-only failures that Linux CI missed.
   Done when: a non-required job runs `hooks/repo/tests/run.sh` under
   `/bin/bash` on `macos-latest` and is green, with any portability failures
   it exposes fixed or filed. No issue yet. This touches
   `.github/workflows/`, so its merge will be held for a human like #770.

## Next

- **Trim what only `/repo:remote` used**, once #766 lands: `Dockerfile` and
  `.github/workflows/docker-build.yml` if #766 leaves them, the `test-macos`
  job's target suite (item 4 above replaces it), and the row for
  `remote-exec-provenance.md` in [`docs/README.md`](README.md). Done when:
  `grep -ri 'repo-remote\|repo:remote'` over tracked files outside
  `CHANGELOG.md`, `WORK_LOG.md` and `work_log/` returns nothing unintended.
- **First release with a real CHANGELOG section**, once PR #770 merges. Done
  when: `/repo:release` Phase 1.5's version-header check passes on `main` and
  the next bump cuts its own dated heading.

## Later

- **Should the test check become required?** #73 decided against a required
  status check for a solo-operator repo and recorded that any future enabler
  must use classic branch protection, not a ruleset (comment above the `test`
  job in `.github/workflows/ci.yml`). Question first: have collaborators
  joined?
- **A linter.** `package.json`'s `lint` script is a placeholder. Question
  first: which shell linter and which baseline of existing findings is
  acceptable, given the suite's bash 3.2 portability constraint?

## Blocked and waiting

- **Merging.** #773: role commands under `.claude/` are git-ignored, so
  automated merge steps cannot run here; it carries a ranked decision block
  (commit the role commands, install them on provision, or merge by hand)
  awaiting the operator. Until it is ruled on, every approved PR waits for a
  human merge.
- **PR #770** (CHANGELOG headings, #769): approved; held because it changes
  `.github/workflows/ci.yml`.
- **PR #800** (quoted guard-hook entry left in `settings.json`, #798):
  approved; held on blast radius, since it changes how `install.sh` and
  `uninstall.sh` rewrite consumers' `settings.json`.
- **#676**: code complete; the remaining criterion is a live Codex CLI session
  selecting and invoking representative `$repo-<verb>` skills.
- **#638**: code complete; open until the owner-side Mend Renovate App removal
  is recorded.
- **#478**: a live-verification checklist that needs admin on a real GitHub
  organization; no code change proposed.
- **#565**: its remaining step is an attended VM check of `/repo:remote`,
  the command #765 removes. #424 is an auto-maintained digest, not work.

Open issues with buildable work and no PR: none. Items 2-4 above are the only
new work a builder can pick up, and none has an issue yet.

## Not planned

- **A canonical remote-execution tool in this repo.** #681 and #680 were
  closed as not planned; `/repo:remote` itself is being removed (#765).
  [`remote-exec-provenance.md`](remote-exec-provenance.md) remains as a record.
- **Org-specific checks in the commands.** The "Adding a skill" rule in the
  README stands: no hardcoded hostnames, project names or infrastructure
  paths; repo-local behaviour belongs in the consumer repo.

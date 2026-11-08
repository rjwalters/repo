# Work Log Archive — 2026-07

Sections moved byte-for-byte from [WORK_LOG.md](../WORK_LOG.md) by `loom-daemon work-docs archive`.

### 2026-07-29

- **Issue #78** (closed): repo:remote idle-shutdown guard: short window + idle-exit marker support for loom-daemon hosts (coordinates with loom#4467)
- **PR #79**: feat(repo-remote): idle-exit marker contract + daemon-host short-window docs for the idle-shutdown guard
- **Issue #72** (closed): guard-destructive: command-word substitution resolving to rm bypasses the deny floor
- **PR #77**: fix(guard-destructive): catch command-word substitutions resolving to rm
- **Issue #35** (closed): install.sh: shell `claude` wrapper to surface a pending handoff note to the human (deferred from #32)
- **PR #65**: feat(install): add opt-in shell claude wrapper surfacing pending handoff notes
- **Issue #71** (closed): guard-destructive: parse_force_ops() and lifecycle_or_cloud_reason() share the per-record qsplit multi-line defect
- **PR #76**: fix(guard-destructive): share ml_segment() lexer so force-op/lifecycle parsers are multi-line quote-aware
- **Issue #70** (closed): release: fold an existing ## Unreleased section into the next version entry
- **PR #75**: docs(release): fold an existing ## Unreleased section into the version draft
- **Issue #73** (closed): ci: decide whether to require the test status check on main
- **PR #74**: docs(ci): record decision to not require the test status check on main
- **Issue #60** (closed): guard-destructive: multi-line quoted literal with line-leading recursive-force delete still false-blocks (extract_rm_targets per-line scan)
- **PR #69**: fix(guard-destructive): make extract_rm_targets quote-aware across newlines
- **Issue #43** (closed): /repo:release exposes no extension points, so projects migrating off /loom:release silently lose their release policy
- **PR #68**: feat(release): add per-project release policy seams to /repo:release
- **Issue #49** (closed): feat: opt-in passwordless-sudo setup for dev machines (sudoers.d drop-in)
- **PR #67**: feat(sudo): add /repo:sudo passwordless-sudo setup command
- **Issue #59** (closed): gitignore: node_modules symlink in issue worktrees shows as untracked (directory-only pattern miss)
- **PR #66**: fix(gitignore): match node_modules symlink by dropping trailing slash
- **Issue #33** (closed): /repo:handoff: the MEMORY.md pointer does not reliably deliver the note — verified miss on a live handoff
- **PR #54**: fix: inline handoff note body under size cap in SessionStart hook
- **Issue #46** (closed): test: branches loss-check suite fails on git < 2.38 and never covers the documented merge-tree fallback
- **PR #64**: test(branches): skip merge-tree assertions on git < 2.38 and cover the fallback
- **Issue #50** (closed): feat: /repo:host-optimize — audit and prepare a Mac for heavy Loom/agent build use
- **PR #63**: feat(repo): add /repo:host-optimize command for build-host preparation
- **Issue #45** (closed): docs(release): announce the new CLAUDE.md marker refusal conditions from #42
- **PR #62**: docs(changelog): announce CLAUDE.md marker refusal conditions from #42
- **Issue #51** (closed): install.sh: gitignore check misses negated patterns (!.claude/commands/) — CLAUDE.md pointer wrongly skipped
- **PR #61**: fix(install): gate CLAUDE.md pointer on commands/ ignore state alone
- **Issue #53** (closed): guard-destructive: dangerous strings inside quoted literals still block (echo/heredoc data, guard self-tests)
- **PR #58**: fix(guard-destructive): redact dangerous strings quoted as echo/printf data
- **Issue #52** (closed): repo:remote: headless/scriptable provisioning entry point (consumed by loom fleet add-worker)
- **PR #57**: feat(remote): add headless repo-remote provisioning script
- **Issue #44** (closed): test: two delegated suites still count as 1 case each — headline says 501, breakdown sums to 578
- **PR #56**: test(run): fold the two delegated suites in at real case counts
- **Issue #48** (closed): ci: no workflow runs the 532-case suite — pnpm test fires only when a human remembers
- **PR #55**: ci: add GitHub Actions workflow running the full test suite

### 2026-07-28

- **Issue #37** (closed): docs(install.sh): SessionStart matcher comment claims alternation is unsupported — it is supported
- **PR #47**: docs(install): correct the SessionStart matcher rationale
- **Issue #39** (closed): branches.md: the permanent-loss check is malformed — `--not` toggles, so it re-includes main
- **PR #41**: fix(branches): correct the permanent-loss check's `--not` toggle and make it content-aware
- **Issue #36** (closed): test: `pnpm test` skips the 444-case guard-destructive regression suite
- **PR #40**: test(hooks): fold the 444-case guard-destructive suite into `pnpm test`

### 2026-07-27

- **Issue #38** (closed): install.sh deletes an adjacent tool's CLAUDE.md marker block
- **PR #42**: fix(install): anchor CLAUDE.md block rewrites to the marker string, not the line
- **Issue #32** (closed): install.sh: offer to wrap the user's shell `claude` command so a pending /repo:handoff note is surfaced at session start
- **PR #34**: feat(hooks): surface a pending /repo:handoff note via a SessionStart hook
- **Issue #31** (closed): install.sh: stale committed CLAUDE.md pointer is never reconciled when .claude/ is gitignored
- **Issue #29** (closed): guard-destructive: curl-pipe pattern false-positives on any pipe target whose path contains "sh" (e.g. /usr/share, tee, shasum)
- **Issue #30** (closed): Consolidate the generic destructive-command guard here (canonical home); Loom defers to it
- **Issue #28** (closed): feat: /repo:handoff — a safe, repeatable ritual for rolling a Claude session
- **Issue #27** (closed): install.sh exits 1 with no error message when run non-interactively

### 2026-07-22

- **Issue #25** (closed): update-tools: land the update on the default branch by default (not just leave it uncommitted)
- **PR #26**: docs(update-tools): commit + land tool updates on the default branch by default

### 2026-07-19

- **PR #24**: feat(tidy): make cache deletion opt-in (--caches); protect node_modules
- **PR #23**: chore(loom): vendor Loom 0.10.10 + docs(changelog): Unreleased section
- **PR #22**: docs(help): add /repo:release to the command table

### 2026-07-18

- **PR #21**: chore(loom): update vendored Loom 45b515c7 → 101d758c

### 2026-07-17

- **Issue #18** (closed): install.sh CLAUDE.md block says hygiene commands are "report-first" — contradicts SKILL.md's "apply safe fixes by default" (v0.4.1)
- **Issue #15** (closed): /repo:followups — capture follow-on issues from a working session into this repo and upstream tool repos
- **PR #20**: docs(commands): add /repo:followups to file session follow-on issues
- **Issue #13** (closed): Adopt the generic destructive-command PreToolUse guard from Loom (guard-destructive.sh)
- **PR #19**: feat: add destructive-command PreToolUse guard hook with settings.json merge wiring
- **Issue #14** (closed): install-metadata.json commits a machine-local absolute source path
- **PR #17**: fix: move machine-local source path + timestamp out of tracked install metadata
- **Issue #12** (closed): Installer's CLAUDE.md block still says hygiene commands are 'report-first' — contradicts the 0.4.0 apply-by-default change
- **PR #16**: docs(install): describe apply-by-default hygiene behavior in CLAUDE.md block

### 2026-07-16

- **PR #11**: feat(remote): dogfood dev env — Claude Code + multi-account token pool + gh label auth
- **PR #10**: feat(remote): load shared cloud creds from ~/.config/repo/remote.env
- **Issue #7** (closed): repo:release — Phase 1.5 CHANGELOG gate assumes bracketed [x.y.z] headers, false-negatives on bracket-less format
- **PR #9**: docs(release): make Phase 1.5 CHANGELOG gate accept bracket-less headers
- **Issue #6** (closed): repo:release — version-tool detection prefers npm/package.json over VERSION even when they disagree
- **PR #8**: fix(release): reconcile VERSION vs package.json before npm bump in Phase 2
- **Issue #4** (closed): install.sh (non-dev): appends tracked CLAUDE.md pointer even when target repo gitignores the install destination
- **PR #5**: fix(install): skip CLAUDE.md pointer when install destination is gitignored

### 2026-07-15

- **Issue #2** (closed): /repo:tidy SAFE category can delete gitignored secrets/data (.env, .venv) — "gitignored" ≠ "regenerable"
- **PR #3**: docs(tidy): make SAFE an allowlist and add never-delete denylist for secrets/venvs
- **Issue #1** (closed): /repo:remote: support GPU instances (GPU AMI + accelerator types + driver/toolkit bootstrap)

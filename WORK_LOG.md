# Work Log

Chronological record of merged PRs and closed issues, maintained automatically
by the Guide triage agent. Newest entries first.

### 2026-08-05

- **Issue #138** (closed): Loom resync wants to strip package.json's version field that scripts/version.sh deliberately mirrors — decide before resyncing
- **Issue #143** (closed): update-tools: resync flag list omits --allow-worktree
- **PR #144**: docs(update-tools): add --allow-worktree to the resync flag list
- **Issue #136** (closed): tidy KEEP: stale fixture count and a doc/transcription mismatch on base-sibling lookup case-sensitivity
- **PR #142**: docs(tidy): fix stale KEEP fixture count and case-sensitivity gap
- **Issue #134** (closed): Guard suite: ambient LOOM_FORCE_SCOPE / LOOM_GUARD_DECISION_LOG silently invalidate 10 cases
- **PR #140**: test(guard): neutralize ambient guard-env vars before the suite runs
- **Issue #137** (closed): update-tools: the resync row's <this-repo>/ prefix documents intent, not target selection
- **PR #141**: docs(update-tools): clarify resync row's <this-repo>/ is not a target arg
- **Issue #135** (closed): update-tools: spot-check the Anvil and kicad-tools rows for the same never-succeeds reinstall #119 fixed for Loom
- **PR #139**: docs(update-tools): record Anvil/kicad-tools reinstall verification
- **Issue #130** (closed): guard-destructive: an inert quoted span can pair across an enclosing active span and swallow the rest of the command
- **PR #133**: test(guard): pin the inert-branch swallow whose opener sits inside the active span
- **Issue #120** (closed): /repo:tidy KEEP tier cannot express 'tracked and actively harmful' vs 'tracked but generated'
- **PR #132**: feat(tidy): split KEEP into generated vs name-collision sub-cases (#120)
- **Issue #119** (closed): update-tools: the prescribed Loom update command can never succeed on an existing install
- **PR #131**: docs(update-tools): use resync-installed.sh as Loom's update path (#119)
- **Issue #113** (closed): guard-destructive: a $(...) in a quoted span bails the lifecycle & rm-target matchers to allow
- **PR #129**: fix(guard): track an active quoted span's real close so it stops swallowing the command

### 2026-08-04

- **Issue #115** (closed): /repo:all early sync-and-switch stage: pull-failure, worktree-collision, and fetch-ordering edge cases
- **PR #128**: docs(all): fetch before resolving origin/HEAD; split the switch failure modes
- **Issue #114** (closed): release.md: PEP 621 pyproject follow-ups (uv-lock error swallowing, single-quote apply mismatch, drift-gate docs, tautological guard)
- **PR #127**: fix(release): propagate uv lock failures and bump single-quoted pyproject versions
- **Issue #103** (closed): Consider REST equivalents for the remaining GraphQL-backed gh pr/gh issue read paths in branches.md, release.md, deps.md
- **PR #126**: refactor(commands): move remaining gh pr/issue --json reads to REST gh api
- **Issue #110** (closed): gitignore/audit: don't propose deduping `X` and `X/` — trailing-slash patterns don't match symlinks (caused a live regression)
- **PR #125**: docs(gitignore): require a verified real directory before deduping `X` and `X/`
- **Issue #104** (closed): tidy inventory: prune .git by -name so nested .git directories are skipped too
- **PR #124**: fix(tidy): prune .git by -name so nested .git directories are skipped
- **Issue #97** (closed): reset/branches: the permanent-loss check is reachability-based, so on a squash-merging repo it protects every merged branch and --prune can never delete one
- **PR #123**: feat(branches): add patch-id arm and per-branch "cleared by" tags to the permanent-loss check
- **Issue #98** (closed): /repo:reset: fetch before the step-1 dirty-tree decision, so the operator isn't asked to resolve a change the remote already fixed
- **PR #122**: fix(reset): fetch in step 1 so the dirty-tree prompt knows the remote
- **Issue #102** (closed): followups step 3: REST search/issues dedup also returns pull requests, unlike the gh issue list form it replaced
- **PR #121**: docs(followups): document that REST dedup deliberately includes pull requests
- **Issue #96** (closed): installer: previously-tracked .install-local.json sidecar gets deleted from other checkouts after untracking
- **PR #118**: fix(install): untrack a previously-tracked .install-local.json sidecar
- **Issue #94** (closed): /repo:all: consider a dependency-currency check in stage 4 alongside update-tools
- **PR #117**: docs(all): extend stage 5 to report dependency currency via deps --check
- **Issue #95** (closed): verify-after-write: the `git diff` / `git status --porcelain` arm can report a reverted edit as still applied
- **PR #116**: docs(repo): make the content re-read primary in verify-after-write
- **PR #111**: feat(shell-wrapper): add codex operator + codex-safe entry points
- **Issue #108** (closed): guard: backslash-escaped \<< is still probed as a heredoc opener (residual #84/#107 deny→allow bypass)
- **PR #112**: fix(guard): do not probe a backslash-escaped \<< as a heredoc opener
- **PR #109**: feat(release): add ## version-source declaration for source-constant versions
- **Issue #84** (closed): guard-destructive: lifecycle matcher false-positives on heredoc body lines inside composite commands
- **PR #107**: fix(guard): make ml_segment() heredoc-aware so body lines are not command words
- **Issue #83** (closed): release: detect PEP 621 pyproject [project].version before the npm fallback
- **PR #105**: feat(release): detect PEP 621 [project].version ahead of the npm fallback
- **PR #106**: feat(all): sync to the default branch before Docs when the branch is fully pushed
- **Issue #86** (closed): /repo:tidy denylist should name git worktree roots explicitly
- **PR #101**: docs(tidy): denylist git worktree roots and report their size
- **Issue #85** (closed): /repo:tidy inventory uses -not -path instead of -prune; find stalls on large repos
- **PR #100**: perf(tidy): prune heavy trees in inventory find walks instead of -not -path
- **Issue #87** (closed): followups: steps 3 and 5 use GraphQL-backed gh issue subcommands and fail in exactly the busy repos the command targets
- **PR #99**: docs(followups): replace GraphQL gh issue calls with REST search + POST
- **Issue #89** (closed): /repo:all: Docs stage edits can be silently lost in a repo with a concurrent agent daemon
- **PR #93**: fix(commands): verify applied fixes are still on disk before reporting them
- **Issue #90** (closed): update-tools: add Dependabot installation and Dependabot PR review
- **Issue #88** (closed): tidy: empty dirs are classified SAFE, so tool scaffolding is auto-deleted before the ASK fallthrough can protect it

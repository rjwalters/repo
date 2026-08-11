# Work Log

Chronological record of merged PRs and closed issues, maintained automatically by the Guide triage agent.

### 2026-08-11

- **PR #259**: docs: Guide document maintenance update
- **Issue #249** (closed): No test pins sudo.md's guard note — #245's doc side can be deleted with the suite green
- **PR #256**: test(repo): pin sudo.md's guard note against the guard it describes

### 2026-08-10

- **Issue #250** (closed): sudo.md's guard note cites four line numbers with nothing checking them
- **PR #255**: docs(sudo): drop drift-prone line-number citations from guard note
- **Issue #251** (closed): test-scrub-contract.sh's bash-fence extraction is anchored and skips indented fences
- **PR #254**: fix(repo): match indented bash fences in test-scrub-contract.sh
- **Issue #245** (closed): #244 blocks /repo:sudo's rollback and cleanup rm paths; sudo.md documents only the write side
- **PR #248**: docs(sudo): document rm-scope denial on all four sudo.md rm calls
- **Issue #246** (closed): SKILL.md's Commands table has no disk-drift test, unlike README's layout block
- **PR #247**: test(repo): assert SKILL.md's Commands table matches commands/repo/*.md on disk
- **Issue #239** (closed): guards.rmScope fails open on unexpanded-variable rm targets, while write confinement fails closed
- **PR #244**: fix(guard): rm-scope fails closed on unexpanded-variable rm targets
- **Issue #240** (closed): /repo:host-optimize build-tree bloat is single-repo and deletion-only; misses sibling repos and the target-dir redirect
- **PR #243**: docs(repo): sweep sibling repos for build-tree bloat and offer target-dir redirect
- **Issue #241** (closed): /repo:deps stale check: for github-actions, each workflow file is a separate manifest
- **PR #242**: docs(deps): clarify each github-actions workflow file is its own manifest
- **PR #238**: docs(changelog): record #236's checkout bump for docker-build.yml
- **PR #236**: build(deps): bump actions/checkout from 4 to 7 in the github-actions group
- **PR #237**: docs(changelog): record the nine PRs merged since v0.9.0
- **Issue #231** (closed): CI never builds the Dockerfile, so docker Dependabot bumps merge on a green check that proves nothing
- **PR #235**: feat(ci): build the Dockerfile in CI, path-filtered
- **Issue #230** (closed): /repo:deps label check only refuses "Applied by: humans", missing other reserved labels
- **PR #234**: fix(repo): /repo:deps label check refuses any reserved party, not just humans
- **Issue #229** (closed): Nothing verifies that work merged since the last tag has a CHANGELOG entry
- **PR #233**: feat(repo): flag merged PRs since the last tag missing from the CHANGELOG draft
- **Issue #228** (closed): /repo:release pre-flight should flag prose citing a version that has not shipped
- **PR #232**: feat(repo): flag prose citing an unshipped version in /repo:release pre-flight
- **Issue #225** (closed): commands/repo/sudo.md's temp-file redirect trips the same destructive-write guard as #222, but needs a different fix
- **PR #227**: docs(repo): document why sudo.md step 5's mktemp writes fail the write guard
- **Issue #222** (closed): /repo:followups step 5's documented --input "$PAYLOAD" form is denied by the destructive-write guard in Loom-managed repos
- **PR #226**: docs(repo): use literal scratch paths in followups.md step 5 filing example
- **PR #223**: build(deps): bump ubuntu from 24.04 to 26.04
- **PR #224**: build(deps): bump the github-actions group with 3 updates
- **PR #221**: chore(deps): scaffold Dependabot for github-actions and docker
- **Issue #215** (closed): README:44 cites 0.9.0 but VERSION is 0.8.1 (likely self-resolving at release)

### 2026-08-09

- **Issue #216** (closed): write_ssh_alias() can write an empty HostName, and one bad stanza makes OpenSSH reject the whole ~/.ssh/config (breaking git-over-SSH too)
- **PR #220**: fix(repo): validate write_ssh_alias() writes and stop swallowing aws_public_ip() errors
- **Issue #214** (closed): /repo:update-tools ignores "dev": true and reports symlinked dev installs as STALE
- **PR #219**: docs(repo): make update-tools.md detect and report dev-mode installs
- **Issue #213** (closed): write_ssh_alias() read-modify-writes ~/.ssh/config with no lock; concurrent /repo:remote runs can lose an alias
- **PR #218**: fix: serialize write_ssh_alias()'s SSH config read-modify-write
- **Issue #212** (closed): Nothing enforces that the README Repository layout block matches disk
- **PR #217**: test(repo): verify README's Repository layout block matches disk
- **PR #211**: docs(repo): stop the README layout block drifting file-by-file

### 2026-08-08

- **Issue #208** (closed): audit: link check false-positives on install-template trees whose links resolve at the destination
- **PR #210**: feat(links): resolve install-template tree links at their installed destination
- **Issue #207** (closed): tidy: 'empty dirs' is not a SAFE-tier signal — auto-deletes live daemon runtime paths
- **PR #209**: docs(repo): qualify empty-dir SAFE wording, add reference-scan net
- **Issue #201** (closed): deps: no guidance for vendored, installer-owned manifests — would scaffold Dependabot against files the installer overwrites
- **PR #205**: docs(deps): classify manifests as repo-owned vs installer-owned before scaffolding
- **Issue #202** (closed): stash scope guard: --git-dir/--work-tree and GIT_DIR= env-prefix shapes still reach the main stash stack
- **PR #204**: fix(guard): thread --git-dir/--work-tree and GIT_DIR=/GIT_WORK_TREE= through the stash scope guard
- **Issue #203** (closed): guard-destructive.sh: resolve_stash_cwd() crashes (awk: bs_escaped undefined) on quoted cd targets, silently bypassing the stash-scope guard
- **Issue #193** (closed): Check in the guard-equivalence harness so drift between the canonical and vendored guards stops being invisible
- **Issue #194** (closed): stash scope guard does not thread `git -C <path>`, so that shape escapes the ask
- **Issue #197** (closed): Quoting a destructive argument weakens the guard verdict (rm -rf "/" is allowed)
- **PR #198**: feat(guard): equivalence harness, git -C stash threading, and the quoting-bypass fix
- **Issue #195** (closed): No configurable positional-arg masking allowlist in the canonical guard
- **PR #199**: feat(guard): configurable ASK-tier positional-argument masking allowlist
- **Issue #196** (closed): /repo:release should flag contradictory entries within one Unreleased section
- **PR #200**: docs(repo): flag contradictory or duplicate Unreleased entries at release time
- **Issue #188** (closed): Implement Bash-tool write confinement in the canonical guard so Loom's dispatcher defers to it
- **PR #192**: feat(guard): implement write confinement and reach parity before emitting the capability marker
- **Issue #190** (closed): /repo:links: 30 findings, 0 real — code spans are scanned, and CLAUDE.md links are root-relative
- **PR #191**: fix(repo): stop /repo:links reporting code spans and root-relative paths
- **Issue #168** (closed): The canonical destructive-command guard never runs in a Loom-managed repo
- **Issue #145** (closed): tidy: offer package-manager-native pruning of orphaned node_modules content (pnpm prune / npm prune)
- **Issue #174** (closed): spike: /repo:scrub — scan a repo's full public surface (code, history, issues, PRs) for sensitive identifiers
- **Issue #186** (closed): scrub: report what CANNOT be removed — PR refs, forks and registries survive a history rewrite
- **PR #189**: feat(repo): add /repo:scrub, tidy prune tier, and honest guard-deferral docs

### 2026-08-07

- **Issue #185** (closed): scrub: sweep forks separately — search cannot see them, and they are the copies you cannot fix
- **PR #187**: feat(repo): sweep GitHub fork networks separately from code/search sweeps
- **Issue #177** (closed): repo-remote: instance launched with KeyName None despite REPO_REMOTE_SSH_KEY and existing account key pair
- **PR #182**: fix(repo-remote): always resolve and attach an EC2 key pair on launch
- **Issue #178** (closed): repo-remote: cost estimate fallback off by 20x for current-gen families, undermining the cost-consent contract
- **PR #180**: fix: scale repo-remote cost fallback by vCPU count instead of a flat rate
- **Issue #176** (closed): repo-remote: security group created with empty ingress rule; current-IP allowlisting breaks behind HTTPS proxies
- **PR #181**: fix(repo-remote): resolve-or-create a security group with verified SSH ingress
- **Issue #175** (closed): repo-remote: IS_GPU string-truthiness mislabels every instance as GPU and misroutes VcpuLimitExceeded remediation
- **PR #179**: fix(repo-remote): correct IS_GPU truthiness and VcpuLimitExceeded quota routing
- **PR #172**: docs: Guide document maintenance update
- **Issue #170** (closed): repo-remote down is not gated by the fleet marker that now guards up
- **PR #171**: fix: gate repo-remote down behind the fleet-marker guard
- **Issue #164** (closed): Design proposal: should repo-remote.sh's idle guard treat fleet-tagged/daemon-managed hosts differently at attach time?
- **PR #169**: feat: gate repo-remote reuse of fleet-marked hosts behind --force
- **Issue #165** (closed): update-tools discovery misses .kct/install-metadata.json — kicad-tools is a named family member with no path in the documented ls
- **PR #167**: fix(repo): discover .kct/install-metadata.json via bounded find sweep
- **Issue #163** (closed): repo-remote.sh idle guard: REPO_REMOTE_IDLE_SHUTDOWN_MIN=0 shuts the host down almost immediately instead of disabling the guard
- **PR #166**: fix: disable repo-remote idle-shutdown guard when IDLE_MIN<=0 instead of firing immediately

### 2026-08-06

- **PR #162**: docs: Guide document maintenance update
- **Issue #158** (closed): bug: test-session-start-handoff.sh mtime assertion is flaky on GNU stat
- **PR #161**: fix: guard mtime capture against GNU stat -f fallback corruption
- **PR #160**: docs: Guide document maintenance update
- **Issue #156** (closed): Own the tool-package installer contract normatively, and ship a consumer-side resync
- **PR #159**: feat: own the installer contract and ship a consumer-side resync
- **PR #157**: docs: Guide document maintenance update
- **PR #155**: docs: Guide document maintenance update
- **Issue #152** (closed): deps --check counts Dependabot PRs the manifest already satisfies
- **PR #154**: docs(deps): classify stale Dependabot PRs the manifest already satisfies

### 2026-08-05

- **Issue #151** (closed): Guide document-maintenance phase creates an infinite self-triggering loop of docs PRs
- **PR #153**: fix(guide): exclude docs-maintenance PRs from WORK_LOG.md new_prs scan
- **PR #150**: docs: Guide document maintenance update
- **PR #149**: docs: Guide document maintenance update
- **PR #148**: docs: Guide document maintenance update
- **PR #147**: docs: Guide document maintenance update
- **PR #146**: docs: Guide document maintenance update
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
- **Issue #80** (closed): feat(shell-wrapper): add Codex operator and safe entry points
- **PR #111**: feat(shell-wrapper): add codex operator + codex-safe entry points
- **Issue #108** (closed): guard: backslash-escaped \<< is still probed as a heredoc opener (residual #84/#107 deny→allow bypass)
- **PR #112**: fix(guard): do not probe a backslash-escaped \<< as a heredoc opener
- **Issue #81** (closed): release: no detection path for versions kept in source constants; scaffold package.json misdirects to npm
- **PR #109**: feat(release): add ## version-source declaration for source-constant versions
- **Issue #84** (closed): guard-destructive: lifecycle matcher false-positives on heredoc body lines inside composite commands
- **PR #107**: fix(guard): make ml_segment() heredoc-aware so body lines are not command words
- **Issue #83** (closed): release: detect PEP 621 pyproject [project].version before the npm fallback
- **PR #105**: feat(release): detect PEP 621 [project].version ahead of the npm fallback
- **Issue #82** (closed): /repo:all: run reset's sync-and-switch before Docs when the working branch is fully pushed
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
- **PR #92**: feat(deps): add /repo:deps for Dependabot setup and bot-PR triage
- **Issue #88** (closed): tidy: empty dirs are classified SAFE, so tool scaffolding is auto-deleted before the ASK fallthrough can protect it
- **PR #91**: fix(tidy): gate empty-dir SAFE rule on the never-delete denylist

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


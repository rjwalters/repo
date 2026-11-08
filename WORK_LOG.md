# Work Log

Chronological record of merged PRs and closed issues, maintained automatically by the Guide triage agent.

## Archives

- [2026-09](work_log/WORK_LOG_2026-09.md)
- [2026-08](work_log/WORK_LOG_2026-08.md)
- [2026-07](work_log/WORK_LOG_2026-07.md)

### 2026-11-07

- **PR #778**: chore: drop dangling worktree:return script from package.json
- **Issue #767** (closed): package.json: drop dangling worktree:return script after Loom resync removed worktree-return.sh
- **PR #772**: ci: run repo-remote.sh suite on macOS with BSD awk
- **Issue #771** (closed): CI: exercise repo-remote.sh tests on macOS (BSD awk) runner
- **PR #780**: docs: document pin-had-no-effect false positive for guard-destructive-generic pin
- **Issue #759** (closed): .loom/resync-ignore: guard-destructive-generic.sh pin no longer matches anything (resync warns 'pin had no effect')
- **PR #779**: fix: make dependabot.yml locally owned and drop review label
- **Issue #757** (closed): .github/dependabot.yml claims fleet-gitops ownership and adds loom:review-requested; rjwalters policy declares no source

### 2026-11-06

- **PR #776**: Fail pnpm test on undelegated test files (#774)
- **Issue #774** (closed): Wire test-update-tools-squad.sh into pnpm test and fail on any undelegated test suite
- **PR #762**: fix(repo-remote): stop prune emptying ssh config under BSD awk
- **Issue #754** (closed): repo-remote prune --yes empties the whole SSH config on macOS when removing 2+ aliases (BSD awk rejects newline in -v)
- **PR #753**: chore(loom): resync installed Loom to v0.19.1263
- **PR #752**: chore: repo hygiene fixes (2026-11-04)
- **PR #736**: fix: unwire our own guard entry when install defers to another guard
- **Issue #733** (closed): install.sh: deferring to another guard leaves Repo Skills' own guard hook wired but unrefreshed, and records guardHookInstalled=false against a tree that still runs it

### 2026-11-05

- **PR #763**: fix(tests): make #722 opaque-heredoc target assertion macOS-portable
- **Issue #755** (closed): test-guard-destructive.sh: three #722 opaque-heredoc cases fail on macOS (target= logical vs physical /private/var path)
- **PR #760**: docs: add docs/ index and link design records from README
- **Issue #758** (closed): docs/: add a README indexing the design/review records
- **PR #751**: feat(guard): add guards.rmAllowDirs (#747)
- **Issue #747** (closed): guard-destructive.sh: allow cleanup outside the repo, and stop parsing quoted/heredoc text as write targets

### 2026-11-04

- **PR #761**: docs(repo): point /repo:decide at loom:operator + decision block
- **Issue #756** (closed): /repo:decide points at the loom:operator-decision label, which Loom 0.19.1263 retires
- **PR #745**: docs(repo): teach update-tools and followups about squad release installs
- **Issue #744** (closed): update-tools/followups: support squad (release-path source has no git remote; document update path; legacy adoption)
- **PR #749**: docs: treat Loom-managed default branch as PR-only in /repo:docs ladder
- **Issue #748** (closed): docs destination ladder: treat Loom-managed default branch as PR-only even when unprotected
- **PR #725**: fix(guard): accurate deny for opaque interpreter-heredoc writes (#722)
- **Issue #722** (closed): worktree-isolation guard blocks a stdin heredoc whose only writes are outside the repository, reporting a write to the repo root

### 2026-11-02
- **PR #741**: fix(repo-remote): keep recently-authorized SSH ingress rules for alternating egress IPs
- **Issue #703** (closed): repo-remote: SSH ingress flip-flops between a host's two egress IPs (revokes the other as 'stale'), leaving boxes unreachable

### 2026-11-01
- **PR #685**: fix(repo): treat a failed git status as unknown, not clean
- **Issue #684** (closed): branches: a failed git status (e.g. broken submodule gitfile) reads as a clean worktree
- **PR #735**: deps: CI value `none` with a local-check substitute (#731); uv ecosystem row and scaffold (#730)
- **Issue #730** (closed): deps: ecosystem detection table lacks Dependabot's dedicated uv ecosystem
- **Issue #731** (closed): deps: define the evidence bar for PR review when the repo has no CI

### 2026-10-31
- **PR #724**: fix: skip SQL DDL scan of heredoc bodies fed to inert consumers
- **Issue #721** (closed): guards.sqlDdl blocks a gh comment or issue body whose prose contains a DDL phrase; match only commands that can execute SQL

### 2026-10-29
- **PR #677**: feat(codex): install each command as its own repo-<verb> skill

### 2026-10-23
- **PR #672**: fix(install): warn on legacy .agents mirror and ignore its sidecar
- **Issue #670** (closed): Installing over a legacy .agents mirror layout gives a non-canonical tree and leaves .install-local.json un-ignored
- **PR #714**: fix(security): pin patched Node workflow runtimes
- **Issue #713** (closed): Pin workflow Node runtime to October security releases

### 2026-10-22
- **Issue #681** (closed): Adopt one canonical remote-exec with provenance-by-construction (2run?) — retire hand-managed box clones
- **Issue #680** (closed): remote-run: refuse dirty tracked tree + record/stamp the synced HEAD SHA (remote-exec provenance)

### 2026-10-21
- **PR #709**: feat: opt-in Rust toolchain in AWS box user-data
- **Issue #708** (closed): repo-remote: bake Rust/cargo (or a prebuilt 2run) into the fit-box bootstrap so on-box 2run install works (retire onbox_2run:off)

### 2026-10-20
- **PR #701**: feat: deny Bash writes into peer worktrees under a valid LOOM_WORKTREE_PATH pin
- **Issue #694** (closed): guard: Bash writes into another agent's linked worktree are allowed (gf180-opamp #214 cases F1/F2)
- **PR #700**: feat: confine mkdir/touch/ln/install writes into the main checkout
- **Issue #693** (closed): guard: mkdir into the main checkout is not a write-confinement idiom (gf180-opamp #214 case E5)
- **PR #689**: chore(deps): bump actions/checkout from 4 to 7 in the github-actions group across 1 directory
- **PR #698**: feat: record HEAD sha and dirty flag on the box in /repo:remote step 5
- **PR #695**: docs: record owner review of guard-confinement evidence cases
- **PR #679**: docs(gitignore): explain tracked files matching an ignore rule
- **Issue #697** (closed): /repo:remote step 5: record SHA on the box, opt-in refuse dirty tracked tree
- **Issue #692** (closed): Review dated guard-confinement evidence and owner-specific cases from gf180-opamp #214
- **Issue #678** (closed): audit/gitignore: 'tracked files match an ignore rule' advice recommends dropping rules that only hide new untracked files
- **PR #686**: docs(update-tools): use Loom's recognized resync commit subject for Loom updates
- **Issue #683** (closed): update-tools: the Loom commit subject it prescribes isn't recognized by Loom's resync guard, so later resyncs block pristine files

### 2026-10-19
- **PR #690**: fix(guard): inert git-search and jq string args no longer trip DELETE-without-WHERE (#688)
- **PR #682**: docs: add remote-exec provenance requirement/owner/gap map
- **Issue #688** (closed): Guard: DELETE-without-WHERE scan denies inert git-search and jq string arguments

### 2026-10-18
- **PR #687**: chore(loom): resync vendored Loom to v0.19.1180

### 2026-10-16
- **PR #667**: fix(install): rewrite a symlinked CLAUDE.md through the link, not over it

### 2026-10-15
- **PR #671**: feat: tag and release each VERSION bump on main, record tag in install metadata
- **Issue #669** (closed): VERSION has moved to 0.24.x but there are no tags or releases since v0.16.1
- **PR #665**: repo-remote: REPO_REMOTE_NAME overrides the box name
- **Issue #664** (closed): repo-remote: allow overriding the box NAME (REPO_REMOTE_NAME / --name) so one checkout can drive a second dedicated box (e.g. a fit box separate from the build/test box)

### 2026-10-14
- **PR #662**: chore: bump version to 0.24.0 for Dependabot default flip (#654)
- **PR #661**: docs: Dependabot-first commands and docs flip (#656)
- **PR #660**: feat(org-policy): Renovate only behind explicit opt-in (#655)
- **Issue #656** (closed): Dependabot default 4/5: commands and docs flip to Dependabot-first (#638)
- **Issue #655** (closed): Dependabot default 3/5: repo-org-policy.py stops publishing Renovate by default (#638)
- **Issue #654** (closed): Dependabot default 5/5: VERSION bump for provider default flip (#638)
- **Issue #636** (closed): /repo:deps: Renovate setup must end active — detect Mend Silent mode (no Dependency Dashboard) and request mode=full
- **Issue #622** (closed): Finish Dependabot→Renovate migration: disable Dependabot PR generation
- **PR #658**: Dependabot default 2/5: Dependabot validator + CI job (#638)
- **PR #657**: Dependabot default 1/5: policy model (provider=dependabot, cooldown) (#638)
- **Issue #653** (closed): Dependabot default 2/5: Dependabot validator + CI job (#638)
- **Issue #652** (closed): Dependabot default 1/5: policy model (provider=dependabot, cooldown) (#638)

### 2026-10-13
- **Issue #140** (closed): README: embed the fleet burndown chart (one line)
- **PR #651**: fix(guard): anchor scratch-clone exemption family on CLAUDE_PROJECT_DIR (#635)
- **PR #650**: Dependabot: render dependabot.yml from the org policy
- **PR #648**: Remove Renovate config: Dependabot takes over
- **PR #647**: Dependabot: render dependabot.yml from the org policy
- **PR #646**: policy: the rjwalters account moves to Dependabot
- **PR #645**: fix(guard): qualified and +refspec force pushes to the protected branch (#634)
- **PR #644**: fix(org-policy): no Renovate App line after a dependabot apply (2AMLogic/2am#4351)
- **PR #643**: fix(guard): look through command/env/nohup wrappers for force ops (#633)
- **PR #642**: feat(org-policy): provider dependabot (2AMLogic/2am#4351)
- **PR #641**: feat(repo-remote): stable name, alias cleanup on terminate, prune (#628)
- **PR #640**: fix(guard): judge force-op reset by the --work-tree it rewrites (#632)
- **PR #639**: fix(guard): treat zsh directory-stack cd (+N/-N, ~+/~-) as unknown cwd (#626)
- **PR #631**: fix(guard): cd to a missing directory leaves the cwd unknown (#625)
- **PR #630**: repo-remote: require a per-user GitHub App token (device flow) for attach (#627)
- **PR #615**: guard: decode quoted force-op words and model --git-dir/--work-tree (#612)
- **Issue #635** (closed): guard: the scratch-clone exemption allows a force op aimed at the main checkout from an unrelated clone
- **Issue #634** (closed): guard: qualified or +refspec force pushes to the protected branch (HEAD:refs/heads/<branch>) are not recognized
- **Issue #633** (closed): guard: force ops behind command/env/nohup wrappers (command git reset --hard) are not parsed
- **Issue #632** (closed): guard: git --work-tree <main> from a worktree rewrites the protected checkout and is allowed
- **Issue #628** (closed): repo-remote: make it reliable & declarative — GC stale ssh-config aliases, consistent host naming, additive SG, sourced creds
- **Issue #627** (closed): repo:remote: require a per-user GitHub App user access token (device flow) for VM sessions
- **Issue #626** (closed): guard: zsh cd +N / -N (directory stack) and pushd/popd are misread as relative paths
- **Issue #625** (closed): guard: a ;-chained write after a cd to a missing directory lands in the protected checkout
- **Issue #612** (closed): guard: quoted git subcommand/flags and --git-dir/--work-tree hide force ops from parse_force_ops
- **PR #611**: guard: cwd trackers see a cd behind a leading redirection and cd options (#604)
- **Issue #604** (closed): guard: cwd trackers miss a cd behind a leading redirection (>/dev/null cd X) and cd options (cd -P/-- X)

### 2026-10-12
- **PR #621**: chore(deps): adopt Renovate via the rjwalters/.github preset
- **PR #620**: fix(repo-remote): per-caller SSH ingress marker so one host can't revoke another's rule (loom#11616)
- **PR #560**: feat(install): persisted --no-guard opt-out for destructive guard hook
- **Issue #557** (closed): install.sh: per-repo opt-out so a reinstall does not re-wire the guard-destructive PreToolUse hook
- **PR #624**: org-policy check-app: report Renovate on personal accounts from activity evidence
- **Issue #623** (closed): org-policy check-app: report Renovate installation from behavioral evidence on personal accounts instead of a bare UNKNOWN
- **Issue #579** (closed): Guard: upstream Loom's vendored-only guard functions so Loom can re-vendor in full and pick up the tmpfs refusal
- **PR #618**: repo-remote: opt-in AWS Spot launch via REPO_REMOTE_MARKET (#616)
- **Issue #616** (closed): repo-remote: optional Spot launch (one-time, terminate on interruption/shutdown)

### 2026-10-11
- **PR #614**: guard: resolve git -C paths with whitespace for force ops (#608)
- **Issue #608** (closed): guard: git -C with a whitespace path fails open for force ops under forceScope: protected
- **PR #610**: guard: cwd trackers follow control flow conservatively (#601)
- **Issue #601** (closed): guard: cwd trackers ignore control flow (short-circuit cd, pushd, eval, functions, case arms)

### 2026-10-10
- **PR #606**: guard: force-op scratch exemption knows the whole repository family (#602)
- **Issue #602** (closed): guard: force-op scratch exemption treats the main checkout as outside known roots from a worktree cwd
- **PR #607**: policies: 2AMLogic preset turns the Dependency Dashboard off
- **PR #605**: policies: add the 2AMLogic organization override
- **PR #603**: fix(guard): recognise disguised cd spellings in the cwd trackers (#600)
- **Issue #600** (closed): guard: cwd tracker misses quoted/escaped cd spellings (c''d, c\d, "c"d, ${C:-c}d)
- **PR #599**: guard: same-command mktemp /tmp template is proven /tmp-rooted for write-confinement (#597)
- **Issue #597** (closed): Write-confinement: treat same-command NAME=$(mktemp -d /tmp/<prefix>.XXXX) as proven /tmp-rooted

### 2026-10-09
- **Issue #159** (closed): T1 item 11: declare ties[] in the array supply spec, re-run klt erc, and cite the ERC and LVS reports together
- **PR #595**: Guard: reconcile Loom environment, service, stash and index rules (#585)
- **Issue #585** (closed): Guard: reconcile Loom environment service stash and index rules
- **PR #594**: guard: port Loom read-only fast path pipelines, reserved extras, tiered config (#584)
- **Issue #584** (closed): Guard: reconcile Loom read-only fast path and configuration precedence

### 2026-10-08
- **Issue #150** (closed): Guard-decision review: rm-scope-unresolved-var never got its own #3898 review, propose keep-flagged
- **PR #592**: Guard: reconcile Loom write confinement and managed worktree rules (#582)
- **PR #591**: Guard: port cargo clean scope while preserving tmpfs target-dir resolution
- **Issue #583** (closed): Guard: port cargo clean scope while preserving tmpfs target-dir resolution
- **Issue #582** (closed): Guard: reconcile Loom write confinement and managed worktree rules
- **PR #588**: Guard: port rm-scope session scratch and same-command resolution (#581)
- **PR #587**: Guard: port Loom --search/jq --arg masking and gh body @path denies (#580)
- **Issue #581** (closed): Guard: reconcile Loom rm scope and session scratch allowances
- **Issue #580** (closed): Guard: port Loom literal masking and gh body-file misuse checks

### 2026-10-07
- **PR #576**: fix(optimize-ci): cache false positives for version keys and shared matrix caches
- **Issue #574** (closed): optimize-ci: false positives for version-keyed caches and matrix legs that share one cache
- **PR #575**: optimize-ci: per-workflow run sampling with true totals and job spread
- **Issue #573** (closed): optimize-ci: default run sample is far too small on busy repos, and bursty workflow_run workflows crowd it out
- **PR #571**: feat(remote): per-session GitHub credentials via repo-remote attach (#565)
- **PR #569**: optimize-ci: cover push-only default-branch workflows; measure overlap and heavy main suites
- **Issue #566** (closed): optimize-ci: cover push-only default-branch workflows, and measure default-branch overlap and scheduled batching of heavy main suites
- **PR #567**: feat(remote): optional SSM Session Manager transport for AWS
- **Issue #564** (closed): repo-remote: optional SSM Session Manager transport (instance profile at launch, no inbound :22)
### 2026-10-06
- **PR #563**: fix(repo-remote): pin IMDSv2 hop-limit-1 metadata options on AWS launch
- **Issue #562** (closed): repo-remote: pass --metadata-options HttpTokens=required,HttpPutResponseHopLimit=1 on run-instances (launches IMDSv1 / hop 2 today)
### 2026-10-05
- **PR #561**: feat: launch AWS root volume as gp3 and warn on gp2 roots at reuse
- **PR #558**: followups: attribute filed issues with a requested-by marker (#556)
- **Issue #559** (closed): repo-remote (AWS): root volume launches as gp2 (default) — burst credits drain under sustained builds/tests and the box crawls; launch gp3 and expose REPO_REMOTE_VOLUME_TYPE/IOPS/THROUGHPUT
- **Issue #556** (closed): /repo:followups: write a <!-- loom:requested-by login=… via=… --> marker naming who asked
### 2026-10-03
- **Issue #144** (closed): Guard telemetry review 2026-09-28: all four logged patterns confirmed correct denials (keep flagged)
- **Issue #126** (closed): OPERATOR: bronze (T1) grant decision — 10/10 read since 2026-08-22, all holes closed, item 11 now outstanding
- **PR #555**: fix(guard): single-quoted spans inert in vendored qsplit() (#447)
- **Issue #447** (closed): Upstream the repo#443 single-quoted-span inertness fix to Loom's vendored guard
### 2026-10-02
- **PR #554**: fix: locale-independent 403 assertion in deps alerts test
- **Issue #553** (closed): test-deps-dependabot-alerts.sh: 403 assertion fails under C/unset locale
### 2026-10-01
- **PR #552**: feat: report open Dependabot alerts in deps --check and /repo:all
- **PR #550**: fix(guard): never pair an escaped quote as a span close or opener
- **Issue #551** (closed): deps --check (and /repo:all) does not report open Dependabot security alerts
- **Issue #548** (closed): guard: an escaped \" in a double-quoted span hides a write into the main checkout
### 2026-09-30
- **Issue #141** (closed): loom:curating claim label stuck on PR #139 for 2+ days — Curator dispatch mismatched a PR number for an issue
- **PR #549**: fix(guard): make subst_depth() quote-aware inside an open $( ) substitution
- **PR #547**: fix(guard): port the repo#436/#437 separator-inside-$( ) fixes to Loom's vendored guard
- **PR #546**: fix(guard): port repo#439 subst_heads() into Loom's vendored guard
- **PR #544**: feat(guard): classify the ambient effective cargo target dir in tmpfsScratch (#462)
- **PR #543**: docs(repo): add a branch+PR destination arm and consolidate the ladder into docs.md
- **PR #542**: fix: stop version.sh bump/set from committing mid merge/rebase/cherry-pick
- **PR #541**: perf(tidy): batch the reference scans and add a --fast/--deep cost dial
- **PR #540**: fix(remote): warn when a linked worktree's in-tree .env is read or written (#538)
- **PR #537**: docs(update-tools): land tool bumps via branch+PR when default branch is protected
- **PR #534**: fix(gitignore): model anchoring and gate rule removals on git check-ignore
- **PR #529**: New /repo:browser environment command — browser-automation stack health + confirm-gated installs (#528)
- **PR #461**: feat(guard): deny a build/scratch dir that resolves onto a tmpfs mount
- **PR #442**: fix(guard): reach into a quoted single-command $( ) for write-target extraction
- **PR #433**: fix(guard): a backslash-escaped backtick no longer vetoes span masking
- **Issue #545** (closed): Port the repo#436/#437 separator-inside-$( ) fixes to Loom's vendored guard
- **Issue #539** (closed): guard: quote-blind subst_depth() lets a quoted ')' inside $( ) hide a write into the main checkout
- **Issue #538** (closed): repo-remote writes .env into the caller's working directory (instance pin), working against repo secrets hygiene
- **Issue #536** (closed): scripts/version.sh set auto-commits, so running it mid-merge creates a commit without the caller's trailers
- **Issue #535** (closed): gitignore anchoring table mis-classifies `dir/**/name` as unanchored, and the removal gate's `ipaths()` is masked by a global excludesFile
- **Issue #532** (closed): docs/gitignore/links destination ladder has no branch+PR arm for PR-protected repos without an issue number
- **Issue #533** (closed): tidy inventory exceeds the command timeout on very large repos (git clean -ndX plus per-directory git grep)
- **Issue #531** (closed): gitignore redundancy check ignores pattern anchoring; require git check-ignore verification before applying
- **Issue #530** (closed): update-tools step 5 lands on the local default branch; unpushable when the default branch is PR-protected
- **Issue #528** (closed): New /repo:browser environment command — check (and confirm-gated install) the fleet-standard browser-automation stack (Browser Use CLI + official skill + auth/credits health)
- **Issue #462** (closed): guards.tmpfsScratch misses the ambient effective target dir (exported CARGO_TARGET_DIR, pre-existing .cargo/config.toml build.target-dir)
- **Issue #454** (closed): Guard: refuse a build/scratch dir assignment that resolves onto a tmpfs mount
- **Issue #441** (closed): Upstream the repo#439 quoted-$( ) write-confinement fix to Loom's vendored guard
- **Issue #439** (closed): Worktree-write-confinement: a quoted single-command $( ) substitution writes into the main checkout in both guards

### 2026-09-29
- **Issue #153** (closed): Consolidate duplicated PVT corner-matrix constants: compare_records.py should reuse render_signoff_table's CORNER_ORDER
- **Issue #149** (closed): Remove duplicated latest_mc_record_for_claim: reuse signoff.latest_record_for_claim
- **Issue #524** (closed): test: hooks/repo/tests fixtures are not hermetic against inherited core.hooksPath (git-fixture.sh header claims they are)
- **PR #525**: test: remove stray `.` line and mojibake left by the #518 adoption commit
- **Issue #518** (closed): test-changelog-merged-work-check.sh fails under Loom dispatch: provenance-hook trailers leak into fixture commits
- **PR #523**: test: make git fixtures hermetic against inherited core.hooksPath
- **Issue #515** (closed): /repo:followups: a PR dedup match can be proposed and executed as a duplicate close (match type is never enforced)
- **PR #521**: fix(followups): enforce dedup match type so a PR is never closed as a duplicate
- **Issue #511** (closed): /repo:scrub has no repo-local extension point, and Repo Skills has no resync-ignore — a consumer's wiring was deleted by reinstall four times
- **PR #519**: feat(installer): add repo-owned pins (C10) and a /repo:scrub local-check hook
- **Issue #520** (closed): test-changelog-merged-work-check.sh case 5 fails under Loom sweep dispatch (provenance trailers leak into its fixture commits)
- **Issue #507** (closed): ci: scope cancel-in-progress to PRs so main pushes are never cancelled
- **PR #517**: ci: scope cancel-in-progress to pull requests in both workflows
- **Issue #510** (closed): update-tools: frozen-component row suppresses a number step 4 still needs (follow-up to #509)
- **PR #516**: fix(update-tools): step 3/4 consistency, example table, installer path
- **PR #514**: chore: resync installed Loom surfaces (0.19.487 → 0.19.498)
- **PR #513**: chore(hygiene): ignore .squad/; document repo-org-policy.py and policies/
- **PR #512**: docs(changelog): 0.16.1 release notes
- **Issue #504** (closed): update-tools: per-component staleness — a tool's top-level version can be a partial claim (anvil skipped_overrides/skill_versions)
- **PR #509**: update-tools: frozen-component drift as a third staleness dimension (#504)
- **Issue #505** (closed): feat: /repo:optimize-ci — audit CI for change-relevance filtering, caching, and wasted runs
- **PR #506**: feat: /repo:optimize-ci — audit CI for path filtering, caching, and wasted runs (#505)
- **Issue #503** (closed): test-handoff-preflight: pin the rationale block itself, and strengthen four token-shaped pins
- **PR #508**: test(handoff): pin the rationale block itself, strengthen four token pins

### 2026-09-28
- **PR #502**: test(handoff): pin the doc/test split's keystone, plus two weak spots
- **Issue #499** (closed): Compress /repo:handoff step 0 — 45% of an installed command file is preflight rationale
- **PR #501**: refactor(handoff): compress step 0 to a checklist, move the why to the tests
- **Issue #498** (closed): handoff step 0: absent settings.json is misrouted to the by-hand repair row
- **PR #500**: fix(handoff): stop misrouting an absent settings.json to a by-hand repair
- **Issue #493** (closed): /repo:handoff never verifies the SessionStart hook that reads the note it writes
- **PR #494**: feat(handoff): verify the note has a reader before writing it
- **Issue #496** (closed): repo-remote: remote.md config-loading snippet inverts REPO_REMOTE_ENV_FILE precedence; tilde test does not exercise expand_tilde
- **PR #497**: fix(remote): env REPO_REMOTE_ENV_FILE beats the shared file in the doc snippet; test expand_tilde for real
- **Issue #492** (closed): repo-remote.sh: per-repo config (and instance-id write-back) is hardwired to <git-root>/.env; allow an out-of-tree location
- **PR #495**: repo-remote: REPO_REMOTE_ENV_FILE override; never auto-create <git-root>/.env
- **Issue #490** (closed): install.sh copies the unused guard-destructive.sh even when it defers to an existing guard
- **PR #491**: install.sh skips copying guard-destructive.sh when a guard already exists

### 2026-09-26
- **Issue #463** (closed): test-repo-remote.sh: SSH-readiness retry assertion flakes under CI load (1s margin)
- **PR #489**: test-repo-remote.sh: widen SSH-readiness timeout margin (repo#463)
- **PR #486**: Add /repo:decide: operator decisions as ranked options, best to worst, each with why
- **Issue #487** (closed): repo-remote (AWS): fail closed on SSH CIDR — no silent 0.0.0.0/0 fallback, validate REPO_REMOTE_SSH_CIDR, revoke stale /32s
- **PR #488**: fix(repo-remote): fail closed on SSH ingress — no silent 0.0.0.0/0 fallback, validated override, revoke stale /32s
- **Issue #481** (closed): /repo:deps has no guidance for sibling supersession or lockfile conflicts between bot PRs
- **PR #484**: docs(deps): classify sibling supersession and serialize lockfile-bearing merges

### 2026-09-25
- **Issue #482** (closed): Guard-hook logs land in a non-ignored path under the tool root, so every consumer must add the same .gitignore rule — ship a self-ignoring logs/ instead
- **PR #485**: fix(hooks): ship a self-ignoring logs/ so consumers need no .gitignore rule for hook runtime logs
- **Issue #479** (closed): /repo:deps blames missing admin for an absent security_and_analysis — but it is absent on private org repos with full admin
- **PR #483**: feat(deps): report security updates as enabled/paused/disabled
- **Issue #480** (closed): /repo:deps stale-check compares npm PRs against the manifest range, so a caret range marks every real upgrade stale
- **Issue #469** (closed): repo-org-policy.py: ambiguous absent/inaccessible error, unconstrained preset visibility, no handoff to deps
- **PR #477**: feat(org-policy): disambiguate an absent target, constrain preset visibility, hand off to deps
- **Issue #470** (closed): deps: label refusal silently disables Loom bot-PR review routing on Loom-managed repos
- **PR #476**: docs(deps): report when label refusal leaves bot PRs unrouted on Loom-managed repos
- **Issue #471** (closed): deps: file a follow-up issue for the deferred Dependabot shutdown instead of only reporting it
- **PR #475**: feat: offer a durable follow-up issue for the deferred Dependabot shutdown
- **Issue #467** (closed): org-policy/deps can report success while Renovate is not installed, leaving the org inert
- **PR #474**: feat: verify Renovate App installation in org-policy and deps reports
- **Issue #466** (closed): assert_matches() in commands/repo/tests/lib/assert.sh: intermittent false FAIL from SIGPIPE under set -o pipefail
- **PR #473**: fix: replace printf|grep pipe with here-string in assert_matches() to avoid SIGPIPE races
- **Issue #468** (closed): deps: no org-wide mode for migrating repos from Dependabot to Renovate
- **PR #472**: feat(deps): add --all-repos org-wide migration survey mode
- **Issue #464** (closed): /repo:followups: step 3c only warns even when the source repo's CLAUDE.md forbids outward writes
- **PR #465**: feat(followups): support source_confidential = "block" firewall mode

### 2026-09-22
- **PR #445**: feat: install canonical organization dependency policy from clients
- **Issue #458** (closed): repo-remote: stale SSH alias + auto-assigned public IPs silently re-point a project at a stranger's instance
- **PR #460**: feat(repo-remote): verify the host identity behind the SSH alias
- **Issue #451** (closed): repo-remote: idle guard stops instances mid-build with no held SSH session; stop/start churns public IP, alias + SG ingress go stale
- **PR #457**: fix(repo-remote): refresh SSH ingress on every reuse path and poll for the public IP
- **Issue #453** (closed): Guard: acn==0 is not a sound 'top level' proxy — a nested $( ) with a quote phantom-closes the active span, re-opening the #450 apostrophe hole
- **PR #459**: fix(guard): a nested $( ) quote must not phantom-close the active span (#453)
- **Issue #448** (closed): /repo:all doc fixes applied in a Loom primary checkout are quarantined by the next sweep; land them on a branch or warn
- **PR #456**: fix(repo): land /repo:* doc fixes where a sweep cannot quarantine them
- **Issue #449** (closed): repo-remote: wait for fresh-instance SSH readiness before declaring provisioning failure
- **PR #455**: fix(repo-remote): wait for fresh-instance SSH readiness before declaring provisioning failure
- **Issue #450** (closed): Guard regression from #446: an apostrophe inside a LIVE double-quoted span makes a real executing $( ) inert, allowing a destructive command
- **PR #452**: fix: scope single-quoted-span inertness to the top level of ml_segment()
- **Issue #443** (closed): rmScope guard denies rm inside a remote command string (ssh host '…') — classify remote deletions separately and default them to ask
- **PR #446**: fix(guard): treat single-quoted spans as inert in ml_segment() (#443)

### 2026-09-21
- **Issue #133** (closed): layout/reports/README.md's array-level LVS section is stale: documents mismatch, lvs-array.json now reads match
- **Issue #128** (closed): Machine-gradeable T1 rows: re-mint LVS input provenance, a klt sim envelope, and repo-relative MC yield records so signoff items 4-6 can verify
- **Issue #127** (closed): Guard-decision review: scratch-var exemption misses the klt/KLayout layout cold-start idiom (inline ./layout/verify.sh reproduction denied), propose extending the #65 exemption
- **Issue #125** (closed): Commit a klt signoff block manifest so this block's T1 state is graded, not hand-read
- **Issue #124** (closed): T1 item 11 (power delivery, structural): no klt erc supply spec or report in this repo

### 2026-09-19
- **Issue #438** (closed): test-guard-equivalence.sh cannot see worktree-write-confinement divergences: every case runs from a cwd with no sibling worktree
- **PR #440**: test: run guard-equivalence cases from a real Loom worktree cwd

### 2026-09-18
- **Issue #436** (closed): guard-destructive.sh: qsplit() mis-splits a quoted redirect target's $(...) at an embedded pipe, causing false worktree-write-confinement DENY
- **PR #437**: fix(guard): stop qsplit() splitting the outer stream at a separator inside $( )
- **Issue #434** (closed): guard: query-sink vetoes read the masked command copy, so an earlier masking pass can hide a veto token (residual from #428)
- **PR #435**: fix(guard): run the data-sink pass before literal-text redaction so a masked span cannot hide a query-sink veto
- **Issue #311** (closed): Auditor: guard-destructive fires on dangerous substrings inside test/data strings, not just executed commands
- **PR #428**: fix(guard): treat jq/grep/sed/awk query text as data, not a command (#311)

### 2026-09-15
- **Issue #432** (closed): merge-pr.sh: _check_champion_hold_state_staleness aborts the whole script on a PR with no champion:hold-state marker
- **Issue #429** (closed): guard: command_has_shell_segment() misses a shell reached through xargs/parallel
- **PR #431**: fix(guard): recognize xargs/parallel as a shell-spawning segment
- **Issue #430** (closed): merge-pr.sh: _check_champion_hold_state_staleness crashes under set -euo pipefail when no champion:hold-state marker exists
- **Issue #257** (closed): Handoff note in another repo is invisible from the repo you start in
- **PR #427**: feat(hooks): opt-in sibling-repo handoff-note visibility (#257)
- **Issue #282** (closed): Add dual-runtime Claude and Codex packaging for Repo Skills


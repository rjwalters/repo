# Guard-confinement evidence review (gf180-opamp #214)

Owner review of the evidence handoff filed as this repo's #692. It classifies
each of the 29 inert synthetic cases against the canonical generic Bash guard,
`hooks/repo/guard-destructive.sh`. It is a review record only: no guard, hook,
settings or CI change is made or authorized by it.

## Sources (pinned, SHA-256 verified before use)

All three are from `2AMLogic/gf180-opamp@29fdfa1e798409280958314d9b7d07462ebc109f`;
hashes were recomputed on the fetched bytes and match the hashes in #692.

| Source | SHA-256 |
| --- | --- |
| `docs/guard-confinement-reproduction.md` | `0975ec8db83b097c7c27f95a26c43d76b5d6d5765ae765799f68fca21e8047d7` |
| `docs/fixtures/guard-confinement-cases.json` | `230be55be97aeda49d10860c9051e251483199e1d9487350d02d13c0d5b96cba` |
| `scripts/guard-confinement-repro.sh` | `6193148b76b19ead642d130c1dfc0ba4f9f9c462de06f0147790c4c8ed0b1f50` |

The reproducer script was **read, not executed**. Payloads were fed to the
guard on stdin only, never eval'd, by a throwaway runner kept outside the
repo. The runner built a fresh `mktemp` git fixture (main checkout + two
`.loom-managed` worktrees `issue-1` / `issue-2` + external scratch dir + a
scratch symlink to `issue-2`) and ran the guard with cwd per the fixture.
`REPO_*` / `LOOM_*` guard toggles were unset.

## Limitations (carried over, plus this review's own)

- Hook-only: the guard script was run directly. Canonical `.claude/settings.json`
  matcher wiring was not exercised.
- Sessions with `LOOM_WORKTREE_PATH` set were not exercised.
- The two reported 2026-10-11 denials remain attributed and unverified. No
  original command text was recovered and none was reproduced here.
- The downstream run used Loom's vendored `guard-destructive-generic.sh`. This
  review ran the **canonical** guard, so differences from the downstream
  table are expected and are not regressions on either side.
- The Edit/Write-tool chain (F3-F5) is `guard-worktree-paths.sh`, which is
  Loom-owned and not in this repo; those cases were not run.
- Review basis: `origin/main` @ `e8c7e61`.
- Peer-worktree separation (2026-10-20 follow-up below) is an accidental-interference
  guard only: hook-only substring parsing, not complete shell parsing; an
  environment variable is not authentication of who is acting; it is not a
  malicious-agent sandbox. The Edit/Write chain (F3-F5) remains Loom's.

## Case mapping

Result column = decision from the canonical guard in the fixture. "Covered"
cites `hooks/repo/tests/test-guard-destructive.sh` at that commit.

| Case | Fixture expects | Canonical result | Classification |
| --- | --- | --- | --- |
| A1 literal `>` to scratch | allow | allow | Covered: `:4992` (`echo x > /tmp/wtc-scratch-$$.txt`, sibling worktree present) |
| A2 quoted body path (printf) | allow | allow | Covered by shape: `:4992` plus quote-aware redirect cases (#4245 family, `:5577`-`:5791`); no byte-identical `printf ... > "path"` case |
| A3 heredoc body to scratch | allow | allow | Covered by shape: heredoc masking (#5000) plus `:4992`; no byte-identical case |
| B1 literal var, redirect | allow | allow | Covered: #293 resolver, `:4302` and the surrounding #293 block (`:4283`-`:4312`) |
| B2 literal var, quoted | allow | allow | Covered: `:4302`, plus the quoted redirect-target case in the same block |
| C1 `D=$(mktemp -d); > $D/x` | record | allow | Covered: #293/#582 proven same-command `mktemp -d` (`:4346`) |
| C2 `mktemp -d <tmpl>` + cp | record | deny (`-unresolved-var`) | Intentionally differs: #597 admits `mktemp -d /tmp/<prefix>.XXXX`. The fixture's template is nested deeper (`<scratch>/c2-XXXXXX`) and fails closed. Verified: `/tmp/c2-XXXXXX` allows, nested template denies. Pinned deny shapes: `:4374`-`:4390` |
| C3 mktemp, quoted write | record | allow | Covered: as C1 with quoting |
| C4 inline `> $(mktemp -d)/x` | record | deny (`-unresolved-var`) | Intentionally differs: provenance proof needs a same-command `NAME=$(mktemp ...)`; inline substitution has no binding. Pinned by `:4371` ("no assignment stays unresolved") |
| D1 checkpoint delete | record | allow | No write target in the segment, so the guard has no role-owned exemption and needs none (nothing to cover or differ) |
| D2 lease release | record | allow | As D1 |
| D3 registry cleanup | record | allow | As D1 |
| D4 follow-up body to `/tmp` | allow | allow | Covered: `:4992` |
| D5 bundle of D1-D4 (wt cwd) | record | allow | As D1; the `/tmp` redirect segment is covered by `:4992` |
| D6 bundle from main cwd | record | allow | As D5. The segment contents contain no main-checkout write target, so allow is consistent with `:4138` |
| E1 unresolved `$V/fresh.json` | deny | deny (`-unresolved-var`) | Covered: `:4239` ("unexpanded `$VAR` write target fails closed") |
| E2 var rebound to main | deny | deny (`-unresolved-var`) | Covered: `:4333` (conflicting reassignment poisons the variable) |
| E3 rebound main then scratch | record | deny (`-unresolved-var`) | Covered: `:4333`; conflicting bindings fail closed |
| E4 literal `>` into main | deny | deny (`worktree-write-confinement`) | Covered: `:4138` + tag check `:4153`-`:4170` |
| E5 `mkdir -p` into main | deny | **allow** | **Gap vs fixture**: `mkdir` is not among the guard's write idioms (`>`, `>>`, `tee`, `sed -i`, `cp`, `mv`), and `:662` pins generic `mkdir` as allow. Follow-up #693. Guard not changed here |
| E6 relative `>` with main cwd | deny | deny (`worktree-write-confinement`) | Covered: cwd-relative cases `:4537`-`:4670` |
| E7 scratch then unresolved | deny | deny (`-unresolved-var`) | Covered: `:4239`, `:4333` (a safe write earlier in the command does not weaken the unresolved check) |
| E8 scratch then main | deny | deny (`worktree-write-confinement`) | Covered: `:4138` (any one main-checkout segment denies the command) |
| E9 mktemp then main | deny | deny (`worktree-write-confinement`) | Covered: `:4138` + `:4346` (mktemp proof does not whitelist other segments) |
| F1 `>` into another agent's worktree | deny | **allow** | Intentionally differs, with a policy question filed (#694): the guard accepts any registered linked worktree (Loom #7415 / #4245 trust boundary, `guard-destructive.sh:9308`-`9325`) and cannot tell which belongs to the acting session. Pinned allow: `:7696`-`:7701` |
| F2 `>` via symlink to it | deny | **allow** | As F1 (no per-agent identity when `LOOM_WORKTREE_PATH` is unset) |
| F3 Write tool into it | deny | not run | Out of scope: `guard-worktree-paths.sh` is Loom-owned |
| F4 Write tool via symlink | deny | not run | As F3 |
| F5 Write tool, own worktree | allow | not run | As F3 |

Totals (26 Bash-chain cases run): 13 MATCH against the fixture's allow/deny
expectation, 10 RECORDED (the fixture presumed no contract: C1-C4, D1-D3, D5,
D6, E3), 3 allow-vs-deny differences (E5, F1, F2). C2 and C4 are intentional
fail-closed differences. The 3 Write-tool cases (F3-F5) were not run. Cases
marked "covered" were judged by reading the cited test and re-running the
payload, not by replaying the suite.

## Negative controls (E1-E9, F1-F4): none dropped

E1-E4 and E6-E9 map to existing cases above and still deny. E5 and F1-F2 do
not deny on the canonical guard (recorded, not hidden); F3-F4 were not
exercised because their guard is outside this repo. The fixture's expected
deny for each of E5/F1/F2 is preserved in the pinned source JSON, whose hash
is recorded above, so the controls remain available to whoever owns the
decision.

## Follow-ups

Filed at `loom:triage` (#693, #694); neither is a claim of a present defect and neither
was authorized to change behavior here:

- #693, E5: should `mkdir` (and similar creators such as `touch`, `ln -s`, `install`)
  into the main checkout be a confinement write idiom?
- #694, F1/F2: should writes into another agent's linked worktree be confined, given
  the guard has no per-agent identity without `LOOM_WORKTREE_PATH`?

## Follow-up 2026-10-20: F1/F2 under a valid pin (#694)

Owner ruling 2026-10-19 (option 1): F1/F2 now **deny only when a valid inherited
`LOOM_WORKTREE_PATH` identifies the acting session's worktree**. The table above is
unchanged and still describes the unpinned behavior (allow).

- **valid** pin: absolute, resolves to a directory, and its physical path equals the
  root of a real linked worktree in `git worktree list` (never the main root or an
  ancestor). Recognized Bash writes (redirect, `tee`, `cp`, `mv`, `sed -i`, any symlink
  or `..` spelling) into a *peer* worktree then deny, tag `worktree-write-confinement-peer`.
  A nested unmanaged worktree under main still allows; one inside the pinned worktree
  is own; one inside a peer belongs to that peer.
- **unset** or **invalid** (relative, nonexistent, plain directory, a path inside a
  worktree, main root/ancestor, `/`): behavior unchanged, no new deny.
- Identity is only the hook process's own inherited variable. A command-local
  `LOOM_WORKTREE_PATH=...`, `export ...;` or `env ...` never counts. cwd is never used.
- Same `guards.worktreeIsolation` toggle as the rest of the confinement; turning it off
  also drops main-checkout protection (unchanged coupling).
- **Handoffs:** use git (commit/push, the other session fetches), a forge comment, or a
  scratch file. A direct Bash write into another session's worktree is what now denies.
  If a launcher ever exports one pin for a process that legitimately writes to several
  worktrees it will see denies; the launcher is Loom's and was not traced here.

## Follow-up note, 2026-10-20 (#693)

The owner selected option 1 for E5: `mkdir`, `touch`, `ln` and `install` destinations
are now write-confinement idioms in `hooks/repo/guard-destructive.sh`
(`creator_targets()`), so E5 now denies with `worktree-write-confinement`. The E5 row
and the pinned-hash table above are dated evidence of `e8c7e61` and are unchanged.
Limits: hook-only; abbreviated long options, command substitution, brace expansion and
globs are not parsed; not a shell sandbox. #694 is unaffected.

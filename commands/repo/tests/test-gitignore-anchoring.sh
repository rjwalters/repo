#!/usr/bin/env bash
# Test suite for /repo:gitignore's redundancy model and its ignore-status gate —
# the two things that stand between "these two rules look the same" and
# "removing one of them is safe".
#
# Usage: ./commands/repo/tests/test-gitignore-anchoring.sh
# Exit code 0 = all tests pass, 1 = failures detected.
#
# Structured like commands/repo/tests/test-verify-fix-persistence.sh: pure bash,
# no test framework, a fixture section that exercises a faithful transcription of
# the documented check against real `git check-ignore` behavior, then a doc-drift
# section asserting the command files still say what this suite implements.
# `pnpm test` delegates to this file via hooks/repo/tests/run.sh.
#
# WHY THIS FILE EXISTS (repo#531): /repo:audit reported `proofs/.gitignore:
# .vscode/` as redundant with the root `.gitignore`'s `.vscode/*` and recommended
# dropping it. It is not redundant — `.vscode/*` contains a non-trailing slash, so
# it is anchored to the directory of the `.gitignore` that declares it and never
# reaches `proofs/.vscode/`. The removal would have un-ignored the whole subtree,
# and was caught only because a `git check-ignore -v` pass ran before the commit.
#
# The contract under test:
#   1  a rule is redundant only if a rule in the SAME OR AN ANCESTOR .gitignore
#      matches the same paths from where that rule sits — anchored ancestor
#      patterns (`/x`, `dir/x`, `dir/*`, and `dir/**/x`: only a LEADING `**/`
#      un-anchors) never cover a subdirectory; unanchored ones (`x`, `*.log`,
#      `**/x`) do
#   1b the gate's own snapshot function carries `core.excludesFile=/dev/null`, so
#      a host-global exclude cannot mask a real difference (repo#535)
#   2  before applying a removal or narrowing, the ignored-path set is captured
#      before and after; any difference REFUSES the edit (report as a finding,
#      do not count as applied)
#   3  the rule-attribution diff is NOT the gate — a genuine dedupe moves
#      coverage to the surviving ancestor rule, which is expected and reported
#   4  the per-rule verification result appears in the report, including when the
#      fixes come from /repo:all's Audit stage

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CMD_DIR="$REPO_ROOT/commands/repo"
GITIGNORE_MD="$CMD_DIR/gitignore.md"
AUDIT_MD="$CMD_DIR/audit.md"

# Assertion helpers (ok/no/skip/assert_eq/assert_contains/assert_not_contains/
# assert_matches) plus the PASS/FAIL/SKIP/TOTAL counters and color vars are
# shared across the repo test suites — see lib/assert.sh (repo#307).
source "$(dirname "${BASH_SOURCE[0]}")/lib/assert.sh"

# Fixture hermeticity (repo#518): a Loom-dispatched session overrides
# core.hooksPath through GIT_CONFIG_* env pairs, which fixture repos inherit
# unless the override is scrubbed — see lib/git-fixture.sh.
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-fixture.sh"
git_fixture_scrub_env

for f in "$GITIGNORE_MD" "$AUDIT_MD"; do
    if [[ ! -f "$f" ]]; then
        echo "FATAL: $f not found" >&2
        exit 1
    fi
done

SCRATCH="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$SCRATCH"' EXIT

# ---------------------------------------------------------------------------
# The check under test — a direct transcription of the documented gate.
# Scratch output lands OUTSIDE the fixture repo, as the doc requires, so the
# snapshot files cannot perturb the listing being compared.
# ---------------------------------------------------------------------------

# ipaths <repo> <pathspec>: the paths ignored today under <pathspec>. Tracked
# files are unaffected by a .gitignore edit, so ignored-untracked is the whole
# exposure.
#
# `-c core.excludesFile=/dev/null` is on THIS function, not only on attrib()
# below, because this is the one whose diff decides SAFE vs REFUSED (repo#535).
# `ls-files --exclude-standard` reads the user's global excludes, so without the
# override a host-global `*.log` keeps a path listed after the repo's own rule is
# removed, the before/after diff comes back empty, and the gate reports SAFE for a
# removal that really did un-ignore the path. The `-- gate: a global excludesFile
# cannot mask a difference --` case below is the negative control for exactly
# this: drop the override here and it fails.
ipaths() {
    git -C "$1" -c core.excludesFile=/dev/null \
        ls-files --others --ignored --exclude-standard -z -- "$2" \
        | tr '\0' '\n' | sed '/^$/d' | sort
}

# attrib <repo> <pathspec>: `<file>:<line>:<pattern>\t<path>` for each of those.
attrib() {
    ipaths "$1" "$2" \
        | git -C "$1" -c core.excludesFile=/dev/null check-ignore -v --stdin
}

# ign <repo> <path> -> "0" ignored / "1" not ignored. Carries the same
# `core.excludesFile=/dev/null` override every other view here does, so a host
# global exclude covering `.vscode` or `*.log` cannot flip an assertion
# (repo#535). `git_fixture_init` also pins it repo-locally; this is belt and
# braces, and it keeps the masking control below honest — that case deliberately
# re-points `core.excludesFile`, and only an explicit `-c` on the command line
# beats repo-local config.
ign() {  # <repo> <path>
    git -C "$1" -c core.excludesFile=/dev/null check-ignore -q "$2"; echo $?
}

# gate <repo> <pathspec> <mutation-command...>
# Captures the ignored-path set, runs the mutation, captures it again, and
# reverts the mutation when the sets differ — exactly the documented behavior
# ("revert the edit and do not count it as applied"). Sets three globals rather
# than echoing a verdict, so it must be called directly and never inside `$(…)`
# (a command substitution subshell would discard the diffs).
GATE_RESULT=""
GATE_PATHS_DIFF=""
GATE_ATTRIB_DIFF=""
gate() {
    local repo="$1" spec="$2"; shift 2
    local d; d="$(mktemp -d "$SCRATCH/gate.XXXXXX")"
    ipaths "$repo" "$spec" >"$d/paths.before"
    attrib "$repo" "$spec" >"$d/attrib.before" 2>/dev/null
    local snapshot; snapshot="$(mktemp -d "$SCRATCH/snap.XXXXXX")"
    cp -a "$repo/." "$snapshot/"
    "$@"
    ipaths "$repo" "$spec" >"$d/paths.after"
    attrib "$repo" "$spec" >"$d/attrib.after" 2>/dev/null
    GATE_PATHS_DIFF="$(diff -u "$d/paths.before" "$d/paths.after" || true)"
    GATE_ATTRIB_DIFF="$(diff -u "$d/attrib.before" "$d/attrib.after" || true)"
    if [[ -n "$GATE_PATHS_DIFF" ]]; then
        rm -rf "$repo"; mkdir -p "$repo"; cp -a "$snapshot/." "$repo/"
        GATE_RESULT="REFUSED"
    else
        GATE_RESULT="SAFE"
    fi
}

# ---------------------------------------------------------------------------
echo "-- anchoring: an anchored ancestor pattern does not cover a subdirectory --"
# ---------------------------------------------------------------------------
# The exact shape from repo#531: root `.vscode/*` (anchored — non-trailing slash)
# plus `proofs/.gitignore: .vscode/`.
R1="$SCRATCH/anchored"
git_fixture_init "$R1" -b main
mkdir -p "$R1/.vscode" "$R1/proofs/.vscode"
printf '.vscode/*\n' >"$R1/.gitignore"
printf '.vscode/\n' >"$R1/proofs/.gitignore"
touch "$R1/.vscode/settings.json" "$R1/proofs/.vscode/settings.json" "$R1/README.md"

R1_WHY="$(git -C "$R1" -c core.excludesFile=/dev/null check-ignore -v \
    proofs/.vscode/settings.json 2>/dev/null)"
assert_contains "the subdirectory rule is what ignores proofs/.vscode/settings.json" \
    "$R1_WHY" "proofs/.gitignore:1:.vscode/"
# `check-ignore -v` names exactly one rule per path — assert it is not the root's.
assert_eq "the root's anchored .vscode/* is NOT what covers it" "0" \
    "$(printf '%s\n' "$R1_WHY" | grep -c '^\.gitignore:')"

# Prove the ancestor rule genuinely cannot reach it, independent of precedence:
# with the subdirectory .gitignore absent, nothing ignores the path at all.
mv "$R1/proofs/.gitignore" "$SCRATCH/parked-gitignore"
assert_eq "with the subdirectory rule gone, proofs/.vscode/settings.json is unignored" \
    "1" "$(ign "$R1" proofs/.vscode/settings.json)"
mv "$SCRATCH/parked-gitignore" "$R1/proofs/.gitignore"
assert_eq "restoring the subdirectory rule re-ignores it" \
    "0" "$(ign "$R1" proofs/.vscode/settings.json)"

# ---------------------------------------------------------------------------
echo ""
echo "-- gate: the repo#531 removal is REFUSED --"
# ---------------------------------------------------------------------------
gate "$R1" "proofs/" rm -f "$R1/proofs/.gitignore"
assert_eq "removing proofs/.gitignore's rule is refused by the gate" "REFUSED" "$GATE_RESULT"
assert_contains "the gate names the path that would un-ignore" \
    "$GATE_PATHS_DIFF" "proofs/.vscode/settings.json"
assert_eq "a refused edit is reverted, so the rule is still on disk" \
    "0" "$(ign "$R1" proofs/.vscode/settings.json)"

# ---------------------------------------------------------------------------
echo ""
echo "-- gate: a genuinely redundant unanchored pair is still SAFE --"
# ---------------------------------------------------------------------------
# The over-conservatism guard: `*.log` has no slash at all, so the root rule does
# reach the subdirectory and the subdirectory copy really is redundant.
R2="$SCRATCH/unanchored"
git_fixture_init "$R2" -b main
mkdir -p "$R2/sub"
printf '*.log\n' >"$R2/.gitignore"
printf '*.log\n' >"$R2/sub/.gitignore"
touch "$R2/a.log" "$R2/sub/b.log" "$R2/README.md"

gate "$R2" "sub/" rm -f "$R2/sub/.gitignore"
assert_eq "removing the redundant unanchored duplicate is SAFE" "SAFE" "$GATE_RESULT"
assert_eq "no path changed ignore status" "" "$GATE_PATHS_DIFF"
assert_eq "the removal actually happened (not reverted)" \
    "1" "$([[ -f "$R2/sub/.gitignore" ]]; echo $?)"
# Contract 3: the attribution diff DOES change here, which is why it cannot be
# the gate — coverage moved up to the surviving ancestor rule.
assert_matches "coverage moved to the ancestor rule (attribution diff is non-empty)" \
    "$GATE_ATTRIB_DIFF" '\+\.gitignore:1:\*\.log'
assert_eq "sub/b.log is still ignored, now by the root rule" \
    "0" "$(ign "$R2" sub/b.log)"

# ---------------------------------------------------------------------------
echo ""
echo "-- anchoring: a LEADING \`**/\` is unanchored, so it does reach every depth --"
# ---------------------------------------------------------------------------
R3="$SCRATCH/globstar"
git_fixture_init "$R3" -b main
mkdir -p "$R3/a/b/build"
printf '**/build/\n' >"$R3/.gitignore"
printf 'build/\n' >"$R3/a/b/.gitignore"
touch "$R3/a/b/build/x" "$R3/README.md"
assert_eq "a root \`**/build/\` reaches a/b/build/x despite containing a slash" \
    "0" "$(ign "$R3" a/b/build/x)"
gate "$R3" "a/" rm -f "$R3/a/b/.gitignore"
assert_eq "so the nested \`build/\` duplicate is SAFE to remove" "SAFE" "$GATE_RESULT"

# ---------------------------------------------------------------------------
echo ""
echo "-- anchoring: a NON-LEADING \`**\` does NOT un-anchor (\`dir/**/name\`) --"
# ---------------------------------------------------------------------------
# repo#535: the first version of the anchoring table grouped `dir/**/name` with
# the leading-`**/name` form above and called both unanchored. It is not — `**`
# crosses the levels *below* the `dir/` prefix, but the prefix itself is still a
# mid-pattern separator, so the whole pattern is relative to the declaring
# .gitignore's directory. A root `dir/**/name` therefore does NOT cover
# `sub/dir/name`, and a `sub/.gitignore: name` beneath it is load-bearing. The
# mis-classification made this exact shape a removal candidate — the #531 failure
# class, reintroduced by the table added to prevent it.
R3B="$SCRATCH/globstar-mid"
git_fixture_init "$R3B" -b main
mkdir -p "$R3B/dir/x" "$R3B/sub/dir"
printf 'dir/**/name\n' >"$R3B/.gitignore"
printf 'name\n' >"$R3B/sub/.gitignore"
touch "$R3B/dir/name" "$R3B/dir/x/name" "$R3B/sub/dir/name" "$R3B/README.md"

# `**` crosses intermediate levels BELOW the anchored prefix...
assert_eq "root \`dir/**/name\` ignores dir/name (zero intermediate levels)" \
    "0" "$(ign "$R3B" dir/name)"
assert_eq "root \`dir/**/name\` ignores dir/x/name (one intermediate level)" \
    "0" "$(ign "$R3B" dir/x/name)"

# ...but does NOT cross the prefix itself. This is the whole point, and it has to
# be measured with the subdirectory rule parked — otherwise `sub/.gitignore: name`
# (unanchored, so it matches at every depth under sub/) answers for the path and
# the ancestor's reach is never actually tested.
mv "$R3B/sub/.gitignore" "$SCRATCH/parked-mid-globstar"
assert_eq "with the subdirectory rule parked, root \`dir/**/name\` does NOT reach sub/dir/name" \
    "1" "$(ign "$R3B" sub/dir/name)"
# Control: the LEADING form, same tree, same parked state, IS unanchored and does
# reach it — so the row above is a real distinction, not an artifact of the fixture.
printf '**/name\n' >"$R3B/.gitignore"
assert_eq "CONTROL: a leading \`**/name\` in the same tree DOES reach sub/dir/name" \
    "0" "$(ign "$R3B" sub/dir/name)"
printf 'dir/**/name\n' >"$R3B/.gitignore"
mv "$SCRATCH/parked-mid-globstar" "$R3B/sub/.gitignore"
assert_eq "restoring the subdirectory rule re-ignores sub/dir/name" \
    "0" "$(ign "$R3B" sub/dir/name)"

# The gate must refuse removing the subdirectory rule: the ancestor cannot reach
# it, so sub/dir/name would un-ignore.
gate "$R3B" "sub/" rm -f "$R3B/sub/.gitignore"
assert_eq "removing \`sub/.gitignore: name\` under a root \`dir/**/name\` is REFUSED" \
    "REFUSED" "$GATE_RESULT"
assert_contains "the gate names the path the mid-\`**\` ancestor cannot cover" \
    "$GATE_PATHS_DIFF" "sub/dir/name"
assert_eq "the refused removal is reverted, so sub/dir/name is still ignored" \
    "0" "$(ign "$R3B" sub/dir/name)"

# ---------------------------------------------------------------------------
echo ""
echo "-- anchoring: a leading slash anchors the same way a mid-pattern one does --"
# ---------------------------------------------------------------------------
R4="$SCRATCH/leadslash"
git_fixture_init "$R4" -b main
mkdir -p "$R4/a/foo"
printf '/foo\n' >"$R4/.gitignore"
printf 'foo\n' >"$R4/a/.gitignore"
touch "$R4/a/foo/x" "$R4/README.md"
gate "$R4" "a/" rm -f "$R4/a/.gitignore"
assert_eq "a root \`/foo\` does not cover a/foo, so removing \`a/.gitignore: foo\` is REFUSED" \
    "REFUSED" "$GATE_RESULT"
assert_contains "the gate names the path under the anchored-away rule" \
    "$GATE_PATHS_DIFF" "a/foo/x"

# ---------------------------------------------------------------------------
echo ""
echo "-- precedence: identical unanchored text can still be load-bearing --"
# ---------------------------------------------------------------------------
# The second reason the textual model is only a candidate filter: .gitignore
# precedence is deepest-file-last, so a subdirectory rule can be re-establishing
# an ignore that an ancestor's negation cancelled.
R5="$SCRATCH/negation"
git_fixture_init "$R5" -b main
mkdir -p "$R5/sub"
printf '*.log\n!important.log\n' >"$R5/.gitignore"
printf '*.log\n' >"$R5/sub/.gitignore"
touch "$R5/important.log" "$R5/sub/important.log" "$R5/sub/other.log" "$R5/README.md"
assert_eq "sub/important.log is ignored only via the subdirectory rule" \
    "0" "$(ign "$R5" sub/important.log)"
gate "$R5" "sub/" rm -f "$R5/sub/.gitignore"
assert_eq "the textually-identical subdirectory rule is REFUSED for removal" \
    "REFUSED" "$GATE_RESULT"
assert_contains "the gate names the path the ancestor negation would un-ignore" \
    "$GATE_PATHS_DIFF" "sub/important.log"

# ---------------------------------------------------------------------------
echo ""
echo "-- gate: an over-broad rewrite (newly ignored paths) is REFUSED too --"
# ---------------------------------------------------------------------------
# The gate is symmetric: broadening a rule so it swallows real content is as much
# a status change as un-ignoring one.
R6="$SCRATCH/overbroad"
git_fixture_init "$R6" -b main
mkdir -p "$R6/sub"
printf '*.log\n' >"$R6/sub/.gitignore"
touch "$R6/sub/b.log" "$R6/sub/notes.md"
broaden() { printf '*\n' >"$R6/sub/.gitignore"; }
gate "$R6" "sub/" broaden
assert_eq "widening sub/.gitignore to \`*\` is refused" "REFUSED" "$GATE_RESULT"
assert_contains "the gate names the newly swallowed path" "$GATE_PATHS_DIFF" "sub/notes.md"
assert_eq "the refused rewrite is reverted" "*.log" "$(cat "$R6/sub/.gitignore")"

# ---------------------------------------------------------------------------
echo ""
echo "-- gate: a global excludesFile cannot mask a difference --"
# ---------------------------------------------------------------------------
# `-c core.excludesFile=/dev/null` makes the result a property of the repo rather
# than of the machine: without it, a user's global ignore of `*.log` keeps
# sub/b.log ignored after the repo's own rule is gone, and the gate says SAFE.
#
# repo#535: this section used to assert only on `check-ignore -v` attribution,
# which the doc explicitly says is NOT the gate — so its title claimed a guarantee
# about the gate that it never exercised, and the omission of the override from
# `ipaths()` went unnoticed. It now drives the real `gate()`. Remove the
# `-c core.excludesFile=/dev/null` from `ipaths()` above and the REFUSED assertion
# below fails (the path-set diff comes back empty and the gate reports SAFE).
R7="$SCRATCH/globalexclude"
git_fixture_init "$R7" -b main
mkdir -p "$R7/sub"
printf '*.log\n' >"$R7/sub/.gitignore"
touch "$R7/sub/b.log" "$R7/sub/keep.txt"
printf '*.log\n' >"$SCRATCH/global-excludes"
# A host whose GLOBAL excludes overlap the rule under test. Set after
# git_fixture_init (which pins /dev/null) — repo-local config, last write wins —
# so only an explicit `-c` on the command line can still beat it.
git -C "$R7" config core.excludesFile "$SCRATCH/global-excludes"

# CONTROL: the masking is real. Without the override, removing the repo's own rule
# leaves the path-set unchanged, because the global `*.log` silently takes over.
masked_ipaths() {  # the pre-#535 ipaths(), verbatim: no override
    git -C "$1" ls-files --others --ignored --exclude-standard -z -- "$2" \
        | tr '\0' '\n' | sed '/^$/d' | sort
}
R7_MASKED_BEFORE="$(masked_ipaths "$R7" "sub/")"
R7_UNMASKED_BEFORE="$(ipaths "$R7" "sub/")"
R7_ATTRIB_MASKED="$(git -C "$R7" check-ignore -v sub/b.log 2>/dev/null)"

# The gate, with the override in place, must REFUSE: sub/b.log really does stop
# being ignored *by the repo* when sub/.gitignore goes away.
gate "$R7" "sub/" rm -f "$R7/sub/.gitignore"
assert_eq "the real gate REFUSES the removal despite the global excludesFile" \
    "REFUSED" "$GATE_RESULT"
assert_contains "the gate names the path the global exclude was masking" \
    "$GATE_PATHS_DIFF" "sub/b.log"
assert_eq "the refused removal is reverted, so the repo's own rule is back" \
    "*.log" "$(cat "$R7/sub/.gitignore")"

# CONTROL, continued: an un-overridden ipaths() sees no difference at all — which
# is exactly why the override has to live on the gate's own snapshot function.
rm -f "$R7/sub/.gitignore"
assert_eq "CONTROL: without the override the path-set diff is empty (gate would say SAFE)" \
    "$R7_MASKED_BEFORE" "$(masked_ipaths "$R7" "sub/")"
assert_matches "CONTROL: the masked listing does include sub/b.log both times" \
    "$R7_MASKED_BEFORE" 'sub/b\.log'
assert_eq "with the override, the path-set really did change" "0" \
    "$([[ "$R7_UNMASKED_BEFORE" != "$(ipaths "$R7" "sub/")" ]]; echo $?)"
assert_contains "without the override, the global excludesFile answers for the path" \
    "$(git -C "$R7" check-ignore -v sub/b.log 2>/dev/null)" "global-excludes"
assert_contains "with the override, nothing in the repo ignores it any more" \
    "$(git -C "$R7" -c core.excludesFile=/dev/null check-ignore -v sub/b.log 2>&1; echo "rc=$?")" \
    "rc=1"
assert_contains "the repo's own rule was the real owner before the removal" \
    "$R7_ATTRIB_MASKED" "sub/.gitignore"
printf '*.log\n' >"$R7/sub/.gitignore"

# ---------------------------------------------------------------------------
echo ""
echo "-- doc drift: gitignore.md documents the anchoring rule --"
# ---------------------------------------------------------------------------
# Prose assertions run against the whitespace-flattened file (flatten(), repo#363)
# so a sentence that wraps across lines still matches.
GI="$(flatten "$GITIGNORE_MD")"

assert_contains "gitignore.md warns against deduping on matching pattern text" \
    "$GI" "Do not flag a subdirectory rule as redundant with an ancestor's on matching"
assert_matches "it names the anchoring rule (a non-trailing slash anchors)" \
    "$GI" 'anchored.*directory of the `.gitignore` that declares it'
assert_matches "it cites man gitignore for the anchoring clause" \
    "$GI" 'separator at the beginning or middle'
assert_contains "it gives the unanchored row (bare name / glob / trailing slash)" \
    "$GI" '| `name`, `*.log`, `name/`'
assert_contains "it gives the anchored row (leading and mid-pattern slash)" \
    "$GI" '| `/name`, `dir/name`, `dir/*`'
# repo#535: these two rows must stay SPLIT. The original table grouped
# `**/name` and `dir/**/name` as one unanchored row, which is wrong — only a
# LEADING `**/` un-anchors — and this assertion pinned that wrong text green.
assert_contains "it gives the unanchored leading-\`**/\` row" \
    "$GI" '| `**/name` (leading `**/`)'
assert_contains "it classifies a non-leading \`**\` as ANCHORED, in its own row" \
    "$GI" '| `dir/**/name` (non-leading `**`) | **yes**'
assert_not_contains "it does NOT group \`dir/**/name\` with the unanchored forms" \
    "$GI" '| `**/name`, `dir/**/name`'
assert_matches "it states that only a leading \`**/\` un-anchors" \
    "$GI" 'Only a \*\*leading\*\* `\*\*/` un-anchors'
assert_matches "it gives the concrete \`dir/\*\*/name\` behavior (sub/dir/name not ignored)" \
    "$GI" '`dir/\*\*/name`.*`dir/name`.*`dir/x/name`.*`sub/dir/name` is \*\*not\*\*'
assert_contains "it states the redundancy condition in terms of same-or-ancestor scope" \
    "$GI" "matches the same paths *from where that rule sits*"
assert_contains "it carries the concrete .vscode regression" "$GI" "proofs/.vscode/"
assert_contains "it cites the issue" "$GI" "#531"
assert_contains "it also covers negation precedence as a load-bearing case" \
    "$GI" "deepest-file-last"
assert_contains "it demotes the textual model to a candidate filter" \
    "$GI" "candidate filter only"

# ---------------------------------------------------------------------------
echo ""
echo "-- doc drift: gitignore.md documents the before/after ignore-status gate --"
# ---------------------------------------------------------------------------
assert_contains "there is a dedicated gate section" "$GI" "### Verify a removal changes nothing"
assert_contains "the gate runs git check-ignore -v" "$GI" "check-ignore -v --stdin"
assert_contains "it neutralizes the user's global excludes" \
    "$GI" "core.excludesFile=/dev/null"
# repo#535: the override has to be on `ipaths` — the function whose diff IS the
# gate — and not only on the attribution view the doc calls explicitly not a gate.
# The documented `ipaths` body is extracted from the fenced recipe so this cannot
# be satisfied by the override appearing somewhere else in the file.
IPATHS_BODY="$(awk '/^ipaths\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$GITIGNORE_MD" | tr '\n' ' ' | tr -s ' ')"
assert_contains "the documented ipaths() (THE GATE) carries the override" \
    "$IPATHS_BODY" "core.excludesFile=/dev/null"
assert_contains "the documented ipaths() still lists ignored-untracked paths" \
    "$IPATHS_BODY" "ls-files --others --ignored --exclude-standard"
assert_matches "the prose says the override belongs on BOTH functions" \
    "$GI" 'core.excludesFile=/dev/null` on \*\*both\*\* functions'
assert_matches "the guarantee is scoped honestly: .git/info/exclude is NOT neutralized" \
    "$GI" '`\.git/info/exclude`.*\*\*not\*\* neutralized here'
assert_contains "it snapshots the ignored-path set before and after" "$GI" "paths.before"
assert_contains "and compares them" "$GI" "paths.after"
assert_matches "the path-set diff is the gate and must be empty" \
    "$GI" 'path-set diff is the gate'
assert_contains "a non-empty diff reverts the edit and does not count as applied" \
    "$GI" "revert the edit and do not count it as applied"
assert_contains "a refused removal is reported as a finding instead" \
    "$GI" "Report it as a finding instead"
assert_contains "the refusal report shape is shown" "$GI" "removal REFUSED"
assert_contains "the verified report shape is shown" "$GI" "verified: 12 paths unchanged"
assert_matches "the attribution diff is explicitly NOT a gate" \
    "$GI" 'attribution diff is not a gate'
assert_contains "the scratch files live outside the repo" \
    "$GI" 'S=$(mktemp -d)'
assert_contains "the gate's limit (paths that do not exist yet) is stated" \
    "$GI" "necessary, not sufficient"
assert_contains "the gate is per rule, not per file" "$GI" "Run the gate per rule, not once per file"
assert_contains "the gate applies to [[all]]'s Audit stage too" \
    "$GI" "Same gate when these fixes are offered from [[all]]'s Audit stage"

# The gate must precede the existing verify-after-write step, since it decides
# whether the edit is applied at all.
GATE_LINE="$(grep -n '^### Verify a removal changes nothing' "$GITIGNORE_MD" | cut -d: -f1)"
AFTER_LINE="$(grep -n '^### Verify after write' "$GITIGNORE_MD" | cut -d: -f1)"
assert_eq "the removal gate is documented before 'Verify after write'" "yes" \
    "$([[ -n "$GATE_LINE" && -n "$AFTER_LINE" && "$GATE_LINE" -lt "$AFTER_LINE" ]] && echo yes || echo no)"

# ---------------------------------------------------------------------------
echo ""
echo "-- doc drift: the verification result is part of the report --"
# ---------------------------------------------------------------------------
# The "For each .gitignore file, show:" list is what /repo:all's Audit stage
# inherits, so the per-rule result has to be a line item there rather than only
# inside the gate section.
INTERACTION="$(awk '/^For each `\.gitignore` file, show:/{f=1} /^By default, apply the clear-cut/{f=0} f{print}' "$GITIGNORE_MD" | tr '\n' ' ' | tr -s ' ')"
assert_contains "the per-file report lists the verification result" \
    "$INTERACTION" "ignore-status verification result for every removal or narrowing"
assert_contains "it is one line per rule, verified or REFUSED" \
    "$INTERACTION" "one line per rule"
assert_contains "the two outcomes are named" "$INTERACTION" "\`verified\` with the path count or \`REFUSED\`"
assert_contains "the line is never omitted" "$INTERACTION" "never omitted"
assert_contains "including from [[all]]'s Audit stage" "$INTERACTION" "Audit stage"

# ---------------------------------------------------------------------------
echo ""
echo "-- doc drift: audit.md carries the anchoring caveat too --"
# ---------------------------------------------------------------------------
AU="$(flatten "$AUDIT_MD")"
assert_contains "audit.md still carries the X + X/ symlink caveat" \
    "$AU" '`X` + `X/` pairs'
assert_contains "audit.md now also carries the anchoring caveat" \
    "$AU" "a subdirectory rule matching an ancestor's pattern text"
assert_matches "it states the anchoring rule in one line" \
    "$AU" 'anchored to its own `.gitignore`'"'"'s directory'
assert_contains "it names the concrete example" "$AU" '`.vscode/*` never covers'
# repo#535: audit.md's one-line form must not contradict gitignore.md's table —
# "a `/` other than a trailing one anchors" has exactly one exception, a LEADING
# `**/`, and a mid-pattern `**` is not it.
assert_matches "it names the only exception (a *leading* \`**/\`) explicitly" \
    "$AU" 'Only a \*leading\* `\*\*/` un-anchors'
assert_matches "it says a mid-pattern \`**\` stays anchored" \
    "$AU" '`dir/\*\*/name` is anchored just like `dir/name`'
assert_contains "it points at gitignore.md's gate" "$AU" "before/after gate"
assert_contains "it keeps audit.md read-only (candidate redundancy only)" \
    "$AU" "candidate* redundancy"

# ---------------------------------------------------------------------------
echo ""
echo "========================================="
echo "  Total:  $TOTAL"
printf "  ${GREEN}Passed${NC}: %s\n" "$PASS"
printf "  ${RED}Failed${NC}: %s\n" "$FAIL"
printf "  ${YELLOW}Skipped${NC}: %s\n" "$SKIP"
echo "========================================="

if [[ $FAIL -gt 0 ]]; then
    printf "\n${RED}TESTS FAILED${NC}\n"
    exit 1
fi
printf "\n${GREEN}ALL TESTS PASSED${NC}\n"
exit 0

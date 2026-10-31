#!/usr/bin/env bash
# Cross-runtime parity test: Claude Code's `/repo:followups` slash command and
# Codex CLI's `repo` skill resolve to the SAME underlying `skills/repo/SKILL.md`
# workflow body for the `followups` verb (repo#286).
#
# Usage: ./hooks/repo/tests/test-skill-parity.sh
# Exit code 0 = all tests pass, 1 = failures detected.
#
# Structured like test-install-codex-skill.sh next door: pure bash, no test
# framework, PASS/FAIL counters and a summary block, real install.sh driven
# against scratch git repos.
#
# WHAT IS UNDER TEST, AND WHY IT'S NOT test-install-codex-skill.sh AGAIN
# ---------------------------------------------------------------------------
# repo#285/PR#288 built the Codex-side registration surface
# (`.agents/skills/repo/`, `lib/codex-skill.sh`) and test-install-codex-skill.sh
# already pins that INSTALL places the right bytes at the right paths — that
# is an install-time placement concern.
#
# repo#282's own review split out THIS issue (repo#286) as a distinct concern:
# INVOCATION parity. Given a fully installed repo, does typing `/repo:followups`
# in Claude Code, and does Codex's own skill-discovery selecting the `repo`
# skill for a followups-shaped task, both end up executing the identical
# workflow body? "Both installers wrote identical files" is necessary evidence
# for that claim but does not itself trace either runtime's OWN resolution path
# to that file — this suite does, for both runtimes' documented resolution
# mechanism:
#
#   - Claude Code: `.claude/commands/<domain>/<verb>.md` is a fixed,
#     documented discovery path — a file there registers `/<domain>:<verb>` as
#     an explicit slash command (skills/README.md "Frontmatter field
#     reference": `type: command` + `user-invocable: true` name this contract).
#     The alias `/repo:followups` -> `commands/repo/followups.md` is therefore
#     load-bearing FRONTMATTER + FILE-PATH data, not documentation prose, and
#     this suite asserts that data directly on the SOURCE file (section 1) —
#     the same file install.sh copies verbatim to
#     `.claude/commands/repo/followups.md` (asserted structurally in section 3;
#     test-install-codex-skill.sh already pins the copy is byte-identical).
#   - Codex CLI: discovers the `repo` skill via `.agents/skills/repo/SKILL.md`
#     (lib/codex-skill.sh's header cites the upstream spec). That file's own
#     body — rendered from the canonical skills/repo/SKILL.md, see
#     lib/codex-skill.sh:codex_skill_render — carries a "Command procedures"
#     section that is Codex's OWN documented pointer from the skill to the
#     verb: "Read the one the task needs … `references/followups.md`". This
#     suite asserts that pointer exists and names the right file (section 4),
#     then that the file it names is byte-identical to the Claude-side file
#     from section 3 and to the canonical source (section 5) — the actual
#     "same file" parity claim.
#
# WHY THIS IS STRUCTURAL, NOT A LIVE `claude` / `codex` DISPATCH
# ---------------------------------------------------------------------------
# Neither runtime exposes a scriptable "resolve this slash command / skill
# reference and print the file it read" primitive, and CI cannot assume the
# `codex` CLI binary is installed (this repo's own guard tests carefully avoid
# assuming external CLIs — see test-shell-wrapper.sh's use of a `command`
# shim rather than the real `claude`/`codex` binaries). So this suite verifies
# every step of BOTH runtimes' documented resolution mechanism mechanically —
# frontmatter contract, installed path, the skill body's own pointer text,
# byte/hash identity — rather than driving either CLI end-to-end. This is
# exactly the fallback the issue's own acceptance criteria allow ("or, if
# automated Codex invocation isn't feasible in CI, a documented manual test").
#
# MANUAL VERIFICATION (documented per that allowance):
#   1. Install Repo Skills into a scratch repo: ./install.sh -y /path/to/scratch
#   2. Claude side: open Claude Code in that repo, run `/repo:followups`,
#      confirm (e.g. via the transcript, or a deliberate typo forcing Claude to
#      report "no such command") that it reads
#      .claude/commands/repo/followups.md.
#   3. Codex side: run `codex` in that repo, ask it to review the session for
#      unresolved follow-up work, confirm (via its tool-call/read transcript)
#      that it loads .agents/skills/repo/SKILL.md and then
#      .agents/skills/repo/references/followups.md.
#   4. Diff the two files opened in steps 2 and 3 — they must be byte-identical
#      (this suite pins that identity automatically; the manual run is only for
#      confirming each runtime's OWN resolution actually reaches that file).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
SRC_FOLLOWUPS="$REPO_ROOT/commands/repo/followups.md"
SRC_SKILL="$REPO_ROOT/skills/repo/SKILL.md"

CLAUDE_REL=".claude/commands/repo/followups.md"
CODEX_REL=".agents/skills/repo-followups/SKILL.md"
CODEX_SKILL_REL=".agents/skills/repo/SKILL.md"

# Assertion helpers (ok/no/skip/assert_eq/assert_contains/assert_not_contains/
# assert_matches) plus the PASS/FAIL/SKIP/TOTAL counters and color vars are
# shared across the repo test suites — see commands/repo/tests/lib/assert.sh
# (repo#307).
source "$(dirname "${BASH_SOURCE[0]}")/../../../commands/repo/tests/lib/assert.sh"

for f in "$INSTALL_SH" "$SRC_FOLLOWUPS" "$SRC_SKILL"; do
    if [[ ! -f "$f" ]]; then
        echo "FATAL: required file not found at $f" >&2
        exit 1
    fi
done

SCRATCH="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$SCRATCH"' EXIT
FAKE_HOME="$SCRATCH/home"
mkdir -p "$FAKE_HOME"

# ---------------------------------------------------------------------------
# File-specific assertion helpers (not in the shared lib)
# ---------------------------------------------------------------------------

assert_file() {  # <label> <path>
    if [[ -f "$2" ]]; then ok "$1"; else no "$1" "no such file: $2"; fi
}
assert_bytes_eq() {  # <label> <file-a> <file-b>
    if cmp -s "$2" "$3"; then
        ok "$1"
    else
        no "$1" "$(diff -u "$2" "$3" 2>&1 | head -20)"
    fi
}
sha() {  # <file> -> sha256 hex digest
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        sha256sum "$1" | awk '{print $1}'
    fi
}

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

new_target() {  # <name> -> prints the target path
    local t="$SCRATCH/$1"
    mkdir -p "$t"
    git init -q "$t" 2>/dev/null
    printf '%s\n' '# scratch' > "$t/README.md"
    git -C "$t" -c user.email=test@example.com -c user.name='Repo Skills Test' \
        add README.md >/dev/null
    git -C "$t" -c user.email=test@example.com -c user.name='Repo Skills Test' \
        commit -q -m "initial"
    printf '%s' "$t"
}

# ===========================================================================
echo "Cross-runtime skill-invocation parity suite (repo#286)"
echo "========================================================"

# ---------------------------------------------------------------------------
echo ""
echo "-- 1. Claude-side alias mechanism: /repo:followups's registration data --"

# The frontmatter contract skills/README.md documents as what makes Claude
# Code register a file at .claude/commands/<domain>/<verb>.md as an explicit
# /<domain>:<verb> slash command. This is asserted on the SOURCE file, which
# install.sh copies byte-for-byte (see section 3) to that fixed path.
FM_NAME="$(awk -F': *' '/^name:/{gsub(/"/,"",$2); print $2; exit}' "$SRC_FOLLOWUPS")"
FM_DOMAIN="$(awk -F': *' '/^domain:/{print $2; exit}' "$SRC_FOLLOWUPS")"
FM_TYPE="$(awk -F': *' '/^type:/{print $2; exit}' "$SRC_FOLLOWUPS")"
FM_INVOCABLE="$(awk -F': *' '/^user-invocable:/{print $2; exit}' "$SRC_FOLLOWUPS")"

assert_eq "frontmatter name is 'followups' (the verb)"          "followups" "$FM_NAME"
assert_eq "frontmatter domain is 'repo'"                        "repo"      "$FM_DOMAIN"
assert_eq "frontmatter type is 'command' (slash-command surface)" "command" "$FM_TYPE"
assert_eq "frontmatter user-invocable is 'true'"                "true"      "$FM_INVOCABLE"
assert_eq "source filename matches the frontmatter verb name" \
    "followups.md" "$(basename "$SRC_FOLLOWUPS")"

# ---------------------------------------------------------------------------
echo ""
echo "-- 2. skills/repo/SKILL.md's index points at the same verb --"

# SKILL.md is the domain-wide index BOTH runtimes' skill surface is built
# from (Claude's .claude/skills/repo/SKILL.md and Codex's
# .agents/skills/repo/SKILL.md are both rendered from this one source file —
# see lib/codex-skill.sh and install.sh step 1/3f). Its Commands table names
# the followups verb via the [[followups]] wiki-link row.
assert_contains "SKILL.md's Commands table carries a [[followups]] row" \
    "$(cat "$SRC_SKILL")" "[[followups]]"

# ---------------------------------------------------------------------------
echo ""
echo "-- 3. install: the Claude-side resolved file exists at its fixed path --"

T1="$(new_target claude-side)"
OUT1="$(HOME="$FAKE_HOME" bash "$INSTALL_SH" -y "$T1" 2>&1)"; RC1=$?
assert_eq   "install exits 0" "0" "$RC1"
assert_file "Claude's fixed discovery path for /repo:followups exists" "$T1/$CLAUDE_REL"

# ---------------------------------------------------------------------------
echo ""
echo "-- 4. install: the Codex-side skill body points at its own resolved file --"

assert_file "Codex's skill index (SKILL.md) is installed" "$T1/$CODEX_SKILL_REL"
assert_file "Codex's per-command followups skill is installed" "$T1/$CODEX_REL"

# Codex's OWN resolution step (repo#676): the umbrella SKILL.md routes to the
# `$repo-followups` skill, which Codex lists as its own entry.
assert_contains "installed SKILL.md's body routes Codex to \$repo-followups" \
    "$(cat "$T1/$CODEX_SKILL_REL")" '`$repo-followups`'

# The Codex file is a rendered form of the command (own frontmatter, a short
# header, and /repo:<verb> -> $repo-<verb> rewriting), so parity is "the command
# body, modulo that rewrite, is the tail of the Codex file".
body_only() { awk 'NR==1&&$0!="---"{print;f=1;next} f{print;next} NR==1{i=1;next} i&&$0=="---"{i=0;s=1;next} i{next} s{print}' "$1"; }
codex_tail_matches() {  # <claude-file> <codex-file>
    local want n
    want="$(body_only "$1" | sed -E 's#/repo:([a-z][a-z0-9]*(-[a-z0-9]+)*)#$repo-\1#g')"
    n="$(printf '%s\n' "$want" | wc -l | tr -d ' ')"
    [[ "$(tail -n "$n" "$2")" == "$want" ]]
}

# ---------------------------------------------------------------------------
echo ""
echo "-- 5. parity: both runtimes' resolved files carry the SAME workflow body --"

assert_bytes_eq "Claude-resolved file == canonical source (commands/repo/followups.md)" \
    "$T1/$CLAUDE_REL" "$SRC_FOLLOWUPS"
if codex_tail_matches "$T1/$CLAUDE_REL" "$T1/$CODEX_REL"; then
    ok "Codex-resolved skill body == Claude command body (modulo cross-reference rewrite)"
else
    no "Codex-resolved skill body == Claude command body (modulo cross-reference rewrite)"
fi

# ---------------------------------------------------------------------------
echo ""
echo "-- 6. generalization: the same parity holds for every installed verb --"

MISMATCH=""
CHECKED=0
for claude_file in "$T1/.claude/commands/repo/"*.md; do
    [[ -f "$claude_file" ]] || continue
    verb="$(basename "$claude_file" .md)"
    codex_file="$T1/.agents/skills/repo-$verb/SKILL.md"
    CHECKED=$((CHECKED + 1))
    if [[ ! -f "$codex_file" ]] || ! codex_tail_matches "$claude_file" "$codex_file"; then
        MISMATCH="$MISMATCH $verb"
    fi
done
assert_eq "every installed verb's Claude/Codex bodies match (checked $CHECKED)" \
    "" "$MISMATCH"

# ===========================================================================
echo ""
echo "========================================="
echo "  Total:  $TOTAL"
printf "  ${GREEN}Passed${NC}: %s\n" "$PASS"
printf "  ${RED}Failed${NC}: %s\n" "$FAIL"
echo "========================================="

if [[ $FAIL -gt 0 ]]; then
    printf "\n${RED}TESTS FAILED${NC}\n"
    exit 1
fi
printf "\n${GREEN}ALL TESTS PASSED${NC}\n"
exit 0

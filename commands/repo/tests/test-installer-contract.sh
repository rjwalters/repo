#!/usr/bin/env bash
# Conformance suite for INSTALLER-CONTRACT.md (repo#156).
#
# Usage: ./commands/repo/tests/test-installer-contract.sh
# Exit code 0 = all tests pass, 1 = failures detected.
#
# WHY THIS FILE EXISTS: a conformance table maintained by hand is a table that
# goes stale, and a stale one is worse than none — it reads as authoritative
# while quietly describing a tool that has moved on. This suite RE-DERIVES the
# `repo` column of that table from the working tree on every run, using the same
# spot-checks the document publishes, and then asserts each derived result
# matches the cell the document prints. Regressing a requirement (or editing the
# table to claim a ✅ this repo has not earned) turns `pnpm test` red.
#
# It deliberately checks only the column this repo can verify: loom, anvil and
# squad live in other repos and are point-in-time observations there. Each
# requirement in the contract carries the command to re-derive those rows.
#
# Structured like the sibling suites: pure bash, no framework, PASS/FAIL/TOTAL
# counters and a summary block. `pnpm test` delegates to this file via
# hooks/repo/tests/run.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CONTRACT="$REPO_ROOT/INSTALLER-CONTRACT.md"

# Assertion helpers (ok/no/skip/assert_eq/assert_contains/assert_not_contains/
# assert_matches) plus the PASS/FAIL/SKIP/TOTAL counters and color vars are
# shared across the repo test suites — see lib/assert.sh (repo#307).
source "$(dirname "${BASH_SOURCE[0]}")/lib/assert.sh"

if [[ ! -f "$CONTRACT" ]]; then
    echo "FATAL: INSTALLER-CONTRACT.md not found at $CONTRACT" >&2
    exit 1
fi

SCRATCH="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$SCRATCH"' EXIT
FAKE_HOME="$SCRATCH/home"
mkdir -p "$FAKE_HOME"

# ---------------------------------------------------------------------------
# Read the documented `repo` cell for a requirement out of the conformance
# table. Columns are: | # | loom | anvil | repo | squad |, so awk field 5 is
# `repo` (field 1 is the empty string before the leading pipe).
# ---------------------------------------------------------------------------
documented_repo_cell() {  # <C1..C8> -> "yes" | "no" | "" (row not found)
    local id="$1" cell
    cell="$(awk -F'|' -v id="$id" '
        $2 ~ ("^ " id " ") { gsub(/^[ \t]+|[ \t]+$/, "", $5); print $5; exit }
    ' "$CONTRACT")"
    case "$cell" in
        "")   echo "" ;;
        ✅*)  echo "yes" ;;
        *)    echo "no" ;;
    esac
}

# tree_fingerprint <dir> — content+mode manifest, used for the "changes nothing"
# requirements (C4 and C7's --dry-run).
tree_fingerprint() {
    [[ -d "$1" ]] || { echo "ABSENT"; return; }
    ( cd "$1" && find . \( -type f -o -type l \) | LC_ALL=C sort | while IFS= read -r f; do
        if [[ -L "$f" ]]; then printf '%s SYMLINK %s\n' "$f" "$(readlink "$f")"
        else printf '%s %s\n' "$f" "$(cksum <"$f")"; fi
      done )
}

new_target() { mkdir -p "$1"; git -C "$1" init -q; }

echo "INSTALLER-CONTRACT.md conformance suite"
echo "======================================="

# Derived results, filled in below and cross-checked against the document last.
C1=no; C2=no; C3=no; C4=no; C5=no; C6=no; C7=no; C8=no; C9=no

# ---------------------------------------------------------------------------
echo ""
echo "-- C1: entry point --"
if [[ -f "$REPO_ROOT/install.sh" && -x "$REPO_ROOT/install.sh" ]]; then
    C1=yes; ok "install.sh exists at the source root and is executable"
else
    no "install.sh exists at the source root and is executable"
fi

# ---------------------------------------------------------------------------
echo ""
echo "-- C2: trailing positional target, defaulting to . --"
C2_T="$SCRATCH/c2"; new_target "$C2_T"
C2_OUT="$( HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --dry-run "$C2_T" 2>&1 )"
C2_DEFAULT="$( cd "$C2_T" && HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --dry-run 2>&1 )"
if [[ "$C2_OUT" == *"$C2_T/.claude/skills/repo/SKILL.md"* ]]; then
    ok "a trailing positional selects the target"
else
    no "a trailing positional selects the target" "$C2_OUT"
fi
if [[ "$C2_DEFAULT" == *"$C2_T/.claude/skills/repo/SKILL.md"* ]]; then
    ok "an omitted target defaults to the current directory"
else
    no "an omitted target defaults to the current directory" "$C2_DEFAULT"
fi
[[ "$C2_OUT" == *"$C2_T/.claude/skills/repo/SKILL.md"* && "$C2_DEFAULT" == *"$C2_T/.claude/skills/repo/SKILL.md"* ]] && C2=yes

# ---------------------------------------------------------------------------
echo ""
echo "-- C4: --dry-run changes nothing and exits 0 --"
# Checked before C3 because it must run against a still-uninstalled target.
C4_BEFORE="$(tree_fingerprint "$C2_T")"
HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --dry-run "$C2_T" >/dev/null 2>&1
C4_RC=$?
C4_AFTER="$(tree_fingerprint "$C2_T")"
assert_eq "install.sh --dry-run exits 0" "0" "$C4_RC"
assert_eq "install.sh --dry-run leaves the target byte-identical" "$C4_BEFORE" "$C4_AFTER"
[[ "$C4_RC" -eq 0 && "$C4_BEFORE" == "$C4_AFTER" ]] && C4=yes

# ---------------------------------------------------------------------------
echo ""
echo "-- C3: -y completes with no TTY --"
C3_T="$SCRATCH/c3"; new_target "$C3_T"
HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" -y "$C3_T" >/dev/null 2>&1 </dev/null
C3_RC=$?
assert_eq "install.sh -y exits 0 with stdin closed" "0" "$C3_RC"
# -y must not be read as consent for the one thing written outside the target.
if [[ ! -e "$FAKE_HOME/.zshrc" && ! -e "$FAKE_HOME/.bashrc" ]]; then
    ok "-y alone writes nothing outside the target repo"
else
    no "-y alone writes nothing outside the target repo"
fi
[[ "$C3_RC" -eq 0 && ! -e "$FAKE_HOME/.zshrc" && ! -e "$FAKE_HOME/.bashrc" ]] && C3=yes

TOOL_ROOT="$C3_T/.claude/skills/repo"
META="$TOOL_ROOT/install-metadata.json"
SIDECAR="$TOOL_ROOT/.install-local.json"

# ---------------------------------------------------------------------------
echo ""
echo "-- C5: tracked metadata, machine-independent --"
C5_OK=true
if [[ -f "$META" ]]; then ok "install-metadata.json exists in the tool root"; else no "install-metadata.json exists in the tool root"; C5_OK=false; fi
META_BODY="$(cat "$META" 2>/dev/null)"
for field in '"version"' '"commit"' '"layout_version"'; do
    if [[ "$META_BODY" == *"$field"* ]]; then ok "tracked metadata carries $field"; else no "tracked metadata carries $field"; C5_OK=false; fi
done
for forbidden in '"source"' '"installed_at"' '"last_resync"'; do
    if [[ "$META_BODY" != *"$forbidden"* ]]; then ok "tracked metadata carries no $forbidden"; else no "tracked metadata carries no $forbidden"; C5_OK=false; fi
done
if [[ "$META_BODY" != *"$SCRATCH"* && "$META_BODY" != *"$HOME"* ]]; then
    ok "tracked metadata embeds no absolute path"
else
    no "tracked metadata embeds no absolute path" "$META_BODY"
    C5_OK=false
fi
# Byte-identical across two installs of the same version+options: the property
# that makes it safe to commit.
C5_T2="$SCRATCH/c5-second"; new_target "$C5_T2"
HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" -y "$C5_T2" >/dev/null 2>&1 </dev/null
if cmp -s "$META" "$C5_T2/.claude/skills/repo/install-metadata.json"; then
    ok "two installs of the same version produce identical tracked metadata"
else
    no "two installs of the same version produce identical tracked metadata"
    C5_OK=false
fi
[[ "$C5_OK" == true ]] && C5=yes

# ---------------------------------------------------------------------------
echo ""
echo "-- C6: gitignored machine-local sidecar --"
C6_OK=true
if [[ -f "$SIDECAR" ]]; then ok "the sidecar exists"; else no "the sidecar exists"; C6_OK=false; fi
SIDE_BODY="$(cat "$SIDECAR" 2>/dev/null)"
for field in '"source"' '"installed_at"'; do
    if [[ "$SIDE_BODY" == *"$field"* ]]; then ok "the sidecar carries $field"; else no "the sidecar carries $field"; C6_OK=false; fi
done
if git -C "$C3_T" check-ignore -q .claude/skills/repo/.install-local.json 2>/dev/null; then
    ok "the installer gitignored the sidecar in the consumer repo"
else
    no "the installer gitignored the sidecar in the consumer repo"
    C6_OK=false
fi
if ! git -C "$C3_T" check-ignore -q .claude/skills/repo/install-metadata.json 2>/dev/null; then
    ok "the tracked metadata is NOT gitignored"
else
    no "the tracked metadata is NOT gitignored"
    C6_OK=false
fi
[[ "$C6_OK" == true ]] && C6=yes

# ---------------------------------------------------------------------------
echo ""
echo "-- C7: consumer-side resync --"
C7_SH="$TOOL_ROOT/scripts/resync-installed.sh"
C7_OK=true
if [[ -x "$C7_SH" ]]; then ok "resync-installed.sh is installed and executable"; else no "resync-installed.sh is installed and executable"; C7_OK=false; fi

C7_BEFORE="$(tree_fingerprint "$C3_T/.claude")"
C7_OUT="$( cd "$C3_T" && HOME="$FAKE_HOME" bash "$C7_SH" --dry-run 2>&1 )"
C7_RC=$?
C7_AFTER="$(tree_fingerprint "$C3_T/.claude")"
if [[ "$C7_RC" -eq 0 || "$C7_RC" -eq 2 ]]; then
    ok "--dry-run exits 0 (in sync) or 2 (drift)"
else
    no "--dry-run exits 0 (in sync) or 2 (drift)" "exit $C7_RC: $C7_OUT"
    C7_OK=false
fi
if [[ "$C7_BEFORE" == "$C7_AFTER" ]]; then ok "--dry-run leaves the install byte-identical"; else no "--dry-run leaves the install byte-identical"; C7_OK=false; fi

C7_QOUT="$( cd "$C3_T" && HOME="$FAKE_HOME" bash "$C7_SH" --quiet 2>&1 )"
C7_QRC=$?
if [[ "$C7_QRC" -eq 0 ]]; then ok "--quiet apply exits 0"; else no "--quiet apply exits 0" "$C7_QOUT"; C7_OK=false; fi
if [[ "$(printf '%s\n' "$C7_QOUT" | grep -c .)" == "1" ]]; then
    ok "--quiet prints a single summary line"
else
    no "--quiet prints a single summary line" "$C7_QOUT"
    C7_OK=false
fi

# Never uninstalls: a full apply must leave every installed file in place.
C7_COUNT_BEFORE="$(find "$C3_T/.claude" -type f | wc -l | tr -d ' ')"
( cd "$C3_T" && HOME="$FAKE_HOME" bash "$C7_SH" >/dev/null 2>&1 )
C7_COUNT_AFTER="$(find "$C3_T/.claude" -type f | wc -l | tr -d ' ')"
if [[ "$C7_COUNT_BEFORE" == "$C7_COUNT_AFTER" ]]; then
    ok "a resync removes no installed file"
else
    no "a resync removes no installed file" "$C7_COUNT_BEFORE -> $C7_COUNT_AFTER"
    C7_OK=false
fi

# Fails loudly rather than half-installing into a target with no install.
C7_BARE="$SCRATCH/c7-bare"; new_target "$C7_BARE"
C7_BOUT="$( cd "$C7_BARE" && HOME="$FAKE_HOME" bash "$C7_SH" --dry-run 2>&1 )"
C7_BRC=$?
if [[ "$C7_BRC" -eq 1 && ! -e "$C7_BARE/.claude" ]]; then
    ok "an uninstalled target fails with exit 1 and stays untouched"
else
    no "an uninstalled target fails with exit 1 and stays untouched" "exit $C7_BRC: $C7_BOUT"
    C7_OK=false
fi
[[ "$C7_OK" == true ]] && C7=yes

# ---------------------------------------------------------------------------
echo ""
echo "-- C8: honest VERSION --"
C8_OK=true
if [[ -s "$REPO_ROOT/VERSION" ]]; then ok "VERSION exists and is non-empty"; else no "VERSION exists and is non-empty"; C8_OK=false; fi
VERSION_VALUE="$(tr -d '[:space:]' <"$REPO_ROOT/VERSION" 2>/dev/null)"
if [[ -n "$VERSION_VALUE" ]]; then ok "VERSION holds a value, not whitespace"; else no "VERSION holds a value, not whitespace"; C8_OK=false; fi
# The installer must report that same value — a version read from anywhere else
# is the "scraped from prose" failure C8 forbids.
if [[ "$META_BODY" == *"\"version\": \"$VERSION_VALUE\""* ]]; then
    ok "install-metadata.json records exactly the VERSION file's value"
else
    no "install-metadata.json records exactly the VERSION file's value" "$META_BODY"
    C8_OK=false
fi
[[ "$C8_OK" == true ]] && C8=yes

# ---------------------------------------------------------------------------
echo ""
echo "-- C9: post-install gitignore sweep --"
C9_OK=true

# A target whose .gitignore incidentally shadows some (not all) installed
# files — the exact repo#385 failure mode: a broad pre-existing rule reaching
# into an otherwise-tracked install and hiding a subset of it.
C9_T="$SCRATCH/c9"; new_target "$C9_T"
echo '*.md' >"$C9_T/.gitignore"
C9_OUT="$( HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" -y "$C9_T" 2>&1 </dev/null )"
C9_RC=$?

if [[ "$C9_RC" -eq 0 ]]; then
    ok "install.sh still exits 0 when the sweep finds ignored payload files"
else
    no "install.sh still exits 0 when the sweep finds ignored payload files" "exit $C9_RC"
    C9_OK=false
fi
if [[ "$C9_OUT" == *".claude/commands/repo/help.md"* ]]; then
    ok "the warning names an ignored payload path"
else
    no "the warning names an ignored payload path" "$C9_OUT"
    C9_OK=false
fi
if [[ "$C9_OUT" == *".gitignore:1:*.md"* ]]; then
    ok "the warning names the matching .gitignore rule"
else
    no "the warning names the matching .gitignore rule" "$C9_OUT"
    C9_OK=false
fi
# The install itself must have proceeded normally — this is a warning, not an
# abort or rollback.
if [[ -f "$C9_T/.claude/skills/repo/install-metadata.json" ]]; then
    ok "the sweep does not abort or roll back an otherwise-successful install"
else
    no "the sweep does not abort or roll back an otherwise-successful install"
    C9_OK=false
fi
# The C6 sidecar is deliberately gitignored by the installer itself — it must
# never appear as a C9 sweep hit (its own "Wrote .install-local.json" success
# line is expected and unrelated; only a sweep-warning line for it would be a
# false positive).
if [[ "$C9_OUT" != *"install-local.json  <-"* ]]; then
    ok "the sweep does not false-positive on the installer's own C6 sidecar"
else
    no "the sweep does not false-positive on the installer's own C6 sidecar" "$C9_OUT"
    C9_OK=false
fi

# A clean target (no shadowing rule) must produce no C9 warning at all.
C9_CLEAN="$SCRATCH/c9-clean"; new_target "$C9_CLEAN"
C9_CLEAN_OUT="$( HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" -y "$C9_CLEAN" 2>&1 </dev/null )"
if [[ "$C9_CLEAN_OUT" != *"INSTALLER-CONTRACT.md C9"* ]]; then
    ok "an unshadowed install produces no C9 warning"
else
    no "an unshadowed install produces no C9 warning" "$C9_CLEAN_OUT"
    C9_OK=false
fi

# resync-installed.sh (C7) re-derives the same sweep after a refresh.
C9_RESYNC_SH="$C9_T/.claude/skills/repo/scripts/resync-installed.sh"
C9_RESYNC_OUT="$( cd "$C9_T" && HOME="$FAKE_HOME" bash "$C9_RESYNC_SH" --dry-run 2>&1 )"
if [[ "$C9_RESYNC_OUT" == *".claude/commands/repo/help.md"* && "$C9_RESYNC_OUT" == *".gitignore:1:*.md"* ]]; then
    ok "resync-installed.sh (C7) runs the same sweep after a refresh"
else
    no "resync-installed.sh (C7) runs the same sweep after a refresh" "$C9_RESYNC_OUT"
    C9_OK=false
fi

# repo#425 — a gitignored *runtime* file under the tool root (guard-hook logs,
# not installer payload) must never trigger the C9 warning. Unlike the C6
# sidecar case above, this file is not written by the installer at all: it is
# left behind by the installed guard hooks running between installs, and a
# consumer deliberately ignoring it (it carries absolute filesystem paths) is
# the CORRECT state, not a defect the warning should flag.
C9_RUNTIME="$SCRATCH/c9-runtime"; new_target "$C9_RUNTIME"
cat >"$C9_RUNTIME/.gitignore" <<'EOF'
# guard-hook decision logs (machine-local)
.claude/skills/repo/logs/
EOF
HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" -y "$C9_RUNTIME" >/dev/null 2>&1 </dev/null
# Simulate a guard hook having run since install and left runtime output behind
# — this directory is never part of the installer's own payload.
mkdir -p "$C9_RUNTIME/.claude/skills/repo/logs"
echo '{"decision":"allow","cmd":"/Users/some-operator/project/run.sh"}' \
    >"$C9_RUNTIME/.claude/skills/repo/logs/guard-decisions.log"
C9_RUNTIME_OUT="$( HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" -y "$C9_RUNTIME" 2>&1 </dev/null )"
if [[ "$C9_RUNTIME_OUT" != *"INSTALLER-CONTRACT.md C9"* ]]; then
    ok "a gitignored runtime log under the tool root does not trigger the C9 warning"
else
    no "a gitignored runtime log under the tool root does not trigger the C9 warning" "$C9_RUNTIME_OUT"
    C9_OK=false
fi
if [[ "$C9_RUNTIME_OUT" != *"guard-decisions.log"* ]]; then
    ok "the runtime log path is not named anywhere in C9 output"
else
    no "the runtime log path is not named anywhere in C9 output" "$C9_RUNTIME_OUT"
    C9_OK=false
fi

[[ "$C9_OK" == true ]] && C9=yes

# ---------------------------------------------------------------------------
echo ""
echo "-- the conformance table matches what was just derived --"
for id in C1 C2 C3 C4 C5 C6 C7 C8 C9; do
    documented="$(documented_repo_cell "$id")"
    derived="$(eval "echo \"\$$id\"")"
    if [[ -z "$documented" ]]; then
        no "$id has a row in the conformance table"
    else
        assert_eq "$id: table says '$documented', tree says '$derived'" "$derived" "$documented"
    fi
done

# ---------------------------------------------------------------------------
echo ""
echo "-- the contract is normative and self-describing --"
CT="$(cat "$CONTRACT")"
assert_contains "the contract states its normative status" "$CT" "normative"
assert_contains "the contract cites RFC 2119 key words" "$CT" "RFC 2119"
for id in C1 C2 C3 C4 C5 C6 C7 C8 C9; do
    assert_contains "the contract has a section for $id" "$CT" "### $id"
done
assert_contains "every requirement publishes a spot-check" "$CT" "Spot-check:"
assert_contains "the table's freshness is stamped" "$CT" "observed 2026-08-06"
assert_contains "the contract explains how the repo column stays honest" \
    "$CT" "test-installer-contract.sh"

# The two consumer commands must LINK here rather than restate the rules.
UT="$(cat "$REPO_ROOT/commands/repo/update-tools.md")"
FU="$(cat "$REPO_ROOT/commands/repo/followups.md")"
CONTRACT_URL="https://github.com/rjwalters/repo/blob/main/INSTALLER-CONTRACT.md"
assert_contains "update-tools.md links to the contract" "$UT" "$CONTRACT_URL"
assert_contains "followups.md links to the contract" "$FU" "$CONTRACT_URL"
# Installed command files live in consumer repos where a relative link would
# 404, so the reference must be a URL.
if [[ "$UT" != *"](INSTALLER-CONTRACT.md)"* && "$FU" != *"](INSTALLER-CONTRACT.md)"* ]]; then
    ok "neither command uses a repo-relative link that would 404 once installed"
else
    no "neither command uses a repo-relative link that would 404 once installed"
fi

# ---------------------------------------------------------------------------
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

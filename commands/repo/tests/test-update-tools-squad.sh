#!/usr/bin/env bash
# Doc-contract test: /repo:update-tools and /repo:followups must keep their
# squad guidance (release-path slug rule, update commands, adoption signature).
#
# Usage: ./commands/repo/tests/test-update-tools-squad.sh
# Exit code 0 = all pass, 1 = failures. Pure bash, hermetic (reads docs only).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
UPDATE_MD="$REPO_ROOT/commands/repo/update-tools.md"
FOLLOWUPS_MD="$REPO_ROOT/commands/repo/followups.md"

PASS=0; FAIL=0
flat() { tr '\n' ' ' | tr -s ' '; }
# has <label> <file> <needle> — needle must appear in the whitespace-flattened file
has() {
    if flat < "$2" | grep -qF -- "$3"; then
        PASS=$((PASS + 1)); echo "PASS: $1"
    else
        FAIL=$((FAIL + 1)); echo "FAIL: $1 (missing: $3)"
    fi
}

has "update-tools names squad as a family member" "$UPDATE_MD" 'squad (`.claude/skills/squad/`)'
has "update-tools gives release-install step"     "$UPDATE_MD" 'scripts/release-install.sh'
has "update-tools gives squad installer command"  "$UPDATE_MD" 'bash <SQUAD_HOME>/current/install.sh [--no-codex] [--no-link] <this-repo>'
has "update-tools notes no C7 resync for squad"   "$UPDATE_MD" 'squad ships no C7 resync-installed.sh'
has "update-tools states release-path rule"       "$UPDATE_MD" 'package: @rjwalters/squad'
has "update-tools infers slug from package name"  "$UPDATE_MD" '`@scope/name` → `scope/name`'
has "update-tools report row wording"             "$UPDATE_MD" 'current (commit drift unknown — source is a release install, not a source clone)'
has "update-tools adoption signature"             "$UPDATE_MD" 'differs from its installed copy'
has "update-tools names legacy adoption"          "$UPDATE_MD" 'legacy (pre-receipt) install needing manual adoption'
has "followups states release-path rule"          "$FOLLOWUPS_MD" 'package: @rjwalters/squad'
has "followups infers slug from package name"     "$FOLLOWUPS_MD" '`@scope/name` → `scope/name`'

echo ""
echo "Passed: $PASS"
echo "Failed: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
echo "ALL TESTS PASSED"

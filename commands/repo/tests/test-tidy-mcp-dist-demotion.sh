#!/usr/bin/env bash
# Test suite for /repo:tidy's CACHE -> ASK demotion when a CACHE-tier
# directory (dist/, .turbo/, etc.) is referenced by a registered MCP server
# config (repo#410).
#
# Usage: ./commands/repo/tests/test-tidy-mcp-dist-demotion.sh
# Exit code 0 = all tests pass, 1 = failures detected.
#
# Structured like commands/repo/tests/test-tidy-keep-tiers.sh: pure bash, no
# test framework, PASS/FAIL/SKIP/TOTAL counters and a summary block. `pnpm
# test` delegates to this file via hooks/repo/tests/run.sh.
#
# WHY THIS FILE EXISTS (repo#410): a /repo:tidy run in rjwalters/loom
# classified `mcp-loom/dist/` as CACHE (regenerable build output, cleared by
# `--caches`) even though that exact path is the bundle a registered
# user-scope `mcp-loom` MCP server loads from — clearing it would break every
# daemon spawn until the next rebuild. "Regenerable" and "harmless to delete
# right now" are different properties: the CACHE allowlist test only proves
# the first, so tidy needs a second test — is anything registered to load
# from this path right now? — before finalizing a CACHE match.
#
# The contract under test (tidy.md's CACHE bullet, "Reference scan"
# sub-paragraph):
#   1  the scan is a **reference scan**, run after the CACHE allowlist match,
#      never a hardcoded path list
#   2  it checks, in order: repo-root `.mcp.json`, `~/.claude.json`
#      top-level `mcpServers`, and `~/.claude.json`
#      `.projects["<repo-root>"].mcpServers` (project-scoped)
#   3  the match is a **path-prefix** match: `x/dist/` demotes on a hit for
#      `x/dist/index.js`, not only on an exact-path hit
#   4  a hit demotes the directory from CACHE to ASK, reported with the
#      reason ("referenced by <config>")
#   5  it is purely a demotion: a CACHE dir with no reference hit stays CACHE,
#      and --caches still reaches it
#   6  a missing/absent config degrades to a no-op, never a false demotion

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CMD_DIR="$REPO_ROOT/commands/repo"

TIDY_MD="$CMD_DIR/tidy.md"

# Assertion helpers (ok/no/skip/assert_eq/assert_contains/assert_not_contains/
# assert_matches) plus the PASS/FAIL/SKIP/TOTAL counters and color vars are
# shared across the repo test suites — see lib/assert.sh (repo#307).
source "$(dirname "${BASH_SOURCE[0]}")/lib/assert.sh"

if [[ ! -f "$TIDY_MD" ]]; then
    echo "FATAL: tidy.md not found at $TIDY_MD" >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "FATAL: jq is required to run these tests" >&2
    exit 1
fi

SCRATCH="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$SCRATCH"' EXIT

# ---------------------------------------------------------------------------
# The check under test — a direct transcription of the documented heuristic.
# ---------------------------------------------------------------------------

# mcp_referenced_paths <repo_root> [claude_json_path] -> every `args` entry
#   in every registered MCP server config this scan is documented to check,
#   newline-separated. Mirrors tidy.md's three ordered sources:
#     1. <repo_root>/.mcp.json                                .mcpServers[]?.args[]?
#     2. <claude_json_path> (if given)                        .mcpServers[]?.args[]?
#     3. <claude_json_path> .projects["<repo_root>"].mcpServers[]?.args[]?
#   A missing file at any source is silently skipped — the scan degrades to a
#   no-op rather than erroring out when a config simply isn't present.
mcp_referenced_paths() {
    local repo_root="$1" claude_json="${2:-}"
    local mcp_json="$repo_root/.mcp.json"

    if [[ -f "$mcp_json" ]]; then
        jq -r '(.mcpServers // {}) | .[]?.args[]?' "$mcp_json" 2>/dev/null
    fi
    if [[ -n "$claude_json" && -f "$claude_json" ]]; then
        jq -r '(.mcpServers // {}) | .[]?.args[]?' "$claude_json" 2>/dev/null
        jq -r --arg root "$repo_root" \
            '(.projects[$root].mcpServers // {}) | .[]?.args[]?' \
            "$claude_json" 2>/dev/null
    fi
}

# cache_demote_reason <repo_root> <claude_json_path> <candidate-dir> -> a
#   non-empty "referenced by <source>" reason string on a hit, empty on a
#   miss. The match is a PATH-PREFIX match, not exact: an absolute reference
#   under repo_root is relativized before comparison, and any referenced path
#   equal to the candidate dir OR nested under it counts as a hit — mirroring
#   tidy.md's "mcp-loom/dist/ demotes on a hit for mcp-loom/dist/index.js"
#   rule.
cache_demote_reason() {
    local repo_root="$1" claude_json="$2" dir="$3" p rel
    dir="${dir%/}"

    local from_mcp_json from_claude
    from_mcp_json="$( [[ -f "$repo_root/.mcp.json" ]] && \
        jq -r '(.mcpServers // {}) | .[]?.args[]?' "$repo_root/.mcp.json" 2>/dev/null )"
    from_claude=""
    if [[ -n "$claude_json" && -f "$claude_json" ]]; then
        from_claude="$(jq -r '(.mcpServers // {}) | .[]?.args[]?' "$claude_json" 2>/dev/null)"
        from_claude+=$'\n'"$(jq -r --arg root "$repo_root" \
            '(.projects[$root].mcpServers // {}) | .[]?.args[]?' "$claude_json" 2>/dev/null)"
    fi

    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        rel="$p"
        [[ "$rel" == "$repo_root"/* ]] && rel="${rel#"$repo_root"/}"
        if [[ "$rel" == "$dir" || "$rel" == "$dir"/* ]]; then
            echo "referenced by .mcp.json"
            return 0
        fi
    done <<< "$from_mcp_json"

    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        rel="$p"
        [[ "$rel" == "$repo_root"/* ]] && rel="${rel#"$repo_root"/}"
        if [[ "$rel" == "$dir" || "$rel" == "$dir"/* ]]; then
            echo "referenced by ~/.claude.json"
            return 0
        fi
    done <<< "$from_claude"

    return 1
}

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

# mkrepo <name> <tracked-path>... -> path to a fresh git repo with the given
#   tracked files (content is irrelevant — only paths matter for this scan).
mkrepo() {
    local name="$1"; shift
    local r="$SCRATCH/$name"
    mkdir -p "$r"
    git -C "$r" init -q
    git -C "$r" config user.email t@example.com
    git -C "$r" config user.name Test
    local p
    for p in "$@"; do
        mkdir -p "$r/$(dirname "$p")"
        printf 'content\n' > "$r/$p"
    done
    git -C "$r" add -A >/dev/null 2>&1
    git -C "$r" commit -qm init >/dev/null 2>&1
    printf '%s' "$r"
}

echo "/repo:tidy CACHE -> ASK MCP-reference demotion test suite"
echo "=========================================================="

# ---------------------------------------------------------------------------
echo ""
echo "-- the motivating case: repo-local .mcp.json referencing x/dist/ --"
# ---------------------------------------------------------------------------
# AC fixture, verbatim from the issue: a repo with .mcp.json pointing at
# x/dist/index.js -> x/dist/ lands in ASK (a demotion reason), not CACHE.
MCPDIST="$(mkrepo mcpdist src/main.py x/dist/index.js)"
cat > "$MCPDIST/.mcp.json" <<'EOF'
{
  "mcpServers": {
    "x": {
      "command": "node",
      "args": ["x/dist/index.js"]
    }
  }
}
EOF
REASON="$(cache_demote_reason "$MCPDIST" "" "x/dist")"
assert_eq "x/dist/ demotes to ASK via repo-local .mcp.json" \
    "referenced by .mcp.json" "$REASON"

# The exact loom#4230-adjacent shape from the issue body.
LOOMWT="$(mkrepo loomwt mcp-loom/src/index.ts mcp-loom/dist/index.js)"
cat > "$LOOMWT/.mcp.json" <<'EOF'
{"mcpServers": {"loom": {"command": "node", "args": ["mcp-loom/dist/index.js"]}}}
EOF
assert_eq "mcp-loom/dist/ (the exact issue#410 case) demotes" \
    "referenced by .mcp.json" \
    "$(cache_demote_reason "$LOOMWT" "" "mcp-loom/dist")"

# ---------------------------------------------------------------------------
echo ""
echo "-- an unreferenced CACHE dir stays CACHE (no false demotion) --"
# ---------------------------------------------------------------------------
UNREF="$(mkrepo unref src/main.py y/dist/index.js)"
cat > "$UNREF/.mcp.json" <<'EOF'
{"mcpServers": {"x": {"command": "node", "args": ["z/dist/index.js"]}}}
EOF
if cache_demote_reason "$UNREF" "" "y/dist" >/dev/null; then
    no "an unreferenced dist/ is not demoted" "y/dist matched but nothing references it"
else
    ok "an unreferenced dist/ is not demoted"
fi

# No .mcp.json at all: degrades to no-op, never a false demotion.
NOCFG="$(mkrepo nocfg src/main.py w/dist/index.js)"
if cache_demote_reason "$NOCFG" "" "w/dist" >/dev/null; then
    no "no .mcp.json present -> no demotion (degrades to no-op)" "unexpected demotion"
else
    ok "no .mcp.json present -> no demotion (degrades to no-op)"
fi

# ---------------------------------------------------------------------------
echo ""
echo "-- user-scope ~/.claude.json: top-level and per-project mcpServers --"
# ---------------------------------------------------------------------------
CLAUDEREPO="$(mkrepo claudetop src/main.py mcp-loom/dist/index.js)"
CLAUDE_JSON="$SCRATCH/claude-top.json"
cat > "$CLAUDE_JSON" <<EOF
{
  "mcpServers": {
    "loom": {
      "command": "node",
      "args": ["$CLAUDEREPO/mcp-loom/dist/index.js"]
    }
  }
}
EOF
assert_eq "top-level ~/.claude.json mcpServers (absolute path) demotes" \
    "referenced by ~/.claude.json" \
    "$(cache_demote_reason "$CLAUDEREPO" "$CLAUDE_JSON" "mcp-loom/dist")"

PROJREPO="$(mkrepo claudeproj src/main.py mcp-loom/dist/index.js)"
PROJ_CLAUDE_JSON="$SCRATCH/claude-proj.json"
cat > "$PROJ_CLAUDE_JSON" <<EOF
{
  "projects": {
    "$PROJREPO": {
      "mcpServers": {
        "loom": {
          "command": "node",
          "args": ["$PROJREPO/mcp-loom/dist/index.js"]
        }
      }
    }
  }
}
EOF
assert_eq "project-scoped ~/.claude.json .projects[<root>].mcpServers demotes" \
    "referenced by ~/.claude.json" \
    "$(cache_demote_reason "$PROJREPO" "$PROJ_CLAUDE_JSON" "mcp-loom/dist")"

# A different project's entry must not leak into this repo's scan.
OTHERPROJ="$(mkrepo otherproj src/main.py mcp-loom/dist/index.js)"
if cache_demote_reason "$OTHERPROJ" "$PROJ_CLAUDE_JSON" "mcp-loom/dist" >/dev/null; then
    no "a different project's entry does not cross-contaminate" "unexpected demotion"
else
    ok "a different project's entry does not cross-contaminate"
fi

# Missing ~/.claude.json entirely: no-op, not a crash.
NOCLAUDE="$(mkrepo noclaude src/main.py mcp-loom/dist/index.js)"
if cache_demote_reason "$NOCLAUDE" "$SCRATCH/does-not-exist.json" "mcp-loom/dist" >/dev/null; then
    no "a missing ~/.claude.json path degrades to no-op" "unexpected demotion"
else
    ok "a missing ~/.claude.json path degrades to no-op"
fi

# ---------------------------------------------------------------------------
echo ""
echo "-- path-prefix match, not exact-path only --"
# ---------------------------------------------------------------------------
# tidy.md is explicit: "mcp-loom/dist/ demotes on a hit for
# mcp-loom/dist/index.js" — the candidate directory, the referenced FILE.
PREFIX="$(mkrepo prefix src/main.py bundle/dist/server/index.js)"
cat > "$PREFIX/.mcp.json" <<'EOF'
{"mcpServers": {"b": {"command": "node", "args": ["bundle/dist/server/index.js"]}}}
EOF
assert_eq "a nested file under the candidate dir still demotes it" \
    "referenced by .mcp.json" \
    "$(cache_demote_reason "$PREFIX" "" "bundle/dist")"

# A path that merely shares a string prefix (not a real path segment) must
# NOT match — dist-tools/ is not a nested path under dist/.
SIBLING="$(mkrepo sibling src/main.py dist/index.js dist-tools/index.js)"
cat > "$SIBLING/.mcp.json" <<'EOF'
{"mcpServers": {"b": {"command": "node", "args": ["dist-tools/index.js"]}}}
EOF
if cache_demote_reason "$SIBLING" "" "dist" >/dev/null; then
    no "a string-prefix (not path-prefix) sibling does not demote" "dist-tools/ falsely matched dist/"
else
    ok "a string-prefix (not path-prefix) sibling does not demote"
fi

# ---------------------------------------------------------------------------
echo ""
echo "-- report: the demotion carries a reason, matching tidy.md's wording --"
# ---------------------------------------------------------------------------
render_ask_line() {  # <dir> <size> <reason>
    printf '  %-24s gitignored, %s  ← live MCP bundle (%s); --caches will not clear it\n' \
        "$1/" "$2" "$3"
}
LINE="$(render_ask_line "mcp-loom/dist" "796K" "referenced by .mcp.json")"
assert_contains "the rendered ASK line names the live MCP bundle" \
    "$LINE" "live MCP bundle"
assert_contains "the rendered ASK line states --caches will not clear it" \
    "$LINE" "--caches will not clear it"
assert_contains "the rendered ASK line carries the reference reason" \
    "$LINE" "referenced by .mcp.json"

# ---------------------------------------------------------------------------
echo ""
echo "-- doc drift: tidy.md still specifies what this suite implements --"
# ---------------------------------------------------------------------------
# Phrases are asserted against a whitespace-flattened copy, since the
# requirement is prose that wraps across lines. (flatten() is defined in
# lib/assert.sh)
TIDY="$(flatten "$TIDY_MD")"

assert_contains "tidy.md documents the CACHE reference scan by name" \
    "$TIDY" 'Reference scan (additional net, after the allowlist match, not instead of'
assert_contains "the CACHE scan is framed as the same mechanism as the empty-dir scan" \
    "$TIDY" 'the same mechanism as the empty-directory reference scan above'
assert_contains "tidy.md distinguishes regenerable from harmless-to-delete-now" \
    "$TIDY" '"Regenerable" and "harmless to delete'
assert_contains "tidy.md names .mcp.json as source 1" \
    "$TIDY" '`.mcp.json` in the repo root, if present'
assert_contains "tidy.md names top-level ~/.claude.json mcpServers as source 2" \
    "$TIDY" '`~/.claude.json` `.mcpServers[]?.args[]?` (top-level, user-scope servers)'
assert_contains "tidy.md names project-scoped ~/.claude.json mcpServers as source 3" \
    "$TIDY" '(project-scoped servers)'
assert_contains "tidy.md resolves the repo root non-hardcoded" \
    "$TIDY" 'never hardcoded'
assert_contains "tidy.md names install-metadata.json as a best-effort source" \
    "$TIDY" "Best-effort: any installed tool's tracked"
assert_contains "tidy.md states the match is a path-prefix match" \
    "$TIDY" '**path-prefix** match, not an exact one'
assert_contains "tidy.md gives the exact mcp-loom/dist/ prefix example" \
    "$TIDY" '`mcp-loom/dist/` demotes on a hit for'
assert_contains "tidy.md states the demotion reason wording" \
    "$TIDY" '← live MCP bundle (referenced by <config-path>)'
assert_contains "tidy.md states this is purely a demotion (never promotes)" \
    "$TIDY" 'this is purely a **demotion** — it never promotes'
assert_contains "tidy.md states an unreferenced CACHE dir stays CACHE" \
    "$TIDY" 'a CACHE entry with no reference hit stays CACHE exactly as before'
assert_contains "the ASK bullet list documents the new demotion source" \
    "$TIDY" '**Any CACHE-tier directory demoted by the MCP-config reference scan**'
assert_contains "the ASK bullet states --caches must not reach a demoted entry" \
    "$TIDY" 'so `--caches` must not reach it'
assert_contains "the sample report shows the demoted mcp-loom/dist/ ASK line" \
    "$TIDY" 'mcp-loom/dist/ gitignored, 796K'
assert_contains "the sample report line names the live MCP bundle reason" \
    "$TIDY" '← live MCP bundle (referenced by ~/.claude.json); --caches will not clear it'
assert_contains "step 2's intro names both reference scans" \
    "$TIDY" 'For empty directories and for CACHE-tier build-output directories, a **reference scan runs after the allowlist match'

# Safety-rule invariants this change must not touch: rule 7 (caches are opt-in)
# and the general "CACHE kept by default" contract stay verbatim.
assert_contains "safety rule 7 (caches are opt-in) is unchanged" \
    "$(cat "$TIDY_MD")" \
    '7. **Caches are opt-in**'

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

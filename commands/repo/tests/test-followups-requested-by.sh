#!/usr/bin/env bash
# Test suite for /repo:followups' requested-by attribution contract (repo#556).
#
# Usage: ./commands/repo/tests/test-followups-requested-by.sh
# Exit code 0 = all tests pass, 1 = failures detected.
#
# Structured like test-followups-dedup-step.sh: pure bash, no test framework,
# PASS/FAIL/SKIP/TOTAL counters and a summary block. `pnpm test` delegates to
# this file via hooks/repo/tests/run.sh. Hermetic — it reads
# commands/repo/followups.md from the working tree, writes only to a mktemp
# directory, and stubs `gh` so no network call or real filing ever happens.
#
# WHY THIS FILE EXISTS (repo#556): /repo:followups filed issues without saying
# who asked for them, so a dashboard saw only the token's login — usually the
# operator's, even when an agent started the follow-up on its own. Step 5 now
# requires exactly one `<!-- loom:requested-by login=<login> via=<session|agent> -->`
# marker, outside code fences, in every newly filed body.
#
# The contract under test:
#   1  step 5 states the marker requirement in PROSE (outside code fences),
#      for this-repo and upstream targets, before the payload is built
#   2  requester resolution: operator session -> operator login + via=session;
#      agent-originated -> initiating role + via=agent; token login alone never
#      establishes the requester
#   3  placement: the recipe's marker check runs before the jq --rawfile
#      payload build, which runs before the POST; dry-run/confirm/scrub intact
#   4  the documented marker check accepts exactly one real marker and rejects
#      none / fenced-only / duplicate bodies
#   5  serialization fixtures: Markdown, backticks, quotes and $(...) survive
#      the documented jq --rawfile payload build, with the right marker for a
#      session and an agent requester sharing one token (stubbed gh POST)
#   6  mutation guard: removing the requirement, or moving it inside a code
#      fence, makes the step-1 contract check fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
FOLLOWUPS_MD="$REPO_ROOT/commands/repo/followups.md"

source "$(dirname "${BASH_SOURCE[0]}")/lib/assert.sh"

if [[ ! -f "$FOLLOWUPS_MD" ]]; then
    echo "FATAL: required file not found at $FOLLOWUPS_MD" >&2
    exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "FATAL: jq is required" >&2
    exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/followups-requested-by.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

FOLLOWUPS="$(cat "$FOLLOWUPS_MD")"

# step5 <file> — the "### 5." section up to "## Safety Rules".
step5() {
    awk '/^### 5\. /{on=1} /^## Safety Rules/{on=0} on' "$1"
}
# unfenced — drop fenced code blocks (``` or ~~~) from stdin.
unfenced() {
    awk '/^[[:space:]]*(```|~~~)/{f=!f; next} !f'
}
# fenced — keep only the contents of fenced code blocks from stdin.
fenced() {
    awk '/^[[:space:]]*(```|~~~)/{f=!f; next} f'
}
flat() { tr '\n' ' ' | tr -s ' '; }

MARKER_TEMPLATE='<!-- loom:requested-by login=<login> via=<session|agent> -->'

# check_requirement <file> — silent; echoes the number of missing prose
# requirements in step 5 (outside fences). 0 means the contract is stated.
check_requirement() {
    local prose missing=0 needle
    prose="$(step5 "$1" | unfenced | flat)"
    for needle in \
        "Every newly filed issue body MUST end with exactly one requested-by marker" \
        "before the payload is built" \
        "for this-repo and upstream targets alike" \
        "$MARKER_TEMPLATE" \
        '`login=<operator GitHub login> via=session`' \
        '`login=<initiating role> via=agent`' \
        "even when the agent and the operator share the same token" \
        "The token's authenticated login alone does not establish the requester." \
        "a marker inside a fenced example does not attribute anything"; do
        [[ "$prose" == *"$needle"* ]] || missing=$((missing + 1))
    done
    echo "$missing"
}

# ---------------------------------------------------------------------------
echo "1. Step 5 states the marker requirement outside code fences"
# ---------------------------------------------------------------------------

STEP5="$(step5 "$FOLLOWUPS_MD")"
STEP5_PROSE="$(printf '%s\n' "$STEP5" | unfenced | flat)"
STEP5_CODE="$(printf '%s\n' "$STEP5" | fenced)"

if [[ -n "$STEP5" ]]; then ok "step 5 section exists"; else no "step 5 section exists" "no '### 5.' heading"; fi
assert_contains "requirement: exactly one marker in every newly filed body" "$STEP5_PROSE" \
    "Every newly filed issue body MUST end with exactly one requested-by marker"
assert_contains "requirement applies to this-repo and upstream targets" "$STEP5_PROSE" \
    "for this-repo and upstream targets alike"
assert_contains "marker is written before the payload is built" "$STEP5_PROSE" \
    "written into the scratch body before the payload is built"
assert_contains "the marker template is given in prose" "$STEP5_PROSE" "$MARKER_TEMPLATE"
assert_contains "a fenced example is not attribution" "$STEP5_PROSE" \
    "a marker inside a fenced example does not attribute anything"
assert_eq "check_requirement passes on the real followups.md" "0" \
    "$(check_requirement "$FOLLOWUPS_MD")"
assert_contains "safety rule 11 records the attribution rule" "$FOLLOWUPS" \
    "11. **Attribute every filed issue to its requester**"
assert_not_contains "create-issue.sh --requested-by flag is not used" "$FOLLOWUPS" "--requested-by"

# ---------------------------------------------------------------------------
echo ""
echo "2. Requester resolution: session vs agent, token login is not the requester"
# ---------------------------------------------------------------------------

assert_contains "operator session -> operator login, via=session" "$STEP5_PROSE" \
    '**Operator session** — a human operator ran `/repo:followups` in this session: `login=<operator GitHub login> via=session`.'
assert_contains "agent-originated -> initiating role, via=agent" "$STEP5_PROSE" \
    '`login=<initiating role> via=agent`'
assert_contains "agent attribution holds under a shared token" "$STEP5_PROSE" \
    "even when the agent and the operator share the same token"
assert_contains "token login alone does not establish the requester" "$STEP5_PROSE" \
    "The token's authenticated login alone does not establish the requester."
assert_contains "no human requester inferred from a shared agent token" "$STEP5_PROSE" \
    "never infer a human requester from a shared agent token"
assert_contains "agent work is never marked via=session" "$STEP5_PROSE" \
    'never mark agent work `via=session`'
assert_contains "a missing human login is asked for, not invented" "$STEP5_PROSE" \
    "ask for it before filing"
assert_contains "attribution does not bypass confirmation" "$STEP5_PROSE" \
    "Attribution never bypasses step 4"

# ---------------------------------------------------------------------------
echo ""
echo "3. Placement in the step 5 recipe; dry-run, confirm and scrub intact"
# ---------------------------------------------------------------------------

CHECK_LN="$(printf '%s\n' "$STEP5" | grep -nE "^awk .*loom:requested-by" | head -1 | cut -d: -f1)"
JQ_LN="$(printf '%s\n' "$STEP5" | grep -nE '^jq -n --arg t "<title>" --rawfile b /tmp/followup-body.md' | head -1 | cut -d: -f1)"
POST_LN="$(printf '%s\n' "$STEP5" | grep -nE '^gh api --method POST "repos/<slug>/issues" --input' | head -1 | cut -d: -f1)"
SHAPE_LN="$(printf '%s\n' "$STEP5" | grep -nF "#      $MARKER_TEMPLATE" | head -1 | cut -d: -f1)"
if [[ -n "$CHECK_LN" && -n "$JQ_LN" && -n "$POST_LN" && -n "$SHAPE_LN" ]] \
    && (( SHAPE_LN < CHECK_LN && CHECK_LN < JQ_LN && JQ_LN < POST_LN )); then
    ok "body shape -> marker check -> jq --rawfile payload -> POST, in order"
else
    no "body shape -> marker check -> jq --rawfile payload -> POST, in order" \
        "shape=$SHAPE_LN check=$CHECK_LN jq=$JQ_LN post=$POST_LN"
fi
CHECK_CMD="$(printf '%s\n' "$STEP5_CODE" | grep -E "^awk .*loom:requested-by" | head -1)"
assert_contains "the marker check is inside the recipe's code block" "$CHECK_CMD" "awk "
assert_contains "the marker check reads the literal scratch path" "$CHECK_CMD" "/tmp/followup-body.md"
assert_not_contains "the marker check uses no shell-variable path" "$CHECK_CMD" '$BODY'
assert_contains "dry-run still stops before filing" "$(flat < "$FOLLOWUPS_MD")" \
    'If `--dry-run` was passed, stop here — file nothing.'
assert_contains "the marker is shown in the step 4 preview" "$STEP5_PROSE" \
    "Show it in step 4's body preview"
assert_contains "the marker is appended after the scrub" "$STEP5_PROSE" "appended after step 3b's scrub"
assert_contains "payload labels stay empty" "$FOLLOWUPS" "'{title: \$t, body: \$b, labels: []}'"
assert_contains "literal scratch-path rule intact" "$FOLLOWUPS" \
    "**Use a literal, spelled-out scratch path — never a"

# ---------------------------------------------------------------------------
echo ""
echo "4. The documented marker check accepts exactly one real marker"
# ---------------------------------------------------------------------------

# run_check <body-file> — run the awk command exactly as documented, pointed
# at a fixture instead of /tmp/followup-body.md.
run_check() {
    local cmd="${CHECK_CMD//\/tmp\/followup-body.md/$1}"
    bash -c "$cmd"
}

FENCE='```'
write_base_body() {  # <file> — Markdown, backticks, quotes, $(…), and a fenced example marker
    cat > "$1" <<EOF
## Context

The "orphans" check's \`find\` misses nested dirs when \`-maxdepth\` is >= 3.
A body line with \$(rm -rf /) and \`backticks\` and 'single' and "double" quotes.

${FENCE}markdown
<!-- loom:requested-by login=example-user via=session -->
${FENCE}

## Suggested acceptance criteria
- [ ] nested dirs are found
- [x] keep \\ backslashes and \t tabs literal
EOF
}

write_base_body "$WORK/none.md"
if run_check "$WORK/none.md"; then no "a body with no real marker is rejected" "check exited 0"; else ok "a body with no real marker is rejected"; fi

if [[ -n "$CHECK_CMD" ]]; then
    write_base_body "$WORK/fenced-only.md"
    printf '\n%s\n<!-- loom:requested-by login=builder via=agent -->\n%s\n' "$FENCE" "$FENCE" >> "$WORK/fenced-only.md"
    if run_check "$WORK/fenced-only.md"; then no "a marker only inside a fence is rejected" "check exited 0"; else ok "a marker only inside a fence is rejected"; fi

    write_base_body "$WORK/two.md"
    printf '\n<!-- loom:requested-by login=builder via=agent -->\n<!-- loom:requested-by login=octo-operator via=session -->\n' >> "$WORK/two.md"
    if run_check "$WORK/two.md"; then no "two effective markers are rejected" "check exited 0"; else ok "two effective markers are rejected"; fi

    write_base_body "$WORK/one.md"
    printf '\n<!-- loom:requested-by login=octo-operator via=session -->\n' >> "$WORK/one.md"
    if run_check "$WORK/one.md"; then ok "exactly one real marker is accepted"; else no "exactly one real marker is accepted" "check exited non-zero"; fi
else
    no "the documented marker check could be extracted" "no awk line in step 5"
fi

# ---------------------------------------------------------------------------
echo ""
echo "5. Serialization through jq --rawfile, session vs agent on a shared token"
# ---------------------------------------------------------------------------

# Stub gh: `api user` reports the shared token's login; a POST records the
# --input payload instead of filing anything.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2" == "api user" ]]; then echo "shared-token-login"; exit 0; fi
input=""
while [[ $# -gt 0 ]]; do
    [[ "$1" == "--input" ]] && { input="$2"; shift; }
    shift
done
[[ -n "$input" ]] && cp "$input" "$STUB_POSTED"
echo "https://github.com/example/example/issues/1"
EOF
chmod +x "$WORK/bin/gh"

JQ_CMD="$(printf '%s\n' "$STEP5_CODE" | grep -A1 -E '^jq -n --arg t "<title>" --rawfile b' | tr -d '\\\n' | tr -s ' ')"
POST_CMD="$(printf '%s\n' "$STEP5_CODE" | grep -E '^gh api --method POST "repos/<slug>/issues" --input' | head -1)"

# effective_marker — the first requested-by marker outside fences in stdin.
effective_marker() {
    unfenced | grep -oE '<!-- loom:requested-by login=[^ ]+ via=[a-z]+ -->' | head -1
}

# file_fixture <name> <login> <via> — build the body, run the documented
# check, jq build and (stubbed) POST; echo the posted body.
file_fixture() {
    local name="$1" login="$2" via="$3" d="$WORK/$1"
    mkdir -p "$d"
    write_base_body "$d/body.md"
    printf '\n<!-- loom:requested-by login=%s via=%s -->\n' "$login" "$via" >> "$d/body.md"
    run_check "$d/body.md" || return 1
    local jq_cmd="${JQ_CMD//\/tmp\/followup-body.md/$d/body.md}"
    jq_cmd="${jq_cmd//\/tmp\/followup-payload.json/$d/payload.json}"
    jq_cmd="${jq_cmd//<title>/followups: \\\"quoted\\\" \\\`title\\\`}"
    local post_cmd="${POST_CMD//\/tmp\/followup-payload.json/$d/payload.json}"
    post_cmd="${post_cmd//<slug>/example/example}"
    bash -c "$jq_cmd" || return 1
    PATH="$WORK/bin:$PATH" STUB_POSTED="$d/posted.json" GH_TOKEN=shared bash -c "$post_cmd" >/dev/null || return 1
    jq -r '.body' "$d/posted.json"
}

assert_contains "the payload build is the documented jq --rawfile form" "$JQ_CMD" "--rawfile b /tmp/followup-body.md"

TOKEN_LOGIN="$(PATH="$WORK/bin:$PATH" gh api user --jq .login)"
for case in "session octo-operator session" "agent builder agent"; do
    read -r name login via <<<"$case"
    posted="$(file_fixture "$name" "$login" "$via")"
    status=$?
    if [[ $status -ne 0 || -z "$posted" ]]; then
        no "$name: fixture files through the documented recipe" "exit $status"
        continue
    fi
    ok "$name: fixture files through the documented recipe"
    assert_eq "$name: posted body is byte-identical to the scratch body" \
        "$(cat "$WORK/$name/body.md")" "$posted"
    assert_eq "$name: effective marker names the right requester" \
        "<!-- loom:requested-by login=$login via=$via -->" \
        "$(printf '%s\n' "$posted" | effective_marker)"
    assert_eq "$name: payload labels are empty" "[]" "$(jq -c '.labels' "$WORK/$name/posted.json")"
    assert_eq "$name: quoted/backticked title survives" 'followups: "quoted" `title`' \
        "$(jq -r '.title' "$WORK/$name/posted.json")"
    for needle in '$(rm -rf /)' '`backticks`' "'single'" '"double"' '>= 3' '- [ ] nested dirs are found' \
                  '\ backslashes and \t tabs'; do
        assert_contains "$name: body keeps literal $needle" "$posted" "$needle"
    done
    assert_contains "$name: fenced example stays in the body" "$posted" \
        "${FENCE}markdown"
done
assert_eq "shared token reports one login for both cases" "shared-token-login" "$TOKEN_LOGIN"
s_marker="$(jq -r '.body' "$WORK/session/posted.json" 2>/dev/null | effective_marker)"
a_marker="$(jq -r '.body' "$WORK/agent/posted.json" 2>/dev/null | effective_marker)"
if [[ -n "$s_marker" && -n "$a_marker" && "$s_marker" != "$a_marker" ]]; then
    ok "session and agent requesters stay distinct under one token"
else
    no "session and agent requesters stay distinct under one token" "s=$s_marker a=$a_marker"
fi
assert_not_contains "the token login is not the agent requester" "$a_marker" "$TOKEN_LOGIN"

# ---------------------------------------------------------------------------
echo ""
echo "6. Mutation guard: removing or fencing the requirement fails the check"
# ---------------------------------------------------------------------------

# Removed: drop the requirement paragraph from step 5.
grep -vF "Every newly filed issue body MUST end with exactly" "$FOLLOWUPS_MD" > "$WORK/removed.md"
r="$(check_requirement "$WORK/removed.md")"
if [[ "$r" -gt 0 ]]; then ok "removing the requirement fails the contract check"; else no "removing the requirement fails the contract check" "missing=0"; fi

# Fenced: wrap the whole "Attribute the requester" block in a code fence.
awk -v f="$FENCE" '
    /^\*\*Attribute the requester\.\*\*/ { print f; inblk=1 }
    inblk && /^Print the resulting issue URLs/ { print f; inblk=0 }
    { print }
' "$FOLLOWUPS_MD" > "$WORK/fenced.md"
r="$(check_requirement "$WORK/fenced.md")"
if [[ "$r" -gt 0 ]]; then ok "fencing the requirement fails the contract check"; else no "fencing the requirement fails the contract check" "missing=0"; fi

# Moved out of step 5: the same text under Safety Rules does not count.
awk '
    /^\*\*Attribute the requester\.\*\*/ { hold=1 }
    hold && /^Print the resulting issue URLs/ { hold=0 }
    hold { buf = buf $0 "\n"; next }
    { print }
    END { printf "%s", buf }
' "$FOLLOWUPS_MD" > "$WORK/moved.md"
r="$(check_requirement "$WORK/moved.md")"
if [[ "$r" -gt 0 ]]; then ok "moving the requirement out of step 5 fails the contract check"; else no "moving the requirement out of step 5 fails the contract check" "missing=0"; fi

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

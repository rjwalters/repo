#!/usr/bin/env bash
# Test suite for scripts/repo/repo-remote.sh — the headless, scriptable
# provisioning entry point documented (as prose) in commands/repo/remote.md and
# consumed by loom's `fleet add-worker` (repo#52).
#
# Usage: ./commands/repo/tests/test-repo-remote.sh
# Exit code 0 = all tests pass, 1 = failures detected.
#
# Structured like commands/repo/tests/test-branches-loss-check.sh: pure bash, no
# framework, PASS/FAIL/TOTAL counters and a summary block. `pnpm test` delegates
# to this file via hooks/repo/tests/run.sh.
#
# WHY THIS FILE EXISTS (repo#52): remote.md is prose an agent reads; the script
# under test is the executable extraction of its provisioning contract. The two
# things this suite pins down are the two things that can cost real money if
# wrong:
#   1. the cost gate — `up` (with or without --yes) must fail LOUDLY (exit 2)
#      when a cost-relevant field (provider, credentials, instance type) is
#      missing from config, never silently substitute a default;
#   2. config-layer precedence — repo `.env` overrides the shared remote.env.
# It also covers JSON output shape, GPU detection/cost, the idle-shutdown guard,
# instance-id write-back, and the end-to-end up/status/down flow against a mock
# `aws` CLI. A doc-drift block at the end asserts remote.md still documents the
# subcommands/flags the script implements.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
RR="$REPO_ROOT/scripts/repo/repo-remote.sh"
REMOTE_MD="$REPO_ROOT/commands/repo/remote.md"

PASS=0
FAIL=0
TOTAL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

if [[ ! -f "$RR" ]]; then
    echo "FATAL: repo-remote.sh not found at $RR" >&2
    exit 1
fi
if [[ ! -f "$REMOTE_MD" ]]; then
    echo "FATAL: remote.md not found at $REMOTE_MD" >&2
    exit 1
fi

SCRATCH="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$SCRATCH"' EXIT

# ---------------------------------------------------------------------------
# Assertion helpers (same shape as test-branches-loss-check.sh)
# ---------------------------------------------------------------------------
ok() { TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1)); printf "  ${GREEN}PASS${NC}: %s\n" "$1"; }
no() {
    TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
    printf "  ${RED}FAIL${NC}: %s\n" "$1"
    [[ -n "${2:-}" ]] && printf "        %s\n" "$2"
    return 0
}
assert_eq()       { if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1" "expected [$2], got [$3]"; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then ok "$1"; else no "$1" "missing [$3] in [$2]"; fi; }
assert_not_contains() { if [[ "$2" != *"$3"* ]]; then ok "$1"; else no "$1" "unexpected [$3] present"; fi; }

# json_field <json> <key> -> value of a flat string/number/bool field
json_field() {
    printf '%s' "$1" | sed -n "s/.*\"$2\":\"\\([^\"]*\\)\".*/\\1/p; s/.*\"$2\":\\([0-9.a-z]*\\).*/\\1/p" | head -n1
}

# ---------------------------------------------------------------------------
# A fixture repo + config layers. XDG_CONFIG_HOME points at a scratch dir so the
# shared remote.env is a fixture; the repo `.env` lives at a scratch git root.
# ---------------------------------------------------------------------------
FIX="$SCRATCH/fixture"
XDG="$FIX/xdg"
REPO="$FIX/myrepo"
SHARED="$XDG/repo/remote.env"
mkdir -p "$XDG/repo" "$REPO"
git -C "$REPO" init -q

write_shared() { mkdir -p "$XDG/repo"; printf '%s\n' "$@" >"$SHARED"; }
write_repo_env() { printf '%s\n' "$@" >"$REPO/.env"; }

# run_rr <extra-env...> -- <args...>  -> runs the script in the fixture repo with
# XDG_CONFIG_HOME set, SSH config redirected to scratch, and the mock aws on PATH.
MOCK_BIN="$SCRATCH/bin"
MOCK_LOG="$SCRATCH/aws.log"
mkdir -p "$MOCK_BIN"
RR_OUT=""; RR_ERR=""; RR_RC=0
run_rr() {
    local -a envs=()
    while [[ "$1" != "--" ]]; do envs+=("$1"); shift; done
    shift
    : >"$MOCK_LOG"
    local errf; errf="$(mktemp)"
    RR_OUT="$(cd "$REPO" && env \
        PATH="$MOCK_BIN:$PATH" \
        XDG_CONFIG_HOME="$XDG" \
        REPO_REMOTE_SSH_CONFIG="$SCRATCH/ssh_config" \
        MOCK_AWS_LOG="$MOCK_LOG" \
        "${envs[@]}" \
        bash "$RR" "$@" 2>"$errf")"
    RR_RC=$?
    RR_ERR="$(cat "$errf")"; rm -f "$errf"
}

# ---------------------------------------------------------------------------
# The mock `aws` CLI. Logs every invocation to $MOCK_AWS_LOG and returns canned
# output for exactly the subcommands repo-remote.sh calls. Scenario is driven by
# env vars so each test controls reuse/create/find behavior.
# ---------------------------------------------------------------------------
cat >"$MOCK_BIN/aws" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${MOCK_AWS_LOG:-/dev/null}"
case "$1 $2" in
  "sts get-caller-identity")
    [[ "${MOCK_AWS_AUTH_FAIL:-0}" == 1 ]] && exit 255
    echo '{"Account":"123456789012","Arn":"arn:aws:iam::123456789012:user/test"}'; exit 0 ;;
  "ec2 describe-images")
    echo "${MOCK_AWS_AMI:-ami-0ubuntu2204}"; exit 0 ;;
  "ec2 describe-security-groups")
    if printf '%s' "$*" | grep -q -- '--group-ids'; then
      # Post-authorize verification (aws_verify_ssh_ingress): a tcp/22 ingress
      # rule must be present, or repo-remote.sh must die loudly (repo#176 AC1).
      if [[ "${MOCK_AWS_SG_INGRESS_EMPTY:-0}" == 1 ]]; then
        printf '\n'
      else
        printf '22\t22\ttcp\t0.0.0.0/0\n'
      fi
    else
      # Tag-based resolve-or-create lookup (aws_find_tagged_sg).
      printf '%s\n' "${MOCK_AWS_SG_FIND:-None}"
    fi
    exit 0 ;;
  "ec2 create-security-group")
    if [[ "${MOCK_AWS_SG_CREATE_FAIL:-0}" == 1 ]]; then
      echo "An error occurred (UnauthorizedOperation) when calling the CreateSecurityGroup operation" >&2
      exit 254
    fi
    echo "${MOCK_AWS_SG_NEW_ID:-sg-0new}"; exit 0 ;;
  "ec2 authorize-security-group-ingress")
    if [[ "${MOCK_AWS_INGRESS_DUP:-0}" == 1 ]]; then
      echo "An error occurred (InvalidPermission.Duplicate) when calling the AuthorizeSecurityGroupIngress operation" >&2
      exit 254
    fi
    exit 0 ;;
  "ec2 describe-instances")
    # Fleet-marker lookup (repo#164) is also an --instance-ids call, so it must
    # be matched FIRST by its Tags[?Key=...] query projection.
    if printf '%s' "$*" | grep -qF "Tags[?Key=="; then
      # repo#170: down's tag-discovery path can resolve MULTIPLE ids, so the
      # per-id marker needs to be distinguishable in tests (mixed-batch
      # scenarios). MOCK_AWS_FLEET_MARKED_IDS, when set, is a space-separated
      # allowlist of instance ids that carry the marker; any id NOT in that
      # list is reported unmarked. When unset, every id gets the single
      # MOCK_AWS_FLEET_TAG value (existing behavior, unchanged).
      if [[ -n "${MOCK_AWS_FLEET_MARKED_IDS:-}" ]]; then
        lookup_id=""
        prev=""
        for a in "$@"; do
          [[ "$prev" == "--instance-ids" ]] && lookup_id="$a"
          prev="$a"
        done
        case " ${MOCK_AWS_FLEET_MARKED_IDS} " in
          *" $lookup_id "*) printf '%s\n' "${MOCK_AWS_FLEET_TAG:-loom}" ;;
          *) printf '%s\n' "None" ;;
        esac
        exit 0
      fi
      printf '%s\n' "${MOCK_AWS_FLEET_TAG:-None}"
      exit 0
    fi
    # --instance-ids (pinned lookup) vs --filters (tag find)
    if printf '%s' "$*" | grep -q -- '--instance-ids'; then
      echo "${MOCK_AWS_STATE:-None}"
    else
      # tag find / status: emit configured rows (may be empty)
      printf '%s' "${MOCK_AWS_FIND:-}"
    fi
    exit 0 ;;
  "ec2 run-instances")
    if [[ "${MOCK_AWS_QUOTA_FAIL:-0}" == 1 ]]; then
      echo "An error occurred (VcpuLimitExceeded) when calling the RunInstances operation" >&2
      exit 254
    fi
    # Capture the generated user-data (idle guard) so the suite can assert on the
    # guard script's content. --user-data is passed as `file://<path>`; the temp
    # file still exists at call time (repo-remote.sh deletes it only afterwards).
    prev=""
    for a in "$@"; do
      if [[ "$prev" == "--user-data" ]]; then
        f="${a#file://}"
        [[ -f "$f" ]] && cat "$f" >"${MOCK_AWS_LOG}.userdata"
      fi
      prev="$a"
    done
    echo "${MOCK_AWS_NEW_ID:-i-0newinstance}"; exit 0 ;;
  "ec2 wait"|"ec2 start-instances"|"ec2 stop-instances"|"ec2 terminate-instances")
    exit 0 ;;
  *) exit 0 ;;
esac
MOCK
chmod +x "$MOCK_BIN/aws"

# ---------------------------------------------------------------------------
# A minimal mock `gcloud`, covering only the calls gcp_up() makes. Added for the
# GCP half of the fleet-marker guard (repo#164) so the label-based check is
# exercised, not just the AWS tag-based one.
# ---------------------------------------------------------------------------
cat >"$MOCK_BIN/gcloud" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${MOCK_AWS_LOG:-/dev/null}"
case "$1 $2 ${3:-}" in
  "compute instances describe")
    if printf '%s' "$*" | grep -qF 'labels.'; then
      printf '%s\n' "${MOCK_GCP_FLEET_LABEL:-}"      # fleet-marker lookup
    elif printf '%s' "$*" | grep -qF 'natIP'; then
      printf '%s\n' "${MOCK_GCP_IP:-1.2.3.4}"        # public IP lookup
    else
      printf '%s\n' "${MOCK_GCP_STATE:-}"            # existence/status lookup
    fi
    exit 0 ;;
esac
exit 0
MOCK
chmod +x "$MOCK_BIN/gcloud"

# ---------------------------------------------------------------------------
# Mock `curl` (backs aws_resolve_ssh_cidr's current-IP detection, repo#176)
# and mock `ssh` (backs aws_check_reachability's end-of-run probe). Both
# default to a benign success so every pre-existing scenario below — which
# doesn't care about either — is unaffected; specific tests override via
# MOCK_CURL_FAIL / MOCK_CURL_IP / MOCK_SSH_FAIL.
# ---------------------------------------------------------------------------
cat >"$MOCK_BIN/curl" <<'MOCK'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"${MOCK_AWS_LOG:-/dev/null}"
[[ "${MOCK_CURL_FAIL:-0}" == 1 ]] && exit 1
printf '%s' "${MOCK_CURL_IP:-203.0.113.7}"
exit 0
MOCK
chmod +x "$MOCK_BIN/curl"

cat >"$MOCK_BIN/ssh" <<'MOCK'
#!/usr/bin/env bash
printf 'ssh %s\n' "$*" >>"${MOCK_AWS_LOG:-/dev/null}"
[[ "${MOCK_SSH_FAIL:-0}" == 1 ]] && exit 255
exit 0
MOCK
chmod +x "$MOCK_BIN/ssh"

echo "repo-remote.sh test suite"
echo "========================="
echo ""

# ---------------------------------------------------------------------------
echo "-- the cost gate: missing required config fails LOUDLY, never defaults --"
# ---------------------------------------------------------------------------
write_shared "REPO_REMOTE_PROVIDER=aws" "AWS_ACCESS_KEY_ID=AKIA" "AWS_SECRET_ACCESS_KEY=sk" "AWS_REGION=us-west-2"
rm -f "$REPO/.env"
run_rr -- up --yes --json
assert_eq   "missing instance type -> exit 2 (the cost gate)" "2" "$RR_RC"
assert_contains "names the missing cost-relevant var" "$RR_ERR" "REPO_REMOTE_INSTANCE_TYPE"
assert_not_contains "did NOT emit an up result (nothing provisioned)" "$RR_OUT" '"action":"up"'
# The mock must not have been asked to launch anything.
assert_eq "no cloud call made when the gate fails" "0" "$(grep -c 'run-instances' "$MOCK_LOG" 2>/dev/null)"

# Missing credentials is the same loud failure, even with a type present.
write_shared "REPO_REMOTE_PROVIDER=aws"
write_repo_env "REPO_REMOTE_INSTANCE_TYPE=m5.2xlarge"
run_rr -- up --yes --json
assert_eq   "missing credentials -> exit 2" "2" "$RR_RC"
assert_contains "names AWS_ACCESS_KEY_ID" "$RR_ERR" "AWS_ACCESS_KEY_ID"

# Missing provider entirely.
write_shared "AWS_ACCESS_KEY_ID=AKIA" "AWS_SECRET_ACCESS_KEY=sk" "AWS_REGION=us-west-2"
write_repo_env "REPO_REMOTE_INSTANCE_TYPE=m5.2xlarge"
run_rr -- up --yes --json
assert_eq   "missing provider -> exit 2" "2" "$RR_RC"
assert_contains "names REPO_REMOTE_PROVIDER" "$RR_ERR" "REPO_REMOTE_PROVIDER"

# ---------------------------------------------------------------------------
echo ""
echo "-- --yes still requires a pre-supplied instance type (removes prompt, not consent) --"
# ---------------------------------------------------------------------------
write_shared "REPO_REMOTE_PROVIDER=aws" "AWS_ACCESS_KEY_ID=AKIA" "AWS_SECRET_ACCESS_KEY=sk" "AWS_REGION=us-west-2"
rm -f "$REPO/.env"
run_rr -- up --yes --json
assert_eq "--yes without instance type STILL fails (exit 2)" "2" "$RR_RC"
assert_not_contains "no instance was created" "$(cat "$MOCK_LOG")" "run-instances"

# ---------------------------------------------------------------------------
echo ""
echo "-- config-layer precedence: repo .env overrides shared remote.env --"
# ---------------------------------------------------------------------------
write_shared "REPO_REMOTE_PROVIDER=aws" "AWS_ACCESS_KEY_ID=AKIA" "AWS_SECRET_ACCESS_KEY=sk" \
             "AWS_REGION=us-west-2" "REPO_REMOTE_INSTANCE_TYPE=m5.large"
write_repo_env "REPO_REMOTE_INSTANCE_TYPE=m5.2xlarge"
run_rr -- up --json          # dry-run plan
assert_eq "repo .env instance type wins over shared" "m5.2xlarge" "$(json_field "$RR_OUT" instance_type)"
assert_eq "region resolved from shared layer" "us-west-2" "$(json_field "$RR_OUT" region)"
# Shared provider stands when repo doesn't override it.
assert_eq "provider resolved (shared)" "aws" "$(json_field "$RR_OUT" provider)"
# Repo overrides provider too.
write_repo_env "REPO_REMOTE_INSTANCE_TYPE=m5.2xlarge" "REPO_REMOTE_PROVIDER=gcp"
run_rr -- up --json
assert_eq "repo .env provider (gcp) overrides shared (aws) -> gcp gate" "2" "$RR_RC"
assert_contains "gcp path now demands GCP creds" "$RR_ERR" "GCP_PROJECT"

# ---------------------------------------------------------------------------
echo ""
echo "-- dry-run plan: cost shown, NOTHING provisioned (plan-before-spend) --"
# ---------------------------------------------------------------------------
write_shared "REPO_REMOTE_PROVIDER=aws" "AWS_ACCESS_KEY_ID=AKIA" "AWS_SECRET_ACCESS_KEY=sk" "AWS_REGION=us-west-2"
write_repo_env "REPO_REMOTE_INSTANCE_TYPE=m5.2xlarge"
run_rr -- up --json
assert_eq   "plain up is a dry run -> exit 0" "0" "$RR_RC"
assert_contains "output marked dry_run" "$RR_OUT" '"dry_run":true'
assert_eq   "plan carries the estimated hourly cost" "0.384" "$(json_field "$RR_OUT" estimated_hourly_cost_usd)"
assert_eq   "no cloud mutation in dry run" "0" "$(grep -c 'run-instances' "$MOCK_LOG" 2>/dev/null)"

# ---------------------------------------------------------------------------
echo ""
echo "-- JSON output shape on a real (mocked) provision --"
# ---------------------------------------------------------------------------
run_rr MOCK_AWS_NEW_ID=i-0abc123 MOCK_AWS_STATE=None -- up --yes --json
assert_eq   "up --yes provisions -> exit 0" "0" "$RR_RC"
assert_contains "JSON has instance id"   "$RR_OUT" '"instance_id":"i-0abc123"'
assert_contains "JSON has a public ip field" "$RR_OUT" '"public_ip"'
assert_contains "JSON has the ssh alias"  "$RR_OUT" '"ssh_alias":"repo-remote-myrepo"'
assert_contains "JSON has estimated hourly cost" "$RR_OUT" '"estimated_hourly_cost_usd":0.384'
assert_contains "JSON reports it created (not reused)" "$RR_OUT" '"reused":false'

# ---------------------------------------------------------------------------
echo ""
echo "-- provisioning applies the required tag, disk, type and idle guard --"
# ---------------------------------------------------------------------------
LOGTXT="$(cat "$MOCK_LOG")"
assert_contains "instance tagged repo-remote=<name>" "$LOGTXT" "repo-remote,Value=myrepo"
assert_contains "requested instance type is passed"  "$LOGTXT" "m5.2xlarge"
assert_contains "disk size from config is applied"   "$LOGTXT" "VolumeSize=50"
assert_contains "user-data (idle guard) is passed"   "$LOGTXT" "user-data"
assert_contains "the resolved security group is attached to run-instances" "$LOGTXT" "security-group-ids sg-0new"

# ---------------------------------------------------------------------------
echo ""
echo "-- security group: resolve-or-create + SSH ingress (repo#176) --"
# ---------------------------------------------------------------------------
# The original incident: a created security group's ingress permission set was
# EMPTY (no SSH rule at all), so SSH timed out indefinitely with no other
# symptom. aws_create() must now resolve-or-create a security group, authorize
# tcp/22 into it, and verify the rule actually landed before run-instances is
# ever called.

# (a) REPO_REMOTE_SECURITY_GROUP unset -> no pre-existing tagged SG found ->
#     a fresh one is created and tagged repo-remote=<name>.
write_repo_env "REPO_REMOTE_INSTANCE_TYPE=m5.2xlarge"
run_rr MOCK_AWS_NEW_ID=i-0sgnew MOCK_AWS_STATE=None MOCK_AWS_SG_FIND=None MOCK_AWS_SG_NEW_ID=sg-0created \
  -- up --yes --json
assert_eq   "SG create path: up still succeeds (exit 0)" "0" "$RR_RC"
SGLOG="$(cat "$MOCK_LOG")"
assert_contains "a security group is created when none is tagged yet" "$SGLOG" "create-security-group"
assert_contains "the created SG is tagged repo-remote=<name>"         "$SGLOG" "repo-remote,Value=myrepo"
assert_contains "the created SG's name embeds the repo name"          "$SGLOG" "repo-remote-myrepo"
# (b) A tcp/22 ingress request is issued against the resolved SG.
assert_contains "an ingress request is issued"          "$SGLOG" "authorize-security-group-ingress"
assert_contains "the ingress request targets the created SG" "$SGLOG" "group-id sg-0created"
assert_contains "the ingress request is for tcp/22"      "$SGLOG" "protocol tcp --port 22"
assert_contains "the created SG is attached to the instance" "$SGLOG" "security-group-ids sg-0created"

# (c) A previously-tagged SG is reused instead of creating a new one
#     (idempotent across repeated `up` runs).
run_rr MOCK_AWS_NEW_ID=i-0sgreuse MOCK_AWS_STATE=None MOCK_AWS_SG_FIND=sg-0existing -- up --yes --json
assert_eq   "SG reuse path: up still succeeds (exit 0)" "0" "$RR_RC"
REUSELOG="$(cat "$MOCK_LOG")"
assert_not_contains "a tagged SG is reused, not recreated" "$REUSELOG" "create-security-group"
assert_contains "ingress is still (idempotently) authorized on the reused SG" \
  "$REUSELOG" "group-id sg-0existing"
assert_contains "the reused SG is attached to the instance" "$REUSELOG" "security-group-ids sg-0existing"

# (d) An explicit REPO_REMOTE_SECURITY_GROUP still wins outright (unchanged
#     prior behavior) -- no resolve-or-create lookup, but ingress is still
#     authorized+verified on it.
run_rr MOCK_AWS_NEW_ID=i-0sgpinned MOCK_AWS_STATE=None REPO_REMOTE_SECURITY_GROUP=sg-0pinned -- up --yes --json
assert_eq   "explicit REPO_REMOTE_SECURITY_GROUP: up succeeds" "0" "$RR_RC"
PINLOG="$(cat "$MOCK_LOG")"
assert_not_contains "explicit SG: no tag-based lookup/creation" "$PINLOG" "create-security-group"
assert_contains "explicit SG: ingress still authorized on it" "$PINLOG" "group-id sg-0pinned"
assert_contains "explicit SG: attached to the instance" "$PINLOG" "security-group-ids sg-0pinned"

# (e) Post-create verification (AC1): an empty ingress rule set after
#     authorize is a LOUD failure (exit 4), not a silently-provisioned box.
run_rr MOCK_AWS_NEW_ID=i-0sgempty MOCK_AWS_STATE=None MOCK_AWS_SG_INGRESS_EMPTY=1 -- up --yes --json
assert_eq   "empty post-create ingress -> loud failure (exit 4)" "4" "$RR_RC"
assert_contains "failure names the missing tcp/22 rule" "$RR_ERR" "no tcp/22 ingress rule"
assert_not_contains "no up result emitted on ingress-verification failure" "$RR_OUT" '"action":"up"'

# (f) InvalidPermission.Duplicate on authorize (a reused SG that already has
#     the rule) is treated as success, not an error.
run_rr MOCK_AWS_NEW_ID=i-0sgdup MOCK_AWS_STATE=None MOCK_AWS_INGRESS_DUP=1 -- up --yes --json
assert_eq   "InvalidPermission.Duplicate is treated as success" "0" "$RR_RC"

# (g) create-security-group itself failing is a loud failure (exit 4), not a
#     silent fall-through to the VPC default SG.
run_rr MOCK_AWS_NEW_ID=i-0sgfail MOCK_AWS_STATE=None MOCK_AWS_SG_CREATE_FAIL=1 -- up --yes --json
assert_eq   "SG creation failure -> loud failure (exit 4)" "4" "$RR_RC"
assert_contains "failure names the failed SG creation" "$RR_ERR" "create-security-group failed"
assert_eq   "SG creation failure: no instance was launched" "0" "$(grep -c 'run-instances' "$MOCK_LOG" 2>/dev/null)"

write_repo_env "REPO_REMOTE_INSTANCE_TYPE=m5.2xlarge"

# ---------------------------------------------------------------------------
echo ""
echo "-- SSH-ingress CIDR: current-IP detection, override, and fallback (repo#176) --"
# ---------------------------------------------------------------------------
# (a) Default path: current IP is detected via the HTTPS echo service and
#     used as a /32.
run_rr MOCK_AWS_NEW_ID=i-0cidrdetect MOCK_AWS_STATE=None MOCK_CURL_IP=198.51.100.9 -- up --yes --json
assert_eq   "detected-IP path succeeds" "0" "$RR_RC"
assert_contains "detected IP is used as a /32 ingress CIDR" \
  "$(cat "$MOCK_LOG")" "cidr 198.51.100.9/32"

# (b) REPO_REMOTE_SSH_CIDR overrides detection outright -- including an
#     explicit 0.0.0.0/0 opt-in -- and no echo-service lookup is made at all.
run_rr MOCK_AWS_NEW_ID=i-0cidroverride MOCK_AWS_STATE=None REPO_REMOTE_SSH_CIDR=203.0.113.55/32 -- up --yes --json
assert_eq   "REPO_REMOTE_SSH_CIDR override succeeds" "0" "$RR_RC"
OVLOG="$(cat "$MOCK_LOG")"
assert_contains     "the override CIDR is used for ingress" "$OVLOG" "cidr 203.0.113.55/32"
assert_not_contains "detection is skipped when the override is set" "$OVLOG" "curl "

run_rr MOCK_AWS_NEW_ID=i-0cidrallopen MOCK_AWS_STATE=None REPO_REMOTE_SSH_CIDR=0.0.0.0/0 -- up --yes --json
assert_eq   "an explicit 0.0.0.0/0 opt-in succeeds" "0" "$RR_RC"
assert_contains "0.0.0.0/0 opt-in is honored verbatim" "$(cat "$MOCK_LOG")" "cidr 0.0.0.0/0"

# (c) IP-detection failure (no REPO_REMOTE_SSH_CIDR set) falls back to
#     0.0.0.0/0 with an explicit printed notice -- never a silently-broken
#     /32 that can never match.
run_rr MOCK_AWS_NEW_ID=i-0cidrfallback MOCK_AWS_STATE=None MOCK_CURL_FAIL=1 -- up --yes --json
assert_eq   "detection failure still provisions (fallback, not a hard error)" "0" "$RR_RC"
assert_contains "fallback CIDR is 0.0.0.0/0"        "$(cat "$MOCK_LOG")" "cidr 0.0.0.0/0"
assert_contains "an explicit fallback notice is printed" "$RR_ERR" "NOTICE"
assert_contains "the notice explains detection failed"   "$RR_ERR" "could not detect current IP"

write_repo_env "REPO_REMOTE_INSTANCE_TYPE=m5.2xlarge"

# ---------------------------------------------------------------------------
echo ""
echo "-- end-of-run SSH reachability check (repo#176 AC3) --"
# ---------------------------------------------------------------------------
# After the SSH alias is written, `up` probes it; an unreachable instance is a
# loud, actionable failure caught in-run rather than a bare timeout later.
# (the mock's describe-instances doesn't distinguish a state vs. a public-IP
# lookup, so MOCK_AWS_STATE doubles as the resolved public IP here — an
# IP-shaped value is needed to make the probe actually run, as opposed to the
# empty-IP "nothing to probe yet" skip exercised elsewhere in this suite.)
run_rr MOCK_AWS_NEW_ID=i-0reachok MOCK_AWS_STATE=203.0.113.20 -- up --yes --json
assert_eq   "reachable (mocked ssh success) -> up still succeeds" "0" "$RR_RC"
assert_contains "the reachability probe actually ran"       "$(cat "$MOCK_LOG")" "ssh "
assert_contains "the probe uses a bounded ConnectTimeout"   "$(cat "$MOCK_LOG")" "ConnectTimeout=10"
assert_contains "the probe is non-interactive (BatchMode)"  "$(cat "$MOCK_LOG")" "BatchMode=yes"

run_rr MOCK_AWS_NEW_ID=i-0reachfail MOCK_AWS_STATE=203.0.113.21 MOCK_SSH_FAIL=1 -- up --yes --json
assert_eq   "unreachable instance -> loud failure (exit 4)" "4" "$RR_RC"
assert_contains "failure names the reachability check" "$RR_ERR" "SSH reachability check failed"

# A missing public IP (nothing to probe) skips the check rather than failing.
run_rr MOCK_AWS_NEW_ID=i-0reachskip MOCK_AWS_STATE=None -- up --yes --json
assert_eq   "no public IP -> up still succeeds (probe skipped)" "0" "$RR_RC"
assert_not_contains "no probe attempted without a public IP" "$(cat "$MOCK_LOG")" "ssh "
assert_contains "a skip notice is logged" "$RR_ERR" "skipping the end-of-run SSH reachability check"

write_repo_env "REPO_REMOTE_INSTANCE_TYPE=m5.2xlarge"

# ---------------------------------------------------------------------------
echo ""
echo "-- idle-shutdown guard content --"
# ---------------------------------------------------------------------------
# The idle guard embeds IDLE_MIN, sourced from config; assert that value flows
# through by setting a distinct idle window and confirming the plan echoes it.
write_repo_env "REPO_REMOTE_INSTANCE_TYPE=m5.2xlarge" "REPO_REMOTE_IDLE_SHUTDOWN_MIN=45"
run_rr -- up --json
assert_eq "idle-shutdown window is read from config" "45" "$(json_field "$RR_OUT" idle_shutdown_min)"
write_repo_env "REPO_REMOTE_INSTANCE_TYPE=m5.2xlarge"

# ---------------------------------------------------------------------------
echo ""
echo "-- idle guard: generated script content + idle-exit marker contract --"
# ---------------------------------------------------------------------------
# The generated cloud-init user-data embeds a cron watchdog script. We capture
# it (mock aws dumps --user-data to $MOCK_LOG.userdata on run-instances) and
# assert on the guard's actual logic — the acceptance criteria for #78 require
# asserting the *generated script* rather than powering off a real host.
UD_CAP="$MOCK_LOG.userdata"

# (a) Regression: with NO marker env var, the existing who/load/$STAMP behavior
#     is present and unchanged, and the corrected mental model holds (SSH session
#     or CPU load only — no process-name veto).
write_repo_env "REPO_REMOTE_INSTANCE_TYPE=m5.2xlarge"
rm -f "$UD_CAP"
run_rr MOCK_AWS_NEW_ID=i-0guard MOCK_AWS_STATE=None -- up --yes --json
UD="$(cat "$UD_CAP" 2>/dev/null)"
assert_contains "guard keeps the SSH-session (who) activity check"   "$UD" 'who | grep -q .'
assert_contains "guard keeps the CPU load-average activity check"    "$UD" '/proc/loadavg'
assert_contains "guard keeps its local stamp countdown"              "$UD" 'STAMP=/var/run/repo-remote-idle.stamp'
assert_contains "guard still shuts down on the local stamp path"     "$UD" 'repo-remote: idle for'
assert_not_contains "no process-name veto is embedded (pgrep)"       "$UD" 'pgrep'
assert_not_contains "no loom-daemon process veto is embedded"        "$UD" 'loom-daemon >/dev/null'

# (b1) Marker branch is present with the default path when the env var is unset.
assert_contains "guard embeds the default idle-exit marker path" \
  "$UD" 'MARKER=/var/run/repo-remote-daemon-idle.marker'
assert_contains "guard reads the marker mtime (GNU stat -c %Y)" \
  "$UD" 'stat -c %Y "$MARKER"'
assert_contains "guard shuts down on an aged idle-exit marker" \
  "$UD" 'repo-remote: daemon idle-exit marker aged'
# The marker branch must REPLACE (not merely supplement) the stamp countdown:
# it exits before the stamp fallback is reached.
assert_contains "marker branch exits before the stamp fallback (replaces it)" \
  "$UD" 'exit 0
fi
# No marker'

# (b2) Setting REPO_REMOTE_IDLE_MARKER overrides the embedded path.
rm -f "$UD_CAP"
run_rr MOCK_AWS_NEW_ID=i-0guard2 MOCK_AWS_STATE=None REPO_REMOTE_IDLE_MARKER=/run/custom-idle.marker \
  -- up --yes --json
UD2="$(cat "$UD_CAP" 2>/dev/null)"
assert_contains "guard embeds the overridden marker path" "$UD2" 'MARKER=/run/custom-idle.marker'
assert_not_contains "overridden path replaces the default" "$UD2" 'MARKER=/var/run/repo-remote-daemon-idle.marker'

# (c) repo#163 regression: REPO_REMOTE_IDLE_SHUTDOWN_MIN=0 must DISABLE the
#     guard entirely, not feed 0 into the fallback countdown's arithmetic
#     (`(NOW - LAST) / 60 -ge 0` is true on the very first post-$STAMP tick,
#     which used to shut the host down almost immediately instead of never).
#     No cron/watchdog script — and no --user-data at all — should be emitted.
write_repo_env "REPO_REMOTE_INSTANCE_TYPE=m5.2xlarge" "REPO_REMOTE_IDLE_SHUTDOWN_MIN=0"
rm -f "$UD_CAP"
run_rr MOCK_AWS_NEW_ID=i-0noguard MOCK_AWS_STATE=None -- up --yes --json
assert_eq "IDLE_MIN=0 still provisions successfully" "0" "$RR_RC"
assert_not_contains "IDLE_MIN=0: no --user-data flag passed to run-instances" \
  "$(cat "$MOCK_LOG")" "user-data"
assert_eq "IDLE_MIN=0: no user-data content was captured at all" \
  "" "$(cat "$UD_CAP" 2>/dev/null)"

# Negative windows are treated the same as 0 (also "disabled").
rm -f "$UD_CAP"
write_repo_env "REPO_REMOTE_INSTANCE_TYPE=m5.2xlarge" "REPO_REMOTE_IDLE_SHUTDOWN_MIN=-5"
run_rr MOCK_AWS_NEW_ID=i-0noguard2 MOCK_AWS_STATE=None -- up --yes --json
assert_not_contains "negative IDLE_MIN: no --user-data flag passed to run-instances" \
  "$(cat "$MOCK_LOG")" "user-data"
assert_eq "negative IDLE_MIN: no user-data content was captured at all" \
  "" "$(cat "$UD_CAP" 2>/dev/null)"

write_repo_env "REPO_REMOTE_INSTANCE_TYPE=m5.2xlarge"

# ---------------------------------------------------------------------------
echo ""
echo "-- instance-id write-back to repo .env (never the shared file) --"
# ---------------------------------------------------------------------------
run_rr MOCK_AWS_NEW_ID=i-0written MOCK_AWS_STATE=None -- up --yes --json
assert_contains "new id written back to repo .env" "$(cat "$REPO/.env")" "REPO_REMOTE_INSTANCE_ID=i-0written"
assert_not_contains "shared remote.env is NOT touched with an instance id" "$(cat "$SHARED")" "REPO_REMOTE_INSTANCE_ID"
# A second run updates in place rather than appending a duplicate line.
run_rr MOCK_AWS_NEW_ID=i-0second MOCK_AWS_STATE=None -- up --yes --json
assert_eq "write-back updates in place (one line only)" "1" "$(grep -c '^REPO_REMOTE_INSTANCE_ID=' "$REPO/.env")"
assert_contains "write-back reflects the newest id" "$(cat "$REPO/.env")" "REPO_REMOTE_INSTANCE_ID=i-0second"

# ---------------------------------------------------------------------------
echo ""
echo "-- reuse: a running pinned instance is reused, not recreated --"
# ---------------------------------------------------------------------------
write_repo_env "REPO_REMOTE_INSTANCE_TYPE=m5.2xlarge" "REPO_REMOTE_INSTANCE_ID=i-0pinned"
run_rr MOCK_AWS_STATE=running -- up --yes --json
assert_contains "reused the pinned running instance" "$RR_OUT" '"instance_id":"i-0pinned"'
assert_contains "reported reused=true" "$RR_OUT" '"reused":true'
assert_eq "no new instance launched on reuse" "0" "$(grep -c 'run-instances' "$MOCK_LOG" 2>/dev/null)"
# repo#176 edge case: reusing an instance must NOT re-run security-group
# creation/ingress-authorization on every `up` — that logic belongs solely to
# aws_create(), which the reuse path never calls.
assert_eq "reuse: no SG creation on every up"  "0" "$(grep -c 'create-security-group' "$MOCK_LOG" 2>/dev/null)"
assert_eq "reuse: no ingress re-authorized on every up" "0" "$(grep -c 'authorize-security-group-ingress' "$MOCK_LOG" 2>/dev/null)"
# A stopped pinned instance is started, still reused.
run_rr MOCK_AWS_STATE=stopped -- up --yes --json
assert_contains "stopped pinned instance is started" "$(cat "$MOCK_LOG")" "start-instances"
assert_contains "still reported reused" "$RR_OUT" '"reused":true'
assert_eq "reuse (start-from-stopped): no SG creation either" \
  "0" "$(grep -c 'create-security-group' "$MOCK_LOG" 2>/dev/null)"
write_repo_env "REPO_REMOTE_INSTANCE_TYPE=m5.2xlarge"

# ---------------------------------------------------------------------------
echo ""
echo "-- fleet-marker guard on AWS reuse discovery (repo#164) --"
# ---------------------------------------------------------------------------
# Reuse discovery (a pinned REPO_REMOTE_INSTANCE_ID, or the repo-remote=<name>
# tag) resolves a handle that can outlive the host's role as an ephemeral dev
# box. Starting/re-aliasing a host that has since become a fleet worker is the
# second finding of 2AMLogic/2am#52, so a fleet marker on the resolved instance
# must block the run unless --force is passed.

# (a) Marker ABSENT -> behavior is exactly as before (reuse proceeds).
write_repo_env "REPO_REMOTE_INSTANCE_TYPE=m5.2xlarge" "REPO_REMOTE_INSTANCE_ID=i-0pinned"
run_rr MOCK_AWS_STATE=stopped MOCK_AWS_FLEET_TAG=None -- up --yes --json
assert_eq   "no fleet marker: reuse still succeeds (exit 0)" "0" "$RR_RC"
assert_contains "no fleet marker: still reports reused" "$RR_OUT" '"reused":true'
assert_contains "no fleet marker: stopped instance still started" "$(cat "$MOCK_LOG")" "start-instances"

# (b) Marker PRESENT, no --force -> blocked before any start/alias.
SSH_BEFORE="$(cat "$SCRATCH/ssh_config" 2>/dev/null || true)"
run_rr MOCK_AWS_STATE=stopped MOCK_AWS_FLEET_TAG=loom -- up --yes --json
assert_eq   "fleet-marked pinned instance is refused (exit 5)" "5" "$RR_RC"
assert_contains "message names the instance"          "$RR_ERR" "i-0pinned"
assert_contains "message names the marker tag"        "$RR_ERR" "Fleet=loom"
assert_contains "message points at the --force override" "$RR_ERR" "--force"
assert_not_contains "blocked run emitted no up result" "$RR_OUT" '"action":"up"'
assert_eq   "blocked run never started the instance" "0" "$(grep -c 'start-instances' "$MOCK_LOG" 2>/dev/null)"
assert_eq   "blocked run never launched anything"    "0" "$(grep -c 'run-instances' "$MOCK_LOG" 2>/dev/null)"
assert_eq   "blocked run left the SSH alias untouched" "$SSH_BEFORE" "$(cat "$SCRATCH/ssh_config" 2>/dev/null || true)"

# (c) Marker PRESENT with --force -> proceeds, after a loud warning.
run_rr MOCK_AWS_STATE=stopped MOCK_AWS_FLEET_TAG=loom -- up --yes --force --json
assert_eq   "--force lets a fleet-marked instance through (exit 0)" "0" "$RR_RC"
assert_contains "--force warns loudly first" "$RR_ERR" "WARNING"
assert_contains "--force warning names the marker" "$RR_ERR" "Fleet=loom"
assert_contains "--force run reuses the instance" "$RR_OUT" '"instance_id":"i-0pinned"'
assert_contains "--force run actually started it" "$(cat "$MOCK_LOG")" "start-instances"

# (d) The tag-discovery path (no pinned id) is guarded identically — this is the
#     branch that let `repo-remote=<name>` tooling rediscover a fleet host.
write_repo_env "REPO_REMOTE_INSTANCE_TYPE=m5.2xlarge"
run_rr MOCK_AWS_FIND="i-0worker stopped" MOCK_AWS_FLEET_TAG=loom -- up --yes --json
assert_eq   "fleet-marked tag-discovered instance is refused (exit 5)" "5" "$RR_RC"
assert_contains "message names the discovered instance" "$RR_ERR" "i-0worker"
assert_eq   "tag-discovery block never started it" "0" "$(grep -c 'start-instances' "$MOCK_LOG" 2>/dev/null)"
run_rr MOCK_AWS_FIND="i-0worker stopped" MOCK_AWS_FLEET_TAG=loom -- up --yes --force --json
assert_eq   "--force allows the tag-discovered instance" "0" "$RR_RC"
assert_contains "--force reuses the discovered instance" "$RR_OUT" '"instance_id":"i-0worker"'

# (e) A tag present with a DIFFERENT value is not this fleet's marker.
write_repo_env "REPO_REMOTE_INSTANCE_TYPE=m5.2xlarge" "REPO_REMOTE_INSTANCE_ID=i-0pinned"
run_rr MOCK_AWS_STATE=running MOCK_AWS_FLEET_TAG=someone-elses -- up --yes --json
assert_eq "a non-matching Fleet value does not block" "0" "$RR_RC"

# (f) The marker key/value are configurable, and an empty key disables the check.
run_rr MOCK_AWS_STATE=running MOCK_AWS_FLEET_TAG=prod \
  REPO_REMOTE_FLEET_TAG_KEY=Environment REPO_REMOTE_FLEET_TAG_VALUE=prod -- up --yes --json
assert_eq   "custom marker key/value blocks (exit 5)" "5" "$RR_RC"
assert_contains "message names the custom marker" "$RR_ERR" "Environment=prod"
run_rr MOCK_AWS_STATE=running MOCK_AWS_FLEET_TAG=loom REPO_REMOTE_FLEET_TAG_KEY= -- up --yes --json
assert_eq "empty REPO_REMOTE_FLEET_TAG_KEY disables the check" "0" "$RR_RC"

# (g) The guard is a *reuse* check: a dry run touches nothing and is never blocked.
run_rr MOCK_AWS_STATE=running MOCK_AWS_FLEET_TAG=loom -- up --json
assert_eq "dry run is never blocked by the fleet marker" "0" "$RR_RC"
assert_contains "dry run still prints the plan" "$RR_OUT" '"dry_run":true'
write_repo_env "REPO_REMOTE_INSTANCE_TYPE=m5.2xlarge"

# ---------------------------------------------------------------------------
echo ""
echo "-- fleet-marker guard on GCP reuse discovery (labels) --"
# ---------------------------------------------------------------------------
GCP_ENV=("REPO_REMOTE_PROVIDER=gcp" "REPO_REMOTE_INSTANCE_TYPE=e2-standard-4"
         "GCP_PROJECT=proj" "GCP_ZONE=us-central1-a"
         "GOOGLE_APPLICATION_CREDENTIALS=$SCRATCH/sa.json")
: >"$SCRATCH/sa.json"
write_repo_env "${GCP_ENV[@]}"

# (a) Label absent -> existing-instance reuse proceeds unchanged.
run_rr MOCK_GCP_STATE=TERMINATED MOCK_GCP_FLEET_LABEL= -- up --yes --json
assert_eq   "GCP: no fleet label -> reuse succeeds" "0" "$RR_RC"
assert_contains "GCP: reports reused" "$RR_OUT" '"reused":true'
assert_contains "GCP: stopped instance started" "$(cat "$MOCK_LOG")" "instances start"

# (b) Label present, no --force -> blocked before start/alias.
write_repo_env "${GCP_ENV[@]}"
run_rr MOCK_GCP_STATE=TERMINATED MOCK_GCP_FLEET_LABEL=loom -- up --yes --json
assert_eq   "GCP: fleet-labeled instance is refused (exit 5)" "5" "$RR_RC"
assert_contains "GCP: message names the marker label" "$RR_ERR" "Fleet=loom"
assert_eq   "GCP: blocked run never started it" "0" "$(grep -c 'instances start' "$MOCK_LOG" 2>/dev/null)"

# (c) Label present with --force -> proceeds.
run_rr MOCK_GCP_STATE=TERMINATED MOCK_GCP_FLEET_LABEL=loom -- up --yes --force --json
assert_eq   "GCP: --force lets it through" "0" "$RR_RC"
assert_contains "GCP: --force warns loudly" "$RR_ERR" "WARNING"
assert_contains "GCP: --force run started the instance" "$(cat "$MOCK_LOG")" "instances start"

write_repo_env "REPO_REMOTE_INSTANCE_TYPE=m5.2xlarge"

# ---------------------------------------------------------------------------
echo ""
echo "-- GPU detection + cost --"
# ---------------------------------------------------------------------------
write_repo_env "REPO_REMOTE_INSTANCE_TYPE=g6e.xlarge"
run_rr -- up --json
assert_contains "GPU family flagged gpu=true" "$RR_OUT" '"gpu":true'
assert_eq "GPU instance carries a GPU-tier cost" "1.861" "$(json_field "$RR_OUT" estimated_hourly_cost_usd)"
# Unknown type -> approximate cost, still a number present.
write_repo_env "REPO_REMOTE_INSTANCE_TYPE=zz.unknown"
run_rr -- up --json
assert_contains "unknown type flagged approximate" "$RR_OUT" '"estimated_cost_approximate":true'
assert_contains "unknown type still carries a cost number" "$RR_OUT" '"estimated_hourly_cost_usd":0.20'
write_repo_env "REPO_REMOTE_INSTANCE_TYPE=m5.2xlarge"

# ---------------------------------------------------------------------------
echo ""
echo "-- dry-run plan text: (GPU) tag only for genuine GPU families (repo#175) --"
# ---------------------------------------------------------------------------
# ${IS_GPU:+ (GPU)} previously fired on the *string* "false" too, tagging every
# instance type as GPU. Assert the human-readable plan line only tags real GPU
# families, using non-JSON output so the plan text itself is exercised.
write_repo_env "REPO_REMOTE_INSTANCE_TYPE=c7i.24xlarge"
run_rr -- up
assert_eq   "plan (dry run) for standard family -> exit 0" "0" "$RR_RC"
assert_not_contains "standard family plan line has NO (GPU) tag" "$RR_ERR" "c7i.24xlarge (GPU)"
write_repo_env "REPO_REMOTE_INSTANCE_TYPE=g6e.xlarge"
run_rr -- up
assert_eq   "plan (dry run) for GPU family -> exit 0" "0" "$RR_RC"
assert_contains "GPU family plan line DOES carry the (GPU) tag" "$RR_ERR" "g6e.xlarge (GPU)"
write_repo_env "REPO_REMOTE_INSTANCE_TYPE=m5.2xlarge"

# ---------------------------------------------------------------------------
echo ""
echo "-- GPU quota (VcpuLimitExceeded) surfaces the exact remediation --"
# ---------------------------------------------------------------------------
write_repo_env "REPO_REMOTE_INSTANCE_TYPE=g6e.xlarge"
run_rr MOCK_AWS_QUOTA_FAIL=1 MOCK_AWS_STATE=None -- up --yes --json
assert_eq   "quota failure -> non-zero exit" "4" "$RR_RC"
assert_contains "names the Service Quotas code" "$RR_ERR" "L-DB2E81BA"
write_repo_env "REPO_REMOTE_INSTANCE_TYPE=m5.2xlarge"

# ---------------------------------------------------------------------------
echo ""
echo "-- standard-family quota (VcpuLimitExceeded) names the standard quota code (repo#175) --"
# ---------------------------------------------------------------------------
write_repo_env "REPO_REMOTE_INSTANCE_TYPE=m5.2xlarge"
run_rr MOCK_AWS_QUOTA_FAIL=1 MOCK_AWS_STATE=None -- up --yes --json
assert_eq   "quota failure -> non-zero exit" "4" "$RR_RC"
assert_contains "names the standard Service Quotas code" "$RR_ERR" "L-1216C47A"
assert_not_contains "does NOT name the GPU quota code" "$RR_ERR" "L-DB2E81BA"
write_repo_env "REPO_REMOTE_INSTANCE_TYPE=m5.2xlarge"

# ---------------------------------------------------------------------------
echo ""
echo "-- status: lists tagged instances as JSON --"
# ---------------------------------------------------------------------------
run_rr MOCK_AWS_FIND="i-0abc running m5.2xlarge 1.2.3.4 2026-07-29T00:00:00Z" -- status --json
assert_eq   "status -> exit 0" "0" "$RR_RC"
assert_contains "status action" "$RR_OUT" '"action":"status"'
assert_contains "status lists the instance" "$RR_OUT" '"instance_id":"i-0abc"'
assert_contains "status carries state" "$RR_OUT" '"state":"running"'

# ---------------------------------------------------------------------------
echo ""
echo "-- down: dry-run vs --yes, and --delete terminates --"
# ---------------------------------------------------------------------------
run_rr MOCK_AWS_FIND="i-0abc" -- down --json      # no --yes -> dry-run
assert_contains "down without --yes is a dry run" "$RR_OUT" '"disposition":"dry-run"'
assert_eq "dry-run down does not stop anything" "0" "$(grep -c 'stop-instances' "$MOCK_LOG" 2>/dev/null)"
run_rr MOCK_AWS_FIND="i-0abc" -- down --yes --json
assert_contains "down --yes stops" "$RR_OUT" '"disposition":"stopped"'
assert_contains "stop-instances actually called" "$(cat "$MOCK_LOG")" "stop-instances"
run_rr MOCK_AWS_FIND="i-0abc" -- down --yes --delete --json
assert_contains "down --yes --delete terminates" "$RR_OUT" '"disposition":"terminated"'
assert_contains "terminate-instances actually called" "$(cat "$MOCK_LOG")" "terminate-instances"

# ---------------------------------------------------------------------------
echo ""
echo "-- fleet-marker guard on AWS down (repo#170) --"
# ---------------------------------------------------------------------------
# `down` resolves instances from the SAME never-expiring handles `up` does (a
# pinned REPO_REMOTE_INSTANCE_ID, or the repo-remote=<name> tag), and is
# strictly worse when it hits a repurposed fleet host: it STOPS it, or with
# --delete TERMINATES it (disk gone, unrecoverable) — the 2AMLogic/2am#52
# failure mode. Mirrors the up-side block above.

# (a) Marker ABSENT -> unchanged behavior (stops as before).
run_rr MOCK_AWS_FIND="i-0abc" MOCK_AWS_FLEET_TAG=None -- down --yes --json
assert_eq   "no fleet marker: down still succeeds (exit 0)" "0" "$RR_RC"
assert_contains "no fleet marker: still stops" "$RR_OUT" '"disposition":"stopped"'
assert_contains "no fleet marker: stop-instances called" "$(cat "$MOCK_LOG")" "stop-instances"

# (b) Marker PRESENT (pinned id), no --force -> refused before any stop call.
write_repo_env "REPO_REMOTE_INSTANCE_TYPE=m5.2xlarge" "REPO_REMOTE_INSTANCE_ID=i-0pinned"
run_rr MOCK_AWS_FLEET_TAG=loom -- down --yes --json
assert_eq   "fleet-marked pinned instance refused on down (exit 5)" "5" "$RR_RC"
assert_contains "down refusal names the instance" "$RR_ERR" "i-0pinned"
assert_contains "down refusal names the marker tag" "$RR_ERR" "Fleet=loom"
assert_contains "down refusal points at --force" "$RR_ERR" "--force"
assert_eq   "blocked down never stopped anything"    "0" "$(grep -c 'stop-instances' "$MOCK_LOG" 2>/dev/null)"
assert_eq   "blocked down never terminated anything" "0" "$(grep -c 'terminate-instances' "$MOCK_LOG" 2>/dev/null)"

# (c) Marker PRESENT with --force -> proceeds after a loud WARNING, and
#     --delete actually terminates once forced.
run_rr MOCK_AWS_FLEET_TAG=loom -- down --yes --force --delete --json
assert_eq   "--force lets a fleet-marked instance through on down (exit 0)" "0" "$RR_RC"
assert_contains "--force warns loudly on down" "$RR_ERR" "WARNING"
assert_contains "--force warning names the marker" "$RR_ERR" "Fleet=loom"
assert_contains "--force down terminates" "$RR_OUT" '"disposition":"terminated"'
assert_contains "--force down actually called terminate-instances" "$(cat "$MOCK_LOG")" "terminate-instances"

# (d) Tag-discovery, MULTIPLE resolved ids, ONLY ONE marked -> the WHOLE batch
#     is refused (the safer default per the issue sketch), not just the marked
#     one — zero stop/terminate calls for ANY of them.
write_repo_env "REPO_REMOTE_INSTANCE_TYPE=m5.2xlarge"
run_rr MOCK_AWS_FIND="$(printf 'i-0clean\ni-0mixedmarked')" MOCK_AWS_FLEET_MARKED_IDS="i-0mixedmarked" \
  -- down --yes --json
assert_eq   "partial batch match refuses the WHOLE batch (exit 5)" "5" "$RR_RC"
assert_contains "batch refusal names the marked instance" "$RR_ERR" "i-0mixedmarked"
assert_eq   "batch refusal: unmarked sibling also NOT stopped" "0" "$(grep -c 'stop-instances' "$MOCK_LOG" 2>/dev/null)"
assert_eq   "batch refusal: nothing terminated either"        "0" "$(grep -c 'terminate-instances' "$MOCK_LOG" 2>/dev/null)"
# --force proceeds and acts on the WHOLE batch (both the marked and unmarked id).
run_rr MOCK_AWS_FIND="$(printf 'i-0clean\ni-0mixedmarked')" MOCK_AWS_FLEET_MARKED_IDS="i-0mixedmarked" \
  -- down --yes --force --json
assert_eq   "--force proceeds on a mixed batch (exit 0)" "0" "$RR_RC"
assert_contains "--force stops the whole batch" "$RR_OUT" '"disposition":"stopped"'
assert_contains "--force batch: stop-instances called" "$(cat "$MOCK_LOG")" "stop-instances"

# (e) Dry run (no --yes) is NEVER blocked by the guard, even when marked — and
#     annotates which resolved id(s) carry the marker.
run_rr MOCK_AWS_FIND="i-0worker" MOCK_AWS_FLEET_TAG=loom -- down --json
assert_eq   "dry-run down is never blocked by the fleet marker" "0" "$RR_RC"
assert_contains "dry-run down still reports dry-run" "$RR_OUT" '"disposition":"dry-run"'
assert_contains "dry-run down annotates the fleet-marked id" "$RR_OUT" '"fleet_marked":["i-0worker"]'
assert_eq   "dry-run down still stopped nothing" "0" "$(grep -c 'stop-instances' "$MOCK_LOG" 2>/dev/null)"
# An unmarked dry-run listing carries an empty fleet_marked array.
run_rr MOCK_AWS_FIND="i-0worker" MOCK_AWS_FLEET_TAG=None -- down --json
assert_contains "dry-run down: unmarked id -> empty fleet_marked array" "$RR_OUT" '"fleet_marked":[]'

write_repo_env "REPO_REMOTE_INSTANCE_TYPE=m5.2xlarge"

# ---------------------------------------------------------------------------
echo ""
echo "-- fleet-marker guard on GCP down (labels, repo#170) --"
# ---------------------------------------------------------------------------
write_repo_env "${GCP_ENV[@]}"

# (a) Label absent -> down proceeds unchanged.
run_rr MOCK_GCP_STATE=RUNNING MOCK_GCP_FLEET_LABEL= -- down --yes --json
assert_eq   "GCP: no fleet label -> down succeeds" "0" "$RR_RC"
assert_contains "GCP: down stops" "$RR_OUT" '"disposition":"stopped"'
assert_contains "GCP: instances stop called" "$(cat "$MOCK_LOG")" "instances stop"

# (b) Label present, no --force -> refused before any stop/delete call.
run_rr MOCK_GCP_STATE=RUNNING MOCK_GCP_FLEET_LABEL=loom -- down --yes --json
assert_eq   "GCP: fleet-labeled instance refused on down (exit 5)" "5" "$RR_RC"
assert_contains "GCP: down refusal names the marker" "$RR_ERR" "Fleet=loom"
assert_eq   "GCP: blocked down never stopped it" "0" "$(grep -c 'instances stop' "$MOCK_LOG" 2>/dev/null)"
assert_eq   "GCP: blocked down never deleted it" "0" "$(grep -c 'instances delete' "$MOCK_LOG" 2>/dev/null)"

# (c) Label present with --force -> proceeds after a loud warning.
run_rr MOCK_GCP_STATE=RUNNING MOCK_GCP_FLEET_LABEL=loom -- down --yes --force --json
assert_eq   "GCP: --force lets it through on down" "0" "$RR_RC"
assert_contains "GCP: --force warns loudly on down" "$RR_ERR" "WARNING"
assert_contains "GCP: --force down stops it" "$(cat "$MOCK_LOG")" "instances stop"

# (d) Dry run is never blocked, and annotates the marked instance.
run_rr MOCK_GCP_STATE=RUNNING MOCK_GCP_FLEET_LABEL=loom -- down --json
assert_eq   "GCP: dry-run down is never blocked" "0" "$RR_RC"
assert_contains "GCP: dry-run down annotates the fleet-marked vm" "$RR_OUT" '"fleet_marked":["repo-remote-myrepo"]'
assert_eq   "GCP: dry-run down stopped nothing" "0" "$(grep -c 'instances stop' "$MOCK_LOG" 2>/dev/null)"

write_repo_env "REPO_REMOTE_INSTANCE_TYPE=m5.2xlarge"

# ---------------------------------------------------------------------------
echo ""
echo "-- auth failure stops loudly, no fallback --"
# ---------------------------------------------------------------------------
run_rr MOCK_AWS_AUTH_FAIL=1 MOCK_AWS_STATE=None -- up --yes --json
assert_eq "auth failure -> exit 3" "3" "$RR_RC"
assert_eq "no instance launched after auth failure" "0" "$(grep -c 'run-instances' "$MOCK_LOG" 2>/dev/null)"

# ---------------------------------------------------------------------------
echo ""
echo "-- usage errors --"
# ---------------------------------------------------------------------------
run_rr -- ; assert_eq "no action -> usage error (64)" "64" "$RR_RC"
run_rr -- bogus ; assert_eq "unknown arg -> usage error (64)" "64" "$RR_RC"

# ---------------------------------------------------------------------------
echo ""
echo "-- doc drift: remote.md documents what the script implements --"
# ---------------------------------------------------------------------------
MD="$(cat "$REMOTE_MD")"
assert_contains "remote.md documents the headless entry point" "$MD" "repo-remote"
assert_contains "remote.md documents 'up' provisioning verb" "$MD" "repo-remote up"
assert_contains "remote.md documents --yes for the non-interactive path" "$MD" "--yes"
assert_contains "remote.md documents --json machine-readable output" "$MD" "--json"
assert_contains "remote.md still documents --status" "$MD" "--status"
assert_contains "remote.md still documents --down" "$MD" "--down"
assert_contains "remote.md documents the repo-remote=<name> tag" "$MD" "repo-remote=<name>"
assert_contains "remote.md documents the cost-gate contract" "$MD" "REPO_REMOTE_INSTANCE_TYPE"
assert_contains "remote.md states --yes preserves consent" "$MD" "removes the prompt, not the consent"

# #78: the idle-exit marker contract and the daemon-host short-window guidance
# are part of the implemented surface — remote.md must document them so the
# script and its docs cannot silently diverge.
assert_contains "remote.md documents the idle-exit marker env var" "$MD" "REPO_REMOTE_IDLE_MARKER"
assert_contains "remote.md documents the default marker path" \
  "$MD" "/var/run/repo-remote-daemon-idle.marker"
assert_contains "remote.md documents the marker's mtime semantics" "$MD" "mtime"
assert_contains "remote.md recommends a short idle window for daemon/worker hosts" \
  "$MD" "REPO_REMOTE_IDLE_SHUTDOWN_MIN=20"

# repo#164: the fleet-marker reuse guard and its --force override are part of
# the implemented surface, so remote.md must document them too.
assert_contains "remote.md documents the --force override" "$MD" "--force"
assert_contains "remote.md documents the fleet-marker key var" "$MD" "REPO_REMOTE_FLEET_TAG_KEY"
assert_contains "remote.md documents the fleet-marker value var" "$MD" "REPO_REMOTE_FLEET_TAG_VALUE"
assert_contains "remote.md documents the default fleet marker" "$MD" "Fleet=loom"
assert_contains "remote.md documents the refusal exit code" "$MD" "exit \`5\`"

# repo#170: the guard now also gates `down`, including its multi-id batch
# refusal and dry-run annotation — remote.md must document that extension too.
assert_contains "remote.md documents down is gated by the fleet marker too" \
  "$MD" "does to that same resolved instance is **stop it"
assert_contains "remote.md documents the whole-batch refusal on down" \
  "$MD" "whole batch is refused"
assert_contains "remote.md documents dry-run annotation (not blocking) on down" \
  "$MD" "fleet_marked"

# The interactive steps must DELEGATE to the shared script, not re-issue cloud
# CLI calls from prose (the "no behavior drift" acceptance criterion).
assert_contains "remote.md delegates provisioning to the shared script" "$MD" "scripts/repo/repo-remote.sh"

# install.sh must ship the script to consumer repos (packaging path).
INSTALL_SH="$REPO_ROOT/install.sh"
if [[ -f "$INSTALL_SH" ]]; then
    IN="$(cat "$INSTALL_SH")"
    assert_contains "install.sh copies repo-remote.sh into the skill scripts dir" \
        "$IN" "scripts/repo-remote.sh"
    assert_contains "install.sh chmod +x the installed script" \
        "$IN" "chmod +x"
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

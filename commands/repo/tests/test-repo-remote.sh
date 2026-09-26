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

# Assertion helpers (ok/no/skip/assert_eq/assert_contains/assert_not_contains/
# assert_matches) plus the PASS/FAIL/SKIP/TOTAL counters and color vars are
# shared across the repo test suites — see lib/assert.sh (repo#307).
source "$(dirname "${BASH_SOURCE[0]}")/lib/assert.sh"

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

# A fixture SSH key pair for the aws_resolve_keypair() path (repo#177):
# run_rr defaults REPO_REMOTE_SSH_KEY at it so every scenario has a usable
# `<key>.pub` unless a test deliberately overrides/removes it.
SSH_KEY_FIXTURE="$SCRATCH/id_test"
ssh-keygen -t ed25519 -N '' -f "$SSH_KEY_FIXTURE" -q

# run_rr <extra-env...> -- <args...>  -> runs the script in the fixture repo with
# XDG_CONFIG_HOME set, SSH config redirected to scratch, and the mock aws on PATH.
# The public-IP poll (repo#451) is pinned SHORT and sleep-free by default
# (2 attempts, 0s apart) so the many scenarios below that resolve no IP don't
# each pay the real 6 x 2s budget; `env` applies assignments left-to-right, so a
# test passing its own REPO_REMOTE_IP_POLL_* value still wins.
MOCK_BIN="$SCRATCH/bin"
MOCK_LOG="$SCRATCH/aws.log"
mkdir -p "$MOCK_BIN"
RR_OUT=""; RR_ERR=""; RR_RC=0
run_rr() {
    local -a envs=()
    while [[ "$1" != "--" ]]; do envs+=("$1"); shift; done
    shift
    : >"$MOCK_LOG"
    : >"$MOCK_LOG.sshprobes"          # per-run ssh probe counter (repo#449)
    # The mock's Nth-poll public-IP counter (MOCK_AWS_PUBLIC_IP_AFTER) is a
    # sidecar of the log, so it must be reset per run alongside it (repo#451).
    rm -f "$MOCK_LOG.ipcount"
    local errf; errf="$(mktemp)"
    # REPO_REMOTE_SSH_READY_* default to 0 here so the suite never pays the
    # real 120s readiness window (repo#449); the assignments below come BEFORE
    # "${envs[@]}", and `env` applies assignments left-to-right, so any test
    # that passes its own value still wins.
    RR_OUT="$(cd "$REPO" && env \
        PATH="$MOCK_BIN:$PATH" \
        XDG_CONFIG_HOME="$XDG" \
        REPO_REMOTE_SSH_CONFIG="$SCRATCH/ssh_config" \
        REPO_REMOTE_SSH_KEY="$SSH_KEY_FIXTURE" \
        REPO_REMOTE_SSH_READY_TIMEOUT=0 \
        REPO_REMOTE_SSH_READY_POLL_INTERVAL=0 \
        MOCK_AWS_LOG="$MOCK_LOG" \
        REPO_REMOTE_IP_POLL_ATTEMPTS=2 \
        REPO_REMOTE_IP_POLL_INTERVAL=0 \
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
    if printf '%s' "$*" | grep -qF 'starts_with(Description'; then
      # Tool-owned rule lookup (aws_tool_owned_ssh_cidrs, repo#487): the CIDRs
      # of tcp/22 rules whose Description carries the repo-remote:<name>:
      # marker. MOCK_AWS_SG_OWNED_CIDRS is a space-separated list; unset means
      # "this group has no rule this tooling owns" (the common case: a freshly
      # created group, or one whose only rules an operator added by hand).
      if [[ -n "${MOCK_AWS_SG_OWNED_CIDRS:-}" ]]; then
        printf '%s\n' "${MOCK_AWS_SG_OWNED_CIDRS}"
      else
        printf 'None\n'
      fi
    elif printf '%s' "$*" | grep -q -- '--group-ids'; then
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
  "ec2 revoke-security-group-ingress")
    # repo#487: revoking this tooling's own stale tcp/22 rules is best-effort —
    # MOCK_AWS_REVOKE_FAIL drives the "left in place, loud NOTICE" branch.
    if [[ "${MOCK_AWS_REVOKE_FAIL:-0}" == 1 ]]; then
      echo "An error occurred (UnauthorizedOperation) when calling the RevokeSecurityGroupIngress operation" >&2
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
    # Post-create KeyName verification (repo#177) is ALSO a --instance-ids
    # describe-instances call, so it must be distinguished by its distinct
    # `.KeyName` query projection before falling into the generic
    # State.Name/PublicIpAddress branch below (which both share the single
    # MOCK_AWS_STATE canned value). Defaults to a non-null name so every
    # EXISTING test (none of which care about this new check) still passes;
    # a dedicated test overrides MOCK_AWS_KEYNAME_CHECK=None to exercise the
    # die-loudly path.
    if printf '%s' "$*" | grep -qF ".KeyName"; then
      printf '%s\n' "${MOCK_AWS_KEYNAME_CHECK:-repo-remote-myrepo}"
      exit 0
    fi
    # The public-IP lookup (aws_public_ip) is the THIRD distinct
    # --instance-ids describe-instances shape, distinguished by its
    # `PublicIpAddress` query projection. It needs its own branch so a test
    # can inject an API-CALL FAILURE (repo#216): "the describe-instances call
    # itself failed" (an unfulfilled spot request, throttling, a transient
    # AWS error) is a genuinely different failure mode from "the call
    # succeeded but AWS has not assigned an IP yet", and aws_public_ip() must
    # let the caller tell them apart. Both knobs are opt-in, so every
    # pre-existing test keeps falling through to the shared MOCK_AWS_STATE
    # canned value below (which is how the succeeded-but-"None" case is
    # driven).
    if printf '%s' "$*" | grep -qF "Instances[0].PublicIpAddress"; then
      if [[ "${MOCK_AWS_PUBLIC_IP_FAIL:-0}" == 1 ]]; then
        echo "An error occurred (InvalidInstanceID.NotFound) when calling the DescribeInstances operation: The instance ID '${MOCK_AWS_NEW_ID:-i-0newinstance}' does not exist" >&2
        exit 254
      fi
      # repo#451: MOCK_AWS_PUBLIC_IP_AFTER=<n> makes the IP appear only from
      # the Nth poll onward (earlier polls answer the literal "None"), which is
      # how the bounded retry in aws_wait_public_ip() is exercised: AWS has not
      # always propagated a restarted instance's NEW public IP by the time
      # `wait instance-running` returns. The call counter is a sidecar of the
      # log file so run_rr can reset it per run.
      if [[ -n "${MOCK_AWS_PUBLIC_IP_AFTER:-}" ]]; then
        ipcount_file="${MOCK_AWS_LOG}.ipcount"
        ipcount=$(( $(cat "$ipcount_file" 2>/dev/null || echo 0) + 1 ))
        printf '%s' "$ipcount" >"$ipcount_file"
        if (( ipcount >= MOCK_AWS_PUBLIC_IP_AFTER )); then
          printf '%s\n' "${MOCK_AWS_PUBLIC_IP:-203.0.113.42}"
        else
          printf 'None\n'
        fi
        exit 0
      fi
      if [[ -n "${MOCK_AWS_PUBLIC_IP:-}" ]]; then
        printf '%s\n' "$MOCK_AWS_PUBLIC_IP"
        exit 0
      fi
    fi
    # --instance-ids (pinned lookup) vs --filters (tag find)
    if printf '%s' "$*" | grep -q -- '--instance-ids'; then
      echo "${MOCK_AWS_STATE:-None}"
    else
      # tag find / status: emit configured rows (may be empty)
      printf '%s' "${MOCK_AWS_FIND:-}"
    fi
    exit 0 ;;
  "ec2 describe-key-pairs")
    # aws_resolve_keypair() fingerprint-reuse lookup (repo#177). Default: no
    # match -> falls through to import-key-pair. A test sets
    # MOCK_AWS_KEYPAIR_NAME to simulate an existing account key pair.
    printf '%s\n' "${MOCK_AWS_KEYPAIR_NAME:-None}"; exit 0 ;;
  "ec2 import-key-pair")
    if [[ "${MOCK_AWS_IMPORT_KEYPAIR_FAIL:-0}" == 1 ]]; then
      echo "An error occurred (InvalidKeyPair.Duplicate) when calling the ImportKeyPair operation" >&2
      exit 254
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
# MOCK_CURL_FAIL / MOCK_CURL_IP / MOCK_SSH_FAIL / MOCK_SSH_FAIL_COUNT /
# MOCK_SSH_STDERR.
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
# `ssh -G` is not a connection at all -- it is write_ssh_alias()'s pure
# config-parse check on the candidate temp file (repo#216). MOCK_SSH_G_FAIL
# fails ONLY that call, so a test can drive the write-then-validate rollback
# (and aws_up()'s handling of a rejected alias write) without also breaking
# the end-of-run reachability probe, which MOCK_SSH_FAIL still covers.
for a in "$@"; do
  if [[ "$a" == "-G" ]]; then
    [[ "${MOCK_SSH_G_FAIL:-0}" == 1 ]] && exit 255
    exit 0
  fi
done

# The host-identity probe (repo#458) is the OTHER non-reachability ssh call:
# repo-remote.sh runs it as `ssh <opts> <alias> 'sh -s'` with the probe script
# on stdin. It is matched (and answered) BEFORE the readiness-probe counter
# below so a verify call never inflates the probe count a repo#449 test
# asserts on.
#   MOCK_SSH_HOST_ID    -- what the reached host reports as its own instance
#                          id. UNSET (the default) means "the host answered but
#                          could name no identity source", which is what every
#                          pre-existing scenario sees.
#   MOCK_SSH_VERIFY_FAIL=1 -- the probe connection itself fails (unreachable
#                          host), which must fail CLOSED, never pass silently.
for a in "$@"; do
  if [[ "$a" == "sh -s" ]]; then
    if [[ "${MOCK_SSH_VERIFY_FAIL:-0}" == 1 ]]; then
      printf 'ssh: connect to host mock port 22: Connection refused\n' >&2
      exit 255
    fi
    printf '%s' "${MOCK_SSH_HOST_ID:-}"
    exit 0
  fi
done

# Everything past here is a real connection attempt, i.e. an
# aws_check_reachability() readiness probe (repo#449). Count them in a
# per-run file (reset by run_rr) so a test can assert exactly how many
# attempts the retry loop burned, and emit the failure on STDERR -- the
# retry loop classifies boot-in-progress vs. hard failure purely from that
# text, so a silent `exit 255` is NOT a faithful mock of either.
PROBES="${MOCK_AWS_LOG:-/dev/null}.sshprobes"
n=0
[[ -f "$PROBES" ]] && n="$(wc -l <"$PROBES" | tr -d ' ')"
n=$(( n + 1 ))
printf 'probe\n' >>"$PROBES"

# MOCK_SSH_STDERR: exact stderr text for a failing probe (defaults to the
#   OpenSSH "still booting" phrasing the retry loop must retry on).
# MOCK_SSH_FAIL_COUNT=<k>: fail the first k probes, then succeed.
# MOCK_SSH_FAIL=1: fail every probe.
fail_msg="${MOCK_SSH_STDERR:-ssh: connect to host mock port 22: Connection refused}"
if [[ -n "${MOCK_SSH_FAIL_COUNT:-}" ]] && (( n <= MOCK_SSH_FAIL_COUNT )); then
  printf '%s\n' "$fail_msg" >&2
  exit 255
fi
if [[ "${MOCK_SSH_FAIL:-0}" == 1 ]]; then
  printf '%s\n' "$fail_msg" >&2
  exit 255
fi
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
assert_contains "the ingress request is for tcp/22"      "$SGLOG" "IpProtocol=tcp,FromPort=22,ToPort=22"
# repo#487: every rule this tooling writes is labelled with an owner marker, so
# an account-wide audit can trace each tcp/22 rule back to its owner.
assert_contains "the ingress rule carries this tooling's owner Description" \
  "$SGLOG" "Description=repo-remote:myrepo:"
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
echo "-- SSH-ingress CIDR: detection, validated override, fail-closed (repo#176, repo#487) --"
# ---------------------------------------------------------------------------
# (a) Default path: current IP is detected via the HTTPS echo service and
#     used as a /32.
run_rr MOCK_AWS_NEW_ID=i-0cidrdetect MOCK_AWS_STATE=None MOCK_CURL_IP=198.51.100.9 -- up --yes --json
assert_eq   "detected-IP path succeeds" "0" "$RR_RC"
assert_contains "detected IP is used as a /32 ingress CIDR" \
  "$(cat "$MOCK_LOG")" "CidrIp=198.51.100.9/32"

# (b) REPO_REMOTE_SSH_CIDR overrides detection outright, and no echo-service
#     lookup is made at all.
run_rr MOCK_AWS_NEW_ID=i-0cidroverride MOCK_AWS_STATE=None REPO_REMOTE_SSH_CIDR=203.0.113.55/32 -- up --yes --json
assert_eq   "REPO_REMOTE_SSH_CIDR override succeeds" "0" "$RR_RC"
OVLOG="$(cat "$MOCK_LOG")"
assert_contains     "the override CIDR is used for ingress" "$OVLOG" "CidrIp=203.0.113.55/32"
assert_not_contains "detection is skipped when the override is set" "$OVLOG" "curl "

# (c) repo#487 SECURITY: a world-open override is REFUSED unless
#     REPO_REMOTE_ALLOW_WORLD_SSH=1 explicitly opts in. "SSH open to the
#     internet" must never happen because a config file had a stale value in
#     it — and an auditor must be able to tell an accidental opening from a
#     deliberate one.
run_rr MOCK_AWS_NEW_ID=i-0cidrallopen MOCK_AWS_STATE=None REPO_REMOTE_SSH_CIDR=0.0.0.0/0 -- up --yes --json
assert_eq   "REPO_REMOTE_SSH_CIDR=0.0.0.0/0 alone is refused (exit 2)" "2" "$RR_RC"
assert_contains "the refusal names the offending CIDR" "$RR_ERR" "0.0.0.0/0"
assert_contains "the refusal names the minimum-prefix knob" "$RR_ERR" "REPO_REMOTE_SSH_MIN_PREFIX"
assert_contains "the refusal names the opt-in knob"    "$RR_ERR" "REPO_REMOTE_ALLOW_WORLD_SSH=1"
assert_eq   "a refused override authorizes NOTHING" "0" \
  "$(grep -c 'authorize-security-group-ingress' "$MOCK_LOG" 2>/dev/null)"
assert_eq   "a refused override launches no instance" "0" \
  "$(grep -c 'run-instances' "$MOCK_LOG" 2>/dev/null)"

# A prefix merely WIDER than the minimum (not world-open) is refused the same
# way -- the gate is the prefix length, not a 0.0.0.0/0 special case.
run_rr MOCK_AWS_NEW_ID=i-0cidrwide MOCK_AWS_STATE=None REPO_REMOTE_SSH_CIDR=203.0.113.0/24 -- up --yes --json
assert_eq   "a /24 override is refused under the default /32 minimum" "2" "$RR_RC"
assert_contains "the refusal names the required minimum" "$RR_ERR" "/32 minimum"

# ...and is ACCEPTED when the minimum is deliberately relaxed to match.
run_rr MOCK_AWS_NEW_ID=i-0cidrwideok MOCK_AWS_STATE=None \
  REPO_REMOTE_SSH_CIDR=203.0.113.0/24 REPO_REMOTE_SSH_MIN_PREFIX=24 -- up --yes --json
assert_eq   "a /24 override succeeds with REPO_REMOTE_SSH_MIN_PREFIX=24" "0" "$RR_RC"
assert_contains "the /24 is authorized once allowed" "$(cat "$MOCK_LOG")" "CidrIp=203.0.113.0/24"

# ...and the explicit world-open opt-in works, loudly.
run_rr MOCK_AWS_NEW_ID=i-0cidrworld MOCK_AWS_STATE=None \
  REPO_REMOTE_SSH_CIDR=0.0.0.0/0 REPO_REMOTE_ALLOW_WORLD_SSH=1 -- up --yes --json
assert_eq   "0.0.0.0/0 with REPO_REMOTE_ALLOW_WORLD_SSH=1 succeeds" "0" "$RR_RC"
assert_contains "the world-open opt-in is honored verbatim" "$(cat "$MOCK_LOG")" "CidrIp=0.0.0.0/0"
assert_contains "the world-open opt-in is logged loudly" "$RR_ERR" "WARNING"
assert_contains "the warning names the opt-in that allowed it" "$RR_ERR" "REPO_REMOTE_ALLOW_WORLD_SSH=1"

# An all-of-IPv6 ::/0 is refused on the same grounds.
run_rr MOCK_AWS_NEW_ID=i-0cidrv6 MOCK_AWS_STATE=None REPO_REMOTE_SSH_CIDR=::/0 -- up --yes --json
assert_eq   "REPO_REMOTE_SSH_CIDR=::/0 is refused (exit 2)" "2" "$RR_RC"
assert_contains "the ::/0 refusal says it is all of IPv6" "$RR_ERR" "all of IPv6"

# A syntactically bogus override is a loud config failure, not something that
# reaches the AWS API.
run_rr MOCK_AWS_NEW_ID=i-0cidrbogus MOCK_AWS_STATE=None REPO_REMOTE_SSH_CIDR=not-a-cidr -- up --yes --json
assert_eq   "a malformed REPO_REMOTE_SSH_CIDR is refused (exit 2)" "2" "$RR_RC"
assert_contains "the malformed-CIDR failure names the variable" "$RR_ERR" "REPO_REMOTE_SSH_CIDR"

# (d) repo#487 SECURITY: IP-detection failure with no REPO_REMOTE_SSH_CIDR set
#     FAILS CLOSED. The old behavior silently fell back to 0.0.0.0/0, so one
#     flaky HTTPS call during `up` left tcp/22 open to the world.
run_rr MOCK_AWS_NEW_ID=i-0cidrfailclosed MOCK_AWS_STATE=None MOCK_CURL_FAIL=1 -- up --yes --json
assert_eq   "create + detection failure fails closed (exit 2)" "2" "$RR_RC"
assert_contains "the failure explains detection failed"  "$RR_ERR" "could not detect the current IP"
assert_contains "the failure refuses 0.0.0.0/0 by name"  "$RR_ERR" "Refusing to fall back to 0.0.0.0/0"
assert_contains "the failure names the fix"              "$RR_ERR" "REPO_REMOTE_SSH_CIDR"
FCLOG="$(cat "$MOCK_LOG")"
assert_eq   "no ingress rule is created on detection failure" "0" \
  "$(grep -c 'authorize-security-group-ingress' "$MOCK_LOG" 2>/dev/null)"
assert_not_contains "no 0.0.0.0/0 reaches the AWS API"   "$FCLOG" "CidrIp=0.0.0.0/0"
assert_eq   "no instance is launched on detection failure" "0" \
  "$(grep -c 'run-instances' "$MOCK_LOG" 2>/dev/null)"

write_repo_env "REPO_REMOTE_INSTANCE_TYPE=m5.2xlarge"

# ---------------------------------------------------------------------------
echo ""
echo "-- SSH ingress replaces rather than accumulates (repo#487) --"
# ---------------------------------------------------------------------------
# Each `up` from a new address used to ADD a /32 and never remove the old one,
# so a roaming laptop left a group admitting every address it had ever had.
# The refresh now revokes this tooling's OWN earlier tcp/22 rules (identified
# by the repo-remote:<name>: Description marker) before authorizing the
# current address.

# (a) A prior tool-owned rule for a DIFFERENT address is revoked, and the
#     current address is authorized.
run_rr MOCK_AWS_NEW_ID=i-0revoke MOCK_AWS_STATE=None MOCK_AWS_SG_FIND=sg-0existing \
  MOCK_AWS_SG_OWNED_CIDRS=52.119.115.124/32 MOCK_CURL_IP=104.7.12.215 -- up --yes --json
assert_eq   "revoke-then-authorize still succeeds" "0" "$RR_RC"
REVLOG="$(cat "$MOCK_LOG")"
assert_contains "the stale tool-owned /32 is revoked" \
  "$REVLOG" "revoke-security-group-ingress --group-id sg-0existing"
assert_contains "the revoke targets the stale CIDR" "$REVLOG" "CidrIp=52.119.115.124/32"
assert_contains "the current address is then authorized" "$REVLOG" "CidrIp=104.7.12.215/32"
assert_contains "the revoke is reported to the operator" "$RR_ERR" "revoked this tooling's stale SSH ingress rule"
# Two properties of the owned-rule query the mock cannot evaluate but a real
# AWS CLI absolutely can, both of which silently broke it in development:
#   * without the `| ` pipe the filter is applied element-wise to each IpRange
#     OBJECT rather than to the flattened list, and matches nothing at all;
#   * without the `Description != null` short-circuit, a description-less rule
#     (extremely common on a real group) makes starts_with() raise a
#     JMESPathTypeError that fails the whole describe call.
assert_contains "the owned-rule query stops the projection with a pipe" \
  "$REVLOG" "IpRanges[] | [?"
assert_contains "the owned-rule query is null-safe for description-less rules" \
  "$REVLOG" "Description != null &&"

# (b) Rules WITHOUT this tooling's marker are somebody else's and are never
#     touched: the owned-rule query returns nothing, so nothing is revoked.
run_rr MOCK_AWS_NEW_ID=i-0noowned MOCK_AWS_STATE=None MOCK_AWS_SG_FIND=sg-0existing \
  MOCK_CURL_IP=104.7.12.215 -- up --yes --json
assert_eq   "unmarked (operator-added) rules leave up succeeding" "0" "$RR_RC"
assert_eq   "no unmarked rule is ever revoked" "0" \
  "$(grep -c 'revoke-security-group-ingress' "$MOCK_LOG" 2>/dev/null)"

# (c) A rule this tooling owns for the address it is about to authorize is NOT
#     revoked -- a repeat run from the same address must not flap the rule.
run_rr MOCK_AWS_NEW_ID=i-0samecidr MOCK_AWS_STATE=None MOCK_AWS_SG_FIND=sg-0existing \
  MOCK_AWS_SG_OWNED_CIDRS=104.7.12.215/32 MOCK_CURL_IP=104.7.12.215 -- up --yes --json
assert_eq   "a repeat run from the same address succeeds" "0" "$RR_RC"
assert_eq   "the still-current rule is not revoked" "0" \
  "$(grep -c 'revoke-security-group-ingress' "$MOCK_LOG" 2>/dev/null)"

# (d) A failed revoke is best-effort: a loud NOTICE, never a failed `up`. It
#     leaves a stale-but-NARROW rule behind, never a wider one, so an operator
#     whose credentials lack RevokeSecurityGroupIngress can still provision.
run_rr MOCK_AWS_NEW_ID=i-0revokefail MOCK_AWS_STATE=None MOCK_AWS_SG_FIND=sg-0existing \
  MOCK_AWS_SG_OWNED_CIDRS=52.119.115.124/32 MOCK_AWS_REVOKE_FAIL=1 MOCK_CURL_IP=104.7.12.215 \
  -- up --yes --json
assert_eq   "a failed revoke does not fail the run" "0" "$RR_RC"
assert_contains "a failed revoke prints a loud NOTICE" "$RR_ERR" "could not revoke this tooling's stale SSH ingress rule"
assert_contains "the NOTICE hands over the manual revoke command" "$RR_ERR" "aws ec2 revoke-security-group-ingress --group-id sg-0existing"
assert_contains "the current address is still authorized" "$(cat "$MOCK_LOG")" "CidrIp=104.7.12.215/32"

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
echo "-- fresh-instance SSH readiness wait (repo#449) --"
# ---------------------------------------------------------------------------
# A freshly booted guest refuses connections for tens of seconds while
# cloud-init/sshd come up. The probe must WAIT (bounded, configurable) rather
# than report a false provisioning failure on the very first refusal -- while
# still failing loudly on a genuinely unreachable host, and failing
# IMMEDIATELY on an auth/config error that no amount of waiting can fix.
#
# ssh_probe_count -> number of real connection attempts in the last run_rr
# (the mock appends one line per probe; `ssh -G` config-parse calls excluded).
ssh_probe_count() { wc -l <"$MOCK_LOG.sshprobes" | tr -d ' '; }

# (a) Two connection-refused attempts, then success: `up` succeeds, the retry
#     actually happened, and exactly ONE instance was launched across it.
run_rr MOCK_AWS_NEW_ID=i-0readyretry MOCK_AWS_STATE=203.0.113.30 \
       MOCK_SSH_FAIL_COUNT=2 \
       REPO_REMOTE_SSH_READY_TIMEOUT=30 REPO_REMOTE_SSH_READY_POLL_INTERVAL=0 \
       -- up --yes --json
assert_eq "connection-refused then success -> up succeeds (no false failure)" "0" "$RR_RC"
assert_eq "the probe retried past the refusals (3 attempts)" "3" "$(ssh_probe_count)"
assert_contains "a retry notice explains the wait" "$RR_ERR" "still booting"
assert_contains "success names the number of attempts" "$RR_ERR" "after 3 attempts"
# The retry loop must NEVER relaunch: exactly one run-instances across the run.
assert_eq "exactly one instance launched across the retry sequence" \
          "1" "$(grep -c 'run-instances' "$MOCK_LOG")"
assert_eq "no extra start-instances issued during the retry" \
          "0" "$(grep -c 'start-instances' "$MOCK_LOG")"
assert_eq "the created instance id is reported" "i-0readyretry" "$(json_field "$RR_OUT" instance_id)"

# Drop the id the run just wrote back, so the next scenario creates afresh
# instead of taking the pinned-reuse path.
write_repo_env "REPO_REMOTE_INSTANCE_TYPE=m5.2xlarge"

# (b) Permanent refusal: still a loud exit-4 die once the window is exhausted,
#     naming the configured window -- never a silent success, never a warning.
run_rr MOCK_AWS_NEW_ID=i-0readytimeout MOCK_AWS_STATE=203.0.113.31 \
       MOCK_SSH_FAIL=1 \
       REPO_REMOTE_SSH_READY_TIMEOUT=1 REPO_REMOTE_SSH_READY_POLL_INTERVAL=1 \
       -- up --yes --json
assert_eq   "permanent refusal -> still a loud failure (exit 4)" "4" "$RR_RC"
assert_contains "failure names the reachability check" "$RR_ERR" "SSH reachability check failed"
assert_contains "failure names the configured wait window" "$RR_ERR" "within 1s"
assert_contains "failure points at the tunable" "$RR_ERR" "REPO_REMOTE_SSH_READY_TIMEOUT"
assert_contains "failure still names the ingress/key/user knobs" "$RR_ERR" "REPO_REMOTE_SSH_CIDR"
# It retried (more than the single pre-#449 attempt) before giving up.
[[ "$(ssh_probe_count)" -ge 2 ]] \
  && ok "the window was actually retried before dying ($(ssh_probe_count) attempts)" \
  || no "expected >= 2 probe attempts before the deadline, got $(ssh_probe_count)"
# ...and the instance id is STILL written back, so a readiness timeout never
# orphans a box the caller has already paid for.
assert_contains "instance id is persisted despite the readiness timeout" \
                "$(cat "$REPO/.env")" "REPO_REMOTE_INSTANCE_ID=i-0readytimeout"
assert_eq "no relaunch while the readiness window was being exhausted" \
          "1" "$(grep -c 'run-instances' "$MOCK_LOG")"

write_repo_env "REPO_REMOTE_INSTANCE_TYPE=m5.2xlarge"

# (c) An authentication failure is NOT boot-in-progress: it must fail on the
#     FIRST attempt rather than burning the whole retry budget on an error
#     that waiting can never fix.
run_rr MOCK_AWS_NEW_ID=i-0readyauth MOCK_AWS_STATE=203.0.113.32 \
       MOCK_SSH_FAIL=1 MOCK_SSH_STDERR="ubuntu@203.0.113.32: Permission denied (publickey)." \
       REPO_REMOTE_SSH_READY_TIMEOUT=60 REPO_REMOTE_SSH_READY_POLL_INTERVAL=1 \
       -- up --yes --json
assert_eq   "auth failure -> loud failure (exit 4)" "4" "$RR_RC"
assert_eq   "auth failure is NOT retried (exactly one attempt)" "1" "$(ssh_probe_count)"
assert_contains "the failure explains waiting will not help" "$RR_ERR" "still booting, so waiting longer will not help"
assert_contains "the failure surfaces ssh's own error text" "$RR_ERR" "Permission denied"
assert_contains "the failure names the key/user knobs" "$RR_ERR" "REPO_REMOTE_SSH_KEY"

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
#     guard's cron/watchdog script, not feed 0 into the fallback countdown's
#     arithmetic (`(NOW - LAST) / 60 -ge 0` is true on the very first
#     post-$STAMP tick, which used to shut the host down almost immediately
#     instead of never). repo#177: --user-data itself is NO LONGER omitted in
#     this case — it now ALWAYS carries the authorized_keys belt-and-suspenders
#     injection regardless of the idle-guard setting; only the cron/watchdog
#     portion is conditional on IDLE_MIN.
write_repo_env "REPO_REMOTE_INSTANCE_TYPE=m5.2xlarge" "REPO_REMOTE_IDLE_SHUTDOWN_MIN=0"
rm -f "$UD_CAP"
run_rr MOCK_AWS_NEW_ID=i-0noguard MOCK_AWS_STATE=None -- up --yes --json
assert_eq "IDLE_MIN=0 still provisions successfully" "0" "$RR_RC"
assert_contains "IDLE_MIN=0: --user-data flag is still passed (repo#177 authorized_keys)" \
  "$(cat "$MOCK_LOG")" "user-data"
assert_contains "IDLE_MIN=0: user-data still injects authorized_keys" \
  "$(cat "$UD_CAP" 2>/dev/null)" "authorized_keys"
assert_not_contains "IDLE_MIN=0: no idle-guard cron/watchdog content is embedded" \
  "$(cat "$UD_CAP" 2>/dev/null)" "repo-remote-idle-check"

# Negative windows are treated the same as 0 (also "disabled") — same
# repo#177 carve-out: the cron/watchdog portion is skipped, authorized_keys
# injection is not.
rm -f "$UD_CAP"
write_repo_env "REPO_REMOTE_INSTANCE_TYPE=m5.2xlarge" "REPO_REMOTE_IDLE_SHUTDOWN_MIN=-5"
run_rr MOCK_AWS_NEW_ID=i-0noguard2 MOCK_AWS_STATE=None -- up --yes --json
assert_contains "negative IDLE_MIN: --user-data flag is still passed" \
  "$(cat "$MOCK_LOG")" "user-data"
assert_contains "negative IDLE_MIN: user-data still injects authorized_keys" \
  "$(cat "$UD_CAP" 2>/dev/null)" "authorized_keys"
assert_not_contains "negative IDLE_MIN: no idle-guard cron/watchdog content is embedded" \
  "$(cat "$UD_CAP" 2>/dev/null)" "repo-remote-idle-check"

write_repo_env "REPO_REMOTE_INSTANCE_TYPE=m5.2xlarge"

# ---------------------------------------------------------------------------
echo ""
echo "-- AWS key-pair resolution at launch (repo#177: KeyName: None fix) --"
# ---------------------------------------------------------------------------
# Root cause: aws_create() used to read --key-name from an undocumented
# REPO_REMOTE_SSH_KEY_NAME that nothing ever set, so --key-name was silently
# omitted and instances launched unreachable (KeyName: None). The fix resolves
# the key pair from REPO_REMOTE_SSH_KEY's public key instead.

# (a) No matching account key pair -> import-key-pair is called, and the
#     resulting --key-name is present on the run-instances call.
rm -f "$UD_CAP"
run_rr MOCK_AWS_NEW_ID=i-0keypair1 MOCK_AWS_STATE=None MOCK_AWS_KEYPAIR_NAME=None -- up --yes --json
assert_eq   "no matching key pair: provisions successfully" "0" "$RR_RC"
assert_contains "no matching key pair: import-key-pair was called" \
  "$(cat "$MOCK_LOG")" "import-key-pair"
assert_contains "run-instances always carries --key-name" \
  "$(cat "$MOCK_LOG")" "--key-name repo-remote-myrepo"

# (b) A matching account key pair already exists (by fingerprint) ->
#     import-key-pair must NOT be called; the discovered name is reused.
run_rr MOCK_AWS_NEW_ID=i-0keypair2 MOCK_AWS_STATE=None MOCK_AWS_KEYPAIR_NAME=existing-key -- up --yes --json
assert_eq   "matching key pair found: provisions successfully" "0" "$RR_RC"
assert_not_contains "matching key pair found: import-key-pair NOT called" \
  "$(cat "$MOCK_LOG")" "import-key-pair"
assert_contains "matching key pair found: reused name is passed as --key-name" \
  "$(cat "$MOCK_LOG")" "--key-name existing-key"

# (c) Post-create verification: the mock reports KeyName: null after creation
#     -> `up` must fail loudly (exit 4) instead of reporting success on an
#     unreachable-by-design host.
run_rr MOCK_AWS_NEW_ID=i-0nokey MOCK_AWS_STATE=None MOCK_AWS_KEYNAME_CHECK=None -- up --yes --json
assert_eq   "post-create KeyName:null -> exit 4" "4" "$RR_RC"
assert_contains "failure message names the instance" "$RR_ERR" "i-0nokey"
assert_contains "failure message names KeyName" "$RR_ERR" "KeyName"

# (d) Edge case: missing REPO_REMOTE_SSH_KEY's .pub file -> a loud, actionable
#     failure (never a silent key-less launch).
run_rr REPO_REMOTE_SSH_KEY="$SCRATCH/no-such-key" MOCK_AWS_NEW_ID=i-0nopub MOCK_AWS_STATE=None \
  -- up --yes --json
assert_eq   "missing .pub file -> loud failure (exit 2)" "2" "$RR_RC"
assert_contains "failure names the expected .pub path" "$RR_ERR" "no-such-key.pub"
assert_eq   "missing .pub file: nothing was ever launched" "0" \
  "$(grep -c 'run-instances' "$MOCK_LOG" 2>/dev/null)"

# (e) The authorized_keys belt-and-suspenders injection is present and
#     idempotent (deduplicated) across repeat boots.
rm -f "$UD_CAP"
run_rr MOCK_AWS_NEW_ID=i-0authkeys MOCK_AWS_STATE=None -- up --yes --json
UD_AUTH="$(cat "$UD_CAP" 2>/dev/null)"
assert_contains "user-data appends to authorized_keys" "$UD_AUTH" ">>~ubuntu/.ssh/authorized_keys"
assert_contains "user-data dedupes on repeat boots (grep -qxF guard)" "$UD_AUTH" "grep -qxF"
PUBLINE="$(cat "${SSH_KEY_FIXTURE}.pub")"
assert_contains "user-data embeds the resolved public key" "$UD_AUTH" "$PUBLINE"

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
# repo#176: reusing an instance must never create a security group per `up` —
# no SG may accumulate per invocation. repo#451 keeps that property: the reuse
# path re-authorizes ingress on a group it can RESOLVE (see the dedicated
# section below), and when there is none to resolve — as here, where the mock
# reports no tagged group — it logs a notice rather than conjuring one that
# could not be attached to an already-running instance anyway.
assert_eq "reuse: no SG creation on every up"  "0" "$(grep -c 'create-security-group' "$MOCK_LOG" 2>/dev/null)"
assert_eq "reuse with no resolvable SG: no ingress call either" "0" \
  "$(grep -c 'authorize-security-group-ingress' "$MOCK_LOG" 2>/dev/null)"
assert_contains "reuse with no resolvable SG: says so explicitly (repo#451)" \
  "$RR_ERR" "SSH ingress was NOT refreshed for this reused instance"
# A stopped pinned instance is started, still reused.
run_rr MOCK_AWS_STATE=stopped MOCK_AWS_SG_FIND=sg-0existing -- up --yes --json
assert_contains "stopped pinned instance is started" "$(cat "$MOCK_LOG")" "start-instances"
assert_contains "still reported reused" "$RR_OUT" '"reused":true'
assert_eq "reuse (start-from-stopped): no SG creation either" \
  "0" "$(grep -c 'create-security-group' "$MOCK_LOG" 2>/dev/null)"
write_repo_env "REPO_REMOTE_INSTANCE_TYPE=m5.2xlarge"

# ---------------------------------------------------------------------------
echo ""
echo "-- reuse re-authorizes SSH ingress for the CURRENT CIDR (repo#451) --"
# ---------------------------------------------------------------------------
# The reported incident: the idle guard stopped the box; the next `up` restarted
# it, but the security group's tcp/22 rule was still pinned to the laptop IP
# from the ORIGINAL create (52.119.115.124), while the laptop had since moved to
# 104.7.12.215 — so SSH timed out until the /32 was revoked and re-authorized by
# hand. Every reuse branch must now re-run resolve-SG -> resolve-CIDR ->
# authorize -> verify for the currently detected address.

# (a) Already-running pinned id: the tagged SG is reused (not recreated) and
#     tcp/22 is re-authorized for the freshly detected CIDR.
write_repo_env "REPO_REMOTE_INSTANCE_TYPE=m5.2xlarge" "REPO_REMOTE_INSTANCE_ID=i-0pinned"
run_rr MOCK_AWS_STATE=running MOCK_AWS_SG_FIND=sg-0existing MOCK_CURL_IP=104.7.12.215 -- up --yes --json
assert_eq   "reuse (running): up still succeeds" "0" "$RR_RC"
assert_contains "reuse (running): still reported reused" "$RR_OUT" '"reused":true'
RIGLOG="$(cat "$MOCK_LOG")"
assert_eq   "reuse (running): nothing new was launched" "0" "$(grep -c 'run-instances' "$MOCK_LOG" 2>/dev/null)"
assert_not_contains "reuse (running): the tagged SG is reused, not recreated" "$RIGLOG" "create-security-group"
assert_contains "reuse (running): ingress re-authorized on the resolved SG" "$RIGLOG" "group-id sg-0existing"
assert_contains "reuse (running): re-authorized for the CURRENT detected CIDR" "$RIGLOG" "CidrIp=104.7.12.215/32"
assert_contains "reuse (running): the rule is tcp/22" "$RIGLOG" "IpProtocol=tcp,FromPort=22,ToPort=22"
assert_contains "reuse (running): the rule is verified after authorizing" \
  "$RIGLOG" "describe-security-groups --group-ids sg-0existing"

# (b) Restarted pinned id (stopped -> start-instances): same refresh.
run_rr MOCK_AWS_STATE=stopped MOCK_AWS_SG_FIND=sg-0existing MOCK_CURL_IP=104.7.12.215 -- up --yes --json
assert_eq   "reuse (restarted pinned): up still succeeds" "0" "$RR_RC"
RESTARTLOG="$(cat "$MOCK_LOG")"
assert_contains "reuse (restarted pinned): the instance was started" "$RESTARTLOG" "start-instances"
assert_contains "reuse (restarted pinned): ingress re-authorized for the current CIDR" \
  "$RESTARTLOG" "CidrIp=104.7.12.215/32"
assert_contains "reuse (restarted pinned): authorized against the resolved SG" \
  "$RESTARTLOG" "group-id sg-0existing"

# (c) Restarted TAG-DISCOVERED instance (no pinned id): same refresh.
write_repo_env "REPO_REMOTE_INSTANCE_TYPE=m5.2xlarge"
run_rr MOCK_AWS_FIND="i-0found stopped" MOCK_AWS_SG_FIND=sg-0existing MOCK_CURL_IP=104.7.12.215 \
  -- up --yes --json
assert_eq   "reuse (tag-discovered): up still succeeds" "0" "$RR_RC"
assert_contains "reuse (tag-discovered): reused the discovered instance" "$RR_OUT" '"instance_id":"i-0found"'
TAGLOG="$(cat "$MOCK_LOG")"
assert_contains "reuse (tag-discovered): the instance was started" "$TAGLOG" "start-instances"
assert_contains "reuse (tag-discovered): ingress re-authorized for the current CIDR" \
  "$TAGLOG" "CidrIp=104.7.12.215/32"

# (d) Edge case: an explicit REPO_REMOTE_SECURITY_GROUP on a reuse path is
#     idempotently re-authorized and re-verified too, never skipped — and still
#     wins outright (no tag lookup, no creation).
write_repo_env "REPO_REMOTE_INSTANCE_TYPE=m5.2xlarge" "REPO_REMOTE_INSTANCE_ID=i-0pinned"
run_rr MOCK_AWS_STATE=running REPO_REMOTE_SECURITY_GROUP=sg-0pinned MOCK_CURL_IP=104.7.12.215 \
  -- up --yes --json
assert_eq   "reuse (explicit SG): up still succeeds" "0" "$RR_RC"
EXPLLOG="$(cat "$MOCK_LOG")"
assert_not_contains "reuse (explicit SG): no SG is created" "$EXPLLOG" "create-security-group"
assert_contains "reuse (explicit SG): ingress authorized on the explicit group" "$EXPLLOG" "group-id sg-0pinned"
assert_contains "reuse (explicit SG): the explicit group is verified" \
  "$EXPLLOG" "describe-security-groups --group-ids sg-0pinned"

# (e) REPO_REMOTE_SSH_CIDR still wins outright on the reuse path (no echo
#     lookup at all), exactly as it does on create.
run_rr MOCK_AWS_STATE=running MOCK_AWS_SG_FIND=sg-0existing REPO_REMOTE_SSH_CIDR=198.51.100.44/32 \
  -- up --yes --json
assert_eq   "reuse (CIDR override): up still succeeds" "0" "$RR_RC"
OVREUSELOG="$(cat "$MOCK_LOG")"
assert_contains     "reuse (CIDR override): the override CIDR is authorized" "$OVREUSELOG" "CidrIp=198.51.100.44/32"
assert_not_contains "reuse (CIDR override): no IP detection is performed" "$OVREUSELOG" "curl "

# (f) A verification failure on the reuse path is just as loud as on create
#     (exit 4) — a reused host whose group admits no SSH is not a success.
run_rr MOCK_AWS_STATE=running MOCK_AWS_SG_FIND=sg-0existing MOCK_AWS_SG_INGRESS_EMPTY=1 \
  -- up --yes --json
assert_eq   "reuse: empty ingress after re-authorizing -> exit 4" "4" "$RR_RC"
assert_contains "reuse: the failure names the missing tcp/22 rule" "$RR_ERR" "no tcp/22 ingress rule"
assert_not_contains "reuse: no up result emitted on ingress-verification failure" "$RR_OUT" '"action":"up"'

# (g) The refresh runs only for a REAL run: a dry run still touches nothing.
run_rr MOCK_AWS_STATE=running MOCK_AWS_SG_FIND=sg-0existing -- up --json
assert_eq   "dry run: exit 0" "0" "$RR_RC"
assert_eq   "dry run: no ingress call is made" "0" \
  "$(grep -c 'authorize-security-group-ingress' "$MOCK_LOG" 2>/dev/null)"

# (h) No group to refresh (none pinned, none tagged): the reuse path must NOT
#     create one — it would not be attached to the already-running instance, so
#     it would leak an unused group while looking like a repair (repo#176's
#     "no new SG accumulates per invocation" still holds). It says so instead,
#     and the run still succeeds.
run_rr MOCK_AWS_STATE=running MOCK_AWS_SG_FIND=None -- up --yes --json
assert_eq   "reuse (no resolvable SG): up still succeeds" "0" "$RR_RC"
NOSGLOG="$(cat "$MOCK_LOG")"
assert_not_contains "reuse (no resolvable SG): no group is created" "$NOSGLOG" "create-security-group"
assert_eq   "reuse (no resolvable SG): no ingress is authorized into thin air" "0" \
  "$(grep -c 'authorize-security-group-ingress' "$MOCK_LOG" 2>/dev/null)"
assert_contains "reuse (no resolvable SG): the notice names the un-refreshed ingress" \
  "$RR_ERR" "SSH ingress was NOT refreshed for this reused instance"
assert_contains "reuse (no resolvable SG): the notice gives the manual remedy" \
  "$RR_ERR" "authorize-security-group-ingress --group-id"

# (i) SECURITY: refreshing ingress on reuse must never WIDEN it. When current-IP
#     detection fails, the create path's documented 0.0.0.0/0 fallback would
#     turn a working /32 on an existing group into an open rule — on a path that
#     previously did not touch ingress at all. With a tcp/22 rule already
#     present, the reuse path leaves the group exactly as it is instead.
run_rr MOCK_AWS_STATE=running MOCK_AWS_SG_FIND=sg-0existing MOCK_CURL_FAIL=1 -- up --yes --json
assert_eq   "reuse (detection failed): up still succeeds" "0" "$RR_RC"
assert_eq   "reuse (detection failed): the existing rule is NOT widened to 0.0.0.0/0" "0" \
  "$(grep -c 'authorize-security-group-ingress' "$MOCK_LOG" 2>/dev/null)"
assert_contains "reuse (detection failed): says the ingress was left as-is" \
  "$RR_ERR" "left EXACTLY as it is"
assert_contains "reuse (detection failed): points at REPO_REMOTE_SSH_CIDR" \
  "$RR_ERR" "REPO_REMOTE_SSH_CIDR"

# An EXPLICIT, opted-in 0.0.0.0/0 is not a detection failure and is still
# honored verbatim on the reuse path (repo#487 adds the opt-in requirement; it
# does not change what happens once the operator has opted in).
run_rr MOCK_AWS_STATE=running MOCK_AWS_SG_FIND=sg-0existing REPO_REMOTE_SSH_CIDR=0.0.0.0/0 \
  REPO_REMOTE_ALLOW_WORLD_SSH=1 -- up --yes --json
assert_eq   "reuse (opted-in 0.0.0.0/0): up succeeds" "0" "$RR_RC"
assert_contains "reuse (opted-in 0.0.0.0/0): the opt-in is honored verbatim" \
  "$(cat "$MOCK_LOG")" "CidrIp=0.0.0.0/0"

# And WITHOUT the opt-in the same reuse run is refused — the validation gate
# applies on every path, not just at create time.
run_rr MOCK_AWS_STATE=running MOCK_AWS_SG_FIND=sg-0existing REPO_REMOTE_SSH_CIDR=0.0.0.0/0 \
  -- up --yes --json
assert_eq   "reuse (un-opted-in 0.0.0.0/0): refused (exit 2)" "2" "$RR_RC"
assert_eq   "reuse (un-opted-in 0.0.0.0/0): nothing is authorized" "0" \
  "$(grep -c 'authorize-security-group-ingress' "$MOCK_LOG" 2>/dev/null)"

# repo#487: with NO tcp/22 rule present at all there is nothing to preserve —
# and, since the 0.0.0.0/0 fallback is gone, nothing this run can safely
# invent either. It fails CLOSED (exit 2) rather than opening the box to the
# world. (Before repo#487 this path applied the world-open fallback and then
# failed verification with exit 4.)
run_rr MOCK_AWS_STATE=running MOCK_AWS_SG_FIND=sg-0existing MOCK_CURL_FAIL=1 \
  MOCK_AWS_SG_INGRESS_EMPTY=1 -- up --yes --json
assert_eq   "reuse (detection failed, no existing rule): fails closed (exit 2)" "2" "$RR_RC"
assert_not_contains "reuse (detection failed, no existing rule): no world-open rule is written" \
  "$(cat "$MOCK_LOG")" "CidrIp=0.0.0.0/0"
assert_contains "reuse (detection failed, no existing rule): names REPO_REMOTE_SSH_CIDR as the fix" \
  "$RR_ERR" "REPO_REMOTE_SSH_CIDR"

write_repo_env "REPO_REMOTE_INSTANCE_TYPE=m5.2xlarge"

# ---------------------------------------------------------------------------
echo ""
echo "-- fleet-marker guard on AWS reuse discovery (repo#164) --"
# ---------------------------------------------------------------------------
# Reuse discovery (a pinned REPO_REMOTE_INSTANCE_ID, or the repo-remote=<name>
# tag) resolves a handle that can outlive the host's role as an ephemeral dev
# box. Starting/re-aliasing a host that has since become a fleet worker is the
# second finding of an operator incident (private tracker), so a fleet marker on the resolved instance
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
assert_contains "GPU table hit has basis=table" "$RR_OUT" '"estimated_cost_basis":"table"'

# Current-gen (7th-gen) type present in the explicit price table -> an exact
# hit, not a guess (repo#178: the price table previously had zero 7th-gen
# entries at all).
write_repo_env "REPO_REMOTE_INSTANCE_TYPE=c7i.xlarge"
run_rr -- up --json
assert_eq "c7i.xlarge table hit carries its exact price" "0.1785" "$(json_field "$RR_OUT" estimated_hourly_cost_usd)"
assert_contains "c7i.xlarge table hit not flagged approximate" "$RR_OUT" '"estimated_cost_approximate":false'
assert_contains "c7i.xlarge table hit basis is table" "$RR_OUT" '"estimated_cost_basis":"table"'

# Current-gen type NOT in the table (a large, 96-vCPU size) -> vCPU-scaled
# fallback, not the old flat-$0.20 bug this issue reports (repo#178). 96 vCPU
# * $0.045/vCPU-hr = $4.32/hr — the right order of magnitude, unlike the
# previous ~20x-too-low flat heuristic.
write_repo_env "REPO_REMOTE_INSTANCE_TYPE=c7i.24xlarge"
run_rr -- up --json
assert_eq "c7i.24xlarge unlisted -> vCPU-scaled, not the flat \$0.20 bug" "4.3200" "$(json_field "$RR_OUT" estimated_hourly_cost_usd)"
assert_contains "c7i.24xlarge flagged approximate" "$RR_OUT" '"estimated_cost_approximate":true'
assert_contains "c7i.24xlarge basis is vcpu-scaled, distinguishable from a table hit" "$RR_OUT" '"estimated_cost_basis":"vcpu-scaled"'

# Unknown type with no AWS-style size suffix -> the true last-resort flat
# heuristic. The $0.20 value itself is unchanged (there is nothing to scale
# from), but it is now explicitly labeled via estimated_cost_basis so a caller
# can distinguish it from a table hit or a vCPU-scaled guess — this replaces
# the old assertion that pinned the flat value with no way to tell it apart
# from a real price.
write_repo_env "REPO_REMOTE_INSTANCE_TYPE=zz.unknown"
run_rr -- up --json
assert_contains "unknown type flagged approximate" "$RR_OUT" '"estimated_cost_approximate":true'
assert_contains "unknown type still carries a cost number" "$RR_OUT" '"estimated_hourly_cost_usd":0.20'
assert_contains "unknown type basis is the last-resort heuristic" "$RR_OUT" '"estimated_cost_basis":"heuristic"'
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
# --delete TERMINATES it (disk gone, unrecoverable) — the operator incident (private tracker)
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
echo "-- write_ssh_alias() concurrency (repo#213) --"
# ---------------------------------------------------------------------------
# repo-remote.sh can be `source`d without invoking main() (the
# BASH_SOURCE[0]==$0 guard at the bottom of the file), so these tests call
# write_ssh_alias() directly instead of going through the full `up` flow --
# there is no need to mock aws/gcp just to exercise this one function.
CONC_CFG="$SCRATCH/concurrent_ssh_config"
rm -f "$CONC_CFG" "$CONC_CFG.lock"
(
  REPO_REMOTE_SSH_CONFIG="$CONC_CFG" bash -c "
    source '$RR'
    NAME=alpha
    write_ssh_alias '10.0.0.1' >/dev/null
  " &
  P1=$!
  REPO_REMOTE_SSH_CONFIG="$CONC_CFG" bash -c "
    source '$RR'
    NAME=beta
    write_ssh_alias '10.0.0.2' >/dev/null
  " &
  P2=$!
  wait "$P1" "$P2"
)
CONC_OUT="$(cat "$CONC_CFG" 2>/dev/null || true)"
assert_contains "concurrent write_ssh_alias: first writer's block survives" "$CONC_OUT" "Host repo-remote-alpha"
assert_contains "concurrent write_ssh_alias: second writer's block survives" "$CONC_OUT" "Host repo-remote-beta"
assert_eq "concurrent write_ssh_alias: no leftover lock dir" "" "$( [[ -e "$CONC_CFG.lock" ]] && echo present )"

# The temp file used for the read-modify-write swap must be created alongside
# the target config (same directory as $cfg), not under the default $TMPDIR --
# otherwise the final `mv` can degrade to a cross-filesystem copy-then-unlink,
# exposing a window where a concurrent reader observes a partial file. Prove
# it by pointing $TMPDIR at a directory that does not exist: if write_ssh_alias
# ever fell back to `mktemp` under $TMPDIR, mktemp would fail loudly there and
# the write would not happen.
TMPDIR_BOGUS_DIR="$SCRATCH/nonexistent_tmpdir_$$"
TMPDIR_TEST_CFG="$SCRATCH/tmpdir_test/ssh_config"
mkdir -p "$(dirname "$TMPDIR_TEST_CFG")"
TMPDIR_TEST_OUT="$(TMPDIR="$TMPDIR_BOGUS_DIR" REPO_REMOTE_SSH_CONFIG="$TMPDIR_TEST_CFG" bash -c "
  source '$RR'
  NAME=tmpdirtest
  write_ssh_alias '10.0.0.9'
" 2>&1)"
TMPDIR_TEST_RC=$?
assert_eq "write_ssh_alias succeeds with an unusable \$TMPDIR (temp file is created beside \$cfg)" "0" "$TMPDIR_TEST_RC"
assert_not_contains "no mktemp-under-\$TMPDIR failure leaked into output" "$TMPDIR_TEST_OUT" "mktemp"
assert_contains "the alias block was actually written despite the bogus \$TMPDIR" \
  "$(cat "$TMPDIR_TEST_CFG" 2>/dev/null || true)" "Host repo-remote-tmpdirtest"

# ---------------------------------------------------------------------------
echo ""
echo "-- write_ssh_alias() value guard + write-then-validate rollback (repo#216) --"
# ---------------------------------------------------------------------------
# repo#216: write_ssh_alias() previously only guarded `-z "$ip"`, so a
# whitespace value or the literal "None" (the AWS CLI's `--output text`
# rendering of a null scalar -- this suite's mock `aws` already defaults
# MOCK_AWS_STATE to "None" for describe-instances) slipped through and wrote
# a HostName-less stanza. OpenSSH does not skip a malformed stanza -- it
# refuses to parse the WHOLE config file, breaking every other Host block
# (and therefore git-over-SSH) in it.

# (a) The literal string "None" is treated exactly like "no IP yet": no
# stanza is written, the function still succeeds and echoes the alias name.
NONE_CFG="$SCRATCH/none_ssh_config"
rm -f "$NONE_CFG" "$NONE_CFG.lock"
NONE_OUT="$(REPO_REMOTE_SSH_CONFIG="$NONE_CFG" bash -c "
  source '$RR'
  NAME=noneval
  write_ssh_alias 'None'
")"
NONE_RC=$?
assert_eq   "literal 'None' IP -> write_ssh_alias still succeeds" "0" "$NONE_RC"
assert_eq   "literal 'None' IP -> alias name is echoed unchanged" "repo-remote-noneval" "$NONE_OUT"
assert_eq   "literal 'None' IP -> no config file was created at all" "" "$( [[ -e "$NONE_CFG" ]] && echo present )"

# (b) A whitespace-only IP is treated the same way.
WS_CFG="$SCRATCH/ws_ssh_config"
rm -f "$WS_CFG" "$WS_CFG.lock"
WS_OUT="$(REPO_REMOTE_SSH_CONFIG="$WS_CFG" bash -c "
  source '$RR'
  NAME=wsval
  write_ssh_alias '   '
")"
WS_RC=$?
assert_eq   "whitespace-only IP -> write_ssh_alias still succeeds" "0" "$WS_RC"
assert_eq   "whitespace-only IP -> alias name is echoed unchanged" "repo-remote-wsval" "$WS_OUT"
assert_eq   "whitespace-only IP -> no config file was created at all" "" "$( [[ -e "$WS_CFG" ]] && echo present )"

# (c) A pre-existing, valid config is left completely untouched when a
# subsequent call is rejected by the value guard -- the write is a no-op,
# not a rewrite-with-nothing-changed.
PRE_CFG="$SCRATCH/pre_ssh_config"
printf 'Host repo-remote-existing\n    HostName 203.0.113.50\n    User ubuntu\n' >"$PRE_CFG"
PRE_BEFORE="$(cat "$PRE_CFG")"
REPO_REMOTE_SSH_CONFIG="$PRE_CFG" bash -c "
  source '$RR'
  NAME=noneval2
  write_ssh_alias 'None' >/dev/null
"
assert_eq "pre-existing valid config untouched by a rejected ('None') write" "$PRE_BEFORE" "$(cat "$PRE_CFG")"

# (d) Write-then-validate backstop: even a non-empty, non-"None" value that
# is not caught by the tightened value guard (e.g. an embedded newline that
# would inject a bogus config line) must never be installed. This proves the
# rollback closes the bug class generally, not just for the two reported
# candidate values.
INJ_CFG="$SCRATCH/inject_ssh_config"
printf 'Host repo-remote-untouched\n    HostName 203.0.113.60\n    User ubuntu\n' >"$INJ_CFG"
INJ_BEFORE="$(cat "$INJ_CFG")"
INJ_OUT="$(REPO_REMOTE_SSH_CONFIG="$INJ_CFG" bash -c "
  source '$RR'
  NAME=inject
  write_ssh_alias \$'10.0.0.1\nBogusDirective value'
")"
INJ_RC=$?
assert_eq   "malformed value rejected by write-then-validate -> non-zero return" "1" "$INJ_RC"
assert_eq   "malformed value rejected -> alias name is still echoed" "repo-remote-inject" "$INJ_OUT"
assert_eq   "malformed value rejected -> pre-existing config completely untouched" "$INJ_BEFORE" "$(cat "$INJ_CFG")"
assert_not_contains "malformed value rejected -> no lock dir left behind" \
  "$( [[ -e "$INJ_CFG.lock" ]] && echo present )" "present"

# (e) End-to-end: `up` against the mock `aws` (MOCK_AWS_STATE defaults its
# describe-instances response to "None", exercising the exact value this
# issue was filed about) must not write a broken stanza, and whatever ends
# up in the SSH config (nothing, for a None IP) must remain parseable.
E2E_CFG="$SCRATCH/e2e_ssh_config"
rm -f "$E2E_CFG" "$E2E_CFG.lock"
run_rr MOCK_AWS_NEW_ID=i-0e2enone REPO_REMOTE_SSH_CONFIG="$E2E_CFG" MOCK_AWS_STATE=None -- up --yes --json
assert_eq   "up with a None public IP still succeeds" "0" "$RR_RC"
if [[ -s "$E2E_CFG" ]]; then
  assert_not_contains "up with a None public IP -> no HostName-less stanza written" \
    "$(cat "$E2E_CFG")" $'HostName\n'
  ssh -G -F "$E2E_CFG" "repo-remote-myrepo" >/dev/null 2>&1
  assert_eq "up with a None public IP -> resulting SSH config still parses" "0" "$?"
else
  ok "up with a None public IP -> no SSH config file was written (nothing to parse)"
fi

# ---------------------------------------------------------------------------
echo ""
echo "-- aws_public_ip() API-failure path + aws_up()'s handling of it (repo#216) --"
# ---------------------------------------------------------------------------
# The other half of repo#216: the section above covers the "describe-instances
# SUCCEEDED but AWS has no IP assigned yet" path (the literal "None"). This
# section covers the path the issue's own diagnosis flags as the more likely
# real-world root cause -- the describe-instances CALL ITSELF failing (an
# unfulfilled spot request, throttling, a transient AWS error). Before the fix
# both collapsed into the same empty string with a swallowed stderr, so the
# caller could not tell them apart; aws_public_ip() must now propagate the
# `aws` exit code and surface the captured stderr, and aws_up() must degrade
# gracefully (log + continue with no IP) rather than crash.

# (f) Baseline for the contrast: a SUCCESSFUL call that yields no IP returns
# 0 and the literal "None". This is the case that must stay distinguishable
# from the failure below.
IPNONE_ERR="$SCRATCH/ip_none.err"
IPNONE_OUT="$(PATH="$MOCK_BIN:$PATH" MOCK_AWS_LOG=/dev/null MOCK_AWS_PUBLIC_IP=None bash -c "
  source '$RR'
  aws_public_ip i-0ipnone
" 2>"$IPNONE_ERR")"
IPNONE_RC=$?
assert_eq   "aws_public_ip: successful call with no IP assigned -> exit 0" "0" "$IPNONE_RC"
assert_eq   "aws_public_ip: successful call with no IP assigned -> echoes 'None'" "None" "$IPNONE_OUT"
assert_not_contains "aws_public_ip: a successful call logs no API error" \
  "$(cat "$IPNONE_ERR")" "failed:"

# (g) An API-call FAILURE propagates the underlying `aws` exit code (254 from
# the mock) instead of the 0 the old code returned, and the captured stderr
# is surfaced rather than swallowed.
IPFAIL_ERR="$SCRATCH/ip_fail.err"
IPFAIL_OUT="$(PATH="$MOCK_BIN:$PATH" MOCK_AWS_LOG=/dev/null MOCK_AWS_PUBLIC_IP_FAIL=1 bash -c "
  source '$RR'
  aws_public_ip i-0ipfail
" 2>"$IPFAIL_ERR")"
IPFAIL_RC=$?
assert_eq   "aws_public_ip: API failure propagates the aws exit code (not 0)" "254" "$IPFAIL_RC"
assert_eq   "aws_public_ip: API failure is distinguishable from the succeeded-but-None case" \
  "different" "$( [[ "$IPFAIL_RC" != "$IPNONE_RC" ]] && echo different || echo same )"
assert_eq   "aws_public_ip: API failure echoes no IP" "" "$IPFAIL_OUT"
assert_contains "aws_public_ip: API failure names the failing call and instance" \
  "$(cat "$IPFAIL_ERR")" "public IP lookup for i-0ipfail"
assert_contains "aws_public_ip: the swallowed aws stderr is surfaced" \
  "$(cat "$IPFAIL_ERR")" "InvalidInstanceID.NotFound"

# (h) End-to-end through aws_up(): a failed public-IP lookup is NON-fatal --
# the instance is up and the IP may resolve on a later run -- so `up` must
# log the degraded path and still succeed, and must not write a HostName-less
# stanza off the back of the empty IP.
IPFAIL_CFG="$SCRATCH/ipfail_ssh_config"
rm -f "$IPFAIL_CFG" "$IPFAIL_CFG.lock"
run_rr MOCK_AWS_NEW_ID=i-0ipfaile2e REPO_REMOTE_SSH_CONFIG="$IPFAIL_CFG" MOCK_AWS_PUBLIC_IP_FAIL=1 \
  -- up --yes --json
assert_eq   "up with a failed public-IP lookup still succeeds (non-fatal)" "0" "$RR_RC"
assert_contains "up logs the underlying API error rather than swallowing it" \
  "$RR_ERR" "public IP lookup for i-0ipfaile2e"
assert_contains "up logs that it is continuing without a public IP" \
  "$RR_ERR" "continuing with no public IP for i-0ipfaile2e"
assert_contains "up still emits an up result after the degraded lookup" "$RR_OUT" '"action":"up"'
assert_eq   "failed public-IP lookup -> no SSH config written for the empty IP" "" \
  "$( [[ -s "$IPFAIL_CFG" ]] && echo present )"
assert_contains "failed public-IP lookup -> the reachability probe is skipped, not failed" \
  "$RR_ERR" "skipping the end-of-run SSH reachability check"

# (i) The other new aws_up() branch: write_ssh_alias() returning non-zero (the
# write-then-validate rollback) must be reported, not silently ignored -- and
# must not abort the run either. MOCK_SSH_G_FAIL fails only write_ssh_alias()'s
# `ssh -G` config-parse check, leaving the reachability probe working, so this
# exercises the rejected-alias branch in isolation.
REJ_CFG="$SCRATCH/reject_ssh_config"
rm -f "$REJ_CFG" "$REJ_CFG.lock"
printf 'Host repo-remote-preexisting\n    HostName 203.0.113.70\n    User ubuntu\n' >"$REJ_CFG"
REJ_BEFORE="$(cat "$REJ_CFG")"
run_rr MOCK_AWS_NEW_ID=i-0aliasrej REPO_REMOTE_SSH_CONFIG="$REJ_CFG" \
  MOCK_AWS_PUBLIC_IP=203.0.113.71 MOCK_SSH_G_FAIL=1 -- up --yes --json
assert_eq   "up with a rejected SSH alias write still succeeds (non-fatal)" "0" "$RR_RC"
assert_contains "up reports that the SSH alias write was rejected" \
  "$RR_ERR" "SSH alias write for repo-remote-myrepo was rejected"
assert_contains "the rejection message names the alias the user would have used" \
  "$RR_ERR" "ssh repo-remote-myrepo"
assert_eq   "a rejected alias write leaves the pre-existing SSH config untouched" \
  "$REJ_BEFORE" "$(cat "$REJ_CFG")"
assert_eq   "a rejected alias write leaves no lock dir behind" "" \
  "$( [[ -e "$REJ_CFG.lock" ]] && echo present )"

# ---------------------------------------------------------------------------
echo ""
echo "-- public IP: bounded retry, and a loud warning when it is exhausted (repo#451) --"
# ---------------------------------------------------------------------------
# The reported incident: the idle guard stopped the box, the next `up` restarted
# it (a BRAND NEW public IP), and the single unretried describe-instances query
# ran before AWS had propagated that address. write_ssh_alias() then correctly
# refused to write a HostName-less stanza (repo#216) -- but that left the
# PREVIOUS session's now-wrong HostName in place, with nothing in the output
# saying the alias had not been refreshed.

# (j) The IP appears only on the 3rd poll: `up` must keep polling (within its
#     bounded budget) and write the EVENTUALLY-resolved IP, not give up on the
#     first "None".
LATE_CFG="$SCRATCH/late_ip_ssh_config"
rm -f "$LATE_CFG" "$LATE_CFG.lock"
run_rr MOCK_AWS_NEW_ID=i-0iplate REPO_REMOTE_SSH_CONFIG="$LATE_CFG" \
  MOCK_AWS_PUBLIC_IP_AFTER=3 MOCK_AWS_PUBLIC_IP=203.0.113.88 \
  REPO_REMOTE_IP_POLL_ATTEMPTS=5 REPO_REMOTE_IP_POLL_INTERVAL=0 -- up --yes --json
assert_eq   "late public IP: up succeeds" "0" "$RR_RC"
assert_contains "late public IP: the resolved IP is reported" "$RR_OUT" '"public_ip":"203.0.113.88"'
assert_contains "late public IP: the alias is written with the resolved IP" \
  "$(cat "$LATE_CFG" 2>/dev/null)" "HostName 203.0.113.88"
assert_eq   "late public IP: the poll actually retried (3 lookups)" "3" \
  "$(grep -c 'Instances\[0\].PublicIpAddress' "$MOCK_LOG" 2>/dev/null)"
assert_contains "late public IP: the retry is reported" "$RR_ERR" "resolved on attempt 3/5"
assert_not_contains "late public IP: no stale-alias warning when it resolves" \
  "$RR_ERR" "was NOT refreshed"

# (k) The budget is BOUNDED: an IP that never arrives stops after exactly
#     REPO_REMOTE_IP_POLL_ATTEMPTS lookups (never an unbounded loop).
STALE_CFG="$SCRATCH/stale_ip_ssh_config"
rm -f "$STALE_CFG" "$STALE_CFG.lock"
printf 'Host repo-remote-myrepo\n    HostName 203.0.113.9\n    User ubuntu\n' >"$STALE_CFG"
STALE_BEFORE="$(cat "$STALE_CFG")"
run_rr MOCK_AWS_NEW_ID=i-0ipnever REPO_REMOTE_SSH_CONFIG="$STALE_CFG" MOCK_AWS_STATE=None \
  REPO_REMOTE_IP_POLL_ATTEMPTS=3 REPO_REMOTE_IP_POLL_INTERVAL=0 -- up --yes --json
assert_eq   "exhausted budget: up still succeeds (non-fatal)" "0" "$RR_RC"
assert_eq   "exhausted budget: exactly the configured number of lookups" "3" \
  "$(grep -c 'Instances\[0\].PublicIpAddress' "$MOCK_LOG" 2>/dev/null)"
# The distinct warning (k2): "the alias was not refreshed" is stated outright,
# separately from the generic "@ <no public ip>" result line, and names both the
# stale-HostName case and the no-public-IP-by-design case so they are
# distinguishable by a reader.
assert_contains "exhausted budget: warns the alias was NOT refreshed" "$RR_ERR" "was NOT refreshed"
assert_contains "exhausted budget: the warning names the alias" "$RR_ERR" "repo-remote-myrepo"
assert_contains "exhausted budget: the warning calls the HostName stale" "$RR_ERR" "STALE"
assert_contains "exhausted budget: the warning names the private-subnet case too" \
  "$RR_ERR" "no public IP by design"
assert_contains "exhausted budget: the warning names the attempt count" "$RR_ERR" "after 3 attempt(s)"
assert_eq   "exhausted budget: the stale SSH config is left untouched (repo#216 behavior)" \
  "$STALE_BEFORE" "$(cat "$STALE_CFG")"

# (k3) The same warning appears on the human (non-JSON) path, where it must be
#      distinguishable from the generic "@ <no public ip>" result line.
rm -f "$STALE_CFG" "$STALE_CFG.lock"
run_rr MOCK_AWS_NEW_ID=i-0ipnever2 REPO_REMOTE_SSH_CONFIG="$STALE_CFG" MOCK_AWS_STATE=None \
  REPO_REMOTE_IP_POLL_ATTEMPTS=2 REPO_REMOTE_IP_POLL_INTERVAL=0 -- up --yes
assert_eq   "exhausted budget (human output): up still succeeds" "0" "$RR_RC"
assert_contains "exhausted budget (human output): the generic result line is still printed" \
  "$RR_ERR" "<no public ip>"
assert_contains "exhausted budget (human output): the distinct warning is printed too" \
  "$RR_ERR" "was NOT refreshed"

# (l) An outright API FAILURE is retried within the same budget and still
#     degrades gracefully -- the repo#216 messages are preserved.
run_rr MOCK_AWS_NEW_ID=i-0ipfailretry MOCK_AWS_PUBLIC_IP_FAIL=1 \
  REPO_REMOTE_IP_POLL_ATTEMPTS=2 REPO_REMOTE_IP_POLL_INTERVAL=0 -- up --yes --json
assert_eq   "API failure: up still succeeds (non-fatal)" "0" "$RR_RC"
assert_eq   "API failure: retried within the bounded budget" "2" \
  "$(grep -c 'Instances\[0\].PublicIpAddress' "$MOCK_LOG" 2>/dev/null)"
assert_contains "API failure: the underlying error is still surfaced" \
  "$RR_ERR" "public IP lookup for i-0ipfailretry"
assert_contains "API failure: still logs that it is continuing without an IP" \
  "$RR_ERR" "continuing with no public IP for i-0ipfailretry"

# (m) A malformed REPO_REMOTE_IP_POLL_ATTEMPTS falls back to the default
#     budget rather than degenerating into "never poll" or an unbounded loop.
POLLDEF_OUT="$(PATH="$MOCK_BIN:$PATH" MOCK_AWS_LOG="$SCRATCH/polldef.log" MOCK_AWS_STATE=None \
  REPO_REMOTE_IP_POLL_ATTEMPTS=not-a-number REPO_REMOTE_IP_POLL_INTERVAL=0 bash -c "
  source '$RR'
  NAME=myrepo
  aws_wait_public_ip i-0polldefault
" 2>&1)"
assert_contains "malformed attempt count falls back to the built-in budget (6)" \
  "$POLLDEF_OUT" "after 6 attempt(s)"
POLLZERO_OUT="$(PATH="$MOCK_BIN:$PATH" MOCK_AWS_LOG="$SCRATCH/pollzero.log" MOCK_AWS_STATE=None \
  REPO_REMOTE_IP_POLL_ATTEMPTS=0 REPO_REMOTE_IP_POLL_INTERVAL=0 bash -c "
  source '$RR'
  NAME=myrepo
  aws_wait_public_ip i-0pollzero
" 2>&1)"
assert_contains "a zero attempt count falls back to the built-in budget (never 'no poll at all')" \
  "$POLLZERO_OUT" "after 6 attempt(s)"

write_repo_env "REPO_REMOTE_INSTANCE_TYPE=m5.2xlarge"

# ---------------------------------------------------------------------------
echo ""
echo "-- host-identity verification: the stale-alias guard (repo#458) --"
# ---------------------------------------------------------------------------
# The reported incident: an instance was stopped and started again. An EC2
# auto-assigned public IPv4 is RELEASED on stop, so the address the SSH alias
# still carried came back up on a DIFFERENT customer's instance. The alias
# resolved, ssh connected, auth succeeded -- and three agents wrote work
# products to a stranger's machine. Nothing in the tooling warned, because
# every check it had (does the alias resolve? does ssh connect?) passed.
#
# The fix is a check on the ONE thing that cannot be inherited with an IP: the
# host's own instance id, read back over the session and compared against the
# id this repo expects. These tests pin down that it fails LOUDLY on a
# mismatch and fails CLOSED when it cannot get an answer at all.
write_shared "REPO_REMOTE_PROVIDER=aws" "AWS_ACCESS_KEY_ID=AKIA" "AWS_SECRET_ACCESS_KEY=sk" "AWS_REGION=us-west-2"
write_repo_env "REPO_REMOTE_INSTANCE_TYPE=m5.2xlarge" "REPO_REMOTE_INSTANCE_ID=i-0pinnedbox"

# (a) The host reports the pinned id -> verified, exit 0, machine-readable.
run_rr MOCK_SSH_HOST_ID=i-0pinnedbox -- verify --json
assert_eq   "verify: matching host identity -> exit 0" "0" "$RR_RC"
assert_eq   "verify: emits the verify action" "verify" "$(json_field "$RR_OUT" action)"
assert_eq   "verify: reports the expected instance id" "i-0pinnedbox" "$(json_field "$RR_OUT" expected_instance_id)"
assert_eq   "verify: reports what the host itself said" "i-0pinnedbox" "$(json_field "$RR_OUT" host_instance_id)"
assert_eq   "verify: reports the alias it checked" "repo-remote-myrepo" "$(json_field "$RR_OUT" ssh_alias)"
assert_contains "verify: says the id came from the pin" "$RR_OUT" "REPO_REMOTE_INSTANCE_ID"
assert_eq   "verify: a pinned id needs no cloud call at all" "0" \
  "$(grep -c 'describe-instances' "$MOCK_LOG" 2>/dev/null)"

# (b) THE incident: the alias resolves and ssh succeeds, but the box at the
#     other end is somebody else's. This must refuse, loudly, non-zero.
run_rr MOCK_SSH_HOST_ID=i-0strangersbox -- verify --json
assert_eq   "verify: host identity MISMATCH -> exit 6 (refuses)" "6" "$RR_RC"
assert_contains "the refusal is unmistakable" "$RR_ERR" "HOST IDENTITY MISMATCH"
assert_contains "the refusal names the expected instance" "$RR_ERR" "i-0pinnedbox"
assert_contains "the refusal names the instance actually reached" "$RR_ERR" "i-0strangersbox"
assert_contains "the refusal names the alias" "$RR_ERR" "repo-remote-myrepo"
assert_contains "the refusal explains the released-public-IP mechanism" "$RR_ERR" "released"
assert_contains "the refusal says not to write anything through the alias" "$RR_ERR" "Do NOT"
assert_contains "the refusal gives the remediation (re-run up)" "$RR_ERR" "repo-remote up --yes"
assert_not_contains "a mismatch emits no success result" "$RR_OUT" '"verified":true'

# (c) --force is the fleet-marker override and NOTHING else: it must not talk
#     a mismatched host into being accepted.
run_rr MOCK_SSH_HOST_ID=i-0strangersbox -- verify --force --json
assert_eq   "verify: --force does NOT relax the identity check" "6" "$RR_RC"
assert_contains "verify: --force still reports the mismatch" "$RR_ERR" "HOST IDENTITY MISMATCH"

# (d) Fail CLOSED: an unreachable host is not evidence that the host is the
#     right one, so "cannot tell" must never be reported as "verified".
run_rr MOCK_SSH_VERIFY_FAIL=1 -- verify --json
assert_eq   "verify: unreachable host -> exit 6 (fails closed, never silently passes)" "6" "$RR_RC"
assert_contains "verify: says the identity could not be established" "$RR_ERR" "could not"
assert_contains "verify: surfaces the underlying ssh error" "$RR_ERR" "Connection refused"
assert_not_contains "verify: an unreachable host emits no success result" "$RR_OUT" '"verified":true'

# (e) Same fail-closed rule when the host answers but can name no identity
#     source (no marker file, no reachable metadata service).
run_rr -- verify --json
assert_eq   "verify: host reports no identity at all -> exit 6" "6" "$RR_RC"
assert_contains "verify: names the marker file it looked for" "$RR_ERR" "/etc/repo-remote-instance-id"

# (f) No pin and no tagged instance: there is nothing to verify AGAINST, which
#     is a config problem (exit 2), not a silent pass.
write_repo_env "REPO_REMOTE_INSTANCE_TYPE=m5.2xlarge"
run_rr MOCK_AWS_FIND="" MOCK_SSH_HOST_ID=i-0whatever -- verify --json
assert_eq   "verify: nothing to verify against -> exit 2" "2" "$RR_RC"
assert_contains "verify: points at REPO_REMOTE_INSTANCE_ID pinning" "$RR_ERR" "REPO_REMOTE_INSTANCE_ID"

# (g) Unpinned but tag-discoverable: the discovered id is the expectation.
run_rr MOCK_AWS_FIND="i-0taggedbox running" MOCK_SSH_HOST_ID=i-0taggedbox -- verify --json
assert_eq   "verify: tag-discovered instance matches -> exit 0" "0" "$RR_RC"
assert_eq   "verify: expectation came from the tag" "i-0taggedbox" "$(json_field "$RR_OUT" expected_instance_id)"
run_rr MOCK_AWS_FIND="i-0taggedbox running" MOCK_SSH_HOST_ID=i-0someoneelse -- verify --json
assert_eq   "verify: tag-discovered instance mismatched -> exit 6" "6" "$RR_RC"

# (h) GCP verifies the same way, against the instance NAME the alias should be
#     pointing at (gcp_up derives repo-remote-<name>).
write_shared "REPO_REMOTE_PROVIDER=gcp" "GCP_PROJECT=p" "GCP_ZONE=us-central1-a" \
             "GOOGLE_APPLICATION_CREDENTIALS=/tmp/sa.json"
write_repo_env "REPO_REMOTE_INSTANCE_TYPE=e2-standard-4"
run_rr MOCK_SSH_HOST_ID=repo-remote-myrepo -- verify --json
assert_eq   "verify (gcp): matching instance name -> exit 0" "0" "$RR_RC"
run_rr MOCK_SSH_HOST_ID=some-other-vm -- verify --json
assert_eq   "verify (gcp): mismatched instance name -> exit 6" "6" "$RR_RC"
assert_contains "verify (gcp): the refusal names the host actually reached" "$RR_ERR" "some-other-vm"

# (i) The probe itself: it must prefer the marker file this tool drops, then
#     fall back to the instance metadata service, so an instance provisioned
#     BEFORE the marker existed is still verifiable.
PROBE="$(bash -c "source '$RR'; host_identity_probe")"
assert_contains "probe reads the marker file first" "$PROBE" "/etc/repo-remote-instance-id"
assert_contains "probe falls back to IMDSv2 (token request)" "$PROBE" "latest/api/token"
assert_contains "probe falls back to the EC2 instance-id metadata key" "$PROBE" "meta-data/instance-id"
assert_contains "probe also handles GCP metadata" "$PROBE" "Metadata-Flavor: Google"
assert_contains "probe exits non-zero when it can name no identity" "$PROBE" "exit 1"

# ---------------------------------------------------------------------------
echo ""
echo "-- host-identity verification is wired into \`up\` (repo#458) --"
# ---------------------------------------------------------------------------
# AC2: the check must not depend on an agent remembering to run it. `up` is the
# one command every session-start sequence already runs, so it verifies the
# alias it just wrote before reporting success.
write_shared "REPO_REMOTE_PROVIDER=aws" "AWS_ACCESS_KEY_ID=AKIA" "AWS_SECRET_ACCESS_KEY=sk" "AWS_REGION=us-west-2"
write_repo_env "REPO_REMOTE_INSTANCE_TYPE=m5.2xlarge"

# (j) The created instance answers with its own id -> `up` says so and succeeds.
run_rr MOCK_AWS_NEW_ID=i-0freshbox MOCK_AWS_PUBLIC_IP=203.0.113.80 MOCK_SSH_HOST_ID=i-0freshbox \
  -- up --yes --json
assert_eq   "up: verified host identity -> exit 0" "0" "$RR_RC"
assert_contains "up: reports the identity it verified" "$RR_ERR" "host identity verified"
assert_contains "up: names the instance id it confirmed" "$RR_ERR" "i-0freshbox"

# (k) The alias `up` just wrote reaches a DIFFERENT box -> refuse, exit 6.
run_rr MOCK_AWS_NEW_ID=i-0freshbox MOCK_AWS_PUBLIC_IP=203.0.113.80 MOCK_SSH_HOST_ID=i-0strangersbox \
  -- up --yes --json
assert_eq   "up: identity mismatch after provisioning -> exit 6" "6" "$RR_RC"
assert_contains "up: the refusal is the same loud one" "$RR_ERR" "HOST IDENTITY MISMATCH"

# (l) A host that can name no identity does NOT fail `up` -- `up` resolved the
#     IP from the cloud API and rewrote the alias in this same run, so the
#     alias is fresh by construction; an unverifiable answer is a warning, and
#     the standalone `verify` (which fails closed) is what a later reconnect
#     must run. Anything stricter would break `up` on every instance
#     provisioned before the marker existed with IMDS locked down.
run_rr MOCK_AWS_NEW_ID=i-0quietbox MOCK_AWS_PUBLIC_IP=203.0.113.81 -- up --yes --json
assert_eq   "up: unverifiable identity is non-fatal" "0" "$RR_RC"
assert_contains "up: but it warns loudly" "$RR_ERR" "could not verify"
assert_contains "up: and names the command that fails closed" "$RR_ERR" "repo-remote verify"

# (m) No public IP resolved -> the alias was NOT refreshed, so it may still
#     carry the PREVIOUS session's address. `up` must say the identity is
#     unverified rather than imply the alias is good.
run_rr MOCK_AWS_NEW_ID=i-0noipbox MOCK_AWS_PUBLIC_IP_FAIL=1 -- up --yes --json
assert_eq   "up with no public IP still succeeds (unchanged, repo#216)" "0" "$RR_RC"
assert_contains "up: warns the stale alias was not identity-verified" "$RR_ERR" "could not"

# (n) The marker itself: a created instance records its OWN id at boot, so a
#     later session has a source that does not depend on IMDS still being
#     reachable.
run_rr MOCK_AWS_NEW_ID=i-0markerbox MOCK_AWS_PUBLIC_IP=203.0.113.82 MOCK_SSH_HOST_ID=i-0markerbox \
  -- up --yes --json
UD="$(cat "$MOCK_LOG.userdata" 2>/dev/null)"
assert_contains "user-data writes the host-identity marker" "$UD" "/etc/repo-remote-instance-id"
assert_contains "the marker value is read from the instance metadata service" "$UD" "meta-data/instance-id"
assert_contains "the marker write uses IMDSv2 (token first)" "$UD" "latest/api/token"
assert_contains "the idle guard is still installed alongside it" "$UD" "repo-remote-idle-check"
assert_contains "authorized_keys injection is still there too" "$UD" "authorized_keys"

# (o) The marker path is overridable (so a test/host with a read-only /etc can
#     move it) and the override reaches BOTH the user-data and the probe.
run_rr MOCK_AWS_NEW_ID=i-0altmarker MOCK_AWS_PUBLIC_IP=203.0.113.83 \
  MOCK_SSH_HOST_ID=i-0altmarker REPO_REMOTE_HOST_ID_FILE=/opt/rr-id -- up --yes --json
assert_contains "user-data honors REPO_REMOTE_HOST_ID_FILE" "$(cat "$MOCK_LOG.userdata" 2>/dev/null)" "/opt/rr-id"

write_repo_env "REPO_REMOTE_INSTANCE_TYPE=m5.2xlarge"

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

# repo#451: the idle guard's background-job caveat, the reuse-path ingress
# refresh, and the bounded public-IP poll are all implemented behavior — the doc
# must state them so an agent reading remote.md gets the same model the script
# enforces.
assert_contains "remote.md warns that a nohup'd job does not hold the idle guard" \
  "$MD" "nohup"
assert_contains "remote.md explains who sees no session once the ssh command returns" \
  "$MD" "no session at all"
assert_contains "remote.md recommends a held session (tmux/screen)" "$MD" "tmux"
assert_contains "remote.md recommends sizing the idle window to the job" \
  "$MD" "Size the window to the job"
assert_contains "remote.md states the ingress chain also runs on reuse" \
  "$MD" "including one that REUSES an existing"
assert_contains "remote.md documents the public-IP poll knobs" \
  "$MD" "REPO_REMOTE_IP_POLL_ATTEMPTS"
assert_contains "remote.md documents the not-refreshed alias warning" \
  "$MD" "alias was not refreshed"

# repo#487: the SSH-ingress posture (fail closed on failed detection, validated
# override with a loud opt-in, revoke-before-authorize keyed on an owner marker)
# is implemented behavior. The doc has to describe THAT, not the old
# fall-back-to-0.0.0.0/0 model, or an agent reading remote.md will believe a
# failed IP lookup still provisions a reachable box.
assert_contains "remote.md documents the minimum-prefix knob" \
  "$MD" "REPO_REMOTE_SSH_MIN_PREFIX"
assert_contains "remote.md documents the world-open opt-in knob" \
  "$MD" "REPO_REMOTE_ALLOW_WORLD_SSH"
assert_contains "remote.md documents the validate-and-fail-closed step" \
  "$MD" "Validate the CIDR, and fail closed"
assert_contains "remote.md states a failed detection creates no rule and no instance" \
  "$MD" "creates **no** ingress rule and **no** instance"
assert_contains "remote.md says a flaky lookup is not consent to open tcp/22" \
  "$MD" "not consent to open tcp/22"
assert_contains "remote.md documents the per-rule owner Description marker" \
  "$MD" "repo-remote:<repo-name>:<YYYY-MM-DD>"
assert_contains "remote.md documents replace-don't-accumulate on refresh" \
  "$MD" "Replace, don't accumulate"
assert_contains "remote.md states unmarked rules are never revoked" \
  "$MD" "rules without that marker are never touched"

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

# repo#177: remote.md must document that --key-name is always resolved from
# REPO_REMOTE_SSH_KEY (never silently omitted) so the doc and script stay in
# sync on the KeyName:None fix.
assert_contains "remote.md documents always attaching a resolved key pair" \
  "$MD" "always attach a key pair"
assert_contains "remote.md documents the key pair is derived from REPO_REMOTE_SSH_KEY" \
  "$MD" "resolved from"

# repo#458: the host-identity check, the IP-churn-on-stop property that makes
# it necessary, and the pinning recommendation are all implemented surface —
# remote.md must document them so an agent reading the prose gets the same
# model the script enforces.
assert_contains "remote.md documents the verify subcommand" "$MD" "repo-remote verify"
assert_contains "remote.md documents the identity-mismatch exit code" "$MD" "exit \`6\`"
assert_contains "remote.md states an auto-assigned public IP is released on stop" \
  "$MD" "released"
assert_contains "remote.md warns the released IP can land on another customer's instance" \
  "$MD" "another AWS customer"
assert_contains "remote.md states the alias is only as fresh as the last up/verify" \
  "$MD" "only as fresh as"
assert_contains "remote.md recommends pinning REPO_REMOTE_INSTANCE_ID as the default" \
  "$MD" "Pin \`REPO_REMOTE_INSTANCE_ID\`"
assert_contains "remote.md documents the host-identity marker file" \
  "$MD" "/etc/repo-remote-instance-id"
assert_contains "remote.md makes verification part of opening the session" \
  "$MD" "before you trust the session"

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

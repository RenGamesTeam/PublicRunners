#!/usr/bin/env bash
# Offline test suite for the runner chain.
#
# Starts tests/mock_github.py, points every script at it through
# GITHUB_API_URL, and verifies both the API traffic and the exit codes. No
# GitHub credentials and no network access are required.
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

PASSED=0
FAILED=0

pass() {
  PASSED=$(( PASSED + 1 ))
  printf '  ok   %s\n' "$1"
}

fail() {
  FAILED=$(( FAILED + 1 ))
  printf '  FAIL %s\n' "$1"
  if [[ -n ${2:-} ]]; then
    printf '       %s\n' "$2"
  fi
}

assert_eq() {
  if [[ "$3" == "$2" ]]; then pass "$1"; else fail "$1" "expected [$2], got [$3]"; fi
}

assert_exit() {
  if [[ "$3" -eq "$2" ]]; then pass "$1"; else fail "$1" "expected exit [$2], got [$3]"; fi
}

assert_contains() {
  if [[ "$3" == *"$2"* ]]; then pass "$1"; else fail "$1" "expected to contain [$2], got [$3]"; fi
}

# --- environment -------------------------------------------------------------

PYTHON=${PYTHON:-}
if [[ -z $PYTHON ]]; then
  if command -v python3 >/dev/null 2>&1; then
    PYTHON=python3
  elif command -v python >/dev/null 2>&1; then
    PYTHON=python
  else
    echo "python3 or python is required to run the mock server" >&2
    exit 2
  fi
fi

if ! command -v jq >/dev/null 2>&1; then
  if [[ -x "$ROOT/.tools/jq.exe" ]]; then
    PATH="$ROOT/.tools:$PATH"
  else
    echo "jq is required (expected on PATH or at .tools/jq.exe)" >&2
    exit 2
  fi
fi

TMP="$ROOT/tests/tmp"
rm -rf "$TMP"
mkdir -p "$TMP"

"$PYTHON" tests/mock_github.py --port-file 'tests/tmp/port' &
MOCK_PID=$!

cleanup() {
  kill "$MOCK_PID" 2>/dev/null || true
  wait "$MOCK_PID" 2>/dev/null || true
}
trap cleanup EXIT

for _ in $(seq 1 100); do
  [[ -s "$TMP/port" ]] && break
  sleep 0.1
done
if [[ ! -s "$TMP/port" ]]; then
  echo "mock server did not start" >&2
  exit 2
fi

API="http://127.0.0.1:$(cat "$TMP/port")"

export GITHUB_API_URL="$API"
export GITHUB_REPOSITORY="acme/widgets"
export GITHUB_RUN_ID="999"
export GITHUB_TOKEN="test-token"
export RUNNER_ADMIN_TOKEN="admin-token"
export ORG_NAME="acme"
export GITHUB_REF_NAME="main"
export WORKFLOW_FILE="runner-ubuntu.yml"
export JOB_NAME="runner"
export GITHUB_OUTPUT="$TMP/output"
export API_ATTEMPTS=2
export POLL_INTERVAL_SECONDS=1
export RETRY_DELAY_SECONDS=0

STATE_INIT='{}'

reset_state() {
  local body=${1:-$STATE_INIT}
  curl -sS --fail -X POST "$API/__reset" \
    -H 'Content-Type: application/json' -d "$body" >/dev/null \
    || { echo "could not reset mock state" >&2; exit 2; }
  : > "$GITHUB_OUTPUT"
}

state() {
  curl -sS "$API/__state"
}

dispatch_count() {
  state | jq -r '.dispatches | length'
}

out_value() {
  grep "^$1=" "$GITHUB_OUTPUT" | tail -1 | cut -d= -f2-
}

run() {
  "$@" >"$TMP/stdout" 2>"$TMP/stderr"
  RC=$?
}

# --- tests -------------------------------------------------------------------

echo "lib.sh"

run bash -c 'source src/common/lib.sh; is_uint 123'
assert_exit "is_uint accepts digits" 0 "$RC"
run bash -c 'source src/common/lib.sh; is_uint 12a'
assert_exit "is_uint rejects letters" 1 "$RC"
run bash -c 'source src/common/lib.sh; die "boom"'
assert_exit "die exits with 1" 1 "$RC"

echo "gen_runner_token.sh"

reset_state '{"registration_token":"tok-from-mock"}'
run bash src/common/gen_runner_token.sh
assert_exit "returns a token" 0 "$RC"
assert_eq "prints only the token" "tok-from-mock" "$(cat "$TMP/stdout")"

reset_state '{"registration_token":null}'
run bash src/common/gen_runner_token.sh
assert_exit "fails on a forbidden response" 1 "$RC"

echo "start_workflow.sh"

reset_state
run bash src/common/start_workflow.sh runner-ubuntu.yml main duration_seconds=60 dry_run=true
assert_exit "dispatches a workflow" 0 "$RC"
assert_eq "records one dispatch" "1" "$(dispatch_count)"
assert_eq "passes the ref" "main" "$(state | jq -r '.dispatches[0].body.ref')"
assert_eq "passes inputs" "60" "$(state | jq -r '.dispatches[0].body.inputs.duration_seconds')"
assert_eq "passes booleans as strings" "true" "$(state | jq -r '.dispatches[0].body.inputs.dry_run')"

reset_state '{"workflow":null}'
run bash src/common/start_workflow.sh runner-ubuntu.yml main
assert_exit "fails when the workflow is missing" 1 "$RC"
assert_eq "does not dispatch when the workflow is missing" "0" "$(dispatch_count)"

reset_state '{"faults":[{"pattern":"/dispatches","status":500,"times":2}]}'
run bash src/common/start_workflow.sh runner-ubuntu.yml main
assert_exit "fails when dispatch keeps returning 500" 1 "$RC"
assert_eq "does not fake a dispatch" "0" "$(dispatch_count)"

reset_state
run bash src/common/start_workflow.sh runner-ubuntu.yml main 'not-a-pair'
assert_exit "rejects malformed inputs" 1 "$RC"

echo "consecutive_failures.sh"

reset_state '{"runs":[{"id":1001,"status":"completed","conclusion":"success","created_at":"2026-10-01T00:00:00Z"}]}'
run bash src/common/consecutive_failures.sh runner-ubuntu.yml
assert_eq "a success resets the streak" "0" "$(cat "$TMP/stdout")"

reset_state '{"runs":[
  {"id":1003,"status":"completed","conclusion":"failure","created_at":"2026-10-01T03:00:00Z"},
  {"id":1002,"status":"completed","conclusion":"failure","created_at":"2026-10-01T02:00:00Z"},
  {"id":1001,"status":"completed","conclusion":"success","created_at":"2026-10-01T01:00:00Z"}
]}'
run bash src/common/consecutive_failures.sh runner-ubuntu.yml
assert_eq "counts only the trailing failures" "2" "$(cat "$TMP/stdout")"

reset_state '{"runs":[
  {"id":1002,"status":"completed","conclusion":"failure","created_at":"2026-10-01T02:00:00Z"},
  {"id":1001,"status":"completed","conclusion":"failure","created_at":"2026-10-01T01:00:00Z"}
]}'
run bash src/common/consecutive_failures.sh runner-ubuntu.yml
assert_eq "counts across runs" "2" "$(cat "$TMP/stdout")"

reset_state '{"runs":[
  {"id":2000,"status":"completed","conclusion":"failure","created_at":"2026-10-01T03:00:00Z"},
  {"id":999,"status":"completed","conclusion":"failure","created_at":"2026-10-01T02:00:00Z"}
]}'
run bash src/common/consecutive_failures.sh runner-ubuntu.yml
assert_eq "ignores the current run" "1" "$(cat "$TMP/stdout")"

echo "monitor.sh"

reset_state '{"jobs":[{"name":"runner","status":"completed","conclusion":"success"}]}'
run bash src/common/monitor.sh
assert_exit "dispatches after a successful runner job" 0 "$RC"
assert_eq "reports should_dispatch=true" "true" "$(out_value should_dispatch)"
assert_eq "dispatches exactly once" "1" "$(dispatch_count)"
assert_eq "forwards the default budget" "0" "$(state | jq -r '.dispatches[0].body.inputs.chain_budget')"

reset_state '{"jobs":[{"name":"runner","status":"completed","conclusion":"success"}]}'
run env CHAIN_BUDGET=1 bash src/common/monitor.sh
assert_eq "stops when the budget is exhausted" "false" "$(out_value should_dispatch)"
assert_eq "does not dispatch when the budget is exhausted" "0" "$(dispatch_count)"

reset_state '{"jobs":[{"name":"runner","status":"completed","conclusion":"success"}]}'
run env CHAIN_BUDGET=3 bash src/common/monitor.sh
assert_eq "decrements the budget" "2" "$(state | jq -r '.dispatches[0].body.inputs.chain_budget')"

reset_state '{"jobs":[{"name":"runner","status":"completed","conclusion":"cancelled"}]}'
run bash src/common/monitor.sh
assert_eq "never undoes a cancellation" "false" "$(out_value should_dispatch)"
assert_eq "does not dispatch after a cancellation" "0" "$(dispatch_count)"

reset_state '{"jobs":[{"name":"runner","status":"completed","conclusion":"failure"}],"runs":[]}'
run bash src/common/monitor.sh
assert_eq "retries after a failed runner job" "true" "$(out_value should_dispatch)"
assert_eq "dispatches the retry" "1" "$(dispatch_count)"

failures=$(jq -n '[range(1;6) | {id: (1000 + .), status: "completed", conclusion: "failure", created_at: ("2026-10-01T0" + (. | tostring) + ":00:00Z")}]')
reset_state "$(jq -n --argjson runs "$failures" '{jobs:[{name:"runner",status:"completed",conclusion:"failure"}],runs:$runs}')"
run env RETRY_DELAY_SECONDS=0 bash src/common/monitor.sh
assert_eq "stops after too many consecutive failures" "false" "$(out_value should_dispatch)"
assert_contains "reports the failure streak" "too-many-consecutive-failures" "$(out_value reason)"
assert_eq "does not dispatch on a broken chain" "0" "$(dispatch_count)"

reset_state '{"jobs":[{"name":"runner","status":"completed","conclusion":"success"}]}'
run env CHAIN_ENABLED=false bash src/common/monitor.sh
assert_eq "honours the kill switch" "false" "$(out_value should_dispatch)"
assert_eq "does not dispatch while disabled" "0" "$(dispatch_count)"

echo "remove_runner.sh"

runners=$(jq -n '
  [range(1;101) | {id: ., name: ("other-" + (. | tostring)), status: "offline"}]
  + [{id: 101, name: "pr-ubuntu-1-1", status: "offline"},
     {id: 102, name: "pr-ubuntu-1-2", status: "online"},
     {id: 103, name: "other-remote", status: "offline"}]')
reset_state "$(jq -n --argjson runners "$runners" '{runners:$runners}')"
run bash src/common/remove_runner.sh --prefix 'pr-ubuntu-'
assert_exit "cleans up matching runners" 0 "$RC"
assert_eq "deletes only matching offline runners" "[101]" "$(state | jq -c '.deletes')"
assert_eq "keeps online matching runners" "1" "$(state | jq '[.runners[] | select(.name | startswith("pr-ubuntu-"))] | length')"

reset_state "$(jq -n --argjson runners "$runners" '{runners:$runners}')"
run bash src/common/remove_runner.sh --prefix 'pr-ubuntu-' --all
assert_exit "cleans all matching runners with --all" 0 "$RC"
assert_eq "deletes both matching runners" "[101,102]" "$(state | jq -c '.deletes')"

reset_state "$(jq -n --argjson runners "$runners" '{runners:$runners}')"
run env RUNNER_ADMIN_TOKEN= bash src/common/remove_runner.sh --prefix 'pr-ubuntu-'
assert_exit "skips cleanup without an admin token" 0 "$RC"
assert_eq "does not delete without a token" "0" "$(state | jq '.deletes | length')"

echo "setup.sh"

fake_runner="$TMP/fake-runner"
mkdir -p "$fake_runner"
touch "$fake_runner/config.sh" "$fake_runner/run.sh"
run env RUNNER_DIR="$fake_runner" bash src/ubuntu/setup.sh
assert_exit "skips an already installed runner" 0 "$RC"
assert_contains "says the runner is already present" "already present" "$(cat "$TMP/stderr")"

run env RUNNER_ARCH=X64 RUNNER_DIR="$fake_runner" bash src/ubuntu/setup.sh
assert_exit "ignores the GitHub-provided RUNNER_ARCH" 0 "$RC"
assert_contains "still skips an installed runner with RUNNER_ARCH set" "already present" "$(cat "$TMP/stderr")"

run env RUNNER_PACKAGE_ARCH=arm64 RUNNER_DIR="$fake_runner" bash src/ubuntu/setup.sh
assert_exit "pins an arm64 checksum" 0 "$RC"
assert_contains "skips an installed arm64 runner" "already present" "$(cat "$TMP/stderr")"

run env RUNNER_PACKAGE_VERSION=9.9.9 bash src/ubuntu/setup.sh
assert_exit "refuses a version without a pinned checksum" 1 "$RC"

run env RUNNER_PACKAGE_VERSION=9.9.9 RUNNER_PACKAGE_SHA256=nothex bash src/ubuntu/setup.sh
assert_exit "rejects an invalid checksum" 1 "$RC"

echo "watchdog.sh"

reset_state "$(jq -n --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{runs:[{id:1,status:"in_progress",conclusion:null,created_at:$now}]}')"
run bash src/common/watchdog.sh
assert_eq "leaves an active chain alone" "0" "$(dispatch_count)"

recent=$(date -u -d '-5 minutes' +%Y-%m-%dT%H:%M:%SZ)
reset_state "$(jq -n --arg now "$recent" '{runs:[{id:1,status:"completed",conclusion:"success",created_at:$now}]}')"
run bash src/common/watchdog.sh
assert_eq "restarts a recently dead chain" "1" "$(dispatch_count)"

old=$(date -u -d '-13 hours' +%Y-%m-%dT%H:%M:%SZ)
reset_state "$(jq -n --arg now "$old" '{runs:[{id:1,status:"completed",conclusion:"success",created_at:$now}]}')"
run bash src/common/watchdog.sh
assert_eq "does not resurrect an old chain" "0" "$(dispatch_count)"

cancelled=$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)
reset_state "$(jq -n --arg now "$cancelled" '{runs:[{id:1,status:"completed",conclusion:"cancelled",created_at:$now}]}')"
run bash src/common/watchdog.sh
assert_eq "respects a recent cancellation" "0" "$(dispatch_count)"

failed_runs=$(jq -n '[range(1;6) | {id: (1000 + .), status: "completed", conclusion: "failure", created_at: (now - 3600 | todate)}]')
reset_state "$(jq -n --argjson runs "$failed_runs" '{runs:$runs}')"
run bash src/common/watchdog.sh
assert_eq "does not restart a chain that keeps failing" "0" "$(dispatch_count)"

run env CHAIN_ENABLED=false bash src/common/watchdog.sh
assert_eq "honours the kill switch" "0" "$(dispatch_count)"

echo "networking.sh"

run bash -c 'source src/ubuntu/networking.sh; render_xray_config 100.64.0.7'
assert_exit "renders an xray config" 0 "$RC"
assert_eq "xray logs at warning level" "warning" "$(jq -r '.log.loglevel' "$TMP/stdout")"
assert_eq "xray socks inbound listens on the tailscale address" "100.64.0.7" "$(jq -r '.inbounds[0].listen' "$TMP/stdout")"
assert_eq "xray socks inbound uses port 10808" "10808" "$(jq -r '.inbounds[0].port' "$TMP/stdout")"
assert_eq "xray socks inbound speaks socks" "socks" "$(jq -r '.inbounds[0].protocol' "$TMP/stdout")"
assert_eq "xray socks inbound requires a password" "password" "$(jq -r '.inbounds[0].settings.auth' "$TMP/stdout")"
assert_eq "xray socks user defaults to pc" "pc" "$(jq -r '.inbounds[0].settings.accounts[0].user' "$TMP/stdout")"
assert_eq "xray socks password defaults to the supplied value" \
  "adac824bc7f80b7f77bfbed7b90c1967855b22dd6cca1eeb" \
  "$(jq -r '.inbounds[0].settings.accounts[0].pass' "$TMP/stdout")"
assert_eq "xray socks allows udp" "true" "$(jq -r '.inbounds[0].settings.udp' "$TMP/stdout")"
assert_eq "xray uses a direct outbound" "freedom" "$(jq -r '.outbounds[0].protocol' "$TMP/stdout")"
assert_eq "xray tags that outbound direct" "direct" "$(jq -r '.outbounds[0].tag' "$TMP/stdout")"

run env XRAY_SOCKS_USER=alice XRAY_SOCKS_PASSWORD=s3cret XRAY_SOCKS_PORT=1080 \
  bash -c 'source src/ubuntu/networking.sh; render_xray_config 100.64.0.8'
assert_exit "renders with environment overrides" 0 "$RC"
assert_eq "honours a custom socks user" "alice" "$(jq -r '.inbounds[0].settings.accounts[0].user' "$TMP/stdout")"
assert_eq "honours a custom socks port" "1080" "$(jq -r '.inbounds[0].port' "$TMP/stdout")"

mkdir -p "$TMP/bin"
cat > "$TMP/bin/tailscale" <<'SH'
#!/usr/bin/env bash
echo 100.64.0.9
SH
chmod +x "$TMP/bin/tailscale"
run env PATH="$TMP/bin:$PATH" bash -c 'source src/ubuntu/networking.sh; wait_for_tailscale_ip 2'
assert_exit "reads the tailscale ipv4 address" 0 "$RC"
assert_eq "prints the tailscale ipv4 address" "100.64.0.9" "$(cat "$TMP/stdout")"

cat > "$TMP/bin/tailscale" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$TMP/bin/tailscale"
run env PATH="$TMP/bin:$PATH" bash -c 'source src/ubuntu/networking.sh; wait_for_tailscale_ip 1'
assert_exit "gives up when tailscale has no address" 1 "$RC"

run env -u TS_OAUTH_CLIENT_ID -u TS_OAUTH_SECRET bash src/ubuntu/setup-network.sh
assert_exit "network setup refuses to run without the oauth secrets" 1 "$RC"

echo "static checks"

run bash -c 'for f in src/common/*.sh src/ubuntu/*.sh tests/*.sh; do bash -n "$f" || exit 1; done'
assert_exit "all shell scripts parse" 0 "$RC"

grep -q 'src/ubuntu/setup-network.sh' .github/workflows/runner-ubuntu.yml
assert_exit "ubuntu workflow prepares the network" 0 "$?"
grep -q 'secrets.TS_OAUTH_CLIENT_ID' .github/workflows/runner-ubuntu.yml
assert_exit "ubuntu workflow reads the tailscale oauth client id" 0 "$?"
grep -q 'secrets.TS_OAUTH_SECRET' .github/workflows/runner-ubuntu.yml
assert_exit "ubuntu workflow reads the tailscale oauth secret" 0 "$?"
awk '/setup-network\.sh/ {net=NR} /Run ephemeral runner loop/ {run=NR} END {exit !(net && run && net < run)}' \
  .github/workflows/runner-ubuntu.yml
assert_exit "network setup runs before the runner is configured" 0 "$?"
grep -q 'TS_TAGS:-tag:ci' src/ubuntu/setup-network.sh
assert_exit "network setup defaults to tag:ci" 0 "$?"
run bash -c '! grep -q "env.TS_TAGS" .github/workflows/runner-ubuntu.yml'
assert_exit "ubuntu workflow needs no tag variable" 0 "$RC"
grep -q -- '--preserve-env=TS_OAUTH_CLIENT_ID' .github/workflows/runner-ubuntu.yml
assert_exit "network setup does not hand the org token to the root shell" 0 "$?"

grep -q 'attempt -le 3' src/windows/run-loop.ps1
assert_exit "windows run loop retries the runner removal" 0 "$?"
awk '/run-loop\.ps1/ {seen=1} seen && /^ *exit 0/ {ok=1} END {exit !ok}' .github/workflows/runner-windows.yml
assert_exit "windows step exits 0 after the loop" 0 "$?"

if [[ -x .tools/actionlint/actionlint.exe ]]; then
  run .tools/actionlint/actionlint.exe -no-color -oneline .github/workflows/runner-ubuntu.yml .github/workflows/runner-windows.yml .github/workflows/runner-watchdog.yml
  assert_exit "workflows pass actionlint" 0 "$RC"
elif command -v actionlint >/dev/null 2>&1; then
  run actionlint -no-color -oneline .github/workflows/runner-ubuntu.yml .github/workflows/runner-windows.yml .github/workflows/runner-watchdog.yml
  assert_exit "workflows pass actionlint" 0 "$RC"
else
  echo "  skip actionlint (not installed)"
fi

if command -v powershell.exe >/dev/null 2>&1; then
  run powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/check-powershell.ps1
  assert_exit "PowerShell scripts parse" 0 "$RC"

  reset_state '{"registration_token":"tok-from-windows"}'
  run powershell.exe -NoProfile -ExecutionPolicy Bypass -Command \
    ". (Join-Path (Get-Location) 'src/windows/lib.ps1'); Get-RegistrationToken -Org 'acme' -Token 'admin-token'"
  assert_exit "windows lib requests a registration token" 0 "$RC"
  assert_eq "windows lib prints only the token" "tok-from-windows" \
    "$(tr -d '\r' < "$TMP/stdout" | sed '/^$/d')"

  # Regression: the pwsh shell wrapper ends with `exit $LASTEXITCODE`, so a
  # best-effort native command that failed inside the loop (for example
  # `config.cmd remove` for a busy runner) used to turn a successful runner
  # step into a failure. The step now ends with `exit 0`; real errors throw.
  mkdir -p tests/tmp
  cat > tests/tmp/step-ok.ps1 <<'PS1'
$global:LASTEXITCODE = 7
exit 0
PS1
  cat > tests/tmp/wrapper-ok.ps1 <<'PS1'
. (Join-Path $PSScriptRoot 'step-ok.ps1')
if ((Test-Path variable:\LASTEXITCODE)) { exit $LASTEXITCODE }
PS1
  run powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/tmp/wrapper-ok.ps1
  assert_exit "windows step exit 0 overrides a failed native command" 0 "$RC"

  cat > tests/tmp/step-fail.ps1 <<'PS1'
$global:LASTEXITCODE = 7
PS1
  cat > tests/tmp/wrapper-fail.ps1 <<'PS1'
. (Join-Path $PSScriptRoot 'step-fail.ps1')
if ((Test-Path variable:\LASTEXITCODE)) { exit $LASTEXITCODE }
PS1
  run powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/tmp/wrapper-fail.ps1
  assert_exit "windows step still fails on a leftover exit code without the guard" 7 "$RC"
else
  echo "  skip PowerShell syntax check"
fi

run "$PYTHON" -m py_compile tests/mock_github.py
assert_exit "mock server compiles" 0 "$RC"

# --- summary -----------------------------------------------------------------

echo
echo "passed: ${PASSED}, failed: ${FAILED}"
[[ $FAILED -eq 0 ]]

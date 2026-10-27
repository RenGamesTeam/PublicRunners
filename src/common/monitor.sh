#!/usr/bin/env bash
# Decides whether the current run should hand over to a successor run.
#
# This job runs after the runner job (needs: runner, if: always()) and inspects
# the runner job's final conclusion through the API. Running sequentially keeps
# the chain simple: at most one runner job is alive per workflow, so the
# schedule concurrency group never has to cancel anything.
#
# The successor is dispatched only when the runner job finished successfully
# (or failed and the failure budget is not exhausted). A cancellation is a
# deliberate stop and is never undone here.
#
# Outputs (also written to $GITHUB_OUTPUT):
#   should_dispatch  "true"/"false"
#   reason           short human readable explanation
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}"
: "${GITHUB_TOKEN:?GITHUB_TOKEN is required}"

JOB_NAME=${JOB_NAME:-runner}
WORKFLOW_FILE=${WORKFLOW_FILE:?WORKFLOW_FILE is required}
REF=${CHAIN_REF:-${GITHUB_REF_NAME:-main}}

DURATION_SECONDS=${DURATION_SECONDS:-18000}
POLL_INTERVAL_SECONDS=${POLL_INTERVAL_SECONDS:-120}
RETRY_DELAY_SECONDS=${RETRY_DELAY_SECONDS:-600}
CHAIN_BUDGET=${CHAIN_BUDGET:-0}
MAX_CONSECUTIVE_FAILURES=${MAX_CONSECUTIVE_FAILURES:-5}
CHAIN_ENABLED=${CHAIN_ENABLED:-true}
RUNNER_PREFIX=${RUNNER_PREFIX:-}
LABELS=${LABELS:-}
DRY_RUN=${DRY_RUN:-false}

for value in \
  "DURATION_SECONDS=$DURATION_SECONDS" \
  "POLL_INTERVAL_SECONDS=$POLL_INTERVAL_SECONDS" \
  "RETRY_DELAY_SECONDS=$RETRY_DELAY_SECONDS" \
  "CHAIN_BUDGET=$CHAIN_BUDGET" \
  "MAX_CONSECUTIVE_FAILURES=$MAX_CONSECUTIVE_FAILURES"; do
  key=${value%%=*}
  raw=${value#*=}
  is_uint "$raw" || die "${key} must be a non-negative integer"
done
(( DURATION_SECONDS >= 1 && DURATION_SECONDS <= 18000 )) \
  || die "DURATION_SECONDS must be between 1 and 18000"
[[ -n $REF ]] || die "ref must not be empty"

require_cmd curl
require_cmd jq

emit() {
  local should_dispatch=$1 reason=$2
  if [[ -n ${GITHUB_OUTPUT:-} ]]; then
    {
      printf 'should_dispatch=%s\n' "$should_dispatch"
      printf 'reason=%s\n' "$reason"
    } >> "$GITHUB_OUTPUT"
  fi
  log "Decision: should_dispatch=${should_dispatch} reason=${reason}"
}

get_job_state() {
  local payload
  payload=$(api_request GET \
    "/repos/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}/jobs?per_page=100" \
    "$GITHUB_TOKEN") || return 1
  jq -r --arg name "$JOB_NAME" '
    [.jobs[] | select(.name == $name)]
    | last
    | if . == null then "missing\t" else "\(.status)\t\(.conclusion // "")" end
  ' <<< "$payload"
}

# Wait for the runner job's row to reach "completed". The runner job is the
# previous job in this run, so this normally returns immediately.
deadline=$(( $(current_epoch) + 1800 ))
state=""
while (( $(current_epoch) < deadline )); do
  state=$(get_job_state) || state=""
  if [[ -n $state ]]; then
    job_status=${state%%$'\t'*}
    job_conclusion=${state#*$'\t'}
    if [[ $job_status == "completed" ]]; then
      break
    fi
  fi
  sleep "$POLL_INTERVAL_SECONDS"
done

if [[ -z $state ]]; then
  emit false "runner-job-not-found"
  exit 0
fi
job_status=${state%%$'\t'*}
job_conclusion=${state#*$'\t'}
if [[ $job_status != "completed" ]]; then
  emit false "runner-job-still-${job_status}"
  exit 0
fi

case $job_conclusion in
  success)
    reason="runner-job-succeeded"
    ;;
  cancelled)
    emit false "runner-job-cancelled"
    exit 0
    ;;
  skipped|neutral)
    emit false "runner-job-${job_conclusion}"
    exit 0
    ;;
  *)
    failures=$(bash "${SCRIPT_DIR}/consecutive_failures.sh" "$WORKFLOW_FILE" 20 || true)
    if ! is_uint "$failures"; then
      emit false "failure-count-unavailable"
      exit 0
    fi
    if (( failures >= MAX_CONSECUTIVE_FAILURES )); then
      emit false "too-many-consecutive-failures-${failures}"
      exit 0
    fi
    log "Runner job concluded '${job_conclusion}'; retrying in ${RETRY_DELAY_SECONDS}s"
    sleep "$RETRY_DELAY_SECONDS"
    reason="runner-job-${job_conclusion}-retry"
    ;;
esac

if [[ $CHAIN_ENABLED != "true" ]]; then
  emit false "chain-disabled"
  exit 0
fi

next_budget=$CHAIN_BUDGET
if (( CHAIN_BUDGET == 1 )); then
  emit false "chain-budget-exhausted"
  exit 0
elif (( CHAIN_BUDGET > 1 )); then
  next_budget=$(( CHAIN_BUDGET - 1 ))
fi

args=(
  "duration_seconds=${DURATION_SECONDS}"
  "poll_interval_seconds=${POLL_INTERVAL_SECONDS}"
  "retry_delay_seconds=${RETRY_DELAY_SECONDS}"
  "chain_budget=${next_budget}"
  "dry_run=${DRY_RUN}"
)
[[ -n $RUNNER_PREFIX ]] && args+=("runner_prefix=${RUNNER_PREFIX}")
[[ -n $LABELS ]] && args+=("labels=${LABELS}")

if bash "${SCRIPT_DIR}/start_workflow.sh" "$WORKFLOW_FILE" "$REF" "${args[@]}"; then
  emit true "$reason"
else
  emit false "dispatch-failed"
  exit 1
fi

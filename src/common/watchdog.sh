#!/usr/bin/env bash
# Watchdog: restarts runner chains that stopped without handing over.
#
# Runs from a schedule (see .github/workflows/runner-watchdog.yml). A chain is
# restarted only when all of the following hold:
#   * it has no queued or in-progress run,
#   * its latest run is not a recent cancellation (a cancellation is the
#     documented way to stop the chain for a while),
#   * fewer than WATCHDOG_MAX_CONSECUTIVE_FAILURES runs failed in a row (a
#     broken chain must not turn into a failure loop),
#   * its latest run started less than WATCHDOG_MAX_IDLE_HOURS ago, so the
#     watchdog never resurrects a chain that was stopped days ago.
#
# Configuration (repository variables):
#   RUNNER_CHAIN_ENABLED            "false" disables every chain and watchdog.
#   WATCHDOG_WORKFLOWS              Comma separated workflow files. Default: runner-ubuntu.yml
#   WATCHDOG_MAX_IDLE_HOURS         Default: 12
#   WATCHDOG_MAX_CONSECUTIVE_FAILURES Default: 5
#   WATCHDOG_CANCEL_COOLDOWN_HOURS  Default: 24
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_TOKEN:?GITHUB_TOKEN is required}"

REF=${REF:-main}
CHAIN_ENABLED=${CHAIN_ENABLED:-true}
WATCHDOG_WORKFLOWS=${WATCHDOG_WORKFLOWS:-runner-ubuntu.yml}
WATCHDOG_MAX_IDLE_HOURS=${WATCHDOG_MAX_IDLE_HOURS:-12}
WATCHDOG_MAX_CONSECUTIVE_FAILURES=${WATCHDOG_MAX_CONSECUTIVE_FAILURES:-5}
WATCHDOG_CANCEL_COOLDOWN_HOURS=${WATCHDOG_CANCEL_COOLDOWN_HOURS:-24}

for value in \
  "WATCHDOG_MAX_IDLE_HOURS=$WATCHDOG_MAX_IDLE_HOURS" \
  "WATCHDOG_MAX_CONSECUTIVE_FAILURES=$WATCHDOG_MAX_CONSECUTIVE_FAILURES" \
  "WATCHDOG_CANCEL_COOLDOWN_HOURS=$WATCHDOG_CANCEL_COOLDOWN_HOURS"; do
  key=${value%%=*}
  raw=${value#*=}
  is_uint "$raw" || die "${key} must be a non-negative integer"
done

if [[ $CHAIN_ENABLED != "true" ]]; then
  log "RUNNER_CHAIN_ENABLED=${CHAIN_ENABLED}; watchdog does nothing"
  exit 0
fi

require_cmd curl
require_cmd jq

IFS=',' read -r -a workflows <<< "$WATCHDOG_WORKFLOWS"
dispatched=0

for raw in "${workflows[@]}"; do
  workflow=$(printf '%s' "$raw" | tr -d '[:space:]')
  [[ -n $workflow ]] || continue

  runs_payload=$(api_request GET \
    "/repos/${GITHUB_REPOSITORY}/actions/workflows/${workflow}/runs?per_page=10" \
    "$GITHUB_TOKEN") || {
    log "WARN: could not list runs for '${workflow}'; skipping"
    continue
  }

  active=$(jq -r '
    [.workflow_runs[] | select(.status == "in_progress" or .status == "queued")] | length
  ' <<< "$runs_payload")

  if (( active > 0 )); then
    log "${workflow}: ${active} queued/in-progress run(s); nothing to do"
    continue
  fi

  latest_conclusion=$(jq -r '.workflow_runs[0].conclusion // empty' <<< "$runs_payload")
  last_created=$(jq -r '.workflow_runs[0].created_at // empty' <<< "$runs_payload")
  if [[ -z $last_created ]]; then
    log "${workflow}: no run history; start the chain manually once"
    continue
  fi

  last_epoch=$(date -d "$last_created" +%s 2>/dev/null || true)
  if [[ -z $last_epoch ]]; then
    log "WARN: could not parse run timestamp '${last_created}' for '${workflow}'"
    continue
  fi

  age=$(( $(current_epoch) - last_epoch ))

  if [[ $latest_conclusion == "cancelled" ]] \
    && (( age < WATCHDOG_CANCEL_COOLDOWN_HOURS * 3600 )); then
    log "${workflow}: cancelled ${age}s ago; respecting the cancellation"
    continue
  fi

  failures=$(bash "${SCRIPT_DIR}/consecutive_failures.sh" "$workflow" 20 || true)
  if [[ -n $failures ]] && (( failures >= WATCHDOG_MAX_CONSECUTIVE_FAILURES )); then
    log "ERROR: ${workflow}: ${failures} consecutive failed run(s) (>= ${WATCHDOG_MAX_CONSECUTIVE_FAILURES}); not restarting"
    continue
  fi

  if (( age > WATCHDOG_MAX_IDLE_HOURS * 3600 )); then
    log "${workflow}: last run started ${age}s ago (> ${WATCHDOG_MAX_IDLE_HOURS}h); not restarting"
    continue
  fi

  log "${workflow}: chain looks dead (no active run, last start ${age}s ago); dispatching"
  if ( cd "$SCRIPT_DIR" && bash ./start_workflow.sh "$workflow" "$REF" ); then
    dispatched=$(( dispatched + 1 ))
  else
    log "ERROR: failed to dispatch '${workflow}'"
  fi
done

log "Watchdog finished; dispatched ${dispatched} workflow(s)"

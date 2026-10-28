#!/usr/bin/env bash
# Runs a loop of ephemeral GitHub Actions runners until the time budget ends.
#
# Each iteration:
#   1. requests a fresh registration token,
#   2. configures the runner with --ephemeral and a unique name,
#   3. runs exactly one job (`run.sh` exits afterwards and deregisters),
#   4. removes the workspace so no data leaks into the next job.
#
# An ephemeral runner accepts a single job and then removes itself, which means
# a compromised job cannot persist on the machine and the organisation does not
# accumulate stale online runners.
#
# Environment:
#   ORG_NAME            Organisation that owns the runner (required)
#   RUNNER_ADMIN_TOKEN  Token allowed to create registration tokens (required)
#   DURATION_SECONDS    Wall clock budget (default: 18000)
#   RUNNER_PREFIX       Runner name prefix (default: pr-ubuntu)
#   LABELS              Runner labels (default: self-hosted,Linux,X64)
#   RUNNER_DIR          Runner install directory (default: <script dir>/actions-runner)
#   GITHUB_SERVER_URL   GitHub server URL (default: https://github.com)
#   RUNNER_LOG_TO_STDOUT
#                       "true" keeps the inner runner's console output in this
#                       (public) step log. The default "false" writes it to
#                       <runner dir>/_diag/console-<name>.log instead, so job
#                       names from other repositories never show up in a public
#                       run log.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../common/lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"

: "${ORG_NAME:?ORG_NAME is required}"
: "${RUNNER_ADMIN_TOKEN:?RUNNER_ADMIN_TOKEN is required}"

DURATION_SECONDS=${DURATION_SECONDS:-18000}
RUNNER_PREFIX=${RUNNER_PREFIX:-pr-ubuntu}
LABELS=${LABELS:-self-hosted,Linux,X64}
RUNNER_DIR=${RUNNER_DIR:-${SCRIPT_DIR}/actions-runner}
SERVER_URL=${GITHUB_SERVER_URL:-https://github.com}
RUN_ID=${GITHUB_RUN_ID:-local}
RUNNER_LOG_TO_STDOUT=${RUNNER_LOG_TO_STDOUT:-false}

is_uint "$DURATION_SECONDS" || die "DURATION_SECONDS must be a non-negative integer"
(( DURATION_SECONDS >= 1 && DURATION_SECONDS <= 18000 )) \
  || die "DURATION_SECONDS must be between 1 and 18000"
[[ -n $RUNNER_PREFIX ]] || die "RUNNER_PREFIX must not be empty"

[[ -f "${RUNNER_DIR}/config.sh" && -f "${RUNNER_DIR}/run.sh" ]] \
  || die "runner not installed at ${RUNNER_DIR}; run setup.sh first"

require_cmd curl
require_cmd jq
require_cmd timeout

deadline=$(( $(current_epoch) + DURATION_SECONDS ))
iteration=0
failure_streak=0

log "Starting ephemeral runner loop for ${DURATION_SECONDS}s (prefix=${RUNNER_PREFIX}, labels=${LABELS})"

while :; do
  remaining=$(( deadline - $(current_epoch) ))
  if (( remaining <= 10 )); then
    break
  fi

  iteration=$(( iteration + 1 ))
  runner_name="${RUNNER_PREFIX}-${RUN_ID}-${iteration}"

  if ! registration_token=$(bash "${SCRIPT_DIR}/../common/gen_runner_token.sh"); then
    failure_streak=$(( failure_streak + 1 ))
    log "WARN: could not obtain a registration token (attempt ${failure_streak}/5)"
    (( failure_streak < 5 )) || die "giving up: no registration token available; check RUNNER_ADMIN_TOKEN and its admin:org scope"
    sleep 30
    continue
  fi

  # A previous iteration that was killed by the timeout may have left local
  # configuration behind. It is safe to drop it here because iterations are
  # sequential and the matching runner is deregistered below.
  rm -f "${RUNNER_DIR}/.runner" "${RUNNER_DIR}/.credentials" "${RUNNER_DIR}/.credentials_rsaparams"

  log "Configuring ephemeral runner '${runner_name}'"
  if ! (
    cd "$RUNNER_DIR"
    ./config.sh \
      --unattended \
      --url "${SERVER_URL}/${ORG_NAME}" \
      --token "$registration_token" \
      --name "$runner_name" \
      --labels "$LABELS" \
      --ephemeral \
      --work "_work"
  ); then
    failure_streak=$(( failure_streak + 1 ))
    log "WARN: runner configuration failed for '${runner_name}' (attempt ${failure_streak}/5)"
    (( failure_streak < 5 )) || die "giving up: runner could not be configured"
    sleep 30
    continue
  fi
  failure_streak=0

  log "Runner '${runner_name}' is waiting for a job (up to ${remaining}s)"
  console_log="${RUNNER_DIR}/_diag/console-${runner_name}.log"
  mkdir -p "${RUNNER_DIR}/_diag"
  set +e
  if [[ $RUNNER_LOG_TO_STDOUT == "true" ]]; then
    (
      cd "$RUNNER_DIR"
      timeout --signal=TERM --kill-after=30 "$remaining" ./run.sh
    )
  else
    # The runner prints the name and result of every job it processes. This run
    # is public, so keep that output on the ephemeral machine instead of the
    # step log (the file disappears with the machine).
    (
      cd "$RUNNER_DIR"
      timeout --signal=TERM --kill-after=30 "$remaining" ./run.sh
    ) >>"$console_log" 2>&1
  fi
  rc=$?
  set -e

  if (( rc != 0 )); then
    if [[ $RUNNER_LOG_TO_STDOUT == "true" ]]; then
      log "Runner '${runner_name}' stopped with exit code ${rc}"
    else
      log "Runner '${runner_name}' stopped with exit code ${rc} (console log: ${console_log})"
    fi
    (
      cd "$RUNNER_DIR"
      ./config.sh remove --token "$registration_token"
    ) || log "WARN: could not remove runner '${runner_name}' (it will be cleaned up by prefix)"
  fi

  # Remove the workspace between two jobs so file system state never carries
  # over from one repository/job to the next.
  rm -rf "${RUNNER_DIR}/_work"
done

log "Runner loop finished after ${iteration} iteration(s)"

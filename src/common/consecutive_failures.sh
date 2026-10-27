#!/usr/bin/env bash
# Counts how many of the most recent runs of a workflow failed in a row.
#
# Usage:
#   consecutive_failures.sh <workflow-file> [max-runs]
#
# Prints a single integer. The current run (GITHUB_RUN_ID) is excluded so the
# value can be used from inside the very run that is deciding whether to hand
# over. The count stops at the first run that did not fail, so an old outage
# never blocks a healthy chain.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

WORKFLOW_FILE=${1:-}
[[ -n $WORKFLOW_FILE ]] || die "usage: $0 <workflow-file> [max-runs]"

MAX_RUNS=${2:-20}
is_uint "$MAX_RUNS" || die "max-runs must be a non-negative integer"
(( MAX_RUNS >= 1 )) || die "max-runs must be at least 1"

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_TOKEN:?GITHUB_TOKEN is required}"

require_cmd curl
require_cmd jq

payload=$(api_request GET \
  "/repos/${GITHUB_REPOSITORY}/actions/workflows/${WORKFLOW_FILE}/runs?per_page=${MAX_RUNS}" \
  "$GITHUB_TOKEN") || die "could not list runs for '${WORKFLOW_FILE}'"

jq -r --argjson current "${GITHUB_RUN_ID:-0}" '
  [.workflow_runs[] | select(.id != $current)]
  | sort_by(.created_at) | reverse
  | reduce .[] as $run ({count: 0, done: false};
      if .done then
        .
      elif (($run.status == "completed") and
            (($run.conclusion == "failure") or ($run.conclusion == "timed_out") or
             ($run.conclusion == "startup_failure"))) then
        .count += 1
      else
        .done = true
      end)
  | .count
' <<< "$payload"

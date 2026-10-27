#!/usr/bin/env bash
# Dispatches the next run of a workflow.
#
# Usage:
#   start_workflow.sh <workflow-file> [ref] [key=value ...]
#
# Example:
#   start_workflow.sh runner-ubuntu.yml main duration_seconds=18000 chain_budget=4
#
# The workflow id is resolved from the workflow file name and validated before
# dispatching. HTTP failures are retried by lib.sh and surface as a non-zero
# exit code, so a failed handover can never look successful again.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

WORKFLOW_FILE=${1:-}
[[ -n $WORKFLOW_FILE ]] || die "usage: $0 <workflow-file> [ref] [key=value ...]"
shift

REF=main
if (( $# > 0 )) && [[ $1 != *=* ]]; then
  REF=$1
  shift
fi

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_TOKEN:?GITHUB_TOKEN is required}"
[[ -n $REF ]] || die "ref must not be empty"

require_cmd curl
require_cmd jq

inputs='{}'
for pair in "$@"; do
  [[ $pair == *=* ]] || die "invalid input '${pair}', expected key=value"
  key=${pair%%=*}
  value=${pair#*=}
  [[ $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "invalid input key '${key}'"
  inputs=$(jq -cn --argjson acc "$inputs" --arg key "$key" --arg value "$value" \
    '$acc + {($key): $value}')
done

workflow_payload=$(api_request GET \
  "/repos/${GITHUB_REPOSITORY}/actions/workflows/${WORKFLOW_FILE}" \
  "$GITHUB_TOKEN") || die "could not resolve workflow '${WORKFLOW_FILE}'"

workflow_id=$(jq -er '.id // empty' <<< "$workflow_payload") \
  || die "workflow '${WORKFLOW_FILE}' returned no id: ${workflow_payload}"
[[ $workflow_id =~ ^[0-9]+$ ]] || die "invalid workflow id '${workflow_id}'"

body=$(jq -cn --arg ref "$REF" --argjson inputs "$inputs" \
  '{ref: $ref, inputs: $inputs}')

api_request POST \
  "/repos/${GITHUB_REPOSITORY}/actions/workflows/${workflow_id}/dispatches" \
  "$GITHUB_TOKEN" "$body" >/dev/null \
  || die "failed to dispatch '${WORKFLOW_FILE}' on ref '${REF}'"

log "Dispatched '${WORKFLOW_FILE}' (id=${workflow_id}) on ref '${REF}' with ${inputs}"

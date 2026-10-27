#!/usr/bin/env bash
# Deletes stale organisation runners whose name starts with a known prefix.
#
# Only runners created by this repository (prefix like "pr-ubuntu-") are
# touched; unrelated or concurrently running runners are never deleted. By
# default only offline runners are removed, so a runner that is still executing
# a job is left alone and will deregister itself (it is ephemeral).
#
# Usage:
#   remove_runner.sh --prefix <name-prefix> [--offline-only] [--all]
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

PREFIX=""
OFFLINE_ONLY=true

usage() {
  cat <<'EOF'
Usage: remove_runner.sh --prefix <name-prefix> [--offline-only] [--all]

  --prefix <value>  Only delete runners whose name starts with this value.
  --offline-only    Delete only runners whose status is "offline" (default).
  --all             Delete matching runners regardless of status.
EOF
}

while (( $# > 0 )); do
  case $1 in
    --prefix)
      PREFIX=${2:-}
      shift 2
      ;;
    --prefix=*)
      PREFIX=${1#*=}
      shift
      ;;
    --offline-only)
      OFFLINE_ONLY=true
      shift
      ;;
    --all)
      OFFLINE_ONLY=false
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n $PREFIX ]] || die "--prefix is required"
: "${ORG_NAME:?ORG_NAME is required}"

if [[ -z ${RUNNER_ADMIN_TOKEN:-} ]]; then
  log "WARN: RUNNER_ADMIN_TOKEN is empty; skipping runner cleanup"
  exit 0
fi

require_cmd curl
require_cmd jq

page=1
total=0
matching=''

while :; do
  payload=$(api_request GET \
    "/orgs/${ORG_NAME}/actions/runners?per_page=100&page=${page}" \
    "$RUNNER_ADMIN_TOKEN") || die "failed to list runners for '${ORG_NAME}'"

  total=$(jq -r '.total_count // 0' <<< "$payload")
  page_rows=$(jq -r --arg prefix "$PREFIX" --argjson offline_only "$OFFLINE_ONLY" '
    .runners[]
    | select(.name | startswith($prefix))
    | select(($offline_only | not) or .status == "offline")
    | [.id, .name, .status] | @tsv
  ' <<< "$payload")

  if [[ -n $page_rows ]]; then
    matching+="${page_rows}"$'\n'
  fi

  (( page * 100 < total )) || break
  page=$(( page + 1 ))
done

deleted=0
failed=0

while IFS=$'\t' read -r id name status; do
  [[ -n ${id:-} ]] || continue
  log "Deleting runner '${name}' (id=${id}, status=${status})"
  if api_request DELETE "/orgs/${ORG_NAME}/actions/runners/${id}" "$RUNNER_ADMIN_TOKEN" >/dev/null; then
    deleted=$(( deleted + 1 ))
  else
    failed=$(( failed + 1 ))
  fi
done <<< "$matching"

log "Runner cleanup finished: deleted=${deleted} failed=${failed} prefix='${PREFIX}'"
(( failed == 0 )) || exit 1

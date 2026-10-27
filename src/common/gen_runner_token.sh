#!/usr/bin/env bash
# Requests a fresh organisation runner registration token.
#
# Prints only the token on stdout; diagnostics go to stderr. The admin token is
# read from the environment (never from argv) so it does not show up in process
# listings.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

: "${ORG_NAME:?ORG_NAME is required}"
: "${RUNNER_ADMIN_TOKEN:?RUNNER_ADMIN_TOKEN is required}"

require_cmd curl
require_cmd jq

payload=$(api_request POST \
  "/orgs/${ORG_NAME}/actions/runners/registration-token" \
  "$RUNNER_ADMIN_TOKEN") || die "failed to create a registration token for '${ORG_NAME}'"

token=$(jq -er '.token // empty' <<< "$payload") \
  || die "registration token missing from API response: ${payload}"

[[ -n $token ]] || die "registration token is empty"
printf '%s\n' "$token"

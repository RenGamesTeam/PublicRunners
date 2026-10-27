#!/usr/bin/env bash
# Shared helpers for the PublicRunners maintenance scripts.
#
# This file is meant to be sourced, not executed:
#
#   source "$(dirname "$0")/lib.sh"
#
# Environment:
#   GITHUB_API_URL      API base URL (default: https://api.github.com).
#                       Override it to test against a mock server or GHES.
#   GITHUB_API_VERSION  REST API version header (default: 2022-11-28).
#   API_ATTEMPTS        Number of attempts for retryable errors (default: 4).

set -euo pipefail

: "${GITHUB_API_URL:=https://api.github.com}"
: "${GITHUB_API_VERSION:=2022-11-28}"

# All diagnostics go to stderr so command substitution only ever captures the
# actual response payload.
log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

die() {
  log "ERROR: $*"
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

is_uint() {
  [[ ${1:-} =~ ^[0-9]+$ ]]
}

# api_request METHOD PATH TOKEN [JSON_BODY]
#
# Calls the GitHub REST API and prints the response body on success. Returns:
#   0  HTTP 2xx
#   1  non-retryable client error (4xx), or malformed response
#   2  retries exhausted (network error / 5xx / 429)
#
# 5xx, 429 and transport errors are retried with linear backoff. Any error
# response body is logged so failures are never silent.
api_request() {
  local method=$1 path=$2 token=$3 body=${4:-}
  local url="${GITHUB_API_URL}${path}"
  local attempt=1 max=${API_ATTEMPTS:-4}
  local out code
  local -a args

  args=(
    --silent --show-error --location --max-time 60
    --request "$method"
    --header "Accept: application/vnd.github+json"
    --header "Authorization: Bearer ${token}"
    --header "X-GitHub-Api-Version: ${GITHUB_API_VERSION}"
    --write-out '\n%{http_code}'
  )
  if [[ -n $body ]]; then
    args+=(--header "Content-Type: application/json" --data-binary "$body")
  fi

  while (( attempt <= max )); do
    if out=$(curl "${args[@]}" "$url" 2>&1); then
      code=${out##*$'\n'}
      if [[ $code =~ ^2[0-9][0-9]$ ]]; then
        printf '%s' "${out%$'\n'*}"
        return 0
      fi
      log "WARN: ${method} ${path} -> HTTP ${code} (attempt ${attempt}/${max})"
      if [[ $code =~ ^4[0-9][0-9]$ ]]; then
        log "ERROR: ${method} ${path} response: ${out%$'\n'*}"
        return 1
      fi
    else
      log "WARN: ${method} ${path} -> curl error (attempt ${attempt}/${max}): ${out}"
    fi

    if (( attempt < max )); then
      sleep "$(( attempt * 2 ))"
    fi
    attempt=$(( attempt + 1 ))
  done

  log "ERROR: ${method} ${path} failed after ${max} attempts"
  return 2
}

# api_json METHOD PATH TOKEN [JSON_BODY]
# Same as api_request but fails when the response is not valid JSON.
api_json() {
  local payload
  payload=$(api_request "$@") || return $?
  jq -e . >/dev/null 2>&1 <<< "$payload" || die "response from $2 is not valid JSON: ${payload}"
  printf '%s' "$payload"
}

# current_epoch prints the current Unix timestamp.
current_epoch() {
  date +%s
}

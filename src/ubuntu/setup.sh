#!/usr/bin/env bash
# Downloads and verifies the GitHub Actions runner for Linux.
#
# The version is pinned and the archive checksum is verified before extraction.
# Already extracted runners are left untouched, so the script is idempotent.
#
# Environment:
#   RUNNER_VERSION  Runner version (default: 2.338.2)
#   RUNNER_ARCH     x64 or arm64 (default: x64)
#   RUNNER_SHA256   Override the expected checksum (required for unknown
#                   version/arch combinations)
#   RUNNER_DIR      Install directory (default: <script dir>/actions-runner)
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../common/lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"

RUNNER_VERSION=${RUNNER_VERSION:-2.338.2}
RUNNER_ARCH=${RUNNER_ARCH:-x64}
RUNNER_DIR=${RUNNER_DIR:-${SCRIPT_DIR}/actions-runner}

# Checksums published with the GitHub Actions runner releases.
declare -A RUNNER_SHA256_MAP=(
  ["2.338.2:x64"]="baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40"
  ["2.338.2:arm64"]=""
)

expected_sha=${RUNNER_SHA256:-${RUNNER_SHA256_MAP["${RUNNER_VERSION}:${RUNNER_ARCH}"]:-}}

[[ -n $expected_sha ]] || die "no pinned checksum for runner ${RUNNER_VERSION}/${RUNNER_ARCH}; set RUNNER_SHA256"
[[ $expected_sha =~ ^[0-9a-fA-F]{64}$ ]] || die "RUNNER_SHA256 must be a 64 character hex digest"

if [[ -f "${RUNNER_DIR}/config.sh" && -f "${RUNNER_DIR}/run.sh" ]]; then
  log "Runner already present at ${RUNNER_DIR}; skipping download"
  exit 0
fi

require_cmd curl
require_cmd tar
require_cmd sha256sum

archive="actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"
url="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${archive}"

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

log "Downloading ${url}"
curl --fail --location --retry 3 --retry-delay 2 --silent --show-error \
  --output "${work_dir}/${archive}" "$url" \
  || die "failed to download ${url}"

log "Verifying SHA256 checksum"
printf '%s  %s\n' "$expected_sha" "${work_dir}/${archive}" | sha256sum --check --status \
  || die "checksum verification failed for ${archive}"

mkdir -p "$RUNNER_DIR"
log "Extracting runner ${RUNNER_VERSION} into ${RUNNER_DIR}"
tar --extract --gzip --file "${work_dir}/${archive}" --directory "$RUNNER_DIR"

[[ -f "${RUNNER_DIR}/run.sh" ]] || die "runner archive did not contain run.sh"
log "Runner ${RUNNER_VERSION} is ready"

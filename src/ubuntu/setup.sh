#!/usr/bin/env bash
# Downloads and verifies the GitHub Actions runner for Linux.
#
# The version is pinned and the archive checksum is verified before extraction.
# Already extracted runners are left untouched, so the script is idempotent.
#
# Note: the variable names are deliberately NOT RUNNER_VERSION / RUNNER_ARCH.
# GitHub Actions already exports RUNNER_ARCH (for example "X64") into every
# step, so reusing that name silently changed the download URL to
# actions-runner-linux-X64-*.tar.gz and broke the checksum lookup.
#
# Environment:
#   RUNNER_PACKAGE_VERSION  Runner version (default: 2.338.2)
#   RUNNER_PACKAGE_ARCH     x64 or arm64 (default: x64, case-insensitive)
#   RUNNER_PACKAGE_SHA256   Override the expected checksum (required for
#                           version/arch combinations that are not pinned)
#   RUNNER_DIR              Install directory (default: <script dir>/actions-runner)
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../common/lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"

RUNNER_PACKAGE_VERSION=${RUNNER_PACKAGE_VERSION:-2.338.2}
RUNNER_PACKAGE_ARCH=${RUNNER_PACKAGE_ARCH:-x64}
RUNNER_DIR=${RUNNER_DIR:-${SCRIPT_DIR}/actions-runner}

RUNNER_PACKAGE_VERSION=${RUNNER_PACKAGE_VERSION#v}
RUNNER_PACKAGE_ARCH=${RUNNER_PACKAGE_ARCH,,}

case "$RUNNER_PACKAGE_ARCH" in
  x64 | arm64) ;;
  *) die "RUNNER_PACKAGE_ARCH must be x64 or arm64 (got '${RUNNER_PACKAGE_ARCH}')" ;;
esac

# Checksums published with the GitHub Actions runner releases.
declare -A RUNNER_SHA256_MAP=(
  ["2.338.2:x64"]="baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40"
  ["2.338.2:arm64"]="670adb2f268fe21dcbb58b3db0e0aa9d5b3bddfe2c651481336e561ff86de945"
)

expected_sha=${RUNNER_PACKAGE_SHA256:-${RUNNER_SHA256_MAP["${RUNNER_PACKAGE_VERSION}:${RUNNER_PACKAGE_ARCH}"]:-}}

[[ -n $expected_sha ]] || die "no pinned checksum for runner ${RUNNER_PACKAGE_VERSION}/${RUNNER_PACKAGE_ARCH}; set RUNNER_PACKAGE_SHA256"
[[ $expected_sha =~ ^[0-9a-fA-F]{64}$ ]] || die "RUNNER_PACKAGE_SHA256 must be a 64 character hex digest"

if [[ -f "${RUNNER_DIR}/config.sh" && -f "${RUNNER_DIR}/run.sh" ]]; then
  log "Runner already present at ${RUNNER_DIR}; skipping download"
  exit 0
fi

require_cmd curl
require_cmd tar
require_cmd sha256sum

archive="actions-runner-linux-${RUNNER_PACKAGE_ARCH}-${RUNNER_PACKAGE_VERSION}.tar.gz"
url="https://github.com/actions/runner/releases/download/v${RUNNER_PACKAGE_VERSION}/${archive}"

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
log "Extracting runner ${RUNNER_PACKAGE_VERSION} into ${RUNNER_DIR}"
tar --extract --gzip --file "${work_dir}/${archive}" --directory "$RUNNER_DIR"

[[ -f "${RUNNER_DIR}/run.sh" ]] || die "runner archive did not contain run.sh"
log "Runner ${RUNNER_PACKAGE_VERSION} is ready"

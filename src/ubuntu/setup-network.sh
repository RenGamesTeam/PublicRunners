#!/usr/bin/env bash
# Prepares the network path of the Ubuntu runner before the Actions runner is
# configured:
#
#   1. installs Tailscale and joins the tailnet with an OAuth client
#      (TS_OAUTH_CLIENT_ID / TS_OAUTH_SECRET, passed as environment variables),
#   2. installs Xray and runs a SOCKS5 inbound on the tailnet address, so the
#      tailnet can reach the runner at <tailscale-ip>:XRAY_SOCKS_PORT.
#
# Must run as root (sudo -E bash src/ubuntu/setup-network.sh).
#
# Environment:
#   TS_OAUTH_CLIENT_ID   OAuth client ID from the tailnet admin console (required)
#   TS_OAUTH_SECRET      OAuth client secret (required)
#   TS_TAGS              Optional comma separated tags, for example "tag:ci".
#                        OAuth clients are scoped to tags; pass them here when the
#                        client does not already imply one.
#   TS_HOSTNAME          Device name in the tailnet (default: pr-ubuntu-<run id>)
#   XRAY_SOCKS_USER      SOCKS5 username (default: pc)
#   XRAY_SOCKS_PASSWORD  SOCKS5 password (default: built-in value)
#   XRAY_SOCKS_PORT      SOCKS5 port (default: 10808)
#   XRAY_CONFIG          Configuration path (default: /usr/local/etc/xray/config.json)
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../common/lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"
# shellcheck source=networking.sh
source "${SCRIPT_DIR}/networking.sh"

: "${TS_OAUTH_CLIENT_ID:?TS_OAUTH_CLIENT_ID is required}"
: "${TS_OAUTH_SECRET:?TS_OAUTH_SECRET is required}"

TS_TAGS=${TS_TAGS:-}
TS_HOSTNAME=${TS_HOSTNAME:-"pr-ubuntu-${GITHUB_RUN_ID:-local}"}
XRAY_CONFIG=${XRAY_CONFIG:-/usr/local/etc/xray/config.json}
XRAY_SOCKS_PORT=${XRAY_SOCKS_PORT:-10808}

# Tailscale refuses to sign in an OAuth client without at least one tag:
# "oauth authkeys require --advertise-tags".
if [[ -z $TS_TAGS ]]; then
  die "TS_TAGS must name at least one tag owned by the OAuth client (for example tag:ci); OAuth auth keys cannot be untagged"
fi

(( EUID == 0 )) || die "run this script as root: sudo -E bash $0"
require_cmd curl
require_cmd jq
require_cmd systemctl

log "Installing Tailscale"
# The official script configures the apt repository and installs the daemon.
curl -fsSL https://tailscale.com/install.sh | sh

# An OAuth client secret can be used directly as an auth key. The query string
# makes the node preauthorized and ephemeral, so it disappears from the tailnet
# when this runner is destroyed.
log "Joining the tailnet as ${TS_HOSTNAME}"
up_args=(
  "--authkey=${TS_OAUTH_SECRET}?preauthorized=true&ephemeral=true"
  "--hostname=${TS_HOSTNAME}"
  "--accept-routes"
  "--accept-dns=false"
)
if [[ -n $TS_TAGS ]]; then
  up_args+=("--advertise-tags=${TS_TAGS}")
fi

for attempt in 1 2 3 4 5; do
  if timeout 120 tailscale up "${up_args[@]}"; then
    break
  fi
  (( attempt < 5 )) || die "tailscale up failed after 5 attempts"
  log "WARN: tailscale up failed (attempt ${attempt}/5); retrying in $(( attempt * 2 ))s"
  sleep $(( attempt * 2 ))
done

# Kernel networking is required: Xray binds the tailnet address, which only
# exists when tailscaled created the tailscale0 interface. Hosted runners do
# provide /dev/net/tun; fail with a clear message if that ever changes.
if ! ip -4 addr show tailscale0 >/dev/null 2>&1; then
  die "tailscale0 interface is missing; this runner cannot use kernel Tailscale"
fi

ts_ip=$(wait_for_tailscale_ip 90) || die "Tailscale did not report an IPv4 address within 90s"
log "Tailscale IPv4 address: ${ts_ip}"

log "Installing Xray"
bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

log "Writing Xray configuration to ${XRAY_CONFIG}"
install -d -m 755 "$(dirname -- "${XRAY_CONFIG}")"
render_xray_config "$ts_ip" > "${XRAY_CONFIG}.tmp"
mv "${XRAY_CONFIG}.tmp" "${XRAY_CONFIG}"
chmod 644 "${XRAY_CONFIG}"

systemctl enable xray >/dev/null 2>&1 || true
systemctl restart xray
sleep 2
systemctl is-active --quiet xray \
  || die "xray failed to start; inspect: journalctl -u xray --no-pager -n 50"

log "Xray SOCKS5 proxy is listening on ${ts_ip}:${XRAY_SOCKS_PORT}"

#!/usr/bin/env bash
# Networking helpers for the Ubuntu runner. Sourced by setup-network.sh and by
# the offline test suite; nothing here touches the network by itself.

# Waits for Tailscale to report an IPv4 address and prints the first one.
#
# Usage: wait_for_tailscale_ip [timeout_seconds]
wait_for_tailscale_ip() {
  local timeout=${1:-60}
  local deadline ip

  deadline=$(( $(date +%s) + timeout ))
  while (( $(date +%s) < deadline )); do
    ip=$(tailscale ip -4 2>/dev/null | head -n 1 || true)
    if [[ -n $ip ]]; then
      printf '%s\n' "$ip"
      return 0
    fi
    sleep 1
  done
  return 1
}

# Prints the Xray configuration with the SOCKS5 inbound bound to the given
# Tailscale address. The password is read from the environment and never
# logged.
#
# Usage: render_xray_config <listen_ip>
render_xray_config() {
  local listen_ip=${1:?listen_ip is required}

  jq -n \
    --arg listen "$listen_ip" \
    --arg user "${XRAY_SOCKS_USER:-pc}" \
    --arg pass "${XRAY_SOCKS_PASSWORD:-adac824bc7f80b7f77bfbed7b90c1967855b22dd6cca1eeb}" \
    --argjson port "${XRAY_SOCKS_PORT:-10808}" \
    '{
      log: {loglevel: "warning"},
      inbounds: [{
        tag: "tailscale-socks",
        listen: $listen,
        port: $port,
        protocol: "socks",
        settings: {
          auth: "password",
          accounts: [{user: $user, pass: $pass}],
          udp: true
        }
      }],
      outbounds: [{tag: "direct", protocol: "freedom"}]
    }'
}

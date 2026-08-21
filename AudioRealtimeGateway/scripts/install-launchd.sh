#!/bin/bash
# ESS-458 — install the Gateway as a persistent launchd LaunchAgent.
#
# Idempotent: safe to re-run; existing service is bootout'd first.
# Assumes the Gateway source has been rsync'd to $DEST (below) with
# node_modules installed and certs/ populated.

set -euo pipefail

DEST="/Users/jacksonmac/Services/Personal-Avatar-iWatch/AudioRealtimeGateway"
AGENTS_DIR="$HOME/Library/LaunchAgents"
GATEWAY_LABEL="beer.workspace.wristagent.gateway"
ROTATOR_LABEL="beer.workspace.wristagent.gateway.rotator"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ ! -d "${DEST}" ]; then
  echo "ERROR: ${DEST} missing. rsync the module dir and run \`npm install\` first." >&2
  exit 1
fi
if [ ! -f "${DEST}/certs/gateway.crt" ] || [ ! -f "${DEST}/certs/gateway.key" ]; then
  echo "ERROR: TLS cert/key missing under ${DEST}/certs. Generate them first (see README §Deployment)." >&2
  exit 1
fi

# Gateway and Bridge share this loopback-only service credential through a
# mode-0600 file. Keep an existing value so restarts/deploys remain compatible.
install -d -m 700 "${DEST}/state"
if [ ! -s "${DEST}/state/fallback-hmac-secret" ]; then
  umask 077
  /usr/bin/openssl rand -hex 32 > "${DEST}/state/fallback-hmac-secret"
fi
chmod 600 "${DEST}/state/fallback-hmac-secret"

install -d "${AGENTS_DIR}"
install -m 644 "${SCRIPT_DIR}/launchd/${GATEWAY_LABEL}.plist" "${AGENTS_DIR}/"
install -m 644 "${SCRIPT_DIR}/launchd/${ROTATOR_LABEL}.plist" "${AGENTS_DIR}/"
install -m 755 "${SCRIPT_DIR}/rotate-log.sh" "${DEST}/scripts/rotate-log.sh"

DOMAIN="gui/$(id -u)"
for label in "${GATEWAY_LABEL}" "${ROTATOR_LABEL}"; do
  launchctl bootout "${DOMAIN}/${label}" 2>/dev/null || true
  launchctl bootstrap "${DOMAIN}" "${AGENTS_DIR}/${label}.plist"
done

sleep 3
echo "--- ${GATEWAY_LABEL} ---"
launchctl list "${GATEWAY_LABEL}" || true
echo "--- ${ROTATOR_LABEL} ---"
launchctl list "${ROTATOR_LABEL}" || true
echo
echo "Loopback health probe:"
curl -k -s -o /tmp/ess458-health.json -w '  status=%{http_code}\n' https://127.0.0.1:8444/v1/health && cat /tmp/ess458-health.json && echo

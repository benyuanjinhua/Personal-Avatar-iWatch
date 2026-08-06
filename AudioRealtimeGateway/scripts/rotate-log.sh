#!/bin/bash
# ESS-458 gateway log rotator.
#
# Runs hourly via launchd (beer.workspace.wristagent.gateway.rotator.plist).
# copy-truncate rotation: preserves the inode of the live file so the launchd-
# owned stdout FD in the running server.mjs keeps writing to the (now truncated)
# same file. Tiny race window during the cp is accepted for a low-volume log.
#
# Policy:
#   - rotate when gateway.log > 20 MiB, OR once per day if any records exist
#   - compress rotated copies with gzip -9
#   - retain 14 days of compressed rotations, delete older
#
# Emit a single JSON line to a sibling rotator.log so operators can grep for
# a rotation event.

set -euo pipefail

LOG_DIR="/Users/jacksonmac/Services/Personal-Avatar-iWatch/AudioRealtimeGateway/logs"
LIVE="${LOG_DIR}/gateway.log"
ROT_LOG="${LOG_DIR}/rotator.log"
SIZE_THRESHOLD_BYTES=$((20 * 1024 * 1024))
RETAIN_DAYS=14

mkdir -p "${LOG_DIR}"

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
emit() {
  local evt="$1"; shift
  local extra="$*"
  printf '{"ts":"%s","evt":"%s"%s}\n' "$(now_iso)" "${evt}" "${extra}" >> "${ROT_LOG}"
}

if [ ! -f "${LIVE}" ]; then
  emit rotator_skipped ',"reason":"no_live_log"'
  exit 0
fi

SIZE=$(stat -f %z "${LIVE}" 2>/dev/null || echo 0)
TODAY="$(date +%Y%m%d)"

# Rotate if size threshold exceeded OR no rotation exists for today AND file has content.
NEEDS_ROTATE=false
if [ "${SIZE}" -ge "${SIZE_THRESHOLD_BYTES}" ]; then
  NEEDS_ROTATE=true
  REASON="size"
elif [ "${SIZE}" -gt 0 ] && ! ls "${LOG_DIR}"/gateway.log."${TODAY}"-*.gz >/dev/null 2>&1; then
  NEEDS_ROTATE=true
  REASON="daily"
fi

if [ "${NEEDS_ROTATE}" = "false" ]; then
  exit 0
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
ROTATED="${LOG_DIR}/gateway.log.${STAMP}"

# copy-truncate: preserves the inode so the running gateway keeps writing
# into ${LIVE}, which is now the empty file.
cp "${LIVE}" "${ROTATED}"
: > "${LIVE}"

gzip -9 "${ROTATED}"
emit rotator_rotated ",\"size_bytes\":${SIZE},\"reason\":\"${REASON}\",\"rotated\":\"${ROTATED}.gz\""

# Retention prune: gzip'd rotations older than RETAIN_DAYS
find "${LOG_DIR}" -maxdepth 1 -name 'gateway.log.*.gz' -type f -mtime "+${RETAIN_DAYS}" -print -delete \
  | while read -r purged; do
      emit rotator_purged ",\"path\":\"${purged}\""
    done || true

exit 0

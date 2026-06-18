#!/bin/sh
# Wait for Milk-V RNDIS (usb0), connect to Oculus over TCP ADB, run payload.
set -eu

ENV_FILE="/etc/oculus-adb.env"
[ -r "$ENV_FILE" ] && . "$ENV_FILE"

: "${ADB_BIN:=/usr/local/bin/adb}"
: "${OCULUS_IP:=192.168.42.2}"
: "${OCULUS_PORT:=5555}"
: "${RNDIS_IFACE:=usb0}"
: "${WAIT_IFACE_SEC:=120}"
: "${WAIT_ADB_SEC:=60}"
: "${PAYLOAD:=/usr/local/bin/oculus-adb-payload.sh}"
: "${LOG:=/var/log/oculus-adb.log}"

log() { printf '%s %s\n' "$(date -Iseconds)" "$*" | tee -a "$LOG"; }

wait_iface() {
  end=$(( $(date +%s) + WAIT_IFACE_SEC ))
  while [ "$(date +%s)" -lt "$end" ]; do
    if ip link show "$RNDIS_IFACE" 2>/dev/null | grep -q 'state UP'; then
      if ip -4 addr show dev "$RNDIS_IFACE" | grep -q 'inet '; then
        return 0
      fi
    fi
    sleep 1
  done
  return 1
}

wait_adb() {
  target="${OCULUS_IP}:${OCULUS_PORT}"
  end=$(( $(date +%s) + WAIT_ADB_SEC ))
  export ADB_SERVER_SOCKET="tcp:127.0.0.1:5037"

  "$ADB_BIN" start-server >>"$LOG" 2>&1 || true

  while [ "$(date +%s)" -lt "$end" ]; do
    if "$ADB_BIN" connect "$target" >>"$LOG" 2>&1; then
      if "$ADB_BIN" -s "$target" get-state 2>/dev/null | grep -q device; then
        log "connected to $target"
        return 0
      fi
    fi
    sleep 2
  done
  return 1
}

log "starting oculus adb client"
wait_iface || { log "timeout waiting for $RNDIS_IFACE"; exit 1; }
log "$RNDIS_IFACE is up"

wait_adb || { log "timeout connecting to ${OCULUS_IP}:${OCULUS_PORT}"; exit 1; }

if [ -x "$PAYLOAD" ]; then
  log "running payload: $PAYLOAD"
  exec "$PAYLOAD" "${OCULUS_IP}:${OCULUS_PORT}"
fi

log "no payload configured; idle"
exit 0

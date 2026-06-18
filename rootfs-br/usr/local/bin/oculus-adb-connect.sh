#!/bin/sh
# Lightweight Buildroot: wait for RNDIS usb0, adb connect Oculus, run payload.
set -eu

ENV_FILE="/etc/oculus-adb.env"
[ -r "$ENV_FILE" ] && . "$ENV_FILE"

: "${ADB_BIN:=/usr/local/bin/adb}"
: "${OCULUS_IP:=192.168.42.2}"
: "${OCULUS_PORT:=5555}"
: "${RNDIS_IFACE:=usb0}"
: "${WAIT_IFACE_SEC:=120}"
: "${WAIT_ADB_SEC:=90}"
: "${PAYLOAD:=/usr/local/bin/oculus-adb-payload.sh}"
: "${LOG:=/var/log/oculus-adb.log}"
: "${LED_BIN:=/usr/local/bin/led-blink.sh}"

log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >>"$LOG"; }

wait_iface() {
  end=$(( $(date +%s) + WAIT_IFACE_SEC ))
  while [ "$(date +%s)" -lt "$end" ]; do
    if ifconfig "$RNDIS_IFACE" 2>/dev/null | grep -q "inet addr:${OCULUS_IP%.*}"; then
      return 0
    fi
    if ifconfig "$RNDIS_IFACE" 2>/dev/null | grep -q "inet "; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_adb() {
  target="${OCULUS_IP}:${OCULUS_PORT}"
  end=$(( $(date +%s) + WAIT_ADB_SEC ))

  "$ADB_BIN" start-server >>"$LOG" 2>&1 || true

  while [ "$(date +%s)" -lt "$end" ]; do
    "$ADB_BIN" connect "$target" >>"$LOG" 2>&1 || true
    if "$ADB_BIN" -s "$target" get-state 2>/dev/null | grep -q device; then
      log "connected to $target"
      return 0
    fi
    sleep 3
  done
  return 1
}

mkdir -p /var/log
[ -x "$LED_BIN" ] && "$LED_BIN" off 2>/dev/null || true
log "oculus-adb starting"

wait_iface || { log "timeout: $RNDIS_IFACE"; exit 1; }
log "$RNDIS_IFACE up"

wait_adb || { log "timeout: adb $OCULUS_IP:$OCULUS_PORT"; [ -x "$LED_BIN" ] && "$LED_BIN" off 2>/dev/null || true; exit 1; }

if [ -x "$PAYLOAD" ]; then
  log "payload: $PAYLOAD"
  exec "$PAYLOAD" "${OCULUS_IP}:${OCULUS_PORT}"
fi

log "done (no payload)"
exit 0

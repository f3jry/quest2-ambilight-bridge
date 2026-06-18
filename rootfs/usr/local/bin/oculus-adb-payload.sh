#!/bin/sh
# Example ADB payload — replace with your ambilight commands.
set -eu

TARGET="${1:-192.168.42.2:5555}"
ADB="${ADB_BIN:-/usr/local/bin/adb}"
LOG="${LOG:-/var/log/oculus-adb.log}"

log() { printf '%s %s\n' "$(date -Iseconds)" "$*" | tee -a "$LOG"; }

log "payload target=$TARGET"

# Example: verify device and run a shell command on the headset.
"$ADB" -s "$TARGET" shell getprop ro.product.model >>"$LOG" 2>&1 || true

# TODO: ambilight-specific adb commands here, e.g.:
# "$ADB" -s "$TARGET" shell input keyevent KEYCODE_WAKEUP

log "payload complete"

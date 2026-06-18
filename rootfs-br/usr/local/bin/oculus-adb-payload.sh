#!/bin/sh
# Grab Quest frames over ADB; resize to low-res; flash blue LED while frames are valid.
set -eu

TARGET="${1:-192.168.42.2:5555}"
ADB="${ADB_BIN:-/usr/local/bin/adb}"
LOG="${LOG:-/var/log/oculus-adb.log}"
LED="/usr/local/bin/led-blink.sh"
FRAME_INTERVAL="${FRAME_INTERVAL:-1}"
FAIL_LIMIT="${FAIL_LIMIT:-3}"
FRAME_DIR="${FRAME_DIR:-/tmp/ambilight-frames}"

# Resolution: max 128 wide, keep Quest 2 aspect ratio (approx 16:9 → 128x72).
# Set FRAME_SCALE=native to skip resizing (larger file, slower).
FRAME_SCALE="${FRAME_SCALE:-128x72}"
# Use ffmpeg if available and not in native mode, otherwise raw capture.
USE_FFMPEG=0
if [ "$FRAME_SCALE" != "native" ] && command -v ffmpeg >/dev/null 2>&1; then
  USE_FFMPEG=1
fi

# Min bytes after resize (4.5 KB typical for 128x72 RGBA PNG; use 512 bytes as guard).
FRAME_MIN_BYTES="${FRAME_MIN_BYTES:-512}"

log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >>"$LOG"; }

mkdir -p "$FRAME_DIR"

frame_ok() {
  raw="/tmp/adb-frame-raw.png"
  out="$FRAME_DIR/latest.png"

  # Wake display (Quest sleeps aggressively; screencap returns empty when screen is off)
  "$ADB" -s "$TARGET" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true

  # Capture full-res PNG
  if ! "$ADB" -s "$TARGET" exec-out screencap -p >"$raw" 2>/dev/null; then
    return 1
  fi

  size=$(wc -c <"$raw" | tr -d ' ')
  if [ "$size" -lt 1024 ]; then
    return 1  # empty or too small — display was off or capture failed
  fi

  # Validate PNG magic bytes (89 50 4e 47)
  if ! head -c 4 "$raw" | od -An -tx1 | grep -q "89 50 4e 47"; then
    return 1
  fi

  # Resize if ffmpeg is available
  if [ "$USE_FFMPEG" = "1" ]; then
    if ! ffmpeg -y -i "$raw" \
        -vf "scale=${FRAME_SCALE}:flags=lanczos" \
        -frames:v 1 \
        "$out" >/dev/null 2>&1; then
      # Fallback: just copy at native res
      cp "$raw" "$out"
    fi
  else
    cp "$raw" "$out"
  fi

  # Validate output
  size=$(wc -c <"$out" | tr -d ' ')
  [ "$size" -ge "$FRAME_MIN_BYTES" ]
}

log "payload target=$TARGET scale=$FRAME_SCALE ffmpeg=$USE_FFMPEG"
"$LED" off 2>/dev/null || true

DAEMON_PID=""
cleanup() {
  if [ -n "$DAEMON_PID" ]; then
    log "Stopping C ambilightd daemon (PID $DAEMON_PID)..."
    kill "$DAEMON_PID" 2>/dev/null || true
  fi
  log "Restoring proximity sensor and stayon settings..."
  "$ADB" -s "$TARGET" shell am broadcast -a com.oculus.vrpowermanager.automation_disable >/dev/null 2>&1 || true
  "$ADB" -s "$TARGET" shell svc power stayon false >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

log "Overriding proximity sensor and setting stayon=usb..."
"$ADB" -s "$TARGET" shell am broadcast -a com.oculus.vrpowermanager.prox_close >/dev/null 2>&1 || true
"$ADB" -s "$TARGET" shell svc power stayon usb >/dev/null 2>&1 || true

# Start C ambilightd daemon in SPI mode if installed
if [ -x /usr/local/bin/ambilightd ]; then
  log "Starting C ambilightd daemon..."
  /usr/local/bin/ambilightd -m spi -o /dev/spidev0.0 >/dev/null 2>&1 &
  DAEMON_PID=$!
fi

fail=0
while true; do
  if frame_ok; then
    fail=0
    "$LED" start 2>/dev/null || true
    log "frame ok ($(wc -c <"$FRAME_DIR/latest.png" | tr -d ' ') bytes) — LED blinking"
  else
    fail=$((fail + 1))
    "$LED" off 2>/dev/null || true
    log "frame fail ($fail/$FAIL_LIMIT)"
    if [ "$fail" -ge "$FAIL_LIMIT" ]; then
      log "too many failures — will keep retrying"
      fail=0
    fi
  fi
  sleep "$FRAME_INTERVAL"
done


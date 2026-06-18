#!/bin/bash
# Live Quest 2 ADB Mirroring Test Harness
# Run this AFTER plugging Quest 2 into PC via USB-C
set -euo pipefail

echo "============================================================"
echo " Quest 2 Live ADB Mirroring Test"
echo "============================================================"
echo ""

# ---- 1. Check USB detection ----
echo "[1/6] Checking USB..."
if lsusb 2>/dev/null | grep -qi 'oculus\|quest\|meta'; then
  echo "  ✓ Quest 2 detected on USB"
  lsusb | grep -i 'oculus\|quest\|meta'
else
  echo "  ✗ Quest 2 NOT detected on USB"
  echo "  → Plug the Quest 2 into this PC via USB-C"
  exit 1
fi

echo ""

# ---- 2. Check ADB connection ----
echo "[2/6] Checking ADB..."
if command -v adb &>/dev/null; then
  ADB=adb
else
  echo "  No host adb found, using RISC-V ADB via QEMU"
  ADB="/tmp/qemu-riscv64-static /mnt/milkv-rootfs/usr/local/bin/adb"
fi

# Start ADB server if needed
$ADB start-server 2>/dev/null || true

# Wait for device (up to 10s)
for i in $(seq 1 10); do
  if $ADB devices 2>/dev/null | grep -q 'device$'; then
    break
  fi
  sleep 1
done

DEVICE=$($ADB devices 2>/dev/null | grep 'device$' | head -1 | awk '{print $1}')
if [ -z "$DEVICE" ]; then
  echo "  ✗ No ADB device found"
  echo "  → On Quest 2: Settings → Developer Mode → Enable"
  echo "  → On Quest 2: Plug in USB, accept 'Allow USB debugging' prompt"
  exit 1
fi

echo "  ✓ Device: $DEVICE"
$ADB -s "$DEVICE" shell getprop ro.product.model 2>/dev/null | tr -d '\r\n' | xargs -I{} echo "  Model: {}"
$ADB -s "$DEVICE" shell getprop ro.build.version.release 2>/dev/null | tr -d '\r\n' | xargs -I{} echo "  Android: {}"

echo ""

# ---- 3. Test screencap (PNG) ----
echo "[3/6] Testing screencap -p..."
FRAME_FILE="/tmp/quest_live_test.png"
if $ADB -s "$DEVICE" exec-out screencap -p >"$FRAME_FILE" 2>/dev/null; then
  SIZE=$(stat -c%s "$FRAME_FILE" 2>/dev/null || echo 0)
  MAGIC=$(head -c 4 "$FRAME_FILE" | od -An -tx1 | tr -d ' ')
  echo "  ✓ Frame captured: ${SIZE} bytes"
  echo "  ✓ PNG magic: $MAGIC"
  if [ "$MAGIC" = "89504e47" ]; then
    echo "  ✓ Valid PNG!"
  else
    echo "  ✗ NOT a valid PNG"
  fi
else
  echo "  ✗ screencap -p FAILED"
fi

echo ""

# ---- 4. Test screenrecord (H.264) ----
echo "[4/6] Testing screenrecord --output-format=h264..."
STREAM_FILE="/tmp/quest_live_test.h264"
if timeout 8 $ADB -s "$DEVICE" exec-out screenrecord \
    --output-format=h264 \
    --bit-rate=4M \
    --size=1280x720 \
    --time-limit=5 \
    - >"$STREAM_FILE" 2>/dev/null; then
  STREAM_SIZE=$(stat -c%s "$STREAM_FILE" 2>/dev/null || echo 0)
  echo "  ✓ H.264 stream captured: ${STREAM_SIZE} bytes"
  NAL_COUNT=$(python3 -c "print(open('$STREAM_FILE', 'rb').read().count(b'\x00\x00\x00\x01'))" 2>/dev/null || echo 0)
  echo "  ✓ NAL start codes found: $NAL_COUNT"
  if [ "$NAL_COUNT" -gt 0 ]; then
    echo "  ✓ Valid H.264 stream!"
  fi
else
  echo "  screenrecord test incomplete (timeout or error)"
  echo "  → Check if Quest has enough storage for recording"
fi

echo ""

# ---- 5. Run the full ambilight payload logic (30s smoke test) ----
echo "[5/6] Running payload smoke test (30s in snap mode)..."
SCRIPT="/home/cachy/ambilight/rootfs-br/usr/local/bin/oculus-adb-payload.sh"
if [ -f "$SCRIPT" ]; then
  export ADB_BIN="$ADB"
  export TARGET="$DEVICE"
  export MIRROR_MODE=snap
  export FRAME_INTERVAL=1
  export LOG=/tmp/payload_smoke_test.log
  export FAIL_LIMIT=3
  
  # Run payload for 30 seconds in background
  timeout 30 bash "$SCRIPT" "$DEVICE" 2>&1 || true
  
  echo "  Payload log (last 20 lines):"
  tail -20 "$LOG" 2>/dev/null || echo "  (no log yet)"
  
  # Check if frames were captured
  FRAMES=""
  if [ -d /tmp/ambilight-frames ]; then
    FRAMES=$(find /tmp/ambilight-frames -name 'latest.png' 2>/dev/null | head -1 || true)
  fi
  if [ -n "$FRAMES" ]; then
    FRAME_SIZE=$(stat -c%s "$FRAMES" 2>/dev/null || echo 0)
    echo "  ✓ Latest frame at $FRAMES (${FRAME_SIZE} bytes)"
  fi
else
  echo "  ✗ Payload script not found at $SCRIPT"
fi

echo ""

# ---- 6. Summary ----
echo "[6/6] Test files:"
ls -lh /tmp/quest_live_test.png /tmp/quest_live_test.h264 2>/dev/null || true
ls -lh /tmp/ambilight-frames/ 2>/dev/null || true

echo ""
echo "============================================================"
echo " Next steps:"
echo "  1. If screencap works → Ambilight frame source is viable"
echo "  2. If screenrecord works → Smoother H.264 stream is viable"
echo "  3. Compare latency: screencap (~1s) vs screenrecord (~200ms)"
echo "  4. Implement LED color extraction from PNG frames"
echo "============================================================"

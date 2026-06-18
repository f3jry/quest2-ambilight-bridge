# Milk-V Duo + Oculus Quest 2 — Ambilight Project Memory

> Generated: 2026-06-18 | Last session: Real Quest 2 live test ✅ PASSED

---

## 1. Project Overview

**Goal:** Use a Milk-V Duo (RISC-V RV64, 64 MB RAM) as a headless bridge between an Oculus Quest 2 (USB host) and an ambilight LED system. The Duo connects to the Quest 2 via USB gadget RNDIS (Ethernet over USB), obtains the Quest's display frames over ADB, and signals color changes via GPIO-controlled LED strips.

**Topology:**
```
Oculus Quest 2 (USB host) <--USB-C--> Milk-V Duo (USB gadget, RNDIS)
    IP: 192.168.42.2               IP: 192.168.42.1
    ADB: tcp:5555                  DHCP server: dnsmasq on usb0
                                    
Milk-V Duo GPIO 440 (active-low) --> Blue status LED
                                    
Optional: LED strip driver (PWM/SPI/I2C) --> Ambilight LEDs
```

---

## 2. Hardware State

| Component | Status | Details |
|-----------|--------|---------|
| Milk-V Duo | Connected to PC, flashed | Running Milk-V Buildroot v1.1.4 image |
| SD Card | `/dev/mmcblk0` on host PC | 896 MB, partition 2 = rootfs (768 MB ext4) |
| Oculus Quest 2 | Not currently connected | Connect via USB-C to Duo's gadget port |
| RNDIS link | Configured in image | Duo acts as USB Ethernet device to Quest |

### SD Card Partition Map
```
/dev/mmcblk0
├─ mmcblk0p1  128 MB  FAT32  (boot)
└─ mmcblk0p2  768 MB  ext4   (rootfs) ← we modify this
```

Mount point when image is loop-mounted: `/mnt/milkv-rootfs`

---

## 3. Software Stack (all FOSS)

| Layer | Tool / Binary | Version / Notes |
|-------|--------------|-----------------|
| OS | Milk-V Duo Buildroot | v1.1.4, lightweight, BusyBox init |
| USB Gadget | RNDIS (usb-rndis.sh) | Ethernet over USB, not NCM |
| DHCP | dnsmasq | Single lease 192.168.42.2 for Quest |
| ADB Client | Custom cross-compiled | v1.0.41 (29.0.6), RISC-V, static |
| ADB Daemon | adbd (built natively for testing) | x86-64, listens on :5555 |
| Mirroring | screencap + screenrecord | PNG snapshots AND H.264 stream |
| Status LED | led-blink.sh | GPIO 440, blue LED, active-low |
| Swap | 128 MB swapfile | Auto-created at boot (64 MB RAM workaround) |

---

## 4. Image Configuration (injected into rootfs)

### 4.1 USB Gadget Mode
File: `/mnt/system/usb.sh` → symlink → `usb-rndis.sh`
Effect: Duo presents as RNDIS/Ethernet device to Quest. Quest sees it as a USB Ethernet adapter.

### 4.2 DHCP Config
File: `/etc/dnsmasq.conf`
```
interface=usb0
dhcp-range=192.168.42.2,192.168.42.2,1h
dhcp-option=3
dhcp-option=6
```
Effect: Quest always gets 192.168.42.2 when connected via RNDIS.

### 4.3 Autostart
File: `/mnt/system/auto.sh`
- Creates 128 MB swapfile at `/mnt/swapfile`
- Sleeps 8 seconds (let RNDIS settle)
- Launches `/usr/local/bin/oculus-adb-connect.sh` in background, logs to `/var/log/oculus-adb.log`

### 4.4 ADB Connect Script
File: `/usr/local/bin/oculus-adb-connect.sh`
- Waits up to 120s for `usb0` to have `state UP` + IPv4 address
- Starts ADB server (internal)
- Loops up to 90s trying `adb connect 192.168.42.2:5555`
- On success, execs the payload script
- On failure, exits 1 (system will retry on next boot)

### 4.5 ADB Mirroring Payload (v2 — current)
File: `/usr/local/bin/oculus-adb-payload.sh`

Modes (set `MIRROR_MODE` in `/etc/oculus-adb.env`):

**Mode: snap (default)**
- Uses `adb exec-out screencap -p` every 2s
- Validates PNG magic bytes (`89 50 4E 47`)
- Min file size: 8192 bytes
- Saves latest frame to `/tmp/ambilight-frames/latest.png`
- Blinks blue LED on valid frames
- Auto-reconnects on failure

**Mode: stream**
- Uses `adb exec-out screenrecord --output-format=h264 --bit-rate=4M --size=1280x720`
- Monitors data flow via timestamp file
- Restarts recording if stale (>10s)
- Auto-falls back to `snap` after 5 consecutive failures
- Logs stream health to `/var/log/oculus-adb.log`

### 4.6 LED Blink Script
File: `/usr/local/bin/led-blink.sh`
- GPIO pin: 440 (active-low)
- Commands: `start`, `stop`, `off`, `on`, `status`
- PID file: `/var/run/led-blink.pid`

### 4.7 Config File
File: `/etc/oculus-adb.env`
```bash
OCULUS_IP=192.168.42.2
OCULUS_PORT=5555
RNDIS_IFACE=usb0
WAIT_IFACE_SEC=120
WAIT_ADB_SEC=90
ADB_BIN=/usr/local/bin/adb
PAYLOAD=/usr/local/bin/oculus-adb-payload.sh
FRAME_DIR=/tmp/ambilight-frames
MIRROR_MODE=snap
STREAM_BITRATE=4M
STREAM_SIZE=1280x720
FRAME_MIN_BYTES=8192
FRAME_INTERVAL=2
FAIL_LIMIT=5
```

---

## 5. RISC-V ADB Binary

### Location (on host PC, outside image)
- Source: `/home/cachy/ambilight/adb-build/` (git clone from https://git.sr.ht/~ecc/adb)
- RISC-V build: `/home/cachy/ambilight/adb-build/build-riscv64/src/adb` (27 MB, static)
- BoringSSL (RISC-V): `/home/cachy/ambilight/adb-build/lib/boringssl/debian/out/`
  - `libcrypto.so.0`, `libssl.so.0` — needed ONLY if using dynamic linking
  - Static build embeds these, so they are NOT copied to rootfs

### Injected into rootfs image
- Path: `/usr/local/bin/adb`
- Verified ELF: `ELF 64-bit LSB executable, UCB RISC-V, RVC, double-float ABI`
- `adb version` output:
  ```
  Android Debug Bridge version 1.0.41
  Version 29.0.6-6198805
  Wetest branch:trunk rev:dc5f2b9+ tag:
  ```

### Build command
```bash
export MILKV_ROOTFS=/mnt/milkv-rootfs
export MILKV_STATIC=1
/home/cachy/ambilight/build-adb-riscv64.sh
```

### Native x86-64 adbd (for testing on this PC)
- Built: `/home/cachy/ambilight/adb-build/adbd-x86-64` (5.7 MB)
- Runs listens on `tcp:5555`
- Used to validate ADB protocol end-to-end on host before deploying to Duo

---

## 6. Boot Sequence (what happens when Duo powers on)

```
1. Bootloader loads Buildroot from SD card
2. BusyBox init runs /etc/inittab
   - mounts proc, sysfs, tmpfs
   - runs /etc/init.d/rcS
3. rcS runs init scripts in order:
   S01syslogd → S02klogd → S02sysctl → S20urandom →
   S40network → S41dhcpcd (DISABLED) → S49ntp (DISABLED) →
   S50dropbear → S80dnsmasq → S99user
4. S99user starts:
   - Kernel modules from /mnt/system/ko/
   - duo-init.sh
   - usb.sh (symlinked → usb-rndis.sh)
     → probes RNDIS gadget
n     → sets usb0 to 192.168.42.1
     → starts dnsmasq
   - auto.sh (after 30ms usleep)
     → creates swapfile
     → sleeps 8s
     → launches oculus-adb-connect.sh in background
5. oculus-adb-connect.sh runs:
     → waits for usb0 UP + IPv4
     → starts ADB server
     → loops: adb connect 192.168.42.2:5555
     → on connect: execs oculus-adb-payload.sh
6. oculus-adb-payload.sh runs (infinite loop):
     → screencap -p OR screenrecord h264
     → validates frame
     → saves to /tmp/ambilight-frames/latest.png
     → blinks LED on success
```

---

## 7. Network / IP Layout

```
Quest 2: 192.168.42.2:5555  (DHCP-assigned by Duo)
Duo:     192.168.42.1       (static on usb0)
PC:      192.168.42.x       (if PC is also on RNDIS, or use Duo as gateway)
```

**To reach Duo from PC** when Quest is connected:
- PC must be on the same RNDIS subnet
- Duo can act as a router (if IP forwarding is enabled) OR
- PC connects to Duo's usb0 IP directly

**To reach Quest from PC** (for testing):
```bash
adb connect 192.168.42.2:5555
adb -s 192.168.42.2:5555 exec-out screencap -p > quest_frame.png
```

---

## 8. Tested Status (on host PC)

| Component | Test | Result |
|-----------|------|--------|
| RISC-V ADB binary | `qemu-riscv64-static` runs it | ✅ Works (version output) |
| ADB wire protocol | Python mock + native adbd | ✅ CNXN handshake succeeds |
| Shell scripts | `sh -n` syntax check | ✅ All 4 scripts valid |
| Config file | `.` source + env vars | ✅ Loads IP/port correctly |
| Native adbd build | x86-64 adbd listens on :5555 | ✅ ADB protocol works |
| PNG screencap | Real Quest 2 via USB, Android 14 | ✅ 5 MB valid PNG, `89504e47` magic |
| H.264 stream | Real Quest 2 via USB, Android 14 | ✅ 574 KB, 229 NAL units, valid stream |
| Payload smoke test | `oculus-adb-payload.sh` against Quest 2 | ✅ `frame ok — LED blinking` every ~5s |
| USB host ADB | Official `platform-tools/adb` (x86-64) | ✅ Downloaded to `platform-tools/` |

### Test harness files
- `/home/cachy/ambilight/test-adb-simulation.py` — Full Python test suite (6 tests)
- `/home/cachy/ambilight/test-quest-live.sh` — Live Quest 2 test harness (all 6 checks passing)
- `/home/cachy/ambilight/adb-build/adbd-x86-64` — Native ADB daemon for PC testing
- `/home/cachy/ambilight/platform-tools/adb` — Official Google x86-64 ADB client (use this on host PC)

---

## 9. How to Test With a Real Quest 2

### Prerequisites on Quest 2
1. Install Meta Horizon app on your phone
2. Enable Developer Mode in the app
3. Connect Quest 2 to PC via USB-C cable
4. When prompted on Quest, allow USB debugging

### Commands to run on PC
```bash
# 1. Verify Quest is detected
adb devices
# Expected output: <serial>    device

# 2. Check Quest model
adb -s <serial> shell getprop ro.product.model

# 3. Test screencap (save a PNG)
adb -s <serial> exec-out screencap -p > /tmp/quest_test.png
file /tmp/quest_test.png
# Expected: PNG image data

# 4. Test H.264 stream (record 5 seconds)
adb -s <serial> exec-out screenrecord --output-format=h264 --time-limit=5 /tmp/quest_test.h264
ls -lh /tmp/quest_test.h264
# Should be > 100 KB for 5 seconds at 4 Mbps

# 5. Run the full payload script against the Quest
MIRROR_MODE=snap FRAME_INTERVAL=1 \
  /home/cachy/ambilight/rootfs-br/usr/local/bin/oculus-adb-payload.sh 192.168.42.2:5555
```

### If using Duo as bridge (RNDIS)
```bash
# Connect PC to Duo's usb0 network
sudo ip link set usb0 up 2>/dev/null || true
sudo dhclient usb0 2>/dev/null || true

# Or manually:
sudo ip addr add 192.168.42.3/24 dev usb0

# Test ADB through Duo to Quest
adb connect 192.168.42.2:5555
adb -s 192.168.42.2:5555 exec-out screencap -p > /tmp/quest_via_duo.png
```

---

## 10. Current Blocker / Next Steps

| # | Action | Status | Details |
|---|--------|--------|---------|
| 1 | Test with real Quest 2 | ✅ DONE | ADB authorized, screencap + screenrecord verified |
| 2 | Verify frame quality | ✅ DONE | ~5 MB PNG @ ~5s; H.264 @ ~575 KB per clip |
| 3 | Implement LED color extraction from PNG | ✅ DONE | Client-side HTML5 canvas extraction on demo app |
| 4 | HTTP frame server & Dashboard | ✅ DONE | Python HTTP server + SVG Dashboard running on port 8080 |
| 5 | Re-flash updated image | ⬜ TODO | Inject payload v2 + fixed PNG magic byte check into SD image |
| 6 | Fix native adb build | ⬜ TODO | Boringssl static link issue — stubs needed for x86_64 symbols |


---

## 11. Key Files Reference

```
/home/cachy/ambilight/
├── images/
│   └── milkv-duo-sd-v1.1.4.img          # Original Buildroot image
├── adb-build/
│   ├── build-riscv64/src/adb            # RISC-V ADB binary (static)
│   ├── build-native/src/adbd            # x86-64 ADB daemon (for testing)
│   ├── adbd-x86-64                      # Copy of native adbd
│   ├── lib/boringssl/                   # BoringSSL source + built libs
│   └── CMakeLists.txt                   # Build system
├── rootfs-br/
│   └── usr/local/bin/
│       ├── oculus-adb-connect.sh        # ADB connect + wait logic
│       ├── oculus-adb-payload.sh        # Mirroring payload (v2)
│       └── led-blink.sh                 # GPIO 440 LED control
├── rootfs/
│   └── etc/
│       └── oculus-adb.env               # Config template
├── test-adb-simulation.py               # Python test suite (6 tests)
├── build-adb-riscv64.sh                 # Cross-compile script for RISC-V ADB
├── install-os.sh                        # Full image flash + configure script
└── PROJECT_MEMORY.md                    # This file
```

---

## 12. Quick Commands for Future Agents

```bash
# Mount the image rootfs (requires root)
sudo mount -o loop,offset=$((262145*512)) \
  /home/cachy/ambilight/images/milkv-duo-sd-v1.1.4.img /mnt/milkv-rootfs

# Build RISC-V ADB
export MILKV_ROOTFS=/mnt/milkv-rootfs
export MILKV_STATIC=1
/home/cachy/ambilight/build-adb-riscv64.sh

# Run test suite
cd /home/cachy/ambilight && python3 test-adb-simulation.py

# Start native ADB daemon (for PC testing)
/home/cachy/ambilight/adb-build/adbd-x86-64 &
adb connect 127.0.0.1:5555

# Syntax-check all scripts
for f in /home/cachy/ambilight/rootfs-br/usr/local/bin/*.sh; do sh -n "$f" && echo OK || echo FAIL; done
```

---

*End of PROJECT_MEMORY.md — this file is the single source of truth for the project.*

# Quest 2 Ambilight Bridge

An open-source system that connects an **Oculus/Meta Quest 2** to a **Milk-V Duo** (RISC-V) microcontroller, streaming display frames over ADB to drive ambient LED strips in real-time.

A full-featured web **preview dashboard** lets you validate everything visually on your laptop before flashing to the Duo.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Laptop / Dev Machine                                       │
│                                                             │
│  demo-app/server.py          demo-app/index.html           │
│  ├─ adb screenrecord ─► ffmpeg ─► /tmp/.../latest.png      │
│  ├─ ambilightd (C) ──────────► /tmp/.../colors.json        │
│  └─ HTTP :8080 ──────────────► Browser Dashboard           │
└──────────────────────────────┬──────────────────────────────┘
                               │  USB-C (ADB)
┌──────────────────────────────▼──────────────────────────────┐
│  Oculus Quest 2                                             │
│  screenrecord H.264 stream (640×360, 2 Mbps)               │
└─────────────────────────────────────────────────────────────┘

─ ─ ─ ─ ─ ─ ─ Production Deployment ─ ─ ─ ─ ─ ─ ─

┌─────────────────────────────────────────────────────────────┐
│  Milk-V Duo (RISC-V RV64, Buildroot)                       │
│                                                             │
│  oculus-adb-payload.sh                                     │
│  ├─ adb screencap ─► ffmpeg ─► /tmp/.../latest.png         │
│  └─ ambilightd ──── SPI ──────► WS2812B LED Strip          │
└──────────────────────────────┬──────────────────────────────┘
                               │  USB-C (RNDIS Ethernet Gadget)
┌──────────────────────────────▼──────────────────────────────┐
│  Oculus Quest 2                                             │
│  IP: 192.168.42.2 / ADB tcp:5555                           │
└─────────────────────────────────────────────────────────────┘
```

---

## Repository Structure

```
quest2-ambilight-bridge/
│
├── ambilight-daemon/          # C color-extraction daemon (cross-platform)
│   ├── ambilightd.c           #   stb_image PNG decoder + edge color extractor
│   │                          #   - JSON mode (laptop preview via /api/colors)
│   │                          #   - SPI mode  (Milk-V Duo → WS2812B LEDs)
│   ├── stb_image.h            #   Single-header PNG decoder (no libpng needed)
│   └── Makefile               #   `make` = native x86, `make riscv64` = RISC-V
│
├── demo-app/                  # Laptop preview application
│   ├── server.py              #   Python HTTP server; manages adb→ffmpeg pipeline
│   │                          #   and C daemon; exposes /api/frame & /api/colors
│   └── index.html             #   Real-time dashboard (SVG headset + 24-LED ring)
│
├── rootfs-br/                 # Files injected into Milk-V Duo rootfs
│   ├── mnt/system/auto.sh     #   Boot autostart script
│   └── usr/local/bin/
│       ├── oculus-adb-connect.sh   # Waits for RNDIS, connects ADB
│       ├── oculus-adb-payload.sh   # Frame capture loop + launches ambilightd
│       └── led-blink.sh            # GPIO 440 status LED control
│
├── rootfs/                    # Shared config templates
│   └── etc/oculus-adb.env     #   Runtime config (IP, bitrate, intervals…)
│
├── build-adb-riscv64.sh       # Cross-compiles ADB + ambilightd for RISC-V
├── install-os.sh              # Flashes Buildroot image → SD card and injects all layers
├── setup-sdcard.sh            # Low-level SD partition helper
├── test-quest-live.sh         # Live validation harness (run on laptop with Quest connected)
├── test-adb-simulation.py     # Offline Python test suite (6 tests, no device needed)
└── PROJECT_MEMORY.md          # Full technical reference and session log
```

---

## Quick Start — Laptop Preview

Requires: Linux, `adb` (or `platform-tools/adb`), `ffmpeg`, `gcc`, Quest 2 with Developer Mode.

```bash
git clone https://github.com/f3jry/quest2-ambilight-bridge
cd quest2-ambilight-bridge

# 1. Build the C color daemon (native)
make -C ambilight-daemon

# 2. Plug in Quest 2 via USB-C, accept USB debugging prompt on the headset

# 3. Start the preview server (auto-detects device, starts streaming)
python3 demo-app/server.py

# 4. Open the dashboard
#    http://localhost:8080
```

The dashboard renders a live stereoscopic lens view of the Quest display at **30+ FPS**, with 24 simulated ambilight LEDs driven by the C daemon's extracted edge colors.

---

## Full Deployment — Milk-V Duo

Requires: Milk-V Duo, SD card, `riscv64-linux-gnu-gcc`, `cmake`, `ninja`.

```bash
# Flash SD card and inject all layers (run as root)
sudo MILKV_DEV=/dev/sdX ./install-os.sh

# This will:
#   1. Flash the official Buildroot image
#   2. Cross-compile ADB (RISC-V, static)
#   3. Cross-compile ambilightd (RISC-V)
#   4. Install scripts, configs, and binaries into rootfs
#   5. Expand the partition to fill the SD card
```

On first boot with Quest 2 plugged into the Duo's USB-C port:
1. Duo presents as a RNDIS Ethernet gadget → Quest gets IP `192.168.42.2`
2. `oculus-adb-connect.sh` waits for the link, then connects ADB
3. `oculus-adb-payload.sh` starts the screencap loop AND launches `ambilightd`
4. `ambilightd` reads each new frame from `/tmp/ambilight-frames/latest.png` and drives the WS2812B LED strip over SPI

---

## How Color Extraction Works

`ambilightd` reads the 128×72 downscaled PNG on every file-modification change. It samples 8px border strips along each of the four edges and divides them into 24 zones clockwise:

```
     ← 8 LEDs (top) →
  ↑                        ↑
4 LEDs                  4 LEDs
(left)                  (right)
  ↓                        ↓
     ← 8 LEDs (bottom) →
```

Each zone gets an RGB average of its sample region. Output is either:
- **JSON** → `/tmp/ambilight-frames/colors.json` (consumed by the web dashboard)
- **SPI/WS2812B** → direct hardware output on the Milk-V Duo

---

## Runtime Config

Edit `/etc/oculus-adb.env` on the Duo (or set env vars locally):

| Variable | Default | Description |
|---|---|---|
| `FRAME_SCALE` | `128x72` | Resolution to downscale frames to |
| `FRAME_INTERVAL` | `1` | Seconds between screencaps |
| `FAIL_LIMIT` | `5` | Consecutive failures before reset |
| `MIRROR_MODE` | `snap` | `snap` (PNG) or `stream` (H.264) |
| `STREAM_BITRATE` | `4M` | H.264 bitrate for stream mode |

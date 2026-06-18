# Quest 2 Ambilight Bridge & Simulator

An open-source bridge and simulation system that connects an Oculus/Meta Quest 2 headset to a Milk-V Duo (RISC-V) microcontroller over USB, streaming display frames over ADB to drive ambient LED strip zones in real-time.

---

## ⚡ Architecture Overview

```
Oculus Quest 2 (USB host) <----USB----> Milk-V Duo (RNDIS Gadget)
    IP: 192.168.42.2                        IP: 192.168.42.1 (dnsmasq)
          |                                         |
          v                                         v
   (H.264 Stream)                            (LED Controller)
```

The system works by configuring the Milk-V Duo as an RNDIS USB Ethernet device. Once connected:
1. The Duo runs a DHCP server (`dnsmasq`) to assign an IP address (`192.168.42.2`) to the Quest 2.
2. The Duo establishes a connection to the Quest's ADB daemon.
3. The Duo requests a continuous screen-capture stream from the Quest and processes the border frame pixels to compute dominant edge colors.
4. The Duo drives a GPIO-connected WS2812B/equivalent LED strip to create the ambilight projection.

---

## 🖥️ Live Laptop Dashboard (Simulator)

For validation and visual testing on a laptop before deploying to the Milk-V Duo, the repository includes a fully featured web application that mirrors the Quest 2 display in real-time at **30+ FPS**.

```
[Oculus Quest 2] 
      │ (USB Connection)
      ▼
[Python Web Server (port 8080)]
      │ (Manages adb screenrecord ➔ ffmpeg pipe)
      ▼
[WebGL/Canvas Frontend]
      ├─► Extract border colors in real-time
      ├─► Projects backing wall-glow aura
      └─► Renders stereoscopic left/right eye lens viewports
```

### Features
- **Continuous H.264 Stream**: Spawns an ADB H.264 video stream from the Quest and pipes it into a local `ffmpeg` decoder, keeping latency under `150ms`.
- **Stereoscopic Lens Wrapping**: Automatically parses the dual-eye display buffer, showing only the left eye in the left lens and the right eye in the right lens (symmetrically centered).
- **Interactive Controls**: Wake up the headset, start/stop the stream, adjust LED glow intensity, and throttle the render framerate from 5 FPS to Max.

### Running the Simulator
Make sure your Quest 2 is connected to your computer via USB with Developer Mode enabled.

1. Install system dependencies (Linux package example shown):
   ```bash
   # Make sure you have adb and ffmpeg installed
   sudo pacman -S android-tools ffmpeg
   ```
2. Navigate to the `demo-app` directory and start the server:
   ```bash
   python3 demo-app/server.py
   ```
3. Open your browser to:
   👉 **[http://localhost:8080](http://localhost:8080)**

---

## 📁 Repository Structure

- `demo-app/`: The interactive web dashboard and python pipeline server.
- `rootfs-br/` & `rootfs/`: Configuration files and customized shell scripts that run on the Milk-V Duo microcontroller.
- `build-adb-riscv64.sh`: Static compile script to build the ADB client for the RISC-V arch.
- `setup-sdcard.sh` & `install-os.sh`: Flash and configure script to inject these custom layers onto the Milk-V Duo Buildroot SD image.
- `test-quest-live.sh`: Host utility to run live validations against your Quest 2 connection.

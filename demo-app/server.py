import http.server
import socketserver
import json
import subprocess
import os
import signal
import sys
import threading
import time
from urllib.parse import urlparse

PORT = 8080
WORKSPACE_DIR = "/home/cachy/ambilight"
ADB_BIN = os.path.join(WORKSPACE_DIR, "platform-tools/adb")
DAEMON_BIN = os.path.join(WORKSPACE_DIR, "ambilight-daemon/ambilightd")
FRAME_DIR = "/tmp/ambilight-frames"
LATEST_FRAME_PATH = os.path.join(FRAME_DIR, "latest.png")
LATEST_COLORS_PATH = os.path.join(FRAME_DIR, "colors.json")
LOG_PATH = "/tmp/payload-demo.log"

stream_manager = None
daemon_process = None
payload_lock = threading.Lock()

def get_adb_device():
    try:
        output = subprocess.check_output([ADB_BIN, "devices"]).decode()
        lines = [line.strip() for line in output.split("\n") if line.strip()]
        devices = []
        for line in lines[1:]:
            parts = line.split()
            if len(parts) >= 2 and parts[1] == "device":
                devices.append(parts[0])
        return devices[0] if devices else None
    except Exception as e:
        print(f"Error checking ADB devices: {e}", file=sys.stderr)
        return None

class StreamManager:
    def __init__(self, device, adb_bin, latest_frame_path):
        self.device = device
        self.adb_bin = adb_bin
        self.latest_frame_path = latest_frame_path
        self.running = False
        self.adb_proc = None
        self.ffmpeg_proc = None
        self.thread = None
        
    def start(self):
        self.running = True
        self.thread = threading.Thread(target=self._run_loop, daemon=True)
        self.thread.start()
        
    def stop(self):
        self.running = False
        self._kill_processes()
        
    def _kill_processes(self):
        if self.adb_proc:
            try:
                self.adb_proc.terminate()
                self.adb_proc.wait(timeout=1)
            except:
                try: self.adb_proc.kill()
                except: pass
            self.adb_proc = None
        if self.ffmpeg_proc:
            try:
                self.ffmpeg_proc.terminate()
                self.ffmpeg_proc.wait(timeout=1)
            except:
                try: self.ffmpeg_proc.kill()
                except: pass
            self.ffmpeg_proc = None
            
    def _run_loop(self):
        if os.path.exists(self.latest_frame_path):
            try:
                os.remove(self.latest_frame_path)
            except:
                pass

        while self.running:
            try:
                subprocess.run([self.adb_bin, "-s", self.device, "shell", "input", "keyevent", "KEYCODE_WAKEUP"], 
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            except:
                pass

            adb_cmd = [
                self.adb_bin, "-s", self.device, "exec-out", "screenrecord",
                "--output-format=h264",
                "--bit-rate=2M",
                "--size=640x360",
                "--time-limit=170",
                "-"
            ]
            
            ffmpeg_cmd = [
                "ffmpeg", "-y",
                "-f", "h264",
                "-i", "pipe:0",
                "-vf", "scale=128:72",
                "-update", "1",
                "-y", self.latest_frame_path
            ]
            
            try:
                os.makedirs(os.path.dirname(self.latest_frame_path), exist_ok=True)
                
                self.adb_proc = subprocess.Popen(
                    adb_cmd,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                    preexec_fn=os.setsid if hasattr(os, 'setsid') else None
                )
                
                self.ffmpeg_proc = subprocess.Popen(
                    ffmpeg_cmd,
                    stdin=self.adb_proc.stdout,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    preexec_fn=os.setsid if hasattr(os, 'setsid') else None
                )
                
                self.adb_proc.stdout.close()
                
                while self.running:
                    if self.ffmpeg_proc.poll() is not None or self.adb_proc.poll() is not None:
                        break
                    time.sleep(0.5)
                    
            except Exception as e:
                print(f"Error in stream loop: {e}", file=sys.stderr)
                
            self._kill_processes()
            if self.running:
                time.sleep(1)

def start_payload():
    global stream_manager, daemon_process
    with payload_lock:
        if stream_manager and stream_manager.running:
            return True
        
        device = get_adb_device()
        if not device:
            print("No ADB device found, cannot start payload", file=sys.stderr)
            return False
        
        # Override proximity sensor so display stays on, and keep display awake
        try:
            subprocess.run([ADB_BIN, "-s", device, "shell", "am", "broadcast", "-a", "com.oculus.vrpowermanager.prox_close"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run([ADB_BIN, "-s", device, "shell", "svc", "power", "stayon", "usb"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            print(f"Disabled proximity sensor and set stayon=usb for device {device}")
        except Exception as e:
            print(f"Failed to override sensor/stayon settings: {e}", file=sys.stderr)
        
        # Ensure target folder exists and is clean
        os.makedirs(FRAME_DIR, exist_ok=True)
        for p in [LATEST_FRAME_PATH, LATEST_COLORS_PATH]:
            if os.path.exists(p):
                try: os.remove(p)
                except: pass

        # 1. Start C ambilightd daemon in JSON mode outputting to /tmp/ambilight-frames/colors.json
        daemon_cmd = [
            DAEMON_BIN,
            "-m", "json",
            "-o", LATEST_COLORS_PATH
        ]
        try:
            daemon_process = subprocess.Popen(
                daemon_cmd,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                preexec_fn=os.setsid if hasattr(os, 'setsid') else None
            )
            print(f"Started C ambilightd daemon with PID {daemon_process.pid}")
        except Exception as e:
            print(f"Failed to start C daemon: {e}", file=sys.stderr)

        # 2. Start H.264 video stream decoding pipeline
        stream_manager = StreamManager(device, ADB_BIN, LATEST_FRAME_PATH)
        stream_manager.start()
        print(f"Started H.264 stream decoding pipeline for device {device}")
        return True

def stop_payload():
    global stream_manager, daemon_process
    with payload_lock:
        # Restore proximity sensor behavior and stayon settings
        device = get_adb_device()
        if device:
            try:
                subprocess.run([ADB_BIN, "-s", device, "shell", "am", "broadcast", "-a", "com.oculus.vrpowermanager.automation_disable"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                subprocess.run([ADB_BIN, "-s", device, "shell", "svc", "power", "stayon", "false"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                print(f"Restored normal proximity sensor and stayon settings for device {device}")
            except Exception as e:
                print(f"Failed to restore sensor/stayon settings: {e}", file=sys.stderr)

        # 1. Stop H.264 stream decoding pipeline
        if stream_manager:
            stream_manager.stop()
            stream_manager = None
            print("Stopped StreamManager")

        # 2. Stop C daemon process
        if daemon_process:
            try:
                os.killpg(os.getpgid(daemon_process.pid), signal.SIGTERM)
                daemon_process.wait(timeout=1)
                print("Stopped C daemon successfully")
            except Exception as e:
                print(f"Error stopping C daemon: {e}", file=sys.stderr)
                try: daemon_process.kill()
                except: pass
            daemon_process = None
        return True

class DemoAppHandler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        if self.path.startswith("/api/"):
            self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
            self.send_header("Pragma", "no-cache")
            self.send_header("Expires", "0")
        super().end_headers()
        
    def do_GET(self):
        parsed_path = urlparse(self.path)
        path = parsed_path.path
        
        if path == "/api/status":
            device = get_adb_device()
            running = stream_manager is not None and stream_manager.running
            
            frame_exists = os.path.exists(LATEST_FRAME_PATH)
            frame_time = os.path.getmtime(LATEST_FRAME_PATH) if frame_exists else 0
            frame_size = os.path.getsize(LATEST_FRAME_PATH) if frame_exists else 0
            
            response = {
                "device_connected": device is not None,
                "device_serial": device if device else "None",
                "capture_running": running,
                "frame_available": frame_exists,
                "frame_timestamp": frame_time,
                "frame_size_bytes": frame_size
            }
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(response).encode())
            
        elif path == "/api/frame":
            if os.path.exists(LATEST_FRAME_PATH):
                self.send_response(200)
                self.send_header("Content-Type", "image/png")
                self.send_header("Access-Control-Allow-Origin", "*")
                self.end_headers()
                with open(LATEST_FRAME_PATH, "rb") as f:
                    self.wfile.write(f.read())
            else:
                self.send_response(404)
                self.end_headers()
                self.wfile.write(b"Frame not found")

        elif path == "/api/colors":
            if os.path.exists(LATEST_COLORS_PATH):
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Access-Control-Allow-Origin", "*")
                self.end_headers()
                with open(LATEST_COLORS_PATH, "rb") as f:
                    self.wfile.write(f.read())
            else:
                self.send_response(404)
                self.end_headers()
                self.wfile.write(b"Colors not found")
                
        elif path == "/api/start":
            success = start_payload()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"success": success}).encode())
            
        elif path == "/api/stop":
            success = stop_payload()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"success": success}).encode())
            
        else:
            super().do_GET()
            
    def do_POST(self):
        parsed_path = urlparse(self.path)
        path = parsed_path.path
        
        if path == "/api/wakeup":
            device = get_adb_device()
            if device:
                try:
                    subprocess.run([ADB_BIN, "-s", device, "shell", "input", "keyevent", "KEYCODE_WAKEUP"], check=True)
                    success = True
                    message = "Wakeup signal sent to Quest 2"
                except Exception as e:
                    success = False
                    message = f"Error sending wakeup: {str(e)}"
            else:
                success = False
                message = "No ADB device connected"
                
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"success": success, "message": message}).encode())
        else:
            self.send_response(404)
            self.end_headers()
            
    def translate_path(self, path):
        root = os.path.join(WORKSPACE_DIR, "demo-app")
        rel_path = path.lstrip('/')
        target = os.path.abspath(os.path.join(root, rel_path))
        if target.startswith(root):
            return target
        return os.path.join(root, "index.html")

class ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True

def main():
    device = get_adb_device()
    if device:
        print(f"Device {device} detected. Starting daemon & pipeline...")
        start_payload()
    else:
        print("No device detected. Connect device and start in web UI.")
        
    server = ThreadingHTTPServer(('0.0.0.0', PORT), DemoAppHandler)
    print(f"Demo Server running on http://localhost:{PORT}")
    
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nKeyboard Interrupt received. Shutting down server...")
    finally:
        stop_payload()
        server.server_close()
        print("Server shutdown complete.")

if __name__ == "__main__":
    main()

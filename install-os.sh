#!/usr/bin/env bash
# Flash official Milk-V Duo Buildroot (lightweight) + RNDIS + static adb + Oculus autostart.
set -euo pipefail

DEV="${MILKV_DEV:-/dev/mmcblk0}"
PART="${MILKV_ROOT_PART:-${DEV}p2}"
MNT="${MILKV_ROOTFS:-/mnt/milkv-rootfs}"
HERE="$(cd "$(dirname "$0")" && pwd)"
IMG="${MILKV_IMAGE:-$HERE/images/milkv-duo-sd-v1.1.4.img}"
IMG_ZIP="${IMG%.img}.zip"

[[ "$(id -u)" -eq 0 ]] || { echo "run as root (pkexec/sudo)" >&2; exit 1; }
[[ -b "$DEV" ]] || { echo "block device not found: $DEV" >&2; exit 1; }

if [[ ! -f "$IMG" ]]; then
  mkdir -p "$(dirname "$IMG")"
  curl -fL -o "$IMG_ZIP" \
    'https://github.com/milkv-duo/duo-buildroot-sdk/releases/download/v1.1.4/milkv-duo-sd-v1.1.4.img.zip'
  unzip -o "$IMG_ZIP" -d "$(dirname "$IMG")"
fi

echo "==> Unmounting $DEV"
for mp in "$MNT" /run/media/*/rootfs /run/media/*/boot; do
  mountpoint -q "$mp" 2>/dev/null && umount "$mp" || true
done
umount "${DEV}"* 2>/dev/null || true
sleep 1

echo "==> Flashing $IMG -> $DEV (ALL DATA ON SD WILL BE ERASED)"
dd if="$IMG" of="$DEV" bs=4M conv=fsync status=progress
sync
partprobe "$DEV" 2>/dev/null || true
sleep 2

echo "==> Mount rootfs"
mkdir -p "$MNT"
mount "$PART" "$MNT"

echo "==> RAM-light tuning"
# RNDIS for Oculus USB host (not NCM)
ln -sfn usb-rndis.sh "$MNT/mnt/system/usb.sh"

# Single Oculus DHCP lease
cat >"$MNT/etc/dnsmasq.conf" <<'EOF'
interface=usb0
dhcp-range=192.168.42.2,192.168.42.2,1h
dhcp-option=3
dhcp-option=6
EOF

# Disable non-essential daemons (~few MB RAM saved)
for svc in S49ntp S41dhcpcd; do
  [[ -f "$MNT/etc/init.d/$svc" ]] && mv "$MNT/etc/init.d/$svc" "$MNT/etc/init.d/${svc}.disabled"
done
[[ -f "$MNT/mnt/system/blink.sh" ]] && mv "$MNT/mnt/system/blink.sh" "$MNT/mnt/system/blink.sh.disabled"

# Headless: no serial autologin shell
sed -i 's|^console::respawn:.*|# &|' "$MNT/etc/inittab"

echo "==> Build + install static adb (runs on musl Buildroot)"
export MILKV_ROOTFS="$MNT"
export MILKV_STATIC=1
"$HERE/build-adb-riscv64.sh"

echo "==> Install ambilight scripts"
install -Dm755 "$HERE/rootfs-br/usr/local/bin/oculus-adb-connect.sh" "$MNT/usr/local/bin/oculus-adb-connect.sh"
install -Dm755 "$HERE/rootfs-br/usr/local/bin/oculus-adb-payload.sh" "$MNT/usr/local/bin/oculus-adb-payload.sh"
install -Dm755 "$HERE/rootfs-br/usr/local/bin/led-blink.sh" "$MNT/usr/local/bin/led-blink.sh"
install -Dm644 "$HERE/rootfs/etc/oculus-adb.env" "$MNT/etc/oculus-adb.env"
install -Dm755 "$HERE/rootfs-br/mnt/system/auto.sh" "$MNT/mnt/system/auto.sh"

echo "==> Expand rootfs to fill SD (optional space for logs)"
# Grow partition 2 to end of disk, then resize ext4
if command -v parted >/dev/null && command -v resize2fs >/dev/null; then
  parted -s "$DEV" "resizepart 2 100%" || true
  resize2fs "$PART" || true
fi

sync
echo "==> Done. Rootfs at $MNT (still mounted)."
echo "    Unmount with: umount $MNT"
echo "    Boot: insert SD, power Duo via USB-C, Oculus on USB gadget port."

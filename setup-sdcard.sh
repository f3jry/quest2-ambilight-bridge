#!/usr/bin/env bash
# Configure Milk-V Duo SD card rootfs for headless RNDIS + Oculus ADB.
set -euo pipefail

DEV="${MILKV_DEV:-/dev/mmcblk0}"
PART="${MILKV_ROOT_PART:-${DEV}p2}"
MNT="${MILKV_ROOTFS:-/mnt/milkv-rootfs}"
HERE="$(cd "$(dirname "$0")" && pwd)"

usage() {
  cat <<EOF
Usage: sudo $0 {mount|install|enable|sync|unmount|all}

  mount    Mount \$PART at \$MNT
  install  Cross-build adb + copy scripts into rootfs
  enable   Enable RNDIS + oculus-adb systemd units
  sync     Flush writes to SD
  unmount  Unmount rootfs
  all      mount -> install -> enable -> sync

Env:
  MILKV_DEV=/dev/mmcblk0
  MILKV_ROOT_PART=/dev/mmcblk0p2
  MILKV_ROOTFS=/mnt/milkv-rootfs
EOF
}

cmd_mount() {
  mkdir -p "$MNT"
  if mountpoint -q "$MNT"; then
    echo "already mounted: $MNT"
  else
    mount "$PART" "$MNT"
    echo "mounted $PART -> $MNT"
  fi
}

cmd_install() {
  mountpoint -q "$MNT" || { echo "not mounted: $MNT" >&2; exit 1; }

  MILKV_ROOTFS="$MNT" "$HERE/build-adb-riscv64.sh"

  install -Dm755 "$HERE/rootfs/usr/local/bin/oculus-adb-connect.sh" "$MNT/usr/local/bin/oculus-adb-connect.sh"
  install -Dm755 "$HERE/rootfs/usr/local/bin/oculus-adb-payload.sh" "$MNT/usr/local/bin/oculus-adb-payload.sh"
  install -Dm644 "$HERE/rootfs/etc/oculus-adb.env" "$MNT/etc/oculus-adb.env"
  install -Dm644 "$HERE/rootfs/etc/systemd/system/oculus-adb.service" "$MNT/etc/systemd/system/oculus-adb.service"

  echo "rootfs files installed"
}

cmd_enable() {
  mountpoint -q "$MNT" || { echo "not mounted: $MNT" >&2; exit 1; }

  # Ensure USB gadget uses RNDIS (Oculus as USB host).
  ln -sfn /etc/usb-rndis.sh "$MNT/mnt/system/usb.sh"

  mkdir -p "$MNT/etc/systemd/system/multi-user.target.wants"
  ln -sfn /usr/lib/systemd/system/rndis.service \
    "$MNT/etc/systemd/system/multi-user.target.wants/rndis.service"
  ln -sfn /etc/systemd/system/oculus-adb.service \
    "$MNT/etc/systemd/system/multi-user.target.wants/oculus-adb.service"

  echo "enabled rndis.service + oculus-adb.service"
}

cmd_sync() {
  sync
  echo "sync complete"
}

cmd_unmount() {
  if mountpoint -q "$MNT"; then
    sync
    umount "$MNT"
    echo "unmounted $MNT"
  else
    echo "not mounted: $MNT"
  fi
}

case "${1:-all}" in
  mount)   cmd_mount ;;
  install) cmd_install ;;
  enable)  cmd_enable ;;
  sync)    cmd_sync ;;
  unmount) cmd_unmount ;;
  all)
    cmd_mount
    cmd_install
    cmd_enable
    cmd_sync
    echo "Done. Safely remove SD with: sudo $0 unmount"
    ;;
  *) usage; exit 1 ;;
esac

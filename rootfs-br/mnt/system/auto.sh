#!/bin/sh
# Headless ambilight autostart (runs after USB/RNDIS from S99user).
# Official docs: enable swap on 64M Duo when memory is tight (v1.1.3+ swapfile method).
if ! swapon --show 2>/dev/null | grep -q swapfile; then
  if [ ! -f /mnt/swapfile ]; then
    fallocate -l 128M /mnt/swapfile 2>/dev/null || dd if=/dev/zero of=/mnt/swapfile bs=1M count=128 2>/dev/null
    chmod 600 /mnt/swapfile 2>/dev/null
    mkswap /mnt/swapfile 2>/dev/null
  fi
  swapon /mnt/swapfile 2>/dev/null || true
fi

sleep 8
/usr/local/bin/oculus-adb-connect.sh >>/var/log/oculus-adb.log 2>&1 &

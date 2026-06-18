#!/usr/bin/env bash
set -euo pipefail

ROOT="${MILKV_ROOTFS:-/mnt/milkv-rootfs}"
SRC="${ADB_SRC:-$(dirname "$0")/adb-build}"

need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
need git
need cmake
need ninja
need riscv64-linux-gnu-gcc
need riscv64-linux-gnu-g++

[[ -d "$ROOT" ]] || { echo "rootfs not mounted at $ROOT" >&2; exit 1; }

if [[ ! -d "$SRC/.git" ]]; then
  git clone --depth 1 https://git.sr.ht/~ecc/adb "$SRC"
fi

if [[ ! -d "$SRC/lib/boringssl/.git" ]]; then
  git clone --depth 1 \
    https://salsa.debian.org/android-tools-team/android-platform-external-boringssl.git \
    "$SRC/lib/boringssl"
fi

echo "[1/3] boringssl (riscv64)"
make -C "$SRC/lib/boringssl" clean >/dev/null 2>&1 || true
make -C "$SRC/lib/boringssl" \
  CFLAGS=-fPIC CC=riscv64-linux-gnu-gcc DEB_HOST_ARCH=riscv64 -f debian/libcrypto.mk
make -C "$SRC/lib/boringssl" \
  CXXFLAGS=-fPIC CXX=riscv64-linux-gnu-g++ DEB_HOST_ARCH=riscv64 -f debian/libssl.mk

if [[ "${MILKV_STATIC:-0}" == "1" ]]; then
  echo "[1b/3] boringssl static archives"
  pushd "$SRC/lib/boringssl" >/dev/null
  riscv64-linux-gnu-ar rcs debian/out/libcrypto.a err_data.o $(find src/crypto -name '*.o')
  riscv64-linux-gnu-ar rcs debian/out/libssl.a $(find src/ssl -name '*.o')
  popd >/dev/null
fi

echo "[2/3] adb (riscv64)"
export MILKV_ROOTFS="$ROOT"
export MILKV_STATIC="${MILKV_STATIC:-0}"
cmake -S "$SRC" -B "$SRC/build-riscv64" \
  -DCMAKE_TOOLCHAIN_FILE="$SRC/cmake/linux/toolchain-riscv64.cmake" \
  -DCMAKE_BUILD_TYPE=Release
cmake --build "$SRC/build-riscv64" -j"$(nproc)"

echo "[3/3] install to rootfs"
inst() { if [[ "$(id -u)" -eq 0 ]]; then install "$@"; else sudo install "$@"; fi; }
inst -Dm755 "$SRC/build-riscv64/src/adb" "$ROOT/usr/local/bin/adb"
if [[ "${MILKV_STATIC:-0}" == "1" ]]; then
  echo "static adb — no runtime libs required"
else
  inst -d "$ROOT/opt/lib/android"
  inst -m755 "$SRC/lib/boringssl/debian/out/libcrypto.so.0" "$ROOT/opt/lib/android/"
  inst -m755 "$SRC/lib/boringssl/debian/out/libssl.so.0" "$ROOT/opt/lib/android/"
  ln -sf libcrypto.so.0 "$ROOT/opt/lib/android/libcrypto.so"
  ln -sf libssl.so.0 "$ROOT/opt/lib/android/libssl.so"
fi

file "$ROOT/usr/local/bin/adb"
echo "adb installed: $ROOT/usr/local/bin/adb"

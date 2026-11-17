#!/usr/bin/env bash
# Integrate BakaSU into the kernel. SUSFS v2.3.0 is already integrated in-tree
# (see fs/susfs.c, include/linux/susfs.h, include/linux/susfs_def.h and the
# hooks in fs/, kernel/, mm/, security/, drivers/input).
# Usage: bash setup_bakasu_susfs.sh [baka_ref]
set -euo pipefail

BAKA_REPO="https://github.com/Baka-SU/BakaSU"
BAKA_REF="${1:-main}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAKA_DIR="$ROOT/KernelSU"

if [ -f "$ROOT/fs/susfs.c" ]; then
  echo "[i] In-tree SUSFS present: $(grep -E '^#define SUSFS_VERSION' "$ROOT/include/linux/susfs.h" 2>/dev/null | head -1)"
else
  echo "[!] fs/susfs.c missing. SUSFS v2.3.0 must be integrated in-tree before building."
  exit 1
fi

# Checkout exactly the requested ref. No silent fallback to a moving master.
if [ ! -d "$BAKA_DIR/.git" ]; then
  rm -rf "$BAKA_DIR"
  git clone --depth 1 --branch "$BAKA_REF" "$BAKA_REPO" "$BAKA_DIR"
else
  git -C "$BAKA_DIR" fetch -q --depth 1 origin "$BAKA_REF"
  git -C "$BAKA_DIR" checkout -q --detach FETCH_HEAD
fi
echo "[+] BakaSU: $(git -C "$BAKA_DIR" describe --always)"

# Link BakaSU into the kernel build. The v2.3.0 port uses CONFIG_KSU_SUSFS,
# and BakaSU's Kbuild selects the SUSFS inline-hook path automatically when
# CONFIG_KSU_SUSFS is set (see KernelSU/kernel/Kbuild).
DRIVER_DIR="$ROOT/drivers"
[ -d "$ROOT/common/drivers" ] && DRIVER_DIR="$ROOT/common/drivers"
rm -f "$DRIVER_DIR/kernelsu"
# BakaSU's kernel source lives in KernelSU/kernel/; the build expects a
# drivers/kernelsu directory that resolves there (Kconfig + Kbuild/obj).
ln -s "$(basename "$BAKA_DIR")/kernel" "$DRIVER_DIR/kernelsu"

# Link the SUSFS inline-hook wiring is already in-tree; ensure the Kconfig
# symbols BakaSU's Kbuild expects are all defined.
CONFIG="$ROOT/arch/arm64/configs/atoll_defconfig"
for cfg in CONFIG_KSU CONFIG_KSU_SUSFS CONFIG_KSU_SUSFS_SUS_PATH \
           CONFIG_KSU_SUSFS_SUS_MOUNT CONFIG_KSU_SUSFS_SUS_KSTAT \
           CONFIG_KSU_SUSFS_SPOOF_UNAME CONFIG_KSU_SUSFS_ENABLE_LOG \
           CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
           CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
           CONFIG_KSU_SUSFS_OPEN_REDIRECT CONFIG_KSU_SUSFS_SUS_MAP; do
  grep -qx "$cfg=y" "$CONFIG" || printf '%s=y\n' "$cfg" >> "$CONFIG"
done

echo '[+] BakaSU integration applied cleanly (in-tree SUSFS v2.3.0).'
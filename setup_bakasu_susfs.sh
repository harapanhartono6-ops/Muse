#!/bin/bash
# ============================================================
# setup_bakasu_susfs.sh
# Integrate BakaSU (KernelSU) + SUSFS into the kernel tree.
# Usage: bash setup_bakasu_susfs.sh [baka_commit] [susfs_commit]
#   baka_commit  : BakaSU ref to use (default: main)
#   susfs_commit : susfs4ksu ref to use (default: v1.3.8 master)
# ============================================================
set -euo pipefail

BAKA_REPO="https://github.com/Baka-SU/BakaSU"
SUSFS_REPO="https://gitlab.com/simonpunk/susfs4ksu.git"
BAKA_REF="${1:-main}"
SUSFS_REF="${2:-master}"

GKI_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAKA_DIR="$GKI_ROOT/KernelSU"

# Kernel version detection
KVER="$(make -s -C "$GKI_ROOT" kernelversion 2>/dev/null || echo "unknown")"
KMAJOR="$(echo "$KVER" | cut -d. -f1)"
KMINOR="$(echo "$KVER" | cut -d. -f2)"
echo "Detected kernel version: $KVER"

# Pick the right SUSFS kernel patch for this kernel
SUSFS_PATCH=""
for candidate in "50_add_susfs_in_kernel-$KMAJOR.$KMINOR.patch" \
                "50_add_susfs_in_kernel-$KMAJOR.patch" \
                "50_add_susfs_in_kernel-${KMAJOR}-${KMINOR}.patch"; do
  : # filled below after clone
done

# ------------------------------------------------------------
# 1. Clone / update BakaSU
# ------------------------------------------------------------
if [ ! -d "$BAKA_DIR" ]; then
  git clone --depth 1 --branch "$BAKA_REF" "$BAKA_REPO" "$BAKA_DIR" 2>/dev/null \
    || { git clone --depth 1 "$BAKA_REPO" "$BAKA_DIR"; }
fi
cd "$BAKA_DIR"
# Make sure we're on the requested ref (shallow clone of that branch is fastest)
git fetch -q --depth 1 origin "$BAKA_REF" 2>/dev/null \
  && git checkout -q FETCH_HEAD \
  || { echo "[!] Could not fetch ref $BAKA_REF, keeping local $(git describe --always)"; }
echo "[+] BakaSU checked out at $(git describe --always)"

# ------------------------------------------------------------
# 2. Clone susfs4ksu (source of kernel patches + susfs.c)
# ------------------------------------------------------------
SUSFS_DIR="$GKI_ROOT/.susfs_src"
if [ ! -d "$SUSFS_DIR" ]; then
  git clone --depth 1 "$SUSFS_REPO" "$SUSFS_DIR" 2>/dev/null \
    || { echo "[!] gitlab clone failed — falling back to cached workspace copy."; \
         if [ -d /data/user/0/com.airynex.agent/files/home/workspace/susfs4ksu ]; then
           cp -r /data/user/0/com.airynex.agent/files/home/workspace/susfs4ksu "$SUSFS_DIR";
         else
           echo "[!] No susfs4ksu source available. Aborting."; exit 1;
         fi; }
fi
cd "$SUSFS_DIR"
# The master branch stays at v1.3.8 (per the repo README); for 4.14 that's
# the right baseline. Newer kernel-target branches exist but 4.14 has no
# dedicated branch, so stick with the stable release.
git log --oneline -1
echo "[+] susfs4ksu source ready"

# ------------------------------------------------------------
# 3. Integrate the BakaSU driver (like upstream setup.sh does)
# ------------------------------------------------------------
cd "$GKI_ROOT"
if [ -d "$GKI_ROOT/common/drivers" ]; then
  DRIVER_DIR="$GKI_ROOT/common/drivers"
else
  DRIVER_DIR="$GKI_ROOT/drivers"
fi

rm -f "$DRIVER_DIR/kernelsu"
ln -s "$(basename "$BAKA_DIR")" "$DRIVER_DIR/kernelsu"
touch "$DRIVER_DIR/kernelsu"

if ! grep -q "kernelsu" "$DRIVER_DIR/Makefile"; then
  echo "obj-\$(CONFIG_KSU) += kernelsu/" >> "$DRIVER_DIR/Makefile"
fi
if ! grep -q "drivers/kernelsu/Kconfig" "$DRIVER_DIR/Kconfig"; then
  echo "source \"drivers/kernelsu/Kconfig\"" >> "$DRIVER_DIR/Kconfig"
fi
echo "[+] BakaSU driver linked into $DRIVER_DIR"

# ------------------------------------------------------------
# 4. Integrate SUSFS kernel side
# ------------------------------------------------------------
cd "$SUSFS_DIR/kernel_patches"
PATCH_FILE=""
for f in 50_add_susfs_in_kernel-*.patch; do
  # match major.minor when present, otherwise major
  if [[ "$f" == *-"$KMAJOR.$KMINOR".patch* ]]; then PATCH_FILE="$f"; break; fi
done
[ -z "$PATCH_FILE" ] && for f in 50_add_susfs_in_kernel-$KMAJOR.patch; do
  [ -e "$f" ] && PATCH_FILE="$f"
done

if [ -z "$PATCH_FILE" ]; then
  echo "[!] No SUSFS patch found for kernel $KVER (available: $(ls 50_add_susfs_in_kernel-*.patch 2>/dev/null | tr '\n' ' '))"
  echo "[!] Falling back to closest-supported major version. You may need to fix hunks manually."
  # fall back to highest available <= KMAJOR, else 4.14
  BEST=""
  for f in 50_add_susfs_in_kernel-*.patch; do
    v="$(echo "$f" | grep -oE '[0-9]+\.[0-9]+$' | head -1)"
    [ -z "$v" ] && continue
    fv="$(echo "$v" | cut -d. -f1)"
    if [ "$fv" -le "$KMAJOR" ]; then
      if [ -z "$BEST" ] || [ "$(echo "$v > $BEST" | bc -l 2>/dev/null)" = "1" ]; then BEST="$v"; fi
    fi
  done
  [ -n "$BEST" ] && PATCH_FILE="50_add_susfs_in_kernel-$BEST.patch"
fi

if [ -n "$PATCH_FILE" ]; then
  echo "[+] Applying SUSFS kernel patch: $PATCH_FILE"
  # Clean any previously applied susfs changes to make re-runs safe
  rm -f "$GKI_ROOT/fs/susfs.c" "$GKI_ROOT/include/linux/susfs.h" "$GKI_ROOT/fs/open.c.rej"
  # Apply, but do not hard-fail: on 4.14 several hunks of the upstream patch
  # are expected to fail (fuzz/offset); we apply the clean hunks and the
  # failed hunks are recorded as .rej files for manual fixing. The BakaSU
  # Kbuild only hard-fails when fs/susfs.c is missing entirely, which we
  # handle by copying it explicitly below.
  if ! patch -p1 -d "$GKI_ROOT" --forward -i "$SUSFS_DIR/kernel_patches/$PATCH_FILE"; then
    echo "[!] Some SUSFS hunks failed — check for .rej files in $GKI_ROOT and fix manually if the build breaks."
    find "$GKI_ROOT" -maxdepth 2 -name "*.rej" -not -path "*/KernelSU/*" -not -path "*/.susfs_src/*" | sed 's/^/    /'
  fi
else
  echo "[!] Could not determine a SUSFS patch file. Aborting."
  exit 1
fi

# Copy susfs.c / susfs.h (the patch adds obj- lines, source must exist)
cp -f "$SUSFS_DIR/kernel_patches/fs/susfs.c" "$GKI_ROOT/fs/susfs.c"
cp -f "$SUSFS_DIR/kernel_patches/include/linux/susfs.h" "$GKI_ROOT/include/linux/susfs.h"
echo "[+] susfs.c / susfs.h copied into kernel tree"

# ------------------------------------------------------------
# 5. Enable SUSFS support in the BakaSU driver
#
# The susfs4ksu v1.3.8 KSU patch predates the BakaSU kernel rework
# (kernel/ksu.c no longer exists, selinux/rules.c layout changed).
# BakaSU main already ships CONFIG_KSU_SUSFS natively, so that patch
# is only applied when it is clean; otherwise we rely on BakaSU's
# built-in support.
# ------------------------------------------------------------
KSU_PATCH="$SUSFS_DIR/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch"
if [ -f "$KSU_PATCH" ]; then
  cd "$BAKA_DIR"
  if patch -p1 --forward --dry-run < "$KSU_PATCH" > /dev/null 2>&1; then
    patch -p1 --forward < "$KSU_PATCH"
    echo "[+] BakaSU SUSFS patch applied"
  else
    echo "[i] 10_enable_susfs_for_ksu.patch does not apply cleanly to BakaSU $(git describe --always)"
    echo "    — relying on BakaSU's native CONFIG_KSU_SUSFS support instead."
    rm -f selinux/rules.c.rej kernel/selinux/rules.c.rej
  fi
else
  echo "[i] No 10_enable_susfs_for_ksu.patch found — assuming BakaSU already supports SUSFS"
fi

# ------------------------------------------------------------
# 6. Enable configs
# ------------------------------------------------------------
CONFIG_FILE="$GKI_ROOT/arch/arm64/configs/atoll_defconfig"
if [ -f "$CONFIG_FILE" ]; then
  for cfg in "CONFIG_KSU=y" "CONFIG_KSU_SUSFS=y" \
             "CONFIG_KSU_SUSFS_SUS_PATH=y" "CONFIG_KSU_SUSFS_SUS_MOUNT=y" \
             "CONFIG_KSU_SUSFS_SUS_KSTAT=y" "CONFIG_KSU_SUSFS_SPOOF_UNAME=y" \
             "CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y"; do
    if ! grep -qx "$cfg" "$CONFIG_FILE"; then
      echo "$cfg" >> "$CONFIG_FILE"
      echo "[+] Enabled $cfg"
    fi
  done
fi

echo
echo "=== Setup complete ==="
echo "Next: run ./build.sh to compile."

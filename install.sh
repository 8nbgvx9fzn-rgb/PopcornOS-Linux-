#!/usr/bin/env bash
set -euo pipefail

# ========= CONFIG =========
DISK="/dev/nvme0n1"          # target disk (WILL BE WIPED)
LABEL="MINISHELL"

# Kernel: Arch Linux package (x86_64)
ARCH_MIRROR_BASE="https://ro.arch.niranjan.co/core-testing/os/x86_64"
ARCH_LINUX_PKG="linux-6.18.9.arch1-2-x86_64.pkg.tar.zst"

# BusyBox: Debian static busybox (amd64)
DEBIAN_POOL_BASE="https://ftp.debian.org/debian/pool/main/b/busybox"
DEBIAN_BUSYBOX_DEB="busybox-static_1.35.0-4+b7_amd64.deb"

# ========= HELPERS =========
need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing required tool: $1"; exit 1; }; }

echo "==> Checking required tools"
# partition/format/boot
need sgdisk
need mkfs.fat
need mount
need umount
need efibootmgr
need partprobe || true
need udevadm || true
# download/extract/build initramfs
need curl
need zstd
need tar
need cpio
need gzip
need ar

[[ -b "$DISK" ]] || { echo "ERROR: $DISK is not a block device"; exit 1; }

echo "==> WARNING: This will ERASE ${DISK}"
echo "    (Ctrl-C to abort)"
sleep 2

# ========= PREP =========
umount -R /mnt 2>/dev/null || true
mkdir -p /mnt

WORK="$(mktemp -d)"
cleanup() { umount -R /mnt 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

# ========= PARTITION =========
echo "==> Partitioning disk (GPT: EFI only)"
sgdisk --zap-all "$DISK"
sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"EFI" "$DISK"
sync
partprobe "$DISK" 2>/dev/null || true
udevadm settle 2>/dev/null || true

if [[ "$DISK" == /dev/nvme* ]]; then
  EFI="${DISK}p1"
else
  EFI="${DISK}1"
fi

echo "==> Formatting EFI partition: $EFI"
mkfs.fat -F32 "$EFI"

echo "==> Mounting EFI to /mnt"
mount "$EFI" /mnt
mkdir -p /mnt/EFI/Linux

# ========= DOWNLOAD KERNEL =========
echo "==> Downloading kernel package from Arch mirror"
KPKG="${WORK}/${ARCH_LINUX_PKG}"
curl -fL --retry 5 --retry-delay 2 -o "$KPKG" "${ARCH_MIRROR_BASE}/${ARCH_LINUX_PKG}"

echo "==> Extracting kernel package"
KEX="${WORK}/arch-kernel"
mkdir -p "$KEX"
# Arch pkg is .tar.zst
tar --use-compress-program=unzstd -xf "$KPKG" -C "$KEX"

# Arch linux package typically includes /boot/vmlinuz-linux
VMLINUX_PATH=""
if [[ -f "$KEX/boot/vmlinuz-linux" ]]; then
  VMLINUX_PATH="$KEX/boot/vmlinuz-linux"
else
  # fallback: find any vmlinuz*
  VMLINUX_PATH="$(find "$KEX" -type f -name 'vmlinuz*' | head -n 1 || true)"
fi
[[ -n "$VMLINUX_PATH" && -f "$VMLINUX_PATH" ]] || { echo "ERROR: could not find vmlinuz in kernel package"; exit 1; }

echo "==> Installing kernel to EFI"
cp -f "$VMLINUX_PATH" /mnt/EFI/Linux/vmlinuz.efi

# ========= DOWNLOAD BUSYBOX STATIC =========
echo "==> Downloading static BusyBox from Debian pool"
BDEB="${WORK}/${DEBIAN_BUSYBOX_DEB}"
curl -fL --retry 5 --retry-delay 2 -o "$BDEB" "${DEBIAN_POOL_BASE}/${DEBIAN_BUSYBOX_DEB}"

echo "==> Extracting BusyBox from .deb"
BEX="${WORK}/debian-busybox"
mkdir -p "$BEX"
(
  cd "$BEX"
  ar x "$BDEB"   # extracts control.tar.*, data.tar.*, debian-binary
)

DATA_TAR="$(ls -1 "$BEX"/data.tar.* | head -n 1 || true)"
[[ -n "$DATA_TAR" && -f "$DATA_TAR" ]] || { echo "ERROR: could not find data.tar.* inside .deb"; exit 1; }

ROOTFS="${WORK}/initramfs"
mkdir -p "$ROOTFS"
tar -xf "$DATA_TAR" -C "$ROOTFS"

# Debian busybox-static installs /bin/busybox (commonly)
BUSYBOX_BIN=""
if [[ -f "$ROOTFS/bin/busybox" ]]; then
  BUSYBOX_BIN="$ROOTFS/bin/busybox"
else
  BUSYBOX_BIN="$(find "$ROOTFS" -type f -name busybox | head -n 1 || true)"
fi
[[ -n "$BUSYBOX_BIN" && -f "$BUSYBOX_BIN" ]] || { echo "ERROR: could not locate busybox binary after extracting"; exit 1; }

# ========= BUILD MIN INITRAMFS =========
echo "==> Building minimal initramfs"
INITDIR="${WORK}/initdir"
mkdir -p "$INITDIR"/{bin,proc,sys,dev}

cp -f "$BUSYBOX_BIN" "$INITDIR/bin/busybox"
chmod +x "$INITDIR/bin/busybox"

cat > "$INITDIR/init" <<'INIT'
#!/bin/busybox sh
/bin/busybox --install -s

mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev || mkdir -p /dev

echo
echo "Minimal Linux booted (initramfs-only)."
echo "Try: ls, dmesg, mount, cat /proc/cpuinfo"
exec sh
INIT
chmod +x "$INITDIR/init"

( cd "$INITDIR" && find . -print0 | cpio --null -ov --format=newc ) | gzip -9 > /mnt/EFI/Linux/initramfs.img
sync

# ========= UEFI BOOT ENTRY =========
echo "==> Creating UEFI boot entry (EFI-stub kernel)"
# -l path is relative to EFI system partition root, backslashes required
# -u passes kernel command line; initrd path is also relative to EFI partition root
efibootmgr -c \
  -d "$DISK" -p 1 \
  -L "$LABEL" \
  -l '\EFI\Linux\vmlinuz.efi' \
  -u "initrd=\EFI\Linux\initramfs.img rdinit=/init quiet"

echo
echo "==> DONE."
echo "Reboot and choose '$LABEL' in your firmware boot menu."

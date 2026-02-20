#!/bin/bash
set -euo pipefail

# Ultra-minimal "kernel + initramfs shell" installer for a UEFI device.
# FIX: Avoid creating UEFI NVRAM boot entries ("Linux Boot Manager") by NOT installing a boot manager.
# Instead, build a single Unified Kernel Image (UKI) and place it at the UEFI fallback path:
#   \EFI\BOOT\BOOTX64.EFI
# Most embedded/appliance UEFI firmwares will boot this automatically without touching NVRAM.

PACKAGES=(linux busybox kmod linux-firmware systemd binutils)
DISK="/dev/nvme0n1"   # whole disk
LABEL="MINISHELL"

echo "==> Safety checks"
[[ -b "$DISK" ]] || { echo "ERROR: $DISK is not a block device"; exit 1; }
if [[ "$DISK" =~ p[0-9]+$ ]] || [[ "$DISK" =~ [0-9]+$ && "$DISK" == /dev/sd* ]]; then
  echo "ERROR: DISK must be a whole disk (e.g. /dev/nvme0n1 or /dev/sda), not a partition"
  exit 1
fi

echo "==> Unmounting /mnt"
swapoff -a || true
umount -R /mnt 2>/dev/null || true

echo "==> Partitioning disk (GPT: EFI only)"
sgdisk --zap-all "$DISK"
sgdisk -n 1:0:+1024M -t 1:ef00 -c 1:"EFI" "$DISK"

sync
partprobe "$DISK" || true
udevadm settle

if [[ "$DISK" == /dev/nvme* ]]; then
  EFI="${DISK}p1"
else
  EFI="${DISK}1"
fi

echo "==> Waiting for EFI partition: $EFI"
for i in {1..20}; do
  [[ -b "$EFI" ]] && break
  sleep 0.2
  udevadm settle
done
[[ -b "$EFI" ]] || { echo "ERROR: partition not found"; lsblk; exit 1; }

echo "==> Formatting + mounting EFI (FAT32)"
mkfs.fat -F32 -n EFI "$EFI"
mount "$EFI" /mnt

# Keep these for debugging/inspection (optional)
mkdir -p /mnt/EFI/Linux

# We'll use a temporary staging root to install packages needed to build the UKI.
STAGE="/tmp/stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
pacstrap -K "$STAGE" "${PACKAGES[@]}"

echo "==> Building ultra-minimal initramfs (busybox + libs + /init)"
INITRAMFS_DIR="/tmp/initramfs.$$"
rm -rf "$INITRAMFS_DIR"
mkdir -p "$INITRAMFS_DIR"/{bin,sbin,etc,proc,sys,dev,usr/bin,usr/sbin,lib,lib64,run,tmp,root}

# Copy busybox
cp -a "$STAGE/usr/bin/busybox" "$INITRAMFS_DIR/bin/busybox"

# Create applet symlinks we care about (add more if you want)
for a in sh mount umount cat echo ls dmesg mkdir mknod uname sleep; do
  ln -sf /bin/busybox "$INITRAMFS_DIR/bin/$a"
done

# Minimal /init: mount pseudo-filesystems and drop to shell
cat > "$INITRAMFS_DIR/init" <<'INIT'
#!/bin/sh
mount -t proc  proc  /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true

echo
echo "=== minishell initramfs ==="
echo "Kernel: $(uname -a)"
echo "Dropping to /bin/sh..."
echo

exec /bin/sh
INIT
chmod +x "$INITRAMFS_DIR/init"

# Copy dynamic linker + libs needed by busybox (Arch busybox is usually dynamic)
echo "==> Copying shared libs for busybox"
mapfile -t libs < <(ldd "$STAGE/usr/bin/busybox" | awk '
  $2 == "=>" { print $3 }
  $1 ~ /^\// { print $1 }
' | sort -u)

for f in "${libs[@]}"; do
  [[ -f "$f" ]] || continue
  dest="$INITRAMFS_DIR${f}"
  mkdir -p "$(dirname "$dest")"
  cp -a "$f" "$dest"
done

# Also copy the dynamic loader explicitly if ldd didn’t list it plainly
for loader in /lib64/ld-linux-*.so.* /lib/ld-linux-*.so.*; do
  if [[ -f "$loader" ]]; then
    mkdir -p "$INITRAMFS_DIR$(dirname "$loader")"
    cp -a "$loader" "$INITRAMFS_DIR$loader"
  fi
done

echo "==> Creating initramfs image"
(
  cd "$INITRAMFS_DIR"
  find . -print0 | cpio --null -ov --format=newc
) | gzip -9 > /mnt/EFI/Linux/initramfs-minishell.img

echo "==> Copying kernel (for reference) + building UKI at UEFI fallback path"
cp -a "$STAGE/boot/vmlinuz-linux" /mnt/EFI/Linux/vmlinuz-linux

# Build a Unified Kernel Image (UKI) using systemd's EFI stub + objcopy.
# This avoids boot managers and (critically) avoids creating UEFI NVRAM boot entries.
STUB="$STAGE/usr/lib/systemd/boot/efi/linuxx64.efi.stub"
OBJCOPY="$STAGE/usr/bin/objcopy"

[[ -f "$STUB" ]] || { echo "ERROR: systemd EFI stub not found at $STUB"; exit 1; }
[[ -x "$OBJCOPY" ]] || { echo "ERROR: objcopy not found at $OBJCOPY"; exit 1; }

CMDLINE_FILE="/tmp/cmdline.$$"
OSREL_FILE="/tmp/os-release.$$"

# Kernel command line (no root= needed; initramfs drops to shell)
echo "quiet loglevel=3" > "$CMDLINE_FILE"

# Minimal os-release metadata (optional but common in UKIs)
cat > "$OSREL_FILE" <<EOF
NAME="$LABEL"
ID=minishell
PRETTY_NAME="$LABEL (UKI)"
EOF

mkdir -p /mnt/EFI/BOOT

# UKI section layout values are conventional; they just need to not overlap.
# These values are commonly used with systemd's EFI stub.
"$OBJCOPY" \
  --add-section .osrel="$OSREL_FILE"     --change-section-vma .osrel=0x20000 \
  --add-section .cmdline="$CMDLINE_FILE" --change-section-vma .cmdline=0x30000 \
  --add-section .linux="$STAGE/boot/vmlinuz-linux" --change-section-vma .linux=0x2000000 \
  --add-section .initrd=/mnt/EFI/Linux/initramfs-minishell.img --change-section-vma .initrd=0x3000000 \
  "$STUB" /mnt/EFI/BOOT/BOOTX64.EFI

sync

echo "==> Done. Unmounting."
umount -R /mnt
rm -rf "$INITRAMFS_DIR" "$STAGE" "$CMDLINE_FILE" "$OSREL_FILE"

echo
echo "==> Install complete."
echo "==> This build does NOT install a boot manager and does NOT create UEFI NVRAM entries."
echo "==> Firmware should boot the fallback loader: \\EFI\\BOOT\\BOOTX64.EFI"
echo "==> Reboot when ready."

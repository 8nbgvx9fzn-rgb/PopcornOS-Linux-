#!/bin/bash
pacnan -Sy --no-confirm cpio

set -euo pipefail

PACKAGES=(linux busybox kmod linux-firmware)
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

echo "==> Removing lingering UEFI NVRAM entries (best-effort)"
if command -v efibootmgr >/dev/null 2>&1; then
  # Remove prior systemd-boot entries (commonly labeled \"Linux Boot Manager\") so they don't accumulate.
  # NVRAM lives on the motherboard, so wiping the disk does not remove these.
  efibootmgr -v | sed -n 's/^Boot\([0-9A-Fa-f]\+\)\* .*Linux Boot Manager.*/\1/p' | while read -r id; do
    [[ -n "$id" ]] || continue
    efibootmgr -b "$id" -B || true
  done
else
  echo "    (efibootmgr not found; skipping NVRAM cleanup)"
fi

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
mkdir -p /mnt/EFI/Linux

# We'll use a temporary staging root to install packages and build initramfs.
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
# This is the part that makes the initramfs actually boot reliably.
echo "==> Copying shared libs for busybox"
mapfile -t libs < <(ldd "$STAGE/usr/bin/busybox" | awk '
  $2 == "=>" { print $3 }
  $1 ~ /^\// { print $1 }
' | sort -u)

for f in "${libs[@]}"; do
  [[ -f "$f" ]] || continue
  # Preserve lib64 vs lib layout
  dest="$INITRAMFS_DIR${f}"
  mkdir -p "$(dirname "$dest")"
  cp -a "$f" "$dest"
done

# Also copy the dynamic loader explicitly if ldd didn’t list it plainly
# (common paths: /lib64/ld-linux-x86-64.so.2, /lib/ld-linux-*.so.*)
for loader in /lib64/ld-linux-*.so.* /lib/ld-linux-*.so.*; do
  if [[ -f "$loader" ]]; then
    mkdir -p "$INITRAMFS_DIR$(dirname "$loader")"
    cp -a "$loader" "$INITRAMFS_DIR$loader"
  fi
done

echo "==> Copying kernel + building initramfs image"
# Kernel image from staging (Arch installs it in /boot within the staged root)
cp -a "$STAGE/boot/vmlinuz-linux" /mnt/EFI/Linux/vmlinuz-linux

# Create initramfs cpio (gzip for compatibility; you can use xz if you want)
(
  cd "$INITRAMFS_DIR"
  find . -print0 | cpio --null -ov --format=newc
) | gzip -9 > /mnt/EFI/Linux/initramfs-minishell.img

echo "==> Installing direct UEFI boot (no NVRAM entries): Unified Kernel Image at fallback path"
# This avoids creating \"Linux Boot Manager\" entries in NVRAM and boots directly via the UEFI fallback path.
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)
    BOOT_EFI="BOOTX64.EFI"
    STUB="/usr/lib/systemd/boot/efi/linuxx64.efi.stub"
    ;;
  aarch64|arm64)
    BOOT_EFI="BOOTAA64.EFI"
    STUB="/usr/lib/systemd/boot/efi/linuxaa64.efi.stub"
    ;;
  *)
    echo "ERROR: unsupported arch: $ARCH (extend script with the right UEFI fallback name + stub path)"
    exit 1
    ;;
esac

command -v objcopy >/dev/null 2>&1 || { echo "ERROR: objcopy not found (install binutils in the live environment)"; exit 1; }
[[ -f "$STUB" ]] || { echo "ERROR: systemd EFI stub not found at $STUB"; exit 1; }

echo "==> Building UKI (kernel+initramfs+cmdline) and placing it at /EFI/BOOT/$BOOT_EFI"
mkdir -p /mnt/EFI/BOOT
CMDLINE_FILE="$(mktemp)"
OSREL_FILE="$(mktemp)"
echo "quiet loglevel=3" > "$CMDLINE_FILE"
cat > "$OSREL_FILE" <<'EOF'
NAME=MINISHELL
ID=minishell
VERSION=1
EOF

# Build UKI to the UEFI removable-media fallback location.
# Firmware can boot this without a Boot#### NVRAM entry.
objcopy \
  --add-section .osrel="$OSREL_FILE"    --change-section-vma .osrel=0x20000 \
  --add-section .cmdline="$CMDLINE_FILE" --change-section-vma .cmdline=0x30000 \
  --add-section .linux="/mnt/EFI/Linux/vmlinuz-linux" --change-section-vma .linux=0x2000000 \
  --add-section .initrd="/mnt/EFI/Linux/initramfs-minishell.img" --change-section-vma .initrd=0x3000000 \
  "$STUB" "/mnt/EFI/BOOT/$BOOT_EFI"

rm -f "$CMDLINE_FILE" "$OSREL_FILE" || true

echo "==> UKI installed. Firmware should boot /EFI/BOOT/$BOOT_EFI directly."

echo "==> Done. Unmounting."
umount -R /mnt
rm -rf "$INITRAMFS_DIR" "$STAGE"

echo
echo "==> Install complete. Reboot when ready."

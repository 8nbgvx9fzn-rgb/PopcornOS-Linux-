#!/bin/bash
set -euo pipefail

DISK="/dev/nvme0n1"       # whole disk
LABEL="MINISHELL"
VMLINUX_SRC="/boot/vmlinuz-linux"   # adjust: where your *current* kernel image is

echo "==> Safety checks"
[[ -b "$DISK" ]] || { echo "ERROR: $DISK is not a block device"; exit 1; }

umount -R /mnt 2>/dev/null || true

echo "==> Partitioning disk (GPT: EFI only)"
sgdisk --zap-all "$DISK"
sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"EFI" "$DISK"
sync
partprobe "$DISK" || true
udevadm settle

if [[ "$DISK" == /dev/nvme* ]]; then
  EFI="${DISK}p1"
else
  EFI="${DISK}1"
fi

echo "==> Formatting EFI partition"
mkfs.fat -F32 "$EFI"

echo "==> Mounting EFI"
mkdir -p /mnt
mount "$EFI" /mnt
mkdir -p /mnt/EFI/Linux

echo "==> Copying kernel"
[[ -f "$VMLINUX_SRC" ]] || { echo "ERROR: kernel not found at $VMLINUX_SRC"; exit 1; }
cp -f "$VMLINUX_SRC" /mnt/EFI/Linux/vmlinuz.efi

echo "==> Building tiny initramfs (BusyBox + /init)"
WORKDIR="$(mktemp -d)"
mkdir -p "$WORKDIR"/{bin,proc,sys,dev}

# Prefer a STATIC busybox if available.
# On many distros it's /bin/busybox; but it may be dynamically linked.
# For ultra-minimal, use a statically linked busybox.
BUSYBOX_SRC="$(command -v busybox || true)"
[[ -n "$BUSYBOX_SRC" ]] || { echo "ERROR: busybox not found in PATH"; exit 1; }
cp -f "$BUSYBOX_SRC" "$WORKDIR/bin/busybox"
chmod +x "$WORKDIR/bin/busybox"

cat > "$WORKDIR/init" <<'INIT'
#!/bin/busybox sh
/bin/busybox --install -s

mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev || mkdir -p /dev

echo
echo "Booted minimal Linux (initramfs only)."
echo "Type 'poweroff -f' or 'reboot -f' if available."
exec sh
INIT
chmod +x "$WORKDIR/init"

# Pack initramfs
( cd "$WORKDIR" && find . -print0 | cpio --null -ov --format=newc ) | gzip -9 > /mnt/EFI/Linux/initramfs.img
rm -rf "$WORKDIR"

sync

echo "==> Creating UEFI boot entry (EFI stub kernel)"
# You may need to adjust -p and the loader path depending on your firmware expectations.
# The loader path is from the EFI partition root.
efibootmgr -c \
  -d "$DISK" -p 1 \
  -L "$LABEL" \
  -l '\EFI\Linux\vmlinuz.efi' \
  -u "initrd=\EFI\Linux\initramfs.img rdinit=/init quiet"

echo
echo "==> Done."
echo "Reboot and pick '$LABEL' in firmware boot menu."

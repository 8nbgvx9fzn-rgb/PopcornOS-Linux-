#!/bin/bash
set -euo pipefail

DISK="/dev/nvme0n1"   # whole disk
ESP_SIZE="+512M"

echo "==> Safety checks"
[[ -b "$DISK" ]] || { echo "ERROR: $DISK is not a block device"; exit 1; }
if [[ "$DISK" =~ p[0-9]+$ ]] || [[ "$DISK" =~ [0-9]+$ && "$DISK" == /dev/sd* ]]; then
  echo "ERROR: DISK must be the whole disk (e.g. /dev/nvme0n1 or /dev/sda), not a partition"
  exit 1
fi

echo "==> Unmounting anything at /mnt"
swapoff -a || true
umount -R /mnt 2>/dev/null || true

echo "==> Partitioning disk (GPT: EFI only)"
sgdisk --zap-all "$DISK"
sgdisk -n 1:0:${ESP_SIZE} -t 1:ef00 "$DISK"

sync
partprobe "$DISK" || true
udevadm settle

if [[ "$DISK" == /dev/nvme* ]]; then
  EFI="${DISK}p1"
else
  EFI="${DISK}1"
fi

echo "==> Waiting for partition to appear: $EFI"
for i in {1..40}; do
  [[ -b "$EFI" ]] && break
  sleep 0.2
  udevadm settle
done
[[ -b "$EFI" ]] || { echo "ERROR: EFI partition not found"; lsblk; exit 1; }

echo "==> Creating filesystem (FAT32 ESP)"
mkfs.fat -F32 "$EFI"

echo "==> Mounting ESP at /mnt/efi"
mkdir -p /mnt/efi
mount "$EFI" /mnt/efi

# We'll build a tiny Arch userspace in tmpfs just long enough to create vmlinuz+initramfs
echo "==> Creating tmpfs staging root at /mnt/root"
mkdir -p /mnt/root
mount -t tmpfs -o size=2G tmpfs /mnt/root

echo "==> Installing only what we need into staging root"
# linux => kernel + mkinitcpio presets
# busybox => shell inside initramfs
pacstrap -K /mnt/root linux busybox

echo "==> Building initramfs that boots directly to a BusyBox shell"
arch-chroot /mnt/root /bin/bash -e <<'EOF'
set -euo pipefail

# Minimal init that mounts basic pseudo-filesystems, then drops to a shell.
cat > /init <<'INIT'
#!/bin/sh
mount -t proc  proc /proc
mount -t sysfs sys  /sys
mount -t devtmpfs dev /dev 2>/dev/null || true
echo
echo "Tiny Linux: initramfs BusyBox shell"
exec /usr/bin/busybox sh
INIT
chmod +x /init

# Minimal mkinitcpio config:
# - include /init and busybox binary in the initramfs
# - keep only essential hooks so the initramfs can run and you have a working console/keyboard
cat > /etc/mkinitcpio.conf <<'MK'
MODULES=()
BINARIES=(/usr/bin/busybox)
FILES=(/init)
HOOKS=(base udev autodetect modconf keyboard keymap consolefont)
COMPRESSION="zstd"
MK

# Generate initramfs (creates /boot/initramfs-linux.img) using our config
mkinitcpio -c /etc/mkinitcpio.conf -g /boot/initramfs-linux.img
EOF

echo "==> Installing systemd-boot to the ESP"
# bootctl is available on the Arch ISO environment; install directly to the mounted ESP
bootctl --esp-path=/mnt/efi install

echo "==> Copying kernel + initramfs to the ESP (only persistent artifacts)"
# Put kernel/initramfs in the ESP root for simple systemd-boot entries
cp -f /mnt/root/boot/vmlinuz-linux /mnt/efi/vmlinuz-linux
cp -f /mnt/root/boot/initramfs-linux.img /mnt/efi/initramfs-linux.img

echo "==> Writing systemd-boot loader entry (no root=..., boots initramfs shell)"
mkdir -p /mnt/efi/loader/entries

cat > /mnt/efi/loader/loader.conf <<'LOADER'
default tiny
timeout 0
editor no
LOADER

cat > /mnt/efi/loader/entries/tiny.conf <<'ENTRY'
title   Tiny initramfs shell
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options rdinit=/init quiet loglevel=3
ENTRY

echo "==> Verification"
echo "--- loader entry ---"
cat /mnt/efi/loader/entries/tiny.conf
echo "--- ESP contents ---"
ls -lah /mnt/efi | sed -n '1,200p'

echo "==> Cleanup"
umount -R /mnt/root
umount -R /mnt/efi

echo
echo "==> Done. Reboot to get a BusyBox shell with no users, no services, no root filesystem."
reboot

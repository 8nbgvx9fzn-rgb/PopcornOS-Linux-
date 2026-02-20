#!/bin/bash
set -euo pipefail

DISK="/dev/nvme0n1"   # <-- set this correctly (whole disk, not a partition)
HOSTNAME="embedded"

echo "==> Safety checks"
[[ -b "$DISK" ]] || { echo "ERROR: $DISK is not a block device"; exit 1; }

# Refuse to run if DISK looks like a partition
if [[ "$DISK" =~ p[0-9]+$ ]] || [[ "$DISK" =~ [0-9]+$ && "$DISK" == /dev/sd* ]]; then
  echo "ERROR: DISK must be the whole disk (e.g. /dev/nvme0n1 or /dev/sda), not a partition"
  exit 1
fi

echo "==> Unmounting anything at /mnt"
swapoff -a || true
umount -R /mnt 2>/dev/null || true

echo "==> Partitioning disk (GPT: EFI + root)"
sgdisk --zap-all "$DISK"
sgdisk -n 1:0:+512M -t 1:ef00 "$DISK"
sgdisk -n 2:0:0     -t 2:8300 "$DISK"

sync
partprobe "$DISK" || true
udevadm settle

# NVMe partitions are p1/p2; SATA/SCSI disks are 1/2
if [[ "$DISK" == /dev/nvme* ]]; then
  EFI="${DISK}p1"
  ROOT="${DISK}p2"
else
  EFI="${DISK}1"
  ROOT="${DISK}2"
fi

echo "==> Waiting for partitions to appear: $EFI and $ROOT"
for i in {1..20}; do
  [[ -b "$EFI" && -b "$ROOT" ]] && break
  sleep 0.2
  udevadm settle
done
[[ -b "$EFI" && -b "$ROOT" ]] || { echo "ERROR: partitions not found"; lsblk; exit 1; }

echo "==> Creating filesystems"
mkfs.fat -F32 "$EFI"
mkfs.ext4 -F "$ROOT"

echo "==> Mounting target"
mount "$ROOT" /mnt
mkdir -p /mnt/boot
mount "$EFI" /mnt/boot

echo "==> Installing base system"
pacstrap -K /mnt linux linux-firmware systemd

echo "==> Generating fstab"
genfstab -U /mnt >> /mnt/etc/fstab

echo "==> Capturing ROOT PARTUUID"
ROOT_PARTUUID="$(blkid -s PARTUUID -o value "$ROOT")"
[[ -n "$ROOT_PARTUUID" ]] || { echo "ERROR: could not read PARTUUID for $ROOT"; exit 1; }
echo "    ROOT_PARTUUID=$ROOT_PARTUUID"

echo "==> Configuring system in chroot"
arch-chroot /mnt /bin/bash -e <<EOF
set -euo pipefail

echo "$HOSTNAME" > /etc/hostname

ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc || true

# Ensure root is usable in emergencies (no password, unlocked).
# For a closed ecosystem, this is fine; otherwise set a password instead.
passwd -d root || true
passwd -u root || true

# Install systemd-boot
bootctl install

cat > /boot/loader/loader.conf <<LOADER
default arch
timeout 0
editor no
LOADER

cat > /boot/loader/entries/arch.conf <<ENTRY
title   Embedded Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options root=PARTUUID=$ROOT_PARTUUID rw quiet loglevel=3
ENTRY

# Success indicator on tty2 so tty1 remains a console
cat > /usr/local/bin/success.sh <<'SCRIPT'
#!/bin/sh
clear
printf "\033[42m\033[30m"
printf "\n\n   INSTALL SUCCESSFUL   \n\n"
printf "   KERNEL BOOTED OK     \n\n"
printf "   (tty1 is console)    \n\n"
printf "\033[0m"
sleep infinity
SCRIPT
chmod +x /usr/local/bin/success.sh

cat > /etc/systemd/system/success@tty2.service <<SERVICE
[Unit]
Description=Visual success indicator (tty2)
After=multi-user.target

[Service]
ExecStart=/usr/local/bin/success.sh
StandardInput=tty
StandardOutput=tty
TTYPath=/dev/tty2

[Install]
WantedBy=multi-user.target
SERVICE

systemctl enable success@tty2.service

# Keep getty on tty1 so you can always recover locally
systemctl enable getty@tty1.service

EOF

echo "==> Post-install verification"
echo "Boot entry written as:"
cat /mnt/boot/loader/entries/arch.conf

echo
echo "==> Verifying that PARTUUID exists on target disk"
blkid | grep -F "$ROOT_PARTUUID" || { echo "ERROR: PARTUUID not found in blkid output"; blkid; exit 1; }

echo
echo "==> Install complete. Rebooting in 5 seconds."
sleep 5
reboot

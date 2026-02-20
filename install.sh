#!/bin/bash
set -euo pipefail

DISK="/dev/nvme0"

echo "==> Partitioning disk"
sgdisk --zap-all "$DISK"
sgdisk -n 1:0:+512M -t 1:ef00 "$DISK"
sgdisk -n 2:0:0     -t 2:8300 "$DISK"

partprobe "$DISK"

mkfs.fat -F32 "${DISK}1"
mkfs.ext4 -F "${DISK}2"

mount "${DISK}2" /mnt
mkdir -p /mnt/boot
mount "${DISK}1" /mnt/boot

echo "==> Installing base system"
pacstrap -K /mnt linux linux-firmware systemd

genfstab -U /mnt >> /mnt/etc/fstab

echo "==> Configuring system"
arch-chroot /mnt /bin/bash <<'EOF'
set -e

ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc || true

echo "embedded" > /etc/hostname

# No users, no passwords, no login
systemctl disable getty@tty1.service

# Minimal bootloader
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
options root=PARTUUID=$(blkid -s PARTUUID -o value /dev/sda2) rw quiet loglevel=3
ENTRY

# Success indicator service
cat > /usr/local/bin/success.sh <<'SCRIPT'
#!/bin/sh
clear
printf "\033[42m\033[30m"
printf "\n\n   INSTALL SUCCESSFUL   \n\n"
printf "   KERNEL BOOTED OK     \n\n"
printf "\033[0m"
sleep infinity
SCRIPT
chmod +x /usr/local/bin/success.sh

cat > /etc/systemd/system/success.service <<SERVICE
[Unit]
Description=Visual success indicator
After=basic.target

[Service]
ExecStart=/usr/local/bin/success.sh
StandardInput=tty
StandardOutput=tty
TTYPath=/dev/tty1

[Install]
WantedBy=default.target
SERVICE

systemctl enable success.service
EOF

echo "==> Install complete. Rebooting in 5 seconds."
sleep 5
reboot

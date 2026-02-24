#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# HARD-CODED TARGETS (edit me)
# -----------------------------
DISK="/dev/nvme0n1"          # e.g. /dev/sda or /dev/nvme0n1
HOSTNAME="archbox"
USERNAME="archuser"
TIMEZONE="America/Phoenix"
LOCALE="en_US.UTF-8"
KEYMAP="us"

# Partition sizes
EFI_SIZE="512MiB"
SWAP_SIZE="0"               # set to e.g. 8GiB, or "0" for none

# Packages
BASE_PKGS=(base linux linux-firmware sudo networkmanager vim)

# -----------------------------
# Safety / environment checks
# -----------------------------
if [[ $EUID -ne 0 ]]; then
  echo "Run as root (you are in the live ISO, so: sudo ./script.sh)" >&2
  exit 1
fi

if [[ ! -b "$DISK" ]]; then
  echo "Disk $DISK not found." >&2
  lsblk
  exit 1
fi

# Don't allow targeting the live USB itself (best-effort).
LIVE_DEV="$(findmnt -no SOURCE /run/archiso/bootmnt || true)"
if [[ -n "${LIVE_DEV}" && "${LIVE_DEV}" == ${DISK}* ]]; then
  echo "Refusing to install to what appears to be the live media: $LIVE_DEV" >&2
  exit 1
fi

echo "About to WIPE and install Arch to: $DISK"
lsblk "$DISK"
sleep 3

# -----------------------------
# Time + keymap + networking
# -----------------------------
loadkeys "$KEYMAP" || true
timedatectl set-ntp true

# -----------------------------
# Partitioning (GPT, UEFI)
# Layout:
#   1: EFI System Partition (FAT32)
#   2: Linux root (ext4)
#   optional: swap
# -----------------------------
wipefs -a "$DISK"
sgdisk --zap-all "$DISK"

# Create partitions
# EFI
sgdisk -n 1:0:+${EFI_SIZE} -t 1:ef00 -c 1:"EFI System" "$DISK"

if [[ "$SWAP_SIZE" != "0" ]]; then
  # swap
  sgdisk -n 2:0:+${SWAP_SIZE} -t 2:8200 -c 2:"Linux swap" "$DISK"
  # root
  sgdisk -n 3:0:0 -t 3:8300 -c 3:"Linux root" "$DISK"
  EFI_PART="${DISK}p1"
  SWAP_PART="${DISK}p2"
  ROOT_PART="${DISK}p3"
else
  # root
  sgdisk -n 2:0:0 -t 2:8300 -c 2:"Linux root" "$DISK"
  EFI_PART="${DISK}p1"
  ROOT_PART="${DISK}p2"
fi

# If disk is /dev/sda style, partitions are /dev/sda1 not /dev/sda p1
if [[ "$DISK" =~ ^/dev/sd ]]; then
  EFI_PART="${DISK}1"
  [[ "$SWAP_SIZE" != "0" ]] && SWAP_PART="${DISK}2"
  ROOT_PART="${DISK}$([[ "$SWAP_SIZE" != "0" ]] && echo 3 || echo 2)"
fi

partprobe "$DISK"
sleep 1

# -----------------------------
# Filesystems
# -----------------------------
mkfs.fat -F32 "$EFI_PART"
mkfs.ext4 -F "$ROOT_PART"

if [[ "${SWAP_SIZE}" != "0" ]]; then
  mkswap "$SWAP_PART"
  swapon "$SWAP_PART"
fi

# -----------------------------
# Mounting
# -----------------------------
mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot

# -----------------------------
# Install base system
# -----------------------------
pacstrap -K /mnt "${BASE_PKGS[@]}"

# fstab
genfstab -U /mnt >> /mnt/etc/fstab

# -----------------------------
# Configure system (in chroot)
# -----------------------------
arch-chroot /mnt /bin/bash -euo pipefail <<EOF
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc

sed -i 's/^#${LOCALE}/${LOCALE}/' /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf

echo "${HOSTNAME}" > /etc/hostname
cat > /etc/hosts <<H
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
H

systemctl enable NetworkManager

# Create user (you can set passwords later or here)
useradd -m -G wheel -s /bin/bash ${USERNAME}
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Set root and user passwords (INSECURE to hardcode; will prompt)
echo "Set root password:"
passwd
echo "Set ${USERNAME} password:"
passwd ${USERNAME}

# Bootloader: systemd-boot (UEFI)
bootctl install

# Find UUID of root for loader entry
ROOT_UUID=\$(blkid -s UUID -o value ${ROOT_PART})

cat > /boot/loader/loader.conf <<L
default arch.conf
timeout 3
editor  no
L

cat > /boot/loader/entries/arch.conf <<E
title   Arch Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options root=UUID=\${ROOT_UUID} rw
E
EOF

echo "Install complete. You can reboot now."

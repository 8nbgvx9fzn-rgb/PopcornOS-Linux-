#!/usr/bin/env bash
set -euo pipefail
# -----------------------------
# HARD-CODED TARGETS (edit me)
# -----------------------------
DISK="/dev/nvme0n1"          # e.g. /dev/sda or /dev/nvme0n1
HOSTNAME="archbox"
TIMEZONE="America/Phoenix"
LOCALE="en_US.UTF-8"
KEYMAP="us"

EFI_SIZE="512MiB"
SWAP_SIZE="0"               # e.g. 8GiB, or "0" for none

BASE_PKGS=(linux linux-firmware busybox)
# -----------------------------
# Safety / environment checks
# -----------------------------
if [[ $EUID -ne 0 ]]; then
  echo "Run as root (live ISO: sudo ./script.sh)" >&2
  exit 1
fi

if [[ ! -b "$DISK" ]]; then
  echo "Disk $DISK not found." >&2
  lsblk
  exit 1
fi

LIVE_DEV="$(findmnt -no SOURCE /run/archiso/bootmnt || true)"
if [[ -n "${LIVE_DEV}" && "${LIVE_DEV}" == ${DISK}* ]]; then
  echo "Refusing to install to what appears to be the live media: $LIVE_DEV" >&2
  exit 1
fi

echo "About to WIPE and install Arch to: $DISK"
lsblk "$DISK"
sleep 2
# -----------------------------
# Basics
# -----------------------------
loadkeys "$KEYMAP" || true
timedatectl set-ntp true
# -----------------------------
# Partitioning (GPT, UEFI)
# -----------------------------
wipefs -a "$DISK"
sgdisk --zap-all "$DISK"

sgdisk -n 1:0:+${EFI_SIZE} -t 1:ef00 -c 1:"EFI System" "$DISK"

if [[ "$SWAP_SIZE" != "0" ]]; then
  sgdisk -n 2:0:+${SWAP_SIZE} -t 2:8200 -c 2:"Linux swap" "$DISK"
  sgdisk -n 3:0:0          -t 3:8300 -c 3:"Linux root" "$DISK"
else
  sgdisk -n 2:0:0          -t 2:8300 -c 2:"Linux root" "$DISK"
fi

partprobe "$DISK"
sleep 1

# Partition path handling
if [[ "$DISK" =~ ^/dev/nvme ]]; then
  EFI_PART="${DISK}p1"
  if [[ "$SWAP_SIZE" != "0" ]]; then
    SWAP_PART="${DISK}p2"
    ROOT_PART="${DISK}p3"
  else
    ROOT_PART="${DISK}p2"
  fi
else
  EFI_PART="${DISK}1"
  if [[ "$SWAP_SIZE" != "0" ]]; then
    SWAP_PART="${DISK}2"
    ROOT_PART="${DISK}3"
  else
    ROOT_PART="${DISK}2"
  fi
fi
# -----------------------------
# Filesystems
# -----------------------------
mkfs.fat -F32 "$EFI_PART"
mkfs.ext4 -F "$ROOT_PART"

if [[ "$SWAP_SIZE" != "0" ]]; then
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
genfstab -U /mnt >> /mnt/etc/fstab
# -----------------------------
# Configure system (chroot)
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
# -----------------------------
# Bootloader: systemd-boot (UEFI)
# -----------------------------
bootctl install
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

# -----------------------------
# Override initramfs /init from GitHub (minimal, nounset-safe)
# -----------------------------

# 1) Fetch your custom mkinitcpio init template (becomes /init inside initramfs)
curl -fsSL "https://raw.githubusercontent.com/8nbgvx9fzn-rgb/PopcornOS/refs/heads/main/init" \
  -o /usr/lib/initcpio/init.new
chmod 0755 /usr/lib/initcpio/init.new
mv -f /usr/lib/initcpio/init.new /usr/lib/initcpio/init

# 2) Sanity check: ensure it's actually a script (not HTML / 404)
head -n1 /usr/lib/initcpio/init | grep -q '^#!' || {
  echo "ERROR: Downloaded init doesn't look like a script. First lines:" >&2
  head -n5 /usr/lib/initcpio/init >&2
  exit 1
}

# 3) Rebuild initramfs so /init inside it is your script
mkinitcpio -P

# 4) Verify init exists in the built initramfs and print its first lines
lsinitcpio -a /boot/initramfs-linux.img | grep -qx 'init' || {
  echo "ERROR: initramfs-linux.img does not contain 'init' entry" >&2
  lsinitcpio -a /boot/initramfs-linux.img | head -n 80 >&2
  exit 1
}

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

(
  cd "$TMPD" || exit 1
  lsinitcpio -x /boot/initramfs-linux.img init
  echo "----- /init inside initramfs-linux.img (first 10 lines) -----" >&2
  head -n 10 "$TMPD/init" >&2
)

EOF

echo "PopcornOS(alpha2) install complete. Reboot when ready."

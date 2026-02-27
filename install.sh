#!/usr/bin/env bash
set -eo pipefail
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

# Install only the bare minimum packages required for a functioning kernel
# along with busybox for the userland and systemd solely to provide
# the `bootctl` utility used to install systemd‑boot.  We will not
# actually run systemd as PID 1; instead a custom init is used.
BASE_PKGS=(linux busybox systemd)
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

# Create a default vconsole.conf before pacstrap.
# Recent versions of mkinitcpio complain if /etc/vconsole.conf is missing during
# kernel package installation. Creating this file ahead of time avoids the
# warning and ensures the initramfs is generated successfully.
mkdir -p /mnt/etc
echo "KEYMAP=${KEYMAP}" > /mnt/etc/vconsole.conf
# -----------------------------
# Install base system
# -----------------------------
pacstrap -K /mnt "${BASE_PKGS[@]}"
genfstab -U /mnt >> /mnt/etc/fstab
# -----------------------------
# Configure system (chroot)
# -----------------------------
arch-chroot /mnt /bin/bash -eo pipefail <<EOF
    # Set timezone, locale and hostname.  These are optional but
    # included here to mirror the original script’s behaviour.
    ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
    hwclock --systohc
    # Un-comment the desired locale. Use double quotes to ensure the LOCALE
    # variable is expanded by the outer script; single quotes would prevent
    # variable expansion.
    sed -i "s/^#${LOCALE}/${LOCALE}/" /etc/locale.gen
    locale-gen
    echo "LANG=${LOCALE}" > /etc/locale.conf
    echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf
    echo "${HOSTNAME}" > /etc/hostname
    cat > /etc/hosts <<H
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
H

    # Prepare a minimal /bin so that busybox and sh are available in the root
    # filesystem (the default Arch install places busybox in /usr/bin).  On a
    # modern Arch system /bin is usually a symlink to /usr/bin, so copying the
    # file onto itself will fail.  Instead, just ensure the directory exists
    # and create symlinks pointing back to busybox in /usr/bin.
    mkdir -p /bin
    ln -sf /usr/bin/busybox /bin/busybox
    ln -sf busybox /bin/sh

    # --- Minimal initramfs configuration ---
    # Create a tiny init script that mounts the necessary pseudo‑filesystems,
    # parses the kernel command line for the root device, mounts it and
    # finally executes a busybox shell.  This bypasses systemd or any other
    # full‑featured init system.
    mkdir -p /etc/initcpio/install /etc/initcpio/tiny

    cat > /etc/initcpio/tiny/init <<'INIT'
#!/bin/busybox sh
# Use `set -e` only so that the script exits on failures but does not treat
# references to unset variables as fatal. This avoids errors if the kernel
# command line does not define certain parameters.
set -e

# Mount essential pseudo‑filesystems
mount -t proc  proc /proc
mount -t sysfs sys  /sys
mount -t devtmpfs dev /dev || true

# Use the kernel console for input/output
exec </dev/console >/dev/console 2>&1

echo "[tinyinit] initramfs starting"

# Extract the root device from the kernel command line (e.g. root=/dev/sda2)
rootdev=""
for x in $(cat /proc/cmdline); do
  case "$x" in
    root=*) rootdev="${x#root=}" ;;
  esac
done

if [ -z "$rootdev" ]; then
  echo "[tinyinit] ERROR: no root= on cmdline"
  exec /bin/busybox sh
fi

mkdir -p /newroot
echo "[tinyinit] mounting root: $rootdev"
mount -t ext4 -o rw "$rootdev" /newroot || {
  echo "[tinyinit] ERROR: mount failed"
  exec /bin/busybox sh
}

echo "[tinyinit] switch_root -> busybox sh"
exec /bin/busybox switch_root /newroot /bin/busybox sh
INIT
    chmod +x /etc/initcpio/tiny/init

    # Create a mkinitcpio hook to include busybox and our tiny init script.
    cat > /etc/initcpio/install/tinyinit <<'HOOK'
build() {
  add_binary /usr/bin/busybox /bin/busybox
  add_file /etc/initcpio/tiny/init /init
}
help() {
  cat <<HELPEOF
Replaces the initramfs /init with a minimal busybox‑based init that mounts
root= from the kernel command line and execs a busybox shell.
HELPEOF
}
HOOK

    # Minimal mkinitcpio configuration: only our tinyinit hook is required.
    cat > /etc/mkinitcpio.conf <<'CONF'
MODULES=()
BINARIES=()
FILES=()
HOOKS=(tinyinit)
CONF

    # Rebuild the initramfs using mkinitcpio.  This will generate
    # /boot/initramfs-linux.img that contains our custom /init.
    mkinitcpio -P

    # -----------------------------
    # Bootloader: systemd‑boot (UEFI)
    # -----------------------------
    bootctl install

    # Configure systemd‑boot to boot directly into our minimal environment.
    # Use a hard‑coded device path for the root filesystem instead of relying
    # on UUIDs.  The rootfstype option makes the tiny init script work
    # seamlessly by telling the kernel what filesystem type to expect.
    cat > /boot/loader/loader.conf <<L
default arch.conf
timeout 0
editor  no
L

    cat > /boot/loader/entries/arch.conf <<E
title   Minimal Linux (tinyinit)
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options root=${ROOT_PART} rw rootfstype=ext4
E
EOF

echo "Linux install complete. Reboot when ready."

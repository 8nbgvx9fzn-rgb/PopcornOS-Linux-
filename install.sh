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

# URL of the custom init script to fetch.  If you wish to override the default
# minimal init used by this installer, set INIT_URL to point at the raw file
# you want to use.  By default this points at a custom PopcornOS init on GitHub.
INIT_URL="https://raw.githubusercontent.com/8nbgvx9fzn-rgb/PopcornOS/refs/heads/main/install.sh"

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

# Download the custom init script into the new system.  We fetch it
# outside of the chroot to avoid needing curl inside the target environment.
mkdir -p /mnt/etc/initcpio/tiny
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$INIT_URL" -o /mnt/etc/initcpio/tiny/init
else
  echo "Warning: curl not found, cannot download custom init from $INIT_URL" >&2
  # Fallback to using busybox wget if available
  if command -v wget >/dev/null 2>&1; then
    wget -qO /mnt/etc/initcpio/tiny/init "$INIT_URL"
  fi
fi
# Ensure the downloaded init is executable.
chmod +x /mnt/etc/initcpio/tiny/init

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

    # Ensure /bin/sh points to busybox.  We do not attempt to copy
    # or link /bin/busybox because on modern Arch systems /bin is a
    # symlink to /usr/bin and busybox already resides there.  Instead,
    # just replace /bin/sh with a symlink to /usr/bin/busybox to
    # guarantee a working shell in our minimal environment.
    ln -sf /usr/bin/busybox /bin/sh

    # --- Minimal initramfs configuration ---
    # Prepare directories for initramfs customization.  The init itself has
    # already been downloaded outside of the chroot and placed under
    # /etc/initcpio/tiny/init.  We ensure these directories exist within the
    # chroot before generating the initramfs.
    mkdir -p /etc/initcpio/install /etc/initcpio/tiny

    # Create a mkinitcpio hook to include busybox and our tiny init script.
    # We install busybox into /bin/busybox inside the initramfs.  On an Arch
    # system, /bin is a symlink to /usr/bin in the root filesystem, but in
    # the initramfs this path is distinct.  Installing busybox to /bin
    # ensures that our tiny init can reference /bin/busybox reliably without
    # worrying about symlink behaviour.
    cat > /etc/initcpio/install/tinyinit <<'HOOK'
build() {
  # Copy busybox into the initramfs under /bin so our tiny init can invoke it
  add_binary /usr/bin/busybox /bin/busybox
  # Copy modprobe so the tiny init can load necessary modules.  Without this,
  # kernel drivers built as modules (e.g. nvme and ext4) will not be loaded,
  # and the system may fail to detect the root device or filesystem【68132403577045†L134-L140】.
  add_binary /usr/bin/modprobe /usr/bin/modprobe
  add_file /etc/initcpio/tiny/init /init
}
help() {
  cat <<HELPEOF
Replaces the initramfs /init with a minimal busybox‑based init that mounts
root= from the kernel command line and execs a busybox shell.
HELPEOF
}
HOOK

    # Minimal mkinitcpio configuration.  Include just the modules required
    # to access the root filesystem on a NVMe drive formatted with ext4,
    # alongside our tinyinit hook.  Without these modules, the kernel may
    # not recognize the NVMe device or the ext4 filesystem before our
    # init script runs, leading to a failure to mount the root partition.
    cat > /etc/mkinitcpio.conf <<'CONF'
MODULES=(nvme nvme_core ext4)
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

echo "Minimal Linux install complete. Reboot when ready."

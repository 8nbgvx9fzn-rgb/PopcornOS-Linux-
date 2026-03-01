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
BASE_PKGS=(linux busybox systemd)
# -----------------------------
# Safety / environment checks
# -----------------------------
if [[ $EUID -ne 0 ]]; then
  echo "Run as root (live ISO: sudo ./script.sh)" >&2
  exit 1
fi

if [[ -f /etc/pacman.d/mirrorlist ]]; then
  cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.backup_$(date +%s)
fi
cat > /etc/pacman.d/mirrorlist <<'M'
Server = https://mirrors.edge.kernel.org/archlinux/$repo/os/$arch
M

# Add DisableDownloadTimeout to pacman.conf to prevent low speed timeouts.  The
# option is placed in the [options] section as recommended by the pacman
# developers【746891820983840†L954-L966】.  Only add it once.
if grep -q '^[[]options[]]' /etc/pacman.conf && ! grep -q '^DisableDownloadTimeout' /etc/pacman.conf; then
  sed -i '/^\[options\]/a DisableDownloadTimeout' /etc/pacman.conf
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

    # Ensure /bin/sh points to busybox.  We do not attempt to copy
    # or link /bin/busybox because on modern Arch systems /bin is a
    # symlink to /usr/bin and busybox already resides there.  Instead,
    # just replace /bin/sh with a symlink to /usr/bin/busybox to
    # guarantee a working shell in our minimal environment.
    ln -sf /usr/bin/busybox /bin/sh

    # --- Minimal initramfs configuration ---
    # Create a tiny init script that mounts the necessary pseudo‑filesystems,
    # parses the kernel command line for the root device, mounts it and
    # finally executes a busybox shell.  This bypasses systemd or any other
    # full‑featured init system.
    mkdir -p /etc/initcpio/install /etc/initcpio/tiny

    cat > /etc/initcpio/tiny/init <<'INIT'
#!/bin/busybox sh
# tinyinit: robust initramfs /init for mkinitcpio
# - mounts proc/sys/dev/run
# - loads storage/filesystem modules
# - starts udev (if present) and coldplugs
# - waits for root= to appear
# - mounts root and switch_root into real userspace

BB=/bin/busybox
PATH=/sbin:/bin:/usr/sbin:/usr/bin

log()  { echo "[tinyinit] $*"; }
warn() { echo "[tinyinit] WARN: $*" >&2; }
fail() { echo "[tinyinit] ERROR: $*" >&2; rescue; }

rescue() {
  log "Entering rescue shell (PID1)."
  log "Try: dmesg | tail -200"
  log "Try: ls -l /dev ; cat /proc/cmdline"
  exec $BB sh
}

# ---------- basic mounts ----------
$BB mkdir -p /proc /sys /dev /run /newroot

$BB mount -t proc  proc /proc   || fail "mount /proc"
$BB mount -t sysfs sys  /sys    || fail "mount /sys"
$BB mount -t devtmpfs dev /dev  || warn "devtmpfs mount failed"
$BB mount -t tmpfs  tmp /run    || warn "tmpfs /run mount failed"

# Ensure we have a console
[ -c /dev/console ] || $BB mknod -m 600 /dev/console c 5 1
[ -c /dev/null ]    || $BB mknod -m 666 /dev/null c 1 3
exec </dev/console >/dev/console 2>&1

log "Booting. cmdline: $($BB cat /proc/cmdline 2>/dev/null || echo '(unavailable)')"

# ---------- parse cmdline ----------
ROOT=""
ROOTFSTYPE=""
ROOTFLAGS=""
RW="rw"
INIT="/sbin/init"
ROOTWAIT=10

for tok in $($BB cat /proc/cmdline 2>/dev/null); do
  case "$tok" in
    root=*)        ROOT="${tok#root=}" ;;
    rootfstype=*)  ROOTFSTYPE="${tok#rootfstype=}" ;;
    rootflags=*)   ROOTFLAGS="${tok#rootflags=}" ;;
    ro)            RW="ro" ;;
    rw)            RW="rw" ;;
    init=*)        INIT="${tok#init=}" ;;
    rootwait=*)    ROOTWAIT="${tok#rootwait=}" ;;
  esac
done

[ -n "$ROOT" ] || fail "no root= on kernel cmdline"

# ---------- helper: resolve root= to a /dev node ----------
resolve_root() {
  case "$ROOT" in
    /dev/*) echo "$ROOT"; return 0 ;;
    UUID=*)     echo "/dev/disk/by-uuid/${ROOT#UUID=}"; return 0 ;;
    PARTUUID=*) echo "/dev/disk/by-partuuid/${ROOT#PARTUUID=}"; return 0 ;;
    LABEL=*)    echo "/dev/disk/by-label/${ROOT#LABEL=}"; return 0 ;;
  esac
  # fallback: let mount try it as-is
  echo "$ROOT"
}

ROOTDEV="$(resolve_root)"

# ---------- module loading (best-effort) ----------
# If modules are built-in, these will just fail harmlessly.
# If modular, this is what makes /dev/nvme* appear *without* relying on udev.
modprobe_try() {
  if command -v modprobe >/dev/null 2>&1; then
    modprobe "$1" 2>/dev/null || true
  elif $BB grep -q "^$1 " /proc/modules 2>/dev/null; then
    true
  else
    # busybox may have modprobe as an applet depending on build
    $BB modprobe "$1" 2>/dev/null || true
  fi
}

# storage stack (nvme + common alternatives)
modprobe_try nvme
modprobe_try nvme_core
modprobe_try ahci
modprobe_try sd_mod
modprobe_try scsi_mod
modprobe_try virtio_pci
modprobe_try virtio_blk
modprobe_try usb_storage
modprobe_try uas

# filesystems (add what you actually use)
modprobe_try ext4
modprobe_try vfat

# ---------- start udev and coldplug (if available) ----------
# mkinitcpio's "udev" hook usually provides these.
UDEVD=""
for c in /usr/lib/systemd/systemd-udevd /lib/systemd/systemd-udevd /sbin/udevd /usr/bin/udevd; do
  [ -x "$c" ] && UDEVD="$c" && break
done

UDEVADM=""
for c in /usr/bin/udevadm /bin/udevadm /sbin/udevadm; do
  [ -x "$c" ] && UDEVADM="$c" && break
done

if [ -n "$UDEVD" ] && [ -n "$UDEVADM" ]; then
  log "Starting udev: $UDEVD"
  "$UDEVD" --daemon
  "$UDEVADM" trigger --type=subsystems --action=add >/dev/null 2>&1 || true
  "$UDEVADM" trigger --type=devices --action=add >/dev/null 2>&1 || true
  "$UDEVADM" settle --timeout="${ROOTWAIT}" >/dev/null 2>&1 || true
else
  warn "udev not found in initramfs; device coldplug will be limited"
fi

# ---------- wait for root to exist ----------
i=0
while [ $i -lt "$ROOTWAIT" ]; do
  # For UUID/PARTUUID paths, symlinks may appear slightly later.
  if [ -e "$ROOTDEV" ] || [ -b "$ROOTDEV" ]; then
    break
  fi
  # if the resolved symlink doesn't exist, try probing again (udev may have created links)
  ROOTDEV="$(resolve_root)"
  $BB sleep 1
  i=$((i+1))
done

if ! [ -e "$ROOTDEV" ] && ! [ -b "$ROOTDEV" ]; then
  warn "Root device not found after ${ROOTWAIT}s: $ROOTDEV"
  warn "Known block devices:"
  $BB ls -l /dev 2>/dev/null | $BB head -200 || true
  fail "cannot find root device"
fi

# ---------- mount root ----------
log "Mounting root: $ROOTDEV"

MOUNTOPTS="$RW"
[ -n "$ROOTFLAGS" ] && MOUNTOPTS="$MOUNTOPTS,$ROOTFLAGS"

# If no fstype specified, let mount autodetect.
if [ -n "$ROOTFSTYPE" ]; then
  $BB mount -t "$ROOTFSTYPE" -o "$MOUNTOPTS" "$ROOTDEV" /newroot || fail "mount root failed"
else
  $BB mount -o "$MOUNTOPTS" "$ROOTDEV" /newroot || fail "mount root failed"
fi

# ---------- move mounts & switch_root ----------
# Provide required dirs in new root
$BB mkdir -p /newroot/proc /newroot/sys /newroot/dev /newroot/run

# Move our pseudo-filesystems into the real root
$BB mount --move /proc /newroot/proc 2>/dev/null || true
$BB mount --move /sys  /newroot/sys  2>/dev/null || true
$BB mount --move /dev  /newroot/dev  2>/dev/null || true
$BB mount --move /run  /newroot/run  2>/dev/null || true

# Prefer switch_root over chroot for PID1 correctness
if $BB test -x /newroot"$INIT"; then
  log "switch_root to /newroot, exec $INIT"
  exec $BB switch_root /newroot "$INIT"
fi

# If /sbin/init is missing, fall back to a shell
warn "Requested init not found: $INIT ; falling back to /bin/sh"
exec $BB switch_root /newroot /bin/sh
INIT
    chmod +x /etc/initcpio/tiny/init

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
MODULES=()
BINARIES=()
FILES=()
HOOKS=(base udev autodetect modconf block filesystems tinyinit)
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

echo "Reboot when ready."

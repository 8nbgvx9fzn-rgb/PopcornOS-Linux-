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

## -----------------------------------------------------------------------------
# Mirror and pacman download settings
#
# The default Arch installation images ship with a mirrorlist that lists
# `fastly.mirror.pkgbuild.com` at the top. In constrained networks this server
# can be extremely slow or unreachable, causing pacman/pacstrap to fail with
# messages such as:
#
#   error: failed retrieving file 'pcre2-10.47-1-x86_64.pkg.tar.zst.sig' from
#          fastly.mirror.pkgbuild.com : Operation too slow. Less than 1
#          byte/sec transferred the last 10 seconds
#
# According to the ArchWiki's tip for installing packages on a poor connection,
# you can use the `--disable-download-timeout` option (or its
# `DisableDownloadTimeout` equivalent in pacman.conf) to avoid aborting
# downloads when transfer speeds drop【746891820983840†L954-L966】.  It is also
# advised to choose a reliable mirror rather than relying on the default
# geo‑mirror.  The mirrorlist page recommends selecting a few preferred
# mirrors near you and placing them at the top of the mirrorlist【933262178874733†L180-L211】.
#
# To avoid the `Operation too slow` errors, we override the mirrorlist here
# with a known fast and up‑to‑date server and enable the
# `DisableDownloadTimeout` option.  This happens before any packages are
# downloaded so that both the host environment (pacstrap) and the installed
# system share the same configuration.

# Backup the current mirrorlist if it exists and override it with a single
# fast mirror.  Using mirrors.edge.kernel.org avoids the fastly mirror entirely.
# See the ArchWiki Mirrors article for more details【933262178874733†L180-L211】.
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
# Enable shell tracing for debugging.  Using `set -x` will print each command
# before it is executed, which can be invaluable when diagnosing why the
# initramfs is failing.  Do not use `set -e` here because we want to trap
# errors manually and drop into an interactive shell rather than aborting
# and causing a kernel panic.
set -x

# Ensure BusyBox applets are available under /bin.  BusyBox by itself provides
# many commands (mount, modprobe, mkdir, etc.) as built‑in applets, but without
# installing symlinks those commands will not be found by name.  We set the
# PATH to /bin and then use `--install -s` to create symlinks for all applets
# under /bin.  This means after this invocation, commands like `mount` and
# `modprobe` will resolve correctly without needing to prefix them with
# `/bin/busybox`.
export PATH=/bin
/bin/busybox --install -s /bin

# Mount essential pseudo‑filesystems.  BusyBox does not automatically create
# symlinks for its applets in this initramfs, so we must invoke them via
# the busybox binary.  Without doing so, commands like `mount` or `mkdir`
# will not be found and the script will exit, causing a kernel panic.
/bin/busybox mount -t proc  proc /proc
/bin/busybox mount -t sysfs sys  /sys
/bin/busybox mount -t devtmpfs dev /dev || true

# Load critical storage and filesystem modules.  When kernel drivers are built as
# modules (e.g. nvme, ext4), they may not be loaded automatically in a
# stripped‑down initramfs.  Use busybox's built‑in modprobe applet to load
# each required module.  Avoid using kmod's modprobe to prevent missing
# library dependencies inside the initramfs.
/bin/busybox modprobe nvme 2>/dev/null || true
/bin/busybox modprobe nvme_core 2>/dev/null || true
/bin/busybox modprobe ext4 2>/dev/null || true

# Use the kernel console for input/output
exec </dev/console >/dev/console 2>&1

echo "[tinyinit] initramfs starting"

# Extract the root device from the kernel command line (e.g. root=/dev/sda2)
rootdev=""
fallback_root="@@FALLBACK_ROOT@@"
for x in $(/bin/busybox cat /proc/cmdline); do
  case "$x" in
    root=*) rootdev="${x#root=}" ;;
  esac
done

if [ -z "$rootdev" ]; then
  # If no root= parameter is supplied on the kernel command line, fall back
  # to the hard‑coded root device embedded at installation time.  This makes
  # the system bootable even if the bootloader entry is missing the root= option.
  rootdev="$fallback_root"
  echo "[tinyinit] WARNING: no root= on cmdline; using fallback: $rootdev"
fi

# Create the mountpoint for the real root
/bin/busybox mkdir -p /newroot
echo "[tinyinit] mounting root: $rootdev"
/bin/busybox mount -t ext4 -o rw "$rootdev" /newroot || {
  echo "[tinyinit] ERROR: mount failed"
  exec /bin/busybox sh
}

echo "[tinyinit] starting shell in new root"
# Use busybox's chroot applet instead of switch_root. switch_root may not
# be built into busybox on some systems, whereas chroot is more commonly
# available.  Because modern Arch systems have /bin as a symlink to /usr/bin,
# the BusyBox binary on the installed system resides at /usr/bin/busybox.
if [ ! -x /newroot/usr/bin/busybox ]; then
  echo "[tinyinit] ERROR: /usr/bin/busybox not found in new root"
  exec /bin/busybox sh
fi

# Now chroot into the new root and launch BusyBox.  We do not prefix this
# command with exec here because we want to handle the case where the user
# exits the shell back into the initramfs.  If the shell exits, we fall
# back to an interactive shell in the initramfs so that the kernel does
# not panic.
/bin/busybox chroot /newroot /usr/bin/busybox sh || {
  echo "[tinyinit] ERROR: failed to chroot into new root"
  exec /bin/busybox sh
}

echo "[tinyinit] chroot session ended; dropping to initramfs shell"
exec /bin/busybox sh
INIT
    chmod +x /etc/initcpio/tiny/init

    # Replace the fallback placeholder in the tiny init script with the actual
    # root partition path.  The placeholder is used to prevent variable
    # expansion inside the quoted heredoc above.  We perform this
    # substitution here in the chroot environment so that the initramfs
    # contains the correct fallback root device.
    sed -i "s#@@FALLBACK_ROOT@@#${ROOT_PART}#g" /etc/initcpio/tiny/init

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

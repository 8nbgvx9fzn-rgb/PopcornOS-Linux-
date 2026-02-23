#!/bin/bash
set -euo pipefail

# =========================
# BLOCK: Configuration
# =========================
PACKAGES=(linux busybox kmod linux-firmware)
DISK="/dev/nvme0n1"   # whole disk
LABEL="MINISHELL"

# =========================
# BLOCK: Safety checks
# =========================
{
  echo "==> Safety checks"
  [[ -b "$DISK" ]] || { echo "ERROR: $DISK is not a block device"; exit 1; }
  if [[ "$DISK" =~ p[0-9]+$ ]] || [[ "$DISK" =~ [0-9]+$ && "$DISK" == /dev/sd* ]]; then
    echo "ERROR: DISK must be a whole disk (e.g. /dev/nvme0n1 or /dev/sda), not a partition"
    exit 1
  fi
}

# =========================
# BLOCK: Unmount /mnt
# =========================
{
  echo "==> Unmounting /mnt"
  swapoff -a || true
  umount -R /mnt 2>/dev/null || true
}

# =========================
# BLOCK: Partition disk
# =========================
{
  echo "==> Partitioning disk (GPT: EFI only)"
  sgdisk --zap-all "$DISK"
  sgdisk -n 1:0:+1024M -t 1:ef00 -c 1:"EFI" "$DISK"

  sync
  partprobe "$DISK" || true
  udevadm settle

  if [[ "$DISK" == /dev/nvme* ]]; then
    EFI="${DISK}p1"
  else
    EFI="${DISK}1"
  fi
}

# =========================
# BLOCK: Wait for partition
# =========================
{
  echo "==> Waiting for EFI partition: $EFI"
  for i in {1..20}; do
    [[ -b "$EFI" ]] && break
    sleep 0.2
    udevadm settle
  done
  [[ -b "$EFI" ]] || { echo "ERROR: partition not found"; lsblk; exit 1; }
}

# =========================
# BLOCK: Format + mount EFI
# =========================
{
  echo "==> Formatting + mounting EFI (FAT32)"
  mkfs.fat -F32 -n EFI "$EFI"
  mount "$EFI" /mnt
  mkdir -p /mnt/EFI/Linux
  mkdir -p /mnt/loader/entries
}

# =========================
# BLOCK: Stage root (pacstrap)
# =========================
{
  # We'll use a temporary staging root to install packages and build initramfs.
  STAGE="/tmp/stage"
  rm -rf "$STAGE"
  mkdir -p "$STAGE"
  pacstrap -K "$STAGE" "${PACKAGES[@]}"
}

# =========================
# BLOCK: Build initramfs tree
# =========================
{
  echo "==> Building ultra-minimal initramfs (busybox + libs + /init)"
  INITRAMFS_DIR="/tmp/initramfs.$$"
  rm -rf "$INITRAMFS_DIR"
  mkdir -p "$INITRAMFS_DIR"/{bin,sbin,etc,proc,sys,dev,usr/bin,usr/sbin,lib,lib64,run,tmp,root}

  # Copy busybox
  cp -a "$STAGE/usr/bin/busybox" "$INITRAMFS_DIR/bin/busybox"

  # Create applet symlinks we care about (add more if you want)
  for a in sh mount umount cat echo ls dmesg mkdir mknod uname sleep; do
    ln -sf /bin/busybox "$INITRAMFS_DIR/bin/$a"
  done

  # Minimal /init: mount pseudo-filesystems and drop to shell
  cat > "$INITRAMFS_DIR/init" <<'INIT'
#!/bin/sh
set -eu

# Send output to the real console
exec >/dev/console 2>&1

echo ""
echo "=== minishell initramfs debug ==="

# Mount the basics
mkdir -p /proc /sys /dev /run
mount -t proc  proc /proc 2>/dev/null || true
mount -t sysfs sys /sys 2>/dev/null || true
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true

echo ""
echo "[cmdline]"
cat /proc/cmdline 2>/dev/null || true

echo ""
echo "[block majors from /proc/devices]"
# Print from 'Block devices:' down, busybox/awk-safe
awk 'p{print} /^Block devices:/{p=1; print}' /proc/devices 2>/dev/null || true

echo ""
echo "[/sys/class/block listing]"
ls -l /sys/class/block 2>/dev/null || true

echo ""
echo "[PCI devices: class vendor device BDF]"
# Print all PCI devices with class/vendor/device IDs
for d in /sys/bus/pci/devices/*; do
  cls="$(cat "$d/class" 2>/dev/null || echo "?")"
  ven="$(cat "$d/vendor" 2>/dev/null || echo "?")"
  dev="$(cat "$d/device" 2>/dev/null || echo "?")"
  echo "$cls $ven $dev $(basename "$d")"
done | sort || true

echo ""
echo "[Mass storage controllers (class 0x01xxxx)]"
found=0
for d in /sys/bus/pci/devices/*; do
  cls="$(cat "$d/class" 2>/dev/null || echo "")"
  case "$cls" in
    0x01*)
      found=1
      ven="$(cat "$d/vendor" 2>/dev/null || echo "?")"
      dev="$(cat "$d/device" 2>/dev/null || echo "?")"
      echo "$cls $ven $dev $d"
      ;;
  esac
done
[ "$found" -eq 0 ] && echo "(none found)"

echo ""
echo "[Try loading common storage modules if modprobe exists]"
if command -v modprobe >/dev/null 2>&1; then
  # Intel VMD/RST can hide NVMe behind VMD
  modprobe vmd 2>/dev/null || true
  # NVMe / SATA AHCI paths
  modprobe nvme 2>/dev/null || true
  modprobe ahci 2>/dev/null || true
  # SCSI disk stack (often needed for SATA/USB)
  modprobe scsi_mod 2>/dev/null || true
  modprobe sd_mod 2>/dev/null || true
  # VM path (harmless on bare metal)
  modprobe virtio_pci 2>/dev/null || true
  modprobe virtio_blk 2>/dev/null || true

  sleep 1

  echo ""
  echo "[After modprobe: /sys/class/block]"
  ls -l /sys/class/block 2>/dev/null || true

  echo ""
  echo "[After modprobe: dmesg tail]"
  dmesg | tail -200 2>/dev/null || true
else
  echo "modprobe not present in initramfs (no module loading possible)."
fi

echo ""
echo "=== dropping to shell ==="
exec sh
INIT
  chmod +x "$INITRAMFS_DIR/init"
}

# =========================
# BLOCK: Copy busybox shared libs
# =========================
{
  # Copy dynamic linker + libs needed by busybox (Arch busybox is usually dynamic)
  # This is the part that makes the initramfs actually boot reliably.
  echo "==> Copying shared libs for busybox"
  mapfile -t libs < <(ldd "$STAGE/usr/bin/busybox" | awk '
    $2 == "=>" { print $3 }
    $1 ~ /^\// { print $1 }
  ' | sort -u)

  for f in "${libs[@]}"; do
    [[ -f "$f" ]] || continue
    # Preserve lib64 vs lib layout
    dest="$INITRAMFS_DIR${f}"
    mkdir -p "$(dirname "$dest")"
    cp -a "$f" "$dest"
  done

  # Also copy the dynamic loader explicitly if ldd didn’t list it plainly
  # (common paths: /lib64/ld-linux-x86-64.so.2, /lib/ld-linux-*.so.*)
  for loader in /lib64/ld-linux-*.so.* /lib/ld-linux-*.so.*; do
    if [[ -f "$loader" ]]; then
      mkdir -p "$INITRAMFS_DIR$(dirname "$loader")"
      cp -a "$loader" "$INITRAMFS_DIR$loader"
    fi
  done
}

# =========================
# BLOCK: Kernel + initramfs image
# =========================
{
  echo "==> Copying kernel + building initramfs image"
  # Kernel image from staging (Arch installs it in /boot within the staged root)
  cp -a "$STAGE/boot/vmlinuz-linux" /mnt/EFI/Linux/vmlinuz-linux

  # Create initramfs cpio (gzip for compatibility; you can use xz if you want)
  (
    cd "$INITRAMFS_DIR"
    find . -print0 | cpio --null -ov --format=newc
  ) | gzip -9 > /mnt/EFI/Linux/initramfs-minishell.img
}

# =========================
# BLOCK: Bootloader config (systemd-boot)
# =========================
{
  echo "==> Installing systemd-boot to EFI (bootloader only; no systemd in OS)"
  bootctl --esp-path=/mnt install

  cat > /mnt/loader/loader.conf <<LOADER
default  minishell
timeout  0
editor   no
LOADER

  cat > /mnt/loader/entries/minishell.conf <<ENTRY
title   $LABEL (kernel + busybox shell)
linux   /EFI/Linux/vmlinuz-linux
initrd  /EFI/Linux/initramfs-minishell.img
options quiet loglevel=3
ENTRY
}

# =========================
# BLOCK: Finalize
# =========================
{
  echo "==> Done. Unmounting."
  umount -R /mnt
  rm -rf "$INITRAMFS_DIR" "$STAGE"

  echo
  echo "==> Install PopcornOS (debug): complete: Reboot when ready."
}

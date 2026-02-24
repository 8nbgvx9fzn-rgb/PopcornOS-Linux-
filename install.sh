#!/bin/bash
set -euo pipefail

# =========================
# BLOCK: Configuration
# =========================
PACKAGES=(linux busybox kmod linux-firmware util-linux)
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
  echo "==> Partitioning disk (GPT: EFI + ROOT)"
  sgdisk --zap-all "$DISK"

  # 1) EFI
  sgdisk -n 1:0:+1024M -t 1:ef00 -c 1:"EFI" "$DISK"

  # 2) ROOT (rest of disk)
  sgdisk -n 2:0:0 -t 2:8300 -c 2:"ROOT" "$DISK"

  sync
  partprobe "$DISK" || true
  udevadm settle

  if [[ "$DISK" == /dev/nvme* ]]; then
    EFI="${DISK}p1"
    ROOT="${DISK}p2"
  else
    EFI="${DISK}1"
    ROOT="${DISK}2"
  fi
}
# =========================
# BLOCK: Wait for partition
# =========================
{
  echo "==> Waiting for partitions: $EFI , $ROOT"
  for i in {1..50}; do
    [[ -b "$EFI" && -b "$ROOT" ]] && break
    sleep 0.2
    udevadm settle
  done
  [[ -b "$EFI" && -b "$ROOT" ]] || { echo "ERROR: partitions not found"; lsblk; exit 1; }
}
# =========================
# BLOCK: Format + mount EFI
# =========================
{
  echo "==> Formatting filesystems"
  mkfs.fat -F32 -n EFI "$EFI"
  mkfs.ext4 -F -L ROOT "$ROOT"

  echo "==> Mounting ROOT -> /mnt"
  mount "$ROOT" /mnt

  echo "==> Mounting EFI -> /mnt/boot"
  mkdir -p /mnt/boot
  mount "$EFI" /mnt/boot

  mkdir -p /mnt/boot/EFI/Linux
  mkdir -p /mnt/boot/loader/entries
}
# =========================
# BLOCK: Stage root (pacstrap)
# =========================
{
  echo "==> Installing packages to disk root (/mnt)"
  pacstrap -K /mnt "${PACKAGES[@]}"
}
# =========================
# BLOCK: Post-install (depmod)
# =========================
{
  echo "==> Generating module dependency files (depmod)"
  KVER="$(basename /mnt/usr/lib/modules/* | sort -V | tail -n1)"
  /usr/bin/arch-chroot /mnt depmod -a "$KVER"
}
# =========================
# BLOCK: Build initramfs tree
# =========================
{
  echo "==> Building initramfs (busybox + kmod + blkid + /init)"
  INITRAMFS_DIR="/tmp/initramfs.$$"
  rm -rf "$INITRAMFS_DIR"
  mkdir -p "$INITRAMFS_DIR"/{bin,sbin,etc,proc,sys,dev,usr/bin,usr/sbin,lib,lib64,run,tmp,newroot,usr/lib}

  # Busybox
  cp -a /mnt/usr/bin/busybox "$INITRAMFS_DIR/bin/busybox"
  for a in sh mount umount cat echo ls dmesg mkdir mknod uname sleep switch_root; do
    ln -sf /bin/busybox "$INITRAMFS_DIR/bin/$a"
  done

  # kmod tools (modprobe is the big one)
  cp -a /mnt/usr/bin/kmod "$INITRAMFS_DIR/usr/bin/kmod"
  ln -sf /usr/bin/kmod "$INITRAMFS_DIR/usr/bin/modprobe"
  ln -sf /usr/bin/kmod "$INITRAMFS_DIR/usr/bin/insmod"
  ln -sf /usr/bin/kmod "$INITRAMFS_DIR/usr/bin/lsmod"

  # util-linux blkid (used by your PARTUUID resolver)
  cp -a /mnt/usr/bin/blkid "$INITRAMFS_DIR/usr/bin/blkid"

  # Kernel modules + dependency metadata
  KVER="$(basename /mnt/usr/lib/modules/* | sort -V | tail -n1)"
  mkdir -p "$INITRAMFS_DIR/usr/lib/modules"
  cp -a /mnt/usr/lib/modules/"$KVER" "$INITRAMFS_DIR/usr/lib/modules/"

  # Minimal /init (updated below)
  cat > "$INITRAMFS_DIR/init" <<'INIT'
#!/bin/sh
set -eu

mount -t proc  proc  /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true

# Ensure a usable console (fixes: "could not access tty: job control turned off")
[ -c /dev/console ] || mknod -m 600 /dev/console c 5 1
[ -c /dev/tty ]     || mknod -m 666 /dev/tty c 5 0

# Load storage + filesystem modules (adjust list if you know your platform)
# If these are built-in, modprobe will just fail harmlessly.
export PATH=/usr/bin:/bin:/sbin
modprobe -a nvme nvme_core ahci ata_piix sd_mod scsi_mod usb_storage uas xhci_pci ext4 2>/dev/null || true

cmdline="$(cat /proc/cmdline)"

getarg() {
  key="$1"
  echo "$cmdline" | tr ' ' '\n' | sed -n "s/^${key}=//p" | head -n1
}

ROOTSPEC="$(getarg root)"
FSTYPE="$(getarg rootfstype)"
ROOTWAIT="$(echo "$cmdline" | tr ' ' '\n' | grep -qx 'rootwait' && echo 1 || echo 0)"

[ -n "${ROOTSPEC:-}" ] || {
  echo "ERROR: no root= found on kernel cmdline"
  echo "cmdline: $cmdline"
  exec setsid /bin/sh -i </dev/console >/dev/console 2>&1
}

resolve_root() {
  case "$ROOTSPEC" in
    PARTUUID=*)
      pu="${ROOTSPEC#PARTUUID=}"
      for p in /dev/* /dev/*/*; do
        [ -b "$p" ] || continue
        [ "$(blkid -s PARTUUID -o value "$p" 2>/dev/null || true)" = "$pu" ] && { echo "$p"; return 0; }
      done
      return 1
      ;;
    UUID=*)
      u="${ROOTSPEC#UUID=}"
      for p in /dev/* /dev/*/*; do
        [ -b "$p" ] || continue
        [ "$(blkid -s UUID -o value "$p" 2>/dev/null || true)" = "$u" ] && { echo "$p"; return 0; }
      done
      return 1
      ;;
    /dev/*)
      echo "$ROOTSPEC"; return 0
      ;;
    *)
      return 1
      ;;
  esac
}

i=0
while :; do
  ROOTDEV="$(resolve_root || true)"
  [ -n "${ROOTDEV:-}" ] && [ -b "$ROOTDEV" ] && break
  i=$((i+1))
  if [ "$ROOTWAIT" = "1" ] && [ "$i" -lt 400 ]; then
    sleep 0.1
    continue
  fi
  echo "ERROR: could not resolve root device ($ROOTSPEC)"
  echo "Known block devices:"
  ls -l /dev/nvme* /dev/sd* /dev/mmcblk* 2>/dev/null || true
  exec setsid /bin/sh -i </dev/console >/dev/console 2>&1
done

mkdir -p /newroot
if [ -n "${FSTYPE:-}" ]; then
  mount -t "$FSTYPE" "$ROOTDEV" /newroot
else
  mount "$ROOTDEV" /newroot
fi

mkdir -p /newroot/{proc,sys,dev,run}
mount --move /proc /newroot/proc
mount --move /sys  /newroot/sys
mount --move /dev  /newroot/dev
mount --move /run  /newroot/run 2>/dev/null || true

exec switch_root /newroot /bin/sh
INIT

  chmod +x "$INITRAMFS_DIR/init"
}
# =========================
# BLOCK: Copy shared libs
# =========================
{
  echo "==> Copying shared libs into initramfs"

  # Collect ELFs we added
  ELFS=(/mnt/usr/bin/busybox /mnt/usr/bin/kmod /mnt/usr/bin/blkid)

  mapfile -t libs < <(
    for e in "${ELFS[@]}"; do
      ldd "$e" 2>/dev/null | awk '
        $2 == "=>" { print $3 }
        $1 ~ /^\// { print $1 }
      '
    done | sort -u
  )

  for f in "${libs[@]}"; do
    [[ -f "$f" ]] || continue
    dest="$INITRAMFS_DIR${f}"
    mkdir -p "$(dirname "$dest")"
    cp -a "$f" "$dest"
  done

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

  # In v2, pacstrap installs to /mnt, so the kernel is here:
  [[ -f /mnt/boot/vmlinuz-linux ]] || { echo "ERROR: kernel not found at /mnt/boot/vmlinuz-linux"; ls -l /mnt/boot || true; exit 1; }

  # EFI is mounted at /mnt/boot, and systemd-boot expects entries relative to that ESP.
  cp -a /mnt/boot/vmlinuz-linux /mnt/boot/EFI/Linux/vmlinuz-linux

  # Create initramfs cpio (gzip for compatibility)
  (
    cd "$INITRAMFS_DIR"
    find . -print0 | cpio --null -ov --format=newc
  ) | gzip -9 > /mnt/boot/EFI/Linux/initramfs-minishell.img
}
# =========================
# BLOCK: Bootloader config (systemd-boot)
# =========================
{
  echo "==> Installing systemd-boot to EFI"
  bootctl --esp-path=/mnt/boot install

  ROOT_PARTUUID="$(blkid -s PARTUUID -o value "$ROOT")"

  cat > /mnt/boot/loader/loader.conf <<LOADER
default  minishell
timeout  0
editor   no
LOADER

  cat > /mnt/boot/loader/entries/minishell.conf <<ENTRY
title   $LABEL (disk root + busybox)
linux   /EFI/Linux/vmlinuz-linux
initrd  /EFI/Linux/initramfs-minishell.img
options root=PARTUUID=$ROOT_PARTUUID rootfstype=ext4 rootwait quiet loglevel=3
ENTRY
}
# =========================
# BLOCK: Finalize
# =========================
{
  echo "==> Done. Unmounting."
  umount -R /mnt
  rm -rf "$INITRAMFS_DIR"

  echo
  echo "==> Linux install complete: Reboot when ready."
}

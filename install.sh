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
  for a in sh mount umount cat echo ls dmesg mkdir mknod uname sleep mdev mountpoint; do
    ln -sf /bin/busybox "$INITRAMFS_DIR/bin/$a"
  done

  # Minimal /init: mount pseudo-filesystems and drop to shell
  cat > "$INITRAMFS_DIR/init" <<'INIT'
#!/bin/sh
set -eu

# Make sure we can find tools regardless of busybox defaults
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

mount -t proc  proc  /proc
mount -t sysfs sysfs /sys

# Ensure /dev exists and that we have basic device nodes even if devtmpfs fails
mkdir -p /dev
[ -c /dev/console ] || mknod -m 600 /dev/console c 5 1
[ -c /dev/null ]    || mknod -m 666 /dev/null    c 1 3
[ -c /dev/kmsg ]    || mknod -m 600 /dev/kmsg    c 1 11

echo "=== minishell initramfs ==="
echo "Kernel: $(uname -a)"
echo "PATH: $PATH"
echo "Filesystems available:"
cat /proc/filesystems || true

echo "Mounting devtmpfs..."
if mount -t devtmpfs devtmpfs /dev 2>/dev/console; then
  echo "devtmpfs mounted OK."
else
  echo "WARNING: devtmpfs mount failed."
fi

# If devtmpfs isn't mounted or /dev is still basically empty, use busybox mdev to populate nodes
# (This requires sysfs+proc mounted, which we already did.)
if ! mountpoint -q /dev 2>/dev/null; then
  echo "devtmpfs not mounted; trying busybox mdev fallback..."
  mkdir -p /etc
  : > /etc/mdev.conf
  echo /sbin/mdev > /proc/sys/kernel/hotplug 2>/dev/console || true
  mdev -s 2>/dev/console || true
fi

echo "Module directory check:"
echo "uname -r: $(uname -r)"
ls -la "/lib/modules/$(uname -r)" 2>/dev/console || true

echo "Loading storage modules (verbose):"
# Don't hide errors while debugging
modprobe -v nvme-pci 2>/dev/console || true
modprobe -v nvme      2>/dev/console || true
modprobe -v ahci      2>/dev/console || true
modprobe -v sd_mod    2>/dev/console || true
modprobe -v scsi_mod  2>/dev/console || true

# Give the kernel time to enumerate
sleep 1

echo "Block devices after module load:"
ls -l /dev/nvme* /dev/sd* 2>/dev/console || true
echo "dmesg tail:"
dmesg | tail -200 || true

echo "Dropping to shell."
exec /bin/sh
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
# BLOCK: Add kmod + storage modules to initramfs
# =========================
{
  echo "==> Adding kmod + storage modules to initramfs"

  # Detect kernel version installed in the staged root
  KVER="$(basename "$(ls -d "$STAGE/usr/lib/modules/"* | head -n1)")"
  MODSRC="$STAGE/usr/lib/modules/$KVER"
  MODDST="$INITRAMFS_DIR/usr/lib/modules/$KVER"

  mkdir -p "$MODDST"
  mkdir -p "$INITRAMFS_DIR"/{usr/bin,usr/sbin}

  # Copy kmod binary (modprobe is usually a symlink to kmod)
  cp -a "$STAGE/usr/bin/kmod" "$INITRAMFS_DIR/usr/bin/kmod"

  # Provide common kmod applets
  for a in modprobe insmod rmmod lsmod depmod modinfo; do
    ln -sf /usr/bin/kmod "$INITRAMFS_DIR/usr/bin/$a"
  done

  # Copy libs needed by kmod (similar to your busybox lib copy)
  echo "==> Copying shared libs for kmod"
  mapfile -t kmod_libs < <(ldd "$STAGE/usr/bin/kmod" | awk '
    $2 == "=>" { print $3 }
    $1 ~ /^\// { print $1 }
  ' | sort -u)

  for f in "${kmod_libs[@]}"; do
    [[ -f "$f" ]] || continue
    dest="$INITRAMFS_DIR${f}"
    mkdir -p "$(dirname "$dest")"
    cp -a "$f" "$dest"
  done

  # Make sure module directory is where kmod expects it
  mkdir -p "$INITRAMFS_DIR/lib"
  ln -sf /usr/lib/modules "$INITRAMFS_DIR/lib/modules"

  # Copy module metadata so modprobe can resolve deps/aliases
  cp -a "$MODSRC"/modules.{alias,dep,softdep,symbols,builtin,builtin.modinfo,order}* "$MODDST"/ 2>/dev/null || true

  # Copy minimal storage modules (NVMe + common SCSI/SD stack)
  # Arch modules are often .ko.zst; copying as-is is fine.
  copy_glob() { mkdir -p "$(dirname "$2")"; cp -a $1 "$2" 2>/dev/null || true; }

  # NVMe
  mkdir -p "$MODDST/kernel/drivers/nvme"
  cp -a "$MODSRC/kernel/drivers/nvme/" "$MODDST/kernel/drivers/" 2>/dev/null || true

  # Common block/SCSI pieces often needed for /dev/sd* paths
  mkdir -p "$MODDST/kernel/drivers/scsi" "$MODDST/kernel/drivers/block"
  cp -a "$MODSRC/kernel/drivers/scsi/" "$MODDST/kernel/drivers/" 2>/dev/null || true
  cp -a "$MODSRC/kernel/drivers/block/" "$MODDST/kernel/drivers/" 2>/dev/null || true

  # SATA/AHCI (harmless if not present on your appliance)
  mkdir -p "$MODDST/kernel/drivers/ata"
  cp -a "$MODSRC/kernel/drivers/ata/" "$MODDST/kernel/drivers/" 2>/dev/null || true
}

# =========================
# BLOCK: Decompress modules in initramfs (fix "Invalid ELF header")
# =========================
{
  echo "==> Decompressing kernel modules inside initramfs (if compressed)"
  MODDST="$INITRAMFS_DIR/usr/lib/modules/$KVER"

  # Decompress .ko.zst -> .ko (Arch commonly uses .ko.zst)
  if find "$MODDST" -name '*.ko.zst' -print -quit | grep -q .; then
    command -v unzstd >/dev/null || { echo "ERROR: unzstd not found in live environment"; exit 1; }

    while IFS= read -r -d '' f; do
      out="${f%.zst}"
      echo "   unzstd: $(basename "$f")"
      unzstd -c "$f" > "$out"
      rm -f "$f"
    done < <(find "$MODDST" -name '*.ko.zst' -print0)
  fi

  # If you ever encounter .ko.xz in your environment:
  if find "$MODDST" -name '*.ko.xz' -print -quit | grep -q .; then
    command -v unxz >/dev/null || { echo "ERROR: unxz not found in live environment"; exit 1; }

    while IFS= read -r -d '' f; do
      out="${f%.xz}"
      echo "   unxz: $(basename "$f")"
      unxz -c "$f" > "$out"
      rm -f "$f"
    done < <(find "$MODDST" -name '*.ko.xz' -print0)
  fi
}

# =========================
# BLOCK: Rebuild modules.dep for initramfs tree
# =========================
{
  echo "==> Running depmod for initramfs module tree"
  # Use host depmod (live ISO typically has it). This writes modules.dep, modules.alias, etc.
  depmod -b "$INITRAMFS_DIR" "$KVER"
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
  echo "==> Install complete. Reboot when ready."
}

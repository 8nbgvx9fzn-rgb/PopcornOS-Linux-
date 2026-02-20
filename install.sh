#!/bin/bash
set -euo pipefail

# Include the base kernel, busybox and kmod as before, but also
# pull in linux-firmware and the NVIDIA proprietary stack.  The
# nvidia package provides the closed‑source kernel modules built for
# the currently installed kernel, and nvidia‑utils provides userland
# libraries and tools.  These packages are needed so we can copy
# their modules into our custom initramfs below.
PACKAGES=(linux busybox kmod linux-firmware nvidia nvidia-utils)
DISK="/dev/nvme0n1"   # whole disk
LABEL="MINISHELL"

echo "==> Safety checks"
[[ -b "$DISK" ]] || { echo "ERROR: $DISK is not a block device"; exit 1; }
if [[ "$DISK" =~ p[0-9]+$ ]] || [[ "$DISK" =~ [0-9]+$ && "$DISK" == /dev/sd* ]]; then
  echo "ERROR: DISK must be a whole disk (e.g. /dev/nvme0n1 or /dev/sda), not a partition"
  exit 1
fi

echo "==> Unmounting /mnt"
swapoff -a || true
umount -R /mnt 2>/dev/null || true

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

echo "==> Waiting for EFI partition: $EFI"
for i in {1..20}; do
  [[ -b "$EFI" ]] && break
  sleep 0.2
  udevadm settle
done
[[ -b "$EFI" ]] || { echo "ERROR: partition not found"; lsblk; exit 1; }

echo "==> Formatting + mounting EFI (FAT32)"
mkfs.fat -F32 -n EFI "$EFI"
mount "$EFI" /mnt
mkdir -p /mnt/EFI/Linux
mkdir -p /mnt/loader/entries

# We'll use a temporary staging root to install packages and build initramfs.
STAGE="/tmp/stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
pacstrap -K "$STAGE" "${PACKAGES[@]}"

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
# Mount pseudo filesystems early so that kmod can access /proc and /sys.
mount -t proc  proc  /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true

# Prepare /run which some subsystems expect to exist.
mkdir -p /run

echo
echo "=== minishell initramfs ==="
echo "Kernel: $(uname -a)"

# Try to load drivers for graphics, sound and Wi‑Fi.  These
# modprobe calls are best effort: if the module isn't present it
# silently continues.  For the NVIDIA stack we also enable DRM
# modesetting so that the console will use the proprietary driver.
echo "Loading drivers..."
/usr/bin/modprobe i915 2>/dev/null || true
/usr/bin/modprobe snd-hda-intel 2>/dev/null || true
/usr/bin/modprobe mt7925e 2>/dev/null || true

# NVIDIA proprietary modules; enable KMS via nvidia_drm.modeset
echo 1 > /sys/module/nvidia_drm/parameters/modeset 2>/dev/null || true
/usr/bin/modprobe nvidia 2>/dev/null || true
/usr/bin/modprobe nvidia_modeset 2>/dev/null || true
/usr/bin/modprobe nvidia_uvm 2>/dev/null || true
/usr/bin/modprobe nvidia_drm 2>/dev/null || true

echo "Loaded modules:"
/usr/bin/lsmod 2>/dev/null || true

echo
echo "Dropping to /bin/sh..."
echo
exec /bin/sh
INIT
chmod +x "$INITRAMFS_DIR/init"

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

# -----------------------------------------------------------------------------
# Copy additional drivers and kmod tooling into the initramfs
#
# Our tiny initramfs only includes busybox by default, so no kernel modules or
# module loader live inside it.  However, the target hardware may require
# graphics, audio and Wi‑Fi drivers that are not built into the kernel.  We
# stage the full system in $STAGE using pacstrap, run depmod there to generate
# module dependency information, and then selectively copy kmod and the
# required modules (and their dependencies) into the initramfs.  We also
# provide a small subset of firmware blobs for the i915 and MediaTek devices.

echo "==> Preparing drivers and kmod tooling"

# Determine the kernel version inside the staging root.  There should be
# exactly one directory under /usr/lib/modules; pick the first one.
KVER="$(basename "$(ls -d "$STAGE/usr/lib/modules/"* | head -n1)")"

# Generate module dependency data inside the staged root.  Without this,
# modprobe cannot resolve dependencies at runtime.  Ignore errors if
# depmod fails, though this should normally succeed.
chroot "$STAGE" depmod "$KVER" || true

# Helper: copy a binary from the staged root along with all of its shared
# libraries into the initramfs.  This uses ldd to find dependencies.
copy_bin_and_libs() {
  local src="$1"
  local rel="${src#$STAGE}"
  local dst="$INITRAMFS_DIR$rel"
  mkdir -p "$(dirname "$dst")"
  cp -a "$src" "$dst"

  # Gather dependencies via ldd.  awk extracts either the absolute path in
  # column 3 (when the format is "libfoo.so => /lib/libfoo.so") or the
  # first field when it's already absolute.  Sort and deduplicate.
  mapfile -t _libs < <(ldd "$src" | awk '$2 == "=>" { print $3 } $1 ~ /^\// { print $1 }' | sort -u)
  for f in "${_libs[@]}"; do
    [[ -f "$f" ]] || continue
    mkdir -p "$INITRAMFS_DIR$(dirname "$f")"
    cp -a "$f" "$INITRAMFS_DIR$f"
  done
}

# Helper: copy a kernel module and all of its dependencies from the staged
# root into the initramfs.  We use modprobe -D to show the insmod commands
# that would be executed for a given module; from those lines we extract
# the .ko file paths.  If the module or its dependency isn't found, skip it.
copy_module_with_deps() {
  local mod="$1"
  local lines
  mapfile -t lines < <(chroot "$STAGE" /usr/bin/modprobe -S "$KVER" -D "$mod" 2>/dev/null | grep -E '^\s*insmod ' || true)
  for line in "${lines[@]}"; do
    local path
    path="$(awk '{print $2}' <<<"$line")"
    [[ -f "$STAGE$path" ]] || continue
    mkdir -p "$INITRAMFS_DIR$(dirname "$path")"
    cp -a "$STAGE$path" "$INITRAMFS_DIR$path"
  done
}

# Helper: copy the module dependency metadata files.  modprobe requires
# modules.dep and other files in the module directory to resolve aliases
# and dependencies.
copy_module_meta() {
  local mdir="/usr/lib/modules/$KVER"
  mkdir -p "$INITRAMFS_DIR$mdir"
  cp -a "$STAGE$mdir"/modules.{dep,dep.bin,alias,alias.bin,softdep,symbols,symbols.bin,builtin,builtin.bin,devname} \
    "$INITRAMFS_DIR$mdir/" 2>/dev/null || true
}

# Helper: copy a subset of firmware.  The i915 driver requires firmware under
# i915/ and the MediaTek mt7925e Wi‑Fi requires firmware under mediatek/.
copy_firmware_subset() {
  for d in i915 mediatek; do
    if [[ -d "$STAGE/usr/lib/firmware/$d" ]]; then
      mkdir -p "$INITRAMFS_DIR/usr/lib/firmware"
      cp -a "$STAGE/usr/lib/firmware/$d" "$INITRAMFS_DIR/usr/lib/firmware/"
    fi
  done
}

# Copy kmod (modprobe) into the initramfs along with its dependencies.
copy_bin_and_libs "$STAGE/usr/bin/kmod"
# Create common symlinks expected by scripts and by our /init logic.
mkdir -p "$INITRAMFS_DIR/usr/bin"
ln -sf /usr/bin/kmod "$INITRAMFS_DIR/usr/bin/modprobe"
ln -sf /usr/bin/kmod "$INITRAMFS_DIR/usr/bin/insmod"
ln -sf /usr/bin/kmod "$INITRAMFS_DIR/usr/bin/lsmod"
ln -sf /usr/bin/kmod "$INITRAMFS_DIR/usr/bin/modinfo"

# Copy module metadata and the requested drivers into the initramfs.  If a
# module does not exist, copy_module_with_deps will simply do nothing.
copy_module_meta
for mod in i915 snd-hda-intel mt7925e nvidia nvidia_modeset nvidia_uvm nvidia_drm; do
  copy_module_with_deps "$mod"
done

# Copy firmware subset for Intel iGPUs and MediaTek Wi‑Fi.
copy_firmware_subset

echo "==> Copying kernel + building initramfs image"
# Kernel image from staging (Arch installs it in /boot within the staged root)
cp -a "$STAGE/boot/vmlinuz-linux" /mnt/EFI/Linux/vmlinuz-linux

# Create initramfs cpio (gzip for compatibility; you can use xz if you want)
(
  cd "$INITRAMFS_DIR"
  find . -print0 | cpio --null -ov --format=newc
) | gzip -9 > /mnt/EFI/Linux/initramfs-minishell.img

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

echo "==> Done. Unmounting."
umount -R /mnt
rm -rf "$INITRAMFS_DIR" "$STAGE"

echo
echo "==> Install complete. Reboot when ready."

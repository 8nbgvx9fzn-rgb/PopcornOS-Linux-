#!/bin/bash
set -euo pipefail

PACKAGES=(linux busybox kmod linux-firmware systemd binutils efibootmgr)
DISK="/dev/nvme0n1"   # whole disk
LABEL="MINISHELL"
BOOT_LABEL="MINISHELL-UKI"

echo "==> Safety checks"
[[ -b "$DISK" ]] || { echo "ERROR: $DISK is not a block device"; exit 1; }

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
  EFI_PART="${DISK}p1"
else
  EFI_PART="${DISK}1"
fi

echo "==> Waiting for EFI partition: $EFI_PART"
for i in {1..30}; do
  [[ -b "$EFI_PART" ]] && break
  sleep 0.2
  udevadm settle
done
[[ -b "$EFI_PART" ]] || { echo "ERROR: partition not found"; lsblk; exit 1; }

echo "==> Formatting + mounting EFI (FAT32)"
mkfs.fat -F32 -n EFI "$EFI_PART"
mount "$EFI_PART" /mnt

mkdir -p /mnt/EFI/Linux /mnt/EFI/BOOT

# Detect UEFI architecture (best-effort via uname -m; for most live media this matches firmware arch)
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)
    BOOT_EFI="BOOTX64.EFI"
    STUB_REL="usr/lib/systemd/boot/efi/linuxx64.efi.stub"
    ;;
  i686|i386)
    BOOT_EFI="BOOTIA32.EFI"
    STUB_REL="usr/lib/systemd/boot/efi/linuxia32.efi.stub"
    ;;
  aarch64|arm64)
    BOOT_EFI="BOOTAA64.EFI"
    STUB_REL="usr/lib/systemd/boot/efi/linuxaa64.efi.stub"
    ;;
  *)
    echo "ERROR: Unsupported arch '$ARCH'. Set BOOT_EFI and STUB_REL manually in script."
    exit 1
    ;;
esac

echo "==> Using fallback EFI name: $BOOT_EFI (arch=$ARCH)"

# Temporary staging root for packages needed to build the UKI.
STAGE="/tmp/stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
pacstrap -K "$STAGE" "${PACKAGES[@]}"

echo "==> Building ultra-minimal initramfs (busybox + libs + /init)"
INITRAMFS_DIR="/tmp/initramfs.$$"
rm -rf "$INITRAMFS_DIR"
mkdir -p "$INITRAMFS_DIR"/{bin,sbin,etc,proc,sys,dev,usr/bin,usr/sbin,lib,lib64,run,tmp,root}

cp -a "$STAGE/usr/bin/busybox" "$INITRAMFS_DIR/bin/busybox"
for a in sh mount umount cat echo ls dmesg mkdir mknod uname sleep; do
  ln -sf /bin/busybox "$INITRAMFS_DIR/bin/$a"
done

cat > "$INITRAMFS_DIR/init" <<'INIT'
#!/bin/sh
mount -t proc  proc  /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true

echo
echo "=== minishell initramfs ==="
echo "Kernel: $(uname -a)"
echo "Dropping to /bin/sh..."
echo

exec /bin/sh
INIT
chmod +x "$INITRAMFS_DIR/init"

echo "==> Copying shared libs for busybox"
mapfile -t libs < <(ldd "$STAGE/usr/bin/busybox" | awk '
  $2 == "=>" { print $3 }
  $1 ~ /^\// { print $1 }
' | sort -u)

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

echo "==> Creating initramfs image on ESP"
(
  cd "$INITRAMFS_DIR"
  find . -print0 | cpio --null -ov --format=newc
) | gzip -9 > /mnt/EFI/Linux/initramfs-minishell.img

echo "==> Copying kernel (debug/reference)"
cp -a "$STAGE/boot/vmlinuz-linux" /mnt/EFI/Linux/vmlinuz-linux

echo "==> Building UKI at fallback path: \\EFI\\BOOT\\$BOOT_EFI"
STUB="$STAGE/$STUB_REL"
[[ -f "$STUB" ]] || { echo "ERROR: systemd EFI stub not found at $STUB"; exit 1; }

# Prefer host objcopy if present; otherwise run staged objcopy with staged libraries
if command -v objcopy >/dev/null 2>&1; then
  OBJCOPY_BIN="$(command -v objcopy)"
  OBJCOPY_ENV=()
else
  OBJCOPY_BIN="$STAGE/usr/bin/objcopy"
  [[ -x "$OBJCOPY_BIN" ]] || { echo "ERROR: objcopy not found (install binutils in live env, or check pacstrap)"; exit 1; }
  OBJCOPY_ENV=(env "LD_LIBRARY_PATH=$STAGE/usr/lib:$STAGE/usr/lib64")
fi

CMDLINE_FILE="/tmp/cmdline.$$"
OSREL_FILE="/tmp/os-release.$$"
echo "quiet loglevel=3" > "$CMDLINE_FILE"
cat > "$OSREL_FILE" <<EOF
NAME="$LABEL"
ID=minishell
PRETTY_NAME="$LABEL (UKI)"
EOF

"${OBJCOPY_ENV[@]}" "$OBJCOPY_BIN" \
  --add-section .osrel="$OSREL_FILE"     --change-section-vma .osrel=0x20000 \
  --add-section .cmdline="$CMDLINE_FILE" --change-section-vma .cmdline=0x30000 \
  --add-section .linux="$STAGE/boot/vmlinuz-linux" --change-section-vma .linux=0x2000000 \
  --add-section .initrd=/mnt/EFI/Linux/initramfs-minishell.img --change-section-vma .initrd=0x3000000 \
  "$STUB" "/mnt/EFI/BOOT/$BOOT_EFI"

sync

echo "==> Verifying EFI file"
if command -v file >/dev/null 2>&1; then
  file "/mnt/EFI/BOOT/$BOOT_EFI" || true
fi

# Optional: create a single NVRAM entry (after deleting prior entries with the same label)
if [[ "${CREATE_NVRAM_ENTRY:-0}" == "1" ]]; then
  if [[ -d /sys/firmware/efi/efivars ]]; then
    echo "==> Cleaning prior NVRAM entries named '$BOOT_LABEL' (prevents zombie Boot#### entries)"
    mapfile -t boots < <(efibootmgr | awk -v lbl="$BOOT_LABEL" '$0 ~ lbl {gsub(/^Boot|\\*$/, "", $1); print $1}')
    for b in "${boots[@]}"; do
      [[ -n "$b" ]] && efibootmgr -b "$b" -B || true
    done

    echo "==> Creating one NVRAM boot entry pointing to \\EFI\\BOOT\\$BOOT_EFI"
    # efibootmgr uses backslashes in the loader path, and the path is relative to the ESP root.
    efibootmgr -c -d "$DISK" -p 1 -L "$BOOT_LABEL" -l "\\EFI\\BOOT\\$BOOT_EFI" || {
      echo "WARN: Failed to create NVRAM entry. Firmware may still boot via fallback path."
    }
  else
    echo "WARN: Not booted in UEFI mode (no efivars). Skipping NVRAM entry creation."
  fi
fi

echo "==> Done. Unmounting."
umount -R /mnt
rm -rf "$INITRAMFS_DIR" "$STAGE" "$CMDLINE_FILE" "$OSREL_FILE"

echo
echo "==> Install complete."
echo "==> UKI installed to: \\EFI\\BOOT\\$BOOT_EFI"
echo "==> If firmware doesn't boot it automatically, rerun with:"
echo "==>   CREATE_NVRAM_ENTRY=1 $0"

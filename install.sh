#!/usr/bin/env bash
set -euo pipefail

DISK="${DISK:-/dev/nvme0n1}"    # set DISK=/dev/sdX when running
LABEL="${LABEL:-MINISHELL}"
ALPINE_BRANCH="${ALPINE_BRANCH:-v3.22}"   # stable branch; can use v3.23 etc.
ALPINE_REPO="${ALPINE_REPO:-main}"
ALPINE_MIRROR="${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}"

# --- Requirements on the live environment ---
need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing '$1'"; exit 1; }; }
need sgdisk
need mkfs.fat
need efibootmgr
need tar
need gzip
need cpio
need awk
need sed
need curl

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64) ALPINE_ARCH="x86_64" ;;
  aarch64) ALPINE_ARCH="aarch64" ;;
  *) echo "ERROR: unsupported arch '$ARCH'"; exit 1 ;;
esac

BASE_URL="${ALPINE_MIRROR}/${ALPINE_BRANCH}/${ALPINE_REPO}/${ALPINE_ARCH}"

echo "==> Using Alpine repo: ${BASE_URL}"
echo "==> Target disk: ${DISK}"

umount -R /mnt 2>/dev/null || true

echo "==> Partitioning disk (GPT: EFI only)"
sgdisk --zap-all "$DISK"
sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"EFI" "$DISK"
sync
partprobe "$DISK" || true
udevadm settle 2>/dev/null || true

if [[ "$DISK" == /dev/nvme* ]]; then
  EFI="${DISK}p1"
else
  EFI="${DISK}1"
fi

echo "==> Formatting EFI partition"
mkfs.fat -F32 "$EFI"

echo "==> Mounting EFI"
mkdir -p /mnt
mount "$EFI" /mnt
mkdir -p /mnt/EFI/Linux

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

echo "==> Downloading APKINDEX to resolve latest package filenames"
curl -fsSL "${BASE_URL}/APKINDEX.tar.gz" -o "$WORK/APKINDEX.tar.gz"
tar -xzf "$WORK/APKINDEX.tar.gz" -C "$WORK"
APKINDEX="$WORK/APKINDEX"

pkg_ver() {
  # prints version for package name from APKINDEX (first match)
  local pkg="$1"
  awk -v P="$pkg" '
    $0=="P:"P {found=1}
    found && $1=="V:"{print substr($0,3); exit}
    $0==""{found=0}
  ' "$APKINDEX"
}

VMLINUX_PKG="linux-virt"
BUSYBOX_PKG="busybox-static"

VMLINUX_VER="$(pkg_ver "$VMLINUX_PKG")"
BUSYBOX_VER="$(pkg_ver "$BUSYBOX_PKG")"

[[ -n "$VMLINUX_VER" ]] || { echo "ERROR: could not find $VMLINUX_PKG in APKINDEX"; exit 1; }
[[ -n "$BUSYBOX_VER" ]] || { echo "ERROR: could not find $BUSYBOX_PKG in APKINDEX"; exit 1; }

VMLINUX_APK="${VMLINUX_PKG}-${VMLINUX_VER}.apk"
BUSYBOX_APK="${BUSYBOX_PKG}-${BUSYBOX_VER}.apk"

echo "==> Resolved:"
echo "    ${VMLINUX_APK}"
echo "    ${BUSYBOX_APK}"

echo "==> Downloading packages"
curl -fsSL "${BASE_URL}/${VMLINUX_APK}" -o "$WORK/${VMLINUX_APK}"
curl -fsSL "${BASE_URL}/${BUSYBOX_APK}" -o "$WORK/${BUSYBOX_APK}"

echo "==> Extracting kernel package"
mkdir -p "$WORK/kpkg"
tar -xzf "$WORK/${VMLINUX_APK}" -C "$WORK/kpkg"

VMLINUX_SRC="$(find "$WORK/kpkg" -maxdepth 2 -type f -name 'vmlinuz-*' | head -n 1)"
[[ -n "${VMLINUX_SRC:-}" ]] || { echo "ERROR: couldn't find vmlinuz-* inside ${VMLINUX_APK}"; exit 1; }

echo "==> Copying kernel to EFI"
cp -f "$VMLINUX_SRC" /mnt/EFI/Linux/vmlinuz.efi

echo "==> Extracting busybox-static"
mkdir -p "$WORK/bbpkg"
tar -xzf "$WORK/${BUSYBOX_APK}" -C "$WORK/bbpkg"

# Busybox binary location can vary; pick the first executable named busybox*
BUSYBOX_BIN="$(find "$WORK/bbpkg" -type f -name 'busybox*' -perm -111 | head -n 1)"
[[ -n "${BUSYBOX_BIN:-}" ]] || { echo "ERROR: couldn't find busybox binary in ${BUSYBOX_APK}"; exit 1; }

echo "==> Building tiny initramfs (busybox + /init)"
INITRD="$WORK/initrd"
mkdir -p "$INITRD"/{bin,proc,sys,dev}
cp -f "$BUSYBOX_BIN" "$INITRD/bin/busybox"
chmod +x "$INITRD/bin/busybox"

cat > "$INITRD/init" <<'INIT'
#!/bin/busybox sh
/bin/busybox --install -s

mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev || mkdir -p /dev

echo
echo "Minimal Linux booted (initramfs only)."
exec sh
INIT
chmod +x "$INITRD/init"

( cd "$INITRD" && find . -print0 | cpio --null -ov --format=newc ) | gzip -9 > /mnt/EFI/Linux/initramfs.img

sync

echo "==> Creating UEFI boot entry (EFI stub kernel)"
efibootmgr -c \
  -d "$DISK" -p 1 \
  -L "$LABEL" \
  -l '\EFI\Linux\vmlinuz.efi' \
  -u "initrd=\EFI\Linux\initramfs.img rdinit=/init quiet"

echo
echo "==> Done. Reboot and choose '${LABEL}' in your firmware boot menu."

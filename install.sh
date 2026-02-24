#!/usr/bin/env bash
set -euo pipefail

### ===== CONFIG (edit these) =====
DISK="/dev/nvme0n1"          # HARD-CODED TARGET DISK (DANGEROUS)
HOSTNAME="archbox"
USERNAME="user"
TIMEZONE="America/Phoenix"
LOCALE="en_US.UTF-8"
KEYMAP="us"

# Packages to install (base already includes essentials)
PKGS=(
  base linux linux-firmware
  amd-ucode intel-ucode
  networkmanager sudo
  vim git
  grub efibootmgr
)

# Partition sizes
EFI_SIZE="512M"              # EFI System Partition
SWAP_SIZE="0"                # set like "8G" or "0" to disable swap partition

### ===== END CONFIG =====

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root from the Arch ISO (live environment)."
    exit 1
  fi
}

confirm_disk() {
  echo "Target disk: ${DISK}"
  echo "THIS WILL WIPE EVERYTHING ON ${DISK}."
  read -r -p "Type WIPE to continue: " ans
  [[ "${ans}" == "WIPE" ]] || { echo "Aborted."; exit 1; }
}

check_live_env() {
  command -v pacstrap >/dev/null
  command -v arch-chroot >/dev/null
}

wipe_and_partition_gpt_uefi() {
  # Requires UEFI boot; for BIOS/MBR you'd do different bootloader steps.
  echo "Partitioning ${DISK} (GPT + UEFI)..."

  # Unmount anything previously mounted
  umount -R /mnt 2>/dev/null || true
  swapoff -a 2>/dev/null || true

  # Zap signatures and partition table
  wipefs -af "${DISK}"
  sgdisk --zap-all "${DISK}"

  # Create partitions:
  # 1) EFI
  # 2) (optional) swap
  # 3) root
  if [[ "${SWAP_SIZE}" != "0" ]]; then
    sgdisk -n 1:0:+${EFI_SIZE} -t 1:ef00 -c 1:"EFI" "${DISK}"
    sgdisk -n 2:0:+${SWAP_SIZE} -t 2:8200 -c 2:"SWAP" "${DISK}"
    sgdisk -n 3:0:0          -t 3:8300 -c 3:"ROOT" "${DISK}"
  else
    sgdisk -n 1:0:+${EFI_SIZE} -t 1:ef00 -c 1:"EFI" "${DISK}"
    sgdisk -n 2:0:0            -t 2:8300 -c 2:"ROOT" "${DISK}"
  fi

  partprobe "${DISK}"
  sleep 1
}

set_part_vars() {
  # Handles nvme0n1pX vs sdaX naming
  if [[ "${DISK}" =~ nvme|mmcblk ]]; then
    EFI="${DISK}p1"
    if [[ "${SWAP_SIZE}" != "0" ]]; then
      SWAP="${DISK}p2"
      ROOT="${DISK}p3"
    else
      ROOT="${DISK}p2"
    fi
  else
    EFI="${DISK}1"
    if [[ "${SWAP_SIZE}" != "0" ]]; then
      SWAP="${DISK}2"
      ROOT="${DISK}3"
    else
      ROOT="${DISK}2"
    fi
  fi
}

format_and_mount() {
  echo "Formatting..."
  mkfs.fat -F32 "${EFI}"
  mkfs.ext4 -F "${ROOT}"

  if [[ "${SWAP_SIZE}" != "0" ]]; then
    mkswap "${SWAP}"
    swapon "${SWAP}"
  fi

  echo "Mounting..."
  mount "${ROOT}" /mnt
  mkdir -p /mnt/boot
  mount "${EFI}" /mnt/boot
}

install_base() {
  echo "Installing base system..."
  # Ensure time is correct for TLS
  timedatectl set-ntp true

  pacstrap -K /mnt "${PKGS[@]}"

  genfstab -U /mnt >> /mnt/etc/fstab
}

configure_system_in_chroot() {
  echo "Configuring system..."
  arch-chroot /mnt /bin/bash -euo pipefail <<EOF
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc

sed -i 's/^#${LOCALE}/${LOCALE}/' /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf

echo "${HOSTNAME}" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
HOSTS

systemctl enable NetworkManager

# Sudo + user
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
useradd -m -G wheel -s /bin/bash ${USERNAME}

echo "Set root password:"
passwd
echo "Set password for ${USERNAME}:"
passwd ${USERNAME}

# Bootloader (GRUB UEFI)
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg
EOF
}

finish() {
  echo "Done."
  echo "You can reboot. If you want to be safe:"
  echo "  umount -R /mnt"
  echo "  swapoff -a"
}

main() {
  need_root
  check_live_env
  confirm_disk

  set_part_vars
  wipe_and_partition_gpt_uefi
  set_part_vars
  format_and_mount
  install_base
  configure_system_in_chroot
  finish
}

main "$@"

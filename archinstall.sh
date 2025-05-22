#!/bin/bash

set -euo pipefail

# === USER CONFIGURATION ===
DISK="/dev/sdX"         # Устройство диска (например, /dev/sda или /dev/nvme0n1)
HOSTNAME="archlinux"    # Имя хоста
USERNAME="user"         # Имя пользователя
USER_PASSWORD="password" # Пароль пользователя
TIMEZONE="UTC"          # Таймзона (например, Europe/Moscow)
LOCALE="en_US.UTF-8"    # Локаль


# === PARTITIONS ===
EFI_PART="${DISK}1"
BOOT_PART="${DISK}2"
ROOT_PART="${DISK}3"

# === MOUNT POINTS ===
MNT="/mnt"

# === PREP ===
echo "Creating filesystems..."
mkfs.fat -F32 -n EFI "$EFI_PART"
mkfs.ext4 -L boot "$BOOT_PART"
mkfs.btrfs -f -L root "$ROOT_PART"

# === CREATE BTRFS SUBVOLUMES ===
echo "Creating BTRFS subvolumes..."
mount "$ROOT_PART" "$MNT"
btrfs subvolume create "$MNT/@"
btrfs subvolume create "$MNT/@home"
btrfs subvolume create "$MNT/@var"
btrfs subvolume create "$MNT/@.snapshots"
umount "$MNT"

# === MOUNT SUBVOLUMES ===
echo "Mounting subvolumes..."
mount -o noatime,compress=zstd,subvol=@ "$ROOT_PART" "$MNT"

mkdir -p "$MNT/"{boot,home,var,.snapshots}
mount -o noatime,compress=zstd,subvol=@home "$ROOT_PART" "$MNT/home"
mount -o noatime,compress=zstd,subvol=@var "$ROOT_PART" "$MNT/var"
mount -o noatime,compress=zstd,subvol=@.snapshots "$ROOT_PART" "$MNT/.snapshots"

mount "$BOOT_PART" "$MNT/boot"
mkdir -p "$MNT/boot/efi"
mount "$EFI_PART" "$MNT/boot/efi"

# === BASE INSTALL ===
echo "Installing base system..."
pacstrap -K "$MNT" base linux linux-firmware btrfs-progs grub efibootmgr sudo git networkmanager

# === FSTAB ===
genfstab -U "$MNT" >> "$MNT/etc/fstab"

# === CHROOT CONFIGURATION ===
arch-chroot "$MNT" /bin/bash <<EOF

ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc
echo "${LOCALE} UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf
echo "${HOSTNAME}" > /etc/hostname

# Networking
systemctl enable NetworkManager

# Add user
useradd -m -G wheel -s /bin/bash ${USERNAME}
echo "${USERNAME}:${USER_PASSWORD}" | chpasswd

# Sudo access
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Bootloader
mkdir -p /boot/efi
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# Enable Snapper (optional, can expand)
pacman -S --noconfirm snapper
snapper -c root create-config /
mv /etc/snapper/configs/root /etc/snapper/configs/@
sed -i 's|/\.snapshots|/.snapshots|' /etc/snapper/configs/@

EOF

# === DONE ===
echo "Installation complete. You can reboot now."
echo "Don't forget to set the correct device name in the script before running."
#!/bin/bash

set -euo pipefail

# Disk device (e.g., /dev/sdX)
DISK="/dev/sdX"
EFI_PART="${DISK}1"
BOOT_PART="${DISK}2"
ROOT_PART="${DISK}3"

# Hostname and user config
HOSTNAME="archlinux"
USERNAME="user"
PASSWORD="password"  # Replace with secure password or prompt

# Timezone and locale
TIMEZONE="Europe/Kyiv"
LOCALE="en_US.UTF-8"

# Partition the disk (adjust for actual disk)
sgdisk --zap-all "$DISK"
sgdisk -n 1:0:+300M -t 1:ef00 "$DISK"
sgdisk -n 2:0:+1G   -t 2:8300 "$DISK"
sgdisk -n 3:0:0     -t 3:8300 "$DISK"

# Format partitions
mkfs.fat -F32 "$EFI_PART"
mkfs.ext4 "$BOOT_PART"
mkfs.btrfs -f "$ROOT_PART"

# Create mountpoint
mount "$ROOT_PART" /mnt

# Create subvolumes
btrfs su cr /mnt/@
btrfs su cr /mnt/@home
btrfs su cr /mnt/@var
btrfs su cr /mnt/@snapshots
umount /mnt

# Mount subvolumes
mount -o noatime,compress=zstd,subvol=@ "$ROOT_PART" /mnt
mkdir -p /mnt/{boot,home,var,.snapshots,boot/efi}
mount -o noatime,compress=zstd,subvol=@home "$ROOT_PART" /mnt/home
mount -o noatime,compress=zstd,subvol=@var "$ROOT_PART" /mnt/var
mount -o noatime,compress=zstd,subvol=@snapshots "$ROOT_PART" /mnt/.snapshots
mount "$BOOT_PART" /mnt/boot
mount "$EFI_PART" /mnt/boot/efi

# Install base system
pacstrap -K /mnt base linux linux-firmware btrfs-progs sudo grub efibootmgr os-prober snapper git base-devel networkmanager

# Generate fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Chroot and configure
arch-chroot /mnt /bin/bash <<EOF

ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

sed -i "s/#$LOCALE/$LOCALE/" /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf
echo "$HOSTNAME" > /etc/hostname

# Hosts config
cat <<HOSTS > /etc/hosts
127.0.0.1       localhost
::1             localhost
127.0.1.1       $HOSTNAME.localdomain $HOSTNAME
HOSTS

# User and password
useradd -m -G wheel $USERNAME
echo "$USERNAME:$PASSWORD" | chpasswd
sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Enable services
systemctl enable NetworkManager

# Setup grub with btrfs support
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
mkdir -p /boot/grub

# Enable grub-btrfs integration
pacman -Sy --noconfirm grub-btrfs
mkdir -p /etc/grub.d
snapper --config root create-config /

# Configure snapper snapshots
systemctl enable snapper-timeline.timer
systemctl enable snapper-cleanup.timer
systemctl enable grub-btrfs.path

# Regenerate grub config
grub-mkconfig -o /boot/grub/grub.cfg
EOF

# Unmount and finish
umount -R /mnt
echo "Installation complete. Reboot your system."
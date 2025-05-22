#!/bin/bash
set -euo pipefail

# ======== CONFIG ========
DISK="/dev/sdX"  # ← ← ← УКАЖИ НУЖНЫЙ ДИСК!
USERNAME="user"
HOSTNAME="archlinux"
PASSWORD="password"  # для root и юзера
LOCALE="en_US.UTF-8"
KEYMAP="us"
TIMEZONE="Europe/Kyiv"

# ======== DISK PREP ========
wipefs -af "$DISK"
parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart primary fat32 1MiB 301MiB
parted -s "$DISK" set 1 esp on
parted -s "$DISK" mkpart primary ext4 301MiB 1300MiB
parted -s "$DISK" mkpart primary btrfs 1300MiB 100%

mkfs.fat -F32 ${DISK}1
mkfs.ext4 -L boot ${DISK}2
mkfs.btrfs -f -L root ${DISK}3

# ======== BTRFS SETUP ========
mount ${DISK}3 /mnt
btrfs su cr /mnt/@
btrfs su cr /mnt/@home
btrfs su cr /mnt/@var
btrfs su cr /mnt/@snapshots
umount /mnt

mount -o compress=zstd:3,subvol=@ ${DISK}3 /mnt
mkdir -p /mnt/{boot,home,var,.snapshots}
mount -o compress=zstd:3,subvol=@home ${DISK}3 /mnt/home
mount -o compress=zstd:3,subvol=@var ${DISK}3 /mnt/var
mount -o compress=zstd:3,subvol=@snapshots ${DISK}3 /mnt/.snapshots
mount ${DISK}2 /mnt/boot
mount ${DISK}1 /mnt/boot/efi

# ======== BASE INSTALL ========
pacstrap -K /mnt base base-devel linux linux-firmware btrfs-progs grub efibootmgr networkmanager sudo git

# ======== CONFIG ========
genfstab -U /mnt >> /mnt/etc/fstab
arch-chroot /mnt /bin/bash -e <<EOF

ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc
echo "$LOCALE UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf
echo "$HOSTNAME" > /etc/hostname
cat <<HOSTS > /etc/hosts
127.0.0.1 localhost
::1       localhost
127.0.1.1 $HOSTNAME.localdomain $HOSTNAME
HOSTS

echo root:$PASSWORD | chpasswd

useradd -m -G wheel -s /bin/bash $USERNAME
echo $USERNAME:$PASSWORD | chpasswd
sed -i '/%wheel ALL=(ALL:ALL) ALL/s/^# //' /etc/sudoers

systemctl enable NetworkManager

# Bootloader
mkdir -p /boot/efi
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
sed -i 's/^#GRUB_DISABLE_SUBMENU=.*/GRUB_DISABLE_SUBMENU=y/' /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg

# Snapper config
pacman -S --noconfirm snapper grub-btrfs inotify-tools
snapper -c root create-config /
sed -i 's|^SUBVOLUME=.*|SUBVOLUME="/"|' /etc/snapper/configs/root
mkdir -p /.snapshots
mount -a

# Hook for autosnap
mkdir -p /etc/pacman.d/hooks
cat <<HOOK > /etc/pacman.d/hooks/50-autosnap-pre.hook
[Trigger]
Operation = Upgrade
Operation = Install
Operation = Remove
Type = Package
Target = *

[Action]
Description = Create Snapper pre-snap before package upgrade
When = PreTransaction
Exec = /usr/bin/snapper --config root create --description "pre pacman"
HOOK

# Enable grub-btrfs
systemctl enable --now grub-btrfs.path

# AUR helper
pacman -S --noconfirm git
cd /home/$USERNAME
sudo -u $USERNAME git clone https://aur.archlinux.org/paru.git
cd paru
sudo -u $USERNAME makepkg -si --noconfirm

EOF

umount -R /mnt
echo "Installation complete. Reboot now."
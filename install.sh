#!/bin/bash
# Downloads and installs the system to a target disk.
# Usage: sudo bash install.sh /dev/sdX
set -euo pipefail

RELEASE_TAG="$(curl -s https://api.github.com/repos/lucasbeiler/system/releases/latest | grep "os-" | grep '"name"' | cut -d'"' -f4 | sed 's/[^0-9]//g')"
RELEASE_URL="https://github.com/lucasbeiler/system/releases/download/${RELEASE_TAG}"
DISK="${1:?Usage: sudo bash install.sh /dev/sdX}"
WORKDIR="$(mktemp -d)"

# Helpers
info() { echo -e "\e[1;32m[INFO]\e[0m  $*"; }
die()  { echo -e "\e[1;31m[ERR]\e[0m   $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root."
[[ -b "$DISK" ]]  || die "$DISK is not a block device."

# Resolve partition naming
if [[ "$DISK" =~ nvme|mmcblk ]]; then
    P="${DISK}p"
else
    P="${DISK}"
fi

# 1. Download artifacts
info "Downloading artifacts..."
curl -L --progress-bar -o "$WORKDIR/bootloader-signed.efi"                "$RELEASE_URL/bootloader-signed.efi"
curl -L --progress-bar -o "$WORKDIR/uki-${RELEASE_TAG}-signed.efi"        "$RELEASE_URL/uki-${RELEASE_TAG}-signed.efi"
curl -L --progress-bar -o "$WORKDIR/rootfs.squashfs"                      "$RELEASE_URL/rootfs.squashfs"
curl -L --progress-bar -o "$WORKDIR/rootfs.squashfs.verity"               "$RELEASE_URL/rootfs.squashfs.verity"

# TODO: Verify signatures.

# 2. Partition the disk
info "Partitioning $DISK..."
sgdisk --zap-all "$DISK"

sgdisk \
    -n 1:0:+512M   -t 1:ef00 -c 1:"ESP" \
    -n 2:0:+5G     -t 2:8300 -c 2:"root_a" \
    -n 3:0:+128M   -t 3:8300 -c 3:"verity_a" \
    -n 4:0:+5G     -t 4:8300 -c 4:"root_b" \
    -n 5:0:+128M   -t 5:8300 -c 5:"verity_b" \
    -n 6:0:0       -t 6:8300 -c 6:"data" \
    "$DISK"

partprobe "$DISK"
sleep 1

# 3. Format ESP and data
info "Formatting ESP..."
mkfs.vfat -F32 -n ESP "${P}1"

# 4. Install bootloader and UKI into ESP (no mount needed)
info "Installing systemd-boot and UKI..."
mmd -i "${P}1" ::/EFI ::/EFI/systemd ::/EFI/BOOT ::/EFI/Linux
mcopy -i "${P}1" "$WORKDIR/bootloader-signed.efi" ::/EFI/systemd/systemd-bootx64.efi
mcopy -i "${P}1" "$WORKDIR/bootloader-signed.efi" ::/EFI/BOOT/BOOTX64.EFI
mcopy -i "${P}1" "$WORKDIR/uki-${RELEASE_TAG}-signed.efi" ::/EFI/Linux/uki-${RELEASE_TAG}-signed.efi
sync

# 5. Write rootfs.squashfs to root_a
info "Writing rootfs.squashfs to root_a (${P}2)..."
dd if="$WORKDIR/rootfs.squashfs" of="${P}2" bs=4M status=progress
sync

# 6. Write verity.squashfs.verity to verity_a
info "Writing rootfs.squashfs.verity to verity_a (${P}3)..."
dd if="$WORKDIR/rootfs.squashfs.verity" of="${P}3" bs=4M status=progress
sync

# Finish
info "Formatting data partition as ext4 (in the first boot, will be turned into a LUKS volume instead)..."
mkfs.ext4 -L data "${P}6"
rm -rf "$WORKDIR"
info "Done! Layout:"
sgdisk -p "$DISK"
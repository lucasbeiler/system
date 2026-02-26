#!/usr/bin/env bash
# update.sh
# Performs an A/B update from the latest GitHub Release.
# Usage: sudo bash update.sh
set -euo pipefail

RELEASE_TAG="$(curl -s https://api.github.com/repos/lucasbeiler/system/releases/latest | grep "os-" | grep '"name"' | cut -d'"' -f4 | sed 's/[^0-9]//g')"
RELEASE_URL="https://github.com/lucasbeiler/system/releases/download/${RELEASE_TAG}"
WORKDIR="$(mktemp -d)"

# Helpers
info() { echo -e "\e[1;32m[INFO]\e[0m  $*"; }
die()  { echo -e "\e[1;31m[ERR]\e[0m   $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root."

# 1. Download artifacts
trap 'rm -rf "$WORKDIR"' EXIT
info "Downloading artifacts (build ${RELEASE_TAG})..."
curl -L --progress-bar -o "$WORKDIR/bootloader-signed.efi"                "$RELEASE_URL/bootloader-signed.efi"
curl -L --progress-bar -o "$WORKDIR/uki-${RELEASE_TAG}-signed.efi"        "$RELEASE_URL/uki-${RELEASE_TAG}-signed.efi"
curl -L --progress-bar -o "$WORKDIR/rootfs.erofs"                      "$RELEASE_URL/rootfs.erofs"
curl -L --progress-bar -o "$WORKDIR/rootfs.erofs.verity"               "$RELEASE_URL/rootfs.erofs.verity"

# TODO: Verify signatures.

# 2. Detect current slot
CURRENT_ROOT="$(findmnt -n -o SOURCE /)"
info "Current root device: $CURRENT_ROOT"

DISK="/dev/$(lsblk -no PKNAME "$CURRENT_ROOT" | head -1)"
[[ -b "$DISK" ]] || die "Could not determine parent disk of $CURRENT_ROOT."

if [[ "$DISK" =~ nvme|mmcblk ]]; then
    P="${DISK}p"
else
    P="${DISK}"
fi

if [[ "$CURRENT_ROOT" == "${P}2" ]]; then
    CURRENT_SLOT="a"
    TARGET_ROOT="${P}4"
    TARGET_VERITY="${P}5"
elif [[ "$CURRENT_ROOT" == "${P}4" ]]; then
    CURRENT_SLOT="b"
    TARGET_ROOT="${P}2"
    TARGET_VERITY="${P}3"
else
    die "Cannot determine current slot from ${CURRENT_ROOT}, expected ${P}2 or ${P}4."
fi

TARGET_SLOT="$([[ $CURRENT_SLOT == a ]] && echo b || echo a)"
info "Current slot: $CURRENT_SLOT"
info "Writing to slot: $TARGET_SLOT ($TARGET_ROOT)"

# 3. Write rootfs and verity to the inactive slots
info "Writing rootfs.erofs to $TARGET_ROOT..."
dd if="$WORKDIR/rootfs.erofs" of="$TARGET_ROOT" bs=4M status=progress
sync

info "Writing rootfs.erofs.verity to $TARGET_VERITY..."
dd if="$WORKDIR/rootfs.erofs.verity" of="$TARGET_VERITY" bs=4M status=progress
sync

# 4. Update bootloader and UKI in ESP
info "Updating ESP..."
mcopy -i "${P}1" "$WORKDIR/bootloader-signed.efi" ::/EFI/systemd/systemd-bootx64.efi
mcopy -i "${P}1" "$WORKDIR/bootloader-signed.efi" ::/EFI/BOOT/BOOTX64.EFI
mcopy -i "${P}1" "$WORKDIR/uki-${RELEASE_TAG}-signed.efi" ::/EFI/Linux/uki-${RELEASE_TAG}-signed.efi
sync

# 5. Reboot
info "Update complete. Rebooting..."
reboot
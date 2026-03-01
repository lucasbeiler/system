
#!/bin/sh
# update.sh
# Performs an A/B update from the latest GitHub Release.
# Usage: sudo sh update.sh

set -eu

RELEASES_URL="https://api.github.com/repos/lucasbeiler/system/releases"
WORKDIR="$(mktemp -d)"

info() { printf '\033[1;32m[INFO]\033[0m  %s\n' "$*"; }
die() { printf '\033[1;31m[ERR]\033[0m   %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run as root."

info "Fetching latest release metadata..."
json="$(curl -s "$RELEASES_URL")" || die "Failed to fetch releases."

RELEASE_TAG="$(printf '%s\n' "$json" | grep -i "os-" | grep '"name"' | head -1 | cut -d'"' -f4 | sed 's/[^0-9]//g')"
[ -n "$RELEASE_TAG" ] || die "Could not determine release tag."

RELEASE_URL="https://github.com/lucasbeiler/system/releases/download/${RELEASE_TAG}"

trap 'rm -rf "$WORKDIR"' EXIT INT TERM

info "Downloading artifacts (build ${RELEASE_TAG})..."

curl -L -f --progress-bar -o "$WORKDIR/bootloader-signed.efi" "$RELEASE_URL/bootloader-signed.efi" || die "Failed bootloader download"
curl -L -f --progress-bar -o "$WORKDIR/uki-${RELEASE_TAG}-signed.efi" "$RELEASE_URL/uki-${RELEASE_TAG}-signed.efi" || die "Failed UKI download"
curl -L -f --progress-bar -o "$WORKDIR/rootfs.erofs" "$RELEASE_URL/rootfs.erofs" || die "Failed rootfs download"
curl -L -f --progress-bar -o "$WORKDIR/rootfs.erofs.verity" "$RELEASE_URL/rootfs.erofs.verity" || die "Failed verity download"

CURRENT_ROOT="/dev/$(ls /sys/class/block/dm-0/slaves/  | sort | head -1)" || die "Cannot detect current partition."
[ -b "$CURRENT_ROOT" ] || die "$CURRENT_ROOT is not a block device."
DISK=$(echo "$CURRENT_ROOT" | sed 's/[0-9]*$//')

if echo "$CURRENT_ROOT" | grep -q '2$' ; then
  CURRENT_SLOT="a"
  TARGET_ROOT="${DISK}4"
  TARGET_VERITY="${DISK}5"
elif "$CURRENT_ROOT" | grep -q '4$'; then
  CURRENT_SLOT="b"
  TARGET_ROOT="${DISK}2"
  TARGET_VERITY="${DISK}3"
else
  die "Cannot determine current slot from ${CURRENT_ROOT}, expected ${DISK}2 or ${DISK}4."
fi

if [ "$CURRENT_SLOT" = "a" ]; then TARGET_SLOT="b"; else TARGET_SLOT="a"; fi

info "Current slot: $CURRENT_SLOT ($CURRENT_ROOT)"
info "Writing to slot: $TARGET_SLOT ($TARGET_ROOT and $TARGET_VERITY)"
info "Writing rootfs.erofs to $TARGET_ROOT..."
dd if="$WORKDIR/rootfs.erofs" of="$TARGET_ROOT" bs=4M || die "dd rootfs failed"
sync

info "Writing rootfs.erofs.verity to $TARGET_VERITY..."
dd if="$WORKDIR/rootfs.erofs.verity" of="$TARGET_VERITY" bs=4M || die "dd verity failed"
sync

info "Updating ESP..."
mcopy -i "${DISK}1" "$WORKDIR/bootloader-signed.efi" ::/EFI/systemd/systemd-bootx64.efi || die "Failed updating systemd-boot"
mcopy -i "${DISK}1" "$WORKDIR/bootloader-signed.efi" ::/EFI/BOOT/BOOTX64.EFI || die "Failed updating fallback bootloader"
mcopy -i "${DISK}1" "$WORKDIR/uki-${RELEASE_TAG}-signed.efi" ::/EFI/Linux/uki-${RELEASE_TAG}-signed.efi || die "Failed updating UKI"
sync

info "Update complete. Rebooting..."
#reboot
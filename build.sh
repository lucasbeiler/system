#!/bin/bash
set -euo pipefail

# Architecture and Alpine version.
ARCH=$(uname -m)
VERSION=v3.23
MIRROR=https://dl-cdn.alpinelinux.org/alpine
WORKDIR=/hardenedos/rootfs
OUTPUT=/hardenedos/rootfs.erofs
ENABLE_TESTING=false

# Require root. TODO: If possible, all the building process should run in a REPRODUCIBLE and ROOTLESS environment as soon as possible! 
if [ "$EUID" -ne 0 ]; then echo "Be root!"; exit 1; fi;

# Clean up previous work
umount ${WORKDIR}/dev ${WORKDIR}/proc ${WORKDIR}/sys 2>/dev/null || :
rm -rf $WORKDIR && mkdir -p $WORKDIR

# Prepare chroot with pseudofilesystems.
mkdir -p ${WORKDIR}/proc ${WORKDIR}/dev ${WORKDIR}/sys
for pseudofs in proc sys dev; do mount -o bind /${pseudofs} ${WORKDIR}/${pseudofs}; done

# Prepare basic DNS connectivity inside the chroot.
mkdir -p ${WORKDIR}/etc/
echo "nameserver 9.9.9.9" > ${WORKDIR}/etc/resolv.conf

# Set up the official package repositories. 
# In the future, I'll have my own repositories for some specific packages (hardened builds of Chromium, iwd, and other security-critical software). 
# And, also, I'll continuously test for Reproducible Builds for the packages that I use from the Alpine repositories.
mkdir -p ${WORKDIR}/etc/apk/keys
echo "$MIRROR/$VERSION/main" >> $WORKDIR/etc/apk/repositories
echo "$MIRROR/$VERSION/community" >> $WORKDIR/etc/apk/repositories
if [[ $VERSION == "edge" || $ENABLE_TESTING == true ]]; then
  echo "$MIRROR/edge/testing" >> $WORKDIR/etc/apk/repositories
fi

# Install the base packages.
apk --keys-dir=/usr/share/apk/keys/ -p $WORKDIR --arch $ARCH --initdb --no-cache add alpine-base alpine-baselayout acpid busybox busybox-suid musl-utils openssl argon2 fortify-headers iwd e2fsprogs e2fsprogs-extra util-linux tpm2-tools tpm2-tss-dev tpm2-tss-tcti-device fscrypt fscryptctl \
  iptables pipewire-pulse pipewire wireplumber pavucontrol apparmor apparmor-profiles apparmor-utils checksec-rs dnscrypt-proxy curl \
  cryptsetup dbus font-terminus mesa linux-firmware-intel sof-firmware linux-stable linux-stable-dev linux-headers pciutils chromium bash eudev udev-init-scripts \
  sway river mako grim fastfetch slurp flameshot swaybg swaylock swayidle kanshi fuzzel yazi waybar alacritty font-dejavu libinput jq git sbctl cryptsetup-dev argon2 argon2-dev argon2-libs musl-dev \
  mesa-dri-gallium mesa-va-gallium iproute2-minimal openssh-client-default mesa-vulkan-intel intel-media-driver libva-intel-driver linux-firmware-i915 linux-firmware-xe intel-ucode wayland-protocols \
  alsa-utils alsaconf pipewire-alsa pipewire-jack font-jetbrains-mono-nerd font-iosevka font-awesome font-liberation font-noto font-noto-emoji power-profiles-daemon

apk -p $WORKDIR --arch $ARCH --no-cache -X https://dl-cdn.alpinelinux.org/alpine/edge/testing add ntpd-rs hardened-malloc ukify systemd-efistub

# TODO: Copy Secure Boot public keys / certs to /var/lib/sbctl/keys/{PK,KEK,db}/*.pem
# TODO: ... then add sbctl's binary and /var/lib/sbctl/keys/ to the initramfs.
# TODO: ... then run sbctl enroll-keys if `sbctl status` shows, in the initramfs, that Secure Boot is enabled in its setup mode.
# Populate root with some configuration files and such.
cp -r root_files/* ${WORKDIR}/

chroot $WORKDIR /bin/sh <<'EOF'
rc-update add acpid default
rc-update add bootmisc boot
rc-update add crond default
rc-update add dbus
rc-update add devfs sysinit
rc-update add dmesg sysinit
rc-update add hostname boot
rc-update add hwclock boot
rc-update add hwdrivers sysinit
rc-update add iptables
rc-update add iwd boot
rc-update add killprocs shutdown
rc-update add mdev sysinit
rc-update add modules boot
rc-update add mount-ro shutdown
rc-update add networking boot
rc-update add ntpd-rs
rc-update add savecache shutdown
rc-update add seedrng boot
rc-update add setup-crosvm-net default
rc-update add swap boot
rc-update add sysctl boot
rc-update add udev sysinit
rc-update add udev-postmount default
rc-update add udev-settle sysinit
rc-update add udev-trigger sysinit
rc-update del networking boot
# rc-update add apparmor boot # TODO: Needs a patched kernel to work.
# rc-update add dnscrypt-proxy # TODO: Patch its configuration to my liking.

# Enable my services.
rc-update add setup-crosvm-net default

setup-desktop sway

# TODO: Do not build as root like this... Or maybe remove altogether and built it elsewhere.
# sh -c "cd /usr/src/crypt/tpm2_luks && cargo build --release && install -m 755 target/release/tpm2_luks /usr/local/bin/crypter"
# [ -f /usr/local/bin/crosvm ] || sh -c 'apk del rust cargo && apk add llvm-dev libcap-dev git rustup wayland-dev gcc clang python3 libcap dtc py3-rich py3-argh && git clone https://chromium.googlesource.com/crosvm/crosvm && cd crosvm && git submodule update --init && rustup-init -y && . "$HOME/.cargo/env" && RUSTFLAGS="-C target-feature=-crt-static" cargo build --release --features gpu && install -m 755 target/release/crosvm /usr/local/bin/crosvm && rm -rf /crosvm /root/.rustup /root/.cargo'

# Lock root user forever. # TODO: Keep uncommented.
# passwd -l root 

# Some misc setup and workarounds.
echo 'mkdir -p ${XDG_RUNTIME_DIR}/openrc && touch ${XDG_RUNTIME_DIR}/openrc/softlevel && rc-service -U pipewire-pulse start' >> /etc/profile
sed -i 's/^SAVE_ON_STOP=.*/SAVE_ON_STOP="no"/' /etc/conf.d/iptables /etc/conf.d/ip6tables

# Symlink some things to /data, but only the things that really need to be read-write.
mkdir /data
rm -rf /home/ /var/lib/iwd/ /var/empty/ /var/lock/ /var/log/
cp /etc/shadow /etc/shadow.bkp
cp /etc/passwd /etc/passwd.bkp
cp /etc/group  /etc/group.bkp
ln -sf /data/etc/shadow /etc/shadow
ln -sf /data/etc/passwd /etc/passwd
ln -sf /data/etc/group /etc/group
ln -sf /data/home /home
ln -sf /data/var/lib/iwd /var/lib/iwd
ln -sf /data/var/empty /var/empty
ln -sf /data/var/log /var/log
ln -sf /data/var/lock /var/lock
EOF

# Change VERSION_ID.
sed -i 's/^VERSION_ID=.*/VERSION_ID='"$OS_BUILD_TAG"'/' ${WORKDIR}/etc/os-release

# Umount things.
umount ${WORKDIR}/dev ${WORKDIR}/proc ${WORKDIR}/sys 2>/dev/null

# Create an ERPOFS image.
rm -f $OUTPUT
mkfs.erofs -L ${OS_BUILD_TAG} -zlz4hc,12 -C65536 -Efragments,ztailpacking $OUTPUT $WORKDIR
VERITY_INFO=$(veritysetup format "$OUTPUT" "${OUTPUT}.verity")
echo "Done: $OUTPUT"

# The rootfs image is already done and verity'ed, so let's (re)create the initramfs now (it needs the verityhash)...
echo "$VERITY_INFO" | awk '/Root hash:/ {print $3}' | tee ${WORKDIR}/verityhash
echo "${OS_BUILD_TAG}" > ${WORKDIR}/os_build_tag
chroot ${WORKDIR} mkinitfs $(ls ${WORKDIR}/lib/modules | head -n1)

# Generate Unified Kernel Image
chroot ${WORKDIR} ukify build \
    --output "/boot/uki.efi" \
    --cmdline "root=/dev/mapper/root rootfstype=erofs" \
    --microcode "/boot/intel-ucode.img" \
    --linux "/boot/vmlinuz-stable" \
    --initrd "/boot/initramfs-stable"
rm ${WORKDIR}/boot/vmlinuz* ${WORKDIR}/boot/initramfs*

# Prepare signed bootloader, UKI and rootfs images.
mv /usr/lib/systemd/boot/efi/systemd-bootx64.efi /hardenedos/bootloader.efi
sbsign --key /tmp/sbsign/keys/db/db.key \
       --cert /tmp/sbsign/keys/db/db.pem \
       --output /hardenedos/bootloader-signed.efi /hardenedos/bootloader.efi

sbsign --key /tmp/sbsign/keys/db/db.key \
       --cert /tmp/sbsign/keys/db/db.pem \
       --output ${WORKDIR}/boot/uki-${OS_BUILD_TAG}-signed.efi ${WORKDIR}/boot/uki.efi

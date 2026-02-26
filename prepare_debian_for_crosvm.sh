#!/usr/bin/env bash
set -euo pipefail


WORKDIR="${1:-/opt/crosvm-image}"
ROOTFS_DIR="$WORKDIR/deb_rootfs"
ROOTFS_IMG="$WORKDIR/deb_rootfs.ext4"
ROOTFS_SIZE="1G"
DEBIAN_SUITE="trixie"
DEBIAN_MIRROR="https://deb.debian.org/debian"
KERNEL_PKG="linux-image-amd64"
HOSTNAME="crosvm-guest"
ROOT_PASSWORD="root"

info()  { echo -e "\e[1;32m[INFO]\e[0m  $*"; }
warn()  { echo -e "\e[1;33m[WARN]\e[0m  $*"; }
die()   { echo -e "\e[1;31m[ERR]\e[0m   $*" >&2; exit 1; }

require_root() {
    [[ $EUID -eq 0 ]] || die "Be root: sudo bash $0"
}

check_deps() {
    local missing=()
    for cmd in debootstrap qemu-img mkfs.ext4 mount umount chroot; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Install: ${missing[*]}\n"
    fi
}

cleanup() {
    info "Finishing up..."
    for mp in "$ROOTFS_DIR/boot" "$ROOTFS_DIR/proc" "$ROOTFS_DIR/sys" \
              "$ROOTFS_DIR/dev/pts" "$ROOTFS_DIR/dev" "$ROOTFS_DIR"; do
        mountpoint -q "$mp" 2>/dev/null && umount -lf "$mp" 2>/dev/null || true
    done
}
trap cleanup EXIT


require_root
check_deps
mkdir -p "$WORKDIR" "$ROOTFS_DIR"

info "Creating image ($ROOTFS_SIZE)..."
if [[ ! -f "$ROOTFS_IMG" ]]; then
    qemu-img create -f raw "$ROOTFS_IMG" "$ROOTFS_SIZE"
    mkfs.ext4 -F -L "debian-root" "$ROOTFS_IMG"
fi

info "Mounting rootfs..."
mount -o loop "$ROOTFS_IMG" "$ROOTFS_DIR"

info "Preparing Debian..."
debootstrap \
    --arch=amd64 \
    --include="linux-image-cloud-amd64,systemd,systemd-sysv,udev,dbus,\
sudo,openssh-server,ca-certificates,curl,vim,iproute2,iputils-ping,\
bash-completion,less,locales,tzdata" \
    "$DEBIAN_SUITE" \
    "$ROOTFS_DIR" \
    "$DEBIAN_MIRROR"


info "Preparing Debian..."

mount --bind /dev  "$ROOTFS_DIR/dev"
mount --bind /dev/pts "$ROOTFS_DIR/dev/pts" 2>/dev/null || true
mount -t proc  proc  "$ROOTFS_DIR/proc"
mount -t sysfs sysfs "$ROOTFS_DIR/sys"

chroot "$ROOTFS_DIR" /bin/bash -ex <<CHROOT
# Hostname
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
127.0.1.1   $HOSTNAME
::1         localhost ip6-localhost ip6-loopback
EOF

echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
ln -sf /usr/share/zoneinfo/America/Sao_Paulo /etc/localtime

echo "root:$ROOT_PASSWORD" | chpasswd

# Login serial (crosvm uses virtio-console / ttyS0)
systemctl enable serial-getty@ttyS0.service 2>/dev/null || true
systemctl enable getty@tty1.service 2>/dev/null || true

sed -i \
    -e 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' \
    -e 's/^#*PermitRootLogin.*/PermitRootLogin yes/' \
    /etc/ssh/sshd_config

systemctl disable apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true

cat > /etc/fstab <<EOF
/dev/vda   /          ext4   defaults  0 1
tmpfs      /tmp       tmpfs  defaults                     0 0
EOF

mkdir -p /etc/systemd/network
cat > /etc/systemd/network/20-wired.network <<EOF
[Match]
Name=en* eth*

[Network]
DHCP=yes
EOF
systemctl enable systemd-networkd systemd-resolved 2>/dev/null || true

dpkg -l $KERNEL_PKG &>/dev/null || apt-get install -y $KERNEL_PKG

cat > /etc/systemd/system/guest-network.service <<'EOF'
[Unit]
Description=Static guest network (crosvm virtio-net)
After=network-pre.target
Before=network.target
Wants=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/guest-network-up.sh

[Install]
WantedBy=multi-user.target
EOF

cat > /usr/local/bin/guest-network-up.sh <<'EOF'
#!/usr/bin/env bash
# Find the only non-lo interface.
GUEST_DEV=\$(ip -o link show | awk -F': ' '\$2 != "lo" {print \$2; exit}')

if [[ -z "\$GUEST_DEV" ]]; then
    echo "guest-network: no interface found. Bye." >&2
    exit 1
fi

ip addr add 192.168.10.2/24 dev "\$GUEST_DEV"
ip link set "\$GUEST_DEV" up
ip route add default via 192.168.10.1
echo "nameserver 8.8.8.8" > /etc/resolv.conf
EOF

chmod +x /usr/local/bin/guest-network-up.sh
systemctl enable guest-network.service


echo "==> Finished chroot!"
CHROOT

# Extract kernel and initramfs.
info "Extracting kernel and initramfs..."
VMLINUZ_SRC=$(ls "$ROOTFS_DIR/boot/vmlinuz-"* 2>/dev/null | sort -V | tail -1)
INITRD_SRC=$(ls  "$ROOTFS_DIR/boot/initrd.img-"* 2>/dev/null | sort -V | tail -1)

[[ -f "$VMLINUZ_SRC" ]] || die "vmlinuz not found: $ROOTFS_DIR/boot/"
[[ -f "$INITRD_SRC"  ]] || die "initrd not found: $ROOTFS_DIR/boot/"

KERNEL_VERSION=$(basename "$VMLINUZ_SRC" | sed 's/vmlinuz-//')
info "Kernel: $KERNEL_VERSION"

if command -v extract-vmlinux &>/dev/null; then
    extract-vmlinux "$VMLINUZ_SRC" > "$WORKDIR/vmlinuz" || cp "$VMLINUZ_SRC" "$WORKDIR/vmlinuz"
else
    cp "$VMLINUZ_SRC" "$WORKDIR/vmlinuz"
fi
cp "$INITRD_SRC" "$WORKDIR/initrd.img"

info "Kernel:    $WORKDIR/vmlinuz"
info "Initramfs: $WORKDIR/initrd.img"
info "Rootfs:    $WORKDIR/deb_rootfs.ext4"
sync
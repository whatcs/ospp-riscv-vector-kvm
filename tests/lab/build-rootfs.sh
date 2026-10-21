#!/bin/bash
# Build a persistent Ubuntu riscv64 lab without modifying the x86 host OS.
set -euo pipefail
lab=/home/riscv/ws/lab
rootfs="$lab/rootfs"
stages="$lab/stages"
mkdir -p "$stages" "$lab/images" "$rootfs"
exec 9>"$lab/build.lock"
flock -n 9 || { echo 'Another rootfs builder is running'; exit 1; }
printf 'running\n' > "$lab/build.result"
trap 'code=$?; printf "exit=%s\n" "$code" > "$lab/build.result"' EXIT

if ! test -f "$stages/foreign"; then
    mkdir -p "$rootfs/var/cache/apt/archives"
    if test -d /home/riscv/rootfs-base/var/cache/apt/archives; then
        cp -an /home/riscv/rootfs-base/var/cache/apt/archives/. \
            "$rootfs/var/cache/apt/archives/"
    fi
    debootstrap --arch=riscv64 --foreign --variant=minbase --components=main \
        --include=ca-certificates noble "$rootfs" \
        https://mirrors.ustc.edu.cn/ubuntu-ports
    touch "$stages/foreign"
fi

if ! test -f "$stages/second"; then
    chroot "$rootfs" /debootstrap/debootstrap --second-stage
    touch "$stages/second"
fi

install -m 644 "$lab/config/sources.list" "$rootfs/etc/apt/sources.list"
install -m 755 "$lab/config/policy-rc.d" "$rootfs/usr/sbin/policy-rc.d"
cp -L /etc/resolv.conf "$rootfs/etc/resolv.conf"
mkdir -p "$rootfs/proc" "$rootfs/sys" "$rootfs/dev" "$rootfs/run"
mountpoint -q "$rootfs/proc" || mount -t proc proc "$rootfs/proc"
mountpoint -q "$rootfs/sys" || mount -t sysfs sysfs "$rootfs/sys"
mountpoint -q "$rootfs/dev" || mount --rbind /dev "$rootfs/dev"
mount --make-rslave "$rootfs/dev"
cleanup() {
    code=$?
    umount -R "$rootfs/dev" || true
    umount "$rootfs/sys" || true
    umount "$rootfs/proc" || true
    printf 'exit=%s\n' "$code" > "$lab/build.result"
}
trap cleanup EXIT

if ! test -f "$stages/packages" || ! test -x "$rootfs/usr/lib/systemd/systemd-udevd"; then
    chroot "$rootfs" apt-get -o Acquire::Retries=3 update
    chroot "$rootfs" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
        apt-get -o Acquire::Retries=3 install -y --no-install-recommends \
        systemd-sysv udev openssh-server iproute2 iputils-ping kmod util-linux \
        procps ca-certificates qemu-system-misc opensbi busybox-static
    touch "$stages/packages"
fi

mkdir -p "$rootfs/etc/systemd/network" "$rootfs/etc/ssh/sshd_config.d" \
    "$rootfs/root/.ssh" "$rootfs/opt/ospp"
install -m 644 "$lab/config/20-wired.network" "$rootfs/etc/systemd/network/20-wired.network"
install -m 644 "$lab/config/20-ospp.conf" "$rootfs/etc/ssh/sshd_config.d/20-ospp.conf"
install -m 600 "$lab/id_ed25519.pub" "$rootfs/root/.ssh/authorized_keys"
chmod 700 "$rootfs/root/.ssh"
printf 'ospp-riscv\n' > "$rootfs/etc/hostname"
printf '127.0.0.1 localhost\n127.0.1.1 ospp-riscv\n' > "$rootfs/etc/hosts"
printf 'nameserver 10.0.2.3\n' > "$rootfs/etc/resolv.conf"
systemctl --root="$rootfs" enable systemd-networkd.service ssh.service
systemctl --root="$rootfs" disable ssh.socket || true
systemctl --root="$rootfs" mask systemd-networkd-wait-online.service
install -m 644 /home/riscv/ws/build-l1/arch/riscv/boot/Image "$rootfs/opt/ospp/Image"
install -m 644 /home/riscv/ws/build-l1/arch/riscv/kvm/kvm.ko "$rootfs/opt/ospp/kvm.ko"
install -m 755 "$lab/rvv-smoke" "$rootfs/opt/ospp/rvv-smoke"
install -m 755 "$lab/start-l2.sh" "$rootfs/opt/ospp/start-l2.sh"

umount -R "$rootfs/dev"
umount "$rootfs/sys"
umount "$rootfs/proc"
trap 'code=$?; printf "exit=%s\n" "$code" > "$lab/build.result"' EXIT

for spec in l1:8G l2:4G; do
    name=${spec%:*}
    size=${spec#*:}
    image="$lab/images/$name.ext4"
    if test -f "$stages/$name-image"; then
        continue
    fi
    if test -e "$image"; then
        echo "Refusing to overwrite an existing unmarked image: $image" >&2
        exit 1
    fi
    truncate -s "$size" "$image"
    mkfs.ext4 -q -F -L "ospp-$name" -d "$rootfs" "$image"
    chown riscv:riscv "$image"
    touch "$stages/$name-image"
done
echo ROOTFS_READY

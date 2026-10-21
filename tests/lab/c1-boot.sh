#!/bin/bash
set -euo pipefail
lab=/home/riscv/ws/lab
for name in c1-n l1; do
    root=$(mktemp -d "$lab/c1-$name.XXXXXX")
    mkdir -p "$root"/{bin,proc,sys,dev}
    install -m 755 /home/riscv/rootfs-min/bin/busybox "$root/bin/busybox"
    for app in sh mount uname insmod ls dmesg grep poweroff; do
        ln -s busybox "$root/bin/$app"
    done
    install -m 755 "$lab/c1-init" "$root/init"
    install -m 644 "/home/riscv/ws/build-$name/arch/riscv/kvm/kvm.ko" "$root/kvm.ko"
    (cd "$root"; find . -print0 | cpio --null -o -H newc | gzip) > "$lab/c1-$name.cpio.gz"
    timeout 180 qemu-system-riscv64 -machine virt -accel tcg \
        -cpu rv64,h=true,v=true,vlen=256 -m 1024 -smp 2 -nographic \
        -bios /usr/lib/riscv64-linux-gnu/opensbi/generic/fw_dynamic.bin \
        -kernel "/home/riscv/ws/build-$name/arch/riscv/boot/Image" \
        -initrd "$lab/c1-$name.cpio.gz" \
        -append 'console=ttyS0 loglevel=5' > "$lab/c1-$name-boot.log" 2>&1
    grep -q '^C1_BOOT_PASS' "$lab/c1-$name-boot.log"
    if grep -q '^C1_BOOT_FAIL' "$lab/c1-$name-boot.log"; then exit 1; fi
    echo "$name BOOT_PASS"
done
echo C1_BOOT_VERIFIED

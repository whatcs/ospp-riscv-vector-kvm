#!/bin/bash
set -euo pipefail
lab=/home/riscv/ws/lab
if test -s "$lab/l1.pid" && kill -0 "$(cat "$lab/l1.pid")" 2>/dev/null; then
    if grep -zFq "$lab/images/l1.ext4" "/proc/$(cat "$lab/l1.pid")/cmdline"; then
        echo 'L1 is already running'
        exit 0
    fi
    echo 'L1 pidfile refers to a different process' >&2
    exit 1
fi
exec qemu-system-riscv64 \
    -machine virt -accel tcg -cpu rv64,h=true,v=true,vlen=256 \
    -m 4096 -smp 8 -display none -monitor none \
    -serial "file:$lab/l1-console.log" \
    -qmp "unix:$lab/l1-qmp.sock,server=on,wait=off" \
    -pidfile "$lab/l1.pid" -daemonize \
    -bios /usr/lib/riscv64-linux-gnu/opensbi/generic/fw_dynamic.bin \
    -kernel /home/riscv/ws/build-l1/arch/riscv/boot/Image \
    -append 'root=/dev/vda rw console=ttyS0 earlycon=sbi loglevel=4' \
    -drive "file=$lab/images/l1.ext4,format=raw,if=none,id=l1" \
    -device virtio-blk-device,drive=l1 \
    -drive "file=$lab/images/l2.ext4,format=raw,if=none,id=l2" \
    -device virtio-blk-device,drive=l2 \
    -netdev user,id=net0,hostfwd=tcp:127.0.0.1:7722-:22 \
    -device virtio-net-device,netdev=net0 \
    -rtc clock=host,base=utc

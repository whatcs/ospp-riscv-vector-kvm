#!/bin/bash
set -euo pipefail
if test -s /run/ospp-l2.pid && kill -0 "$(cat /run/ospp-l2.pid)" 2>/dev/null; then
    if grep -zFq 'file=/dev/vdb' "/proc/$(cat /run/ospp-l2.pid)/cmdline"; then
        echo 'L2 is already running'
        exit 0
    fi
    echo 'L2 pidfile refers to a different process' >&2
    exit 1
fi
test -c /dev/kvm
test -b /dev/vdb
# /dev/vdb is the dedicated L2 disk attached by start-l1.sh.
if findmnt -rn -S /dev/vdb >/dev/null; then
    echo 'L2 disk is mounted in L1; refusing concurrent access' >&2
    exit 1
fi
exec qemu-system-riscv64 \
    -machine virt -accel kvm -cpu host \
    -m 1536 -smp 2 -display none -monitor none \
    -serial file:/var/log/ospp-l2-console.log \
    -qmp tcp:127.0.0.1:8444,server=on,wait=off \
    -pidfile /run/ospp-l2.pid -daemonize \
    -bios none -kernel /opt/ospp/Image \
    -append 'root=/dev/vda rw console=ttyS0 earlycon=sbi loglevel=4' \
    -drive file=/dev/vdb,format=raw,if=none,id=l2 \
    -device virtio-blk-device,drive=l2 \
    -netdev user,id=net0,hostfwd=tcp:127.0.0.1:8822-:22 \
    -device virtio-net-device,netdev=net0 \
    -rtc clock=host,base=utc

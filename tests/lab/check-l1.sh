#!/bin/bash
set -euo pipefail
uname -a
grep -m1 '^isa' /proc/cpuinfo
/opt/ospp/rvv-smoke
if ! test -c /dev/kvm; then
    insmod /opt/ospp/kvm.ko
fi
test -c /dev/kvm
ls -l /dev/kvm
dmesg | grep 'kvm \['
qemu-system-riscv64 --version | head -n 1
qemu-system-riscv64 -accel help
echo L1_READY

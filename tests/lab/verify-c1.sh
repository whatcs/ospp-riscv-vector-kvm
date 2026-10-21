#!/bin/bash
set -euo pipefail
cd /home/riscv/ws/linux
git branch --show-current
git rev-parse HEAD
git diff --check
git diff | ./scripts/checkpatch.pl --strict --no-signoff -
test "$(cat /home/riscv/ws/c1-full-build.result)" = PASS
for name in c1-n l1; do
    build=/home/riscv/ws/build-$name
    grep -E '^(# CONFIG_RISCV_ISA_V is not set|CONFIG_RISCV_ISA_V=y|CONFIG_KVM=)' "$build/.config"
    test -s "$build/Module.symvers"
    test -s "$build/arch/riscv/boot/Image"
    test -s "$build/arch/riscv/kvm/kvm.ko"
    sha256sum "$build/arch/riscv/boot/Image" "$build/arch/riscv/kvm/kvm.ko"
    riscv64-linux-gnu-readelf -h "$build/arch/riscv/kvm/kvm.ko" | grep Machine
    modinfo -F vermagic "$build/arch/riscv/kvm/kvm.ko"
done
if riscv64-linux-gnu-nm -u /home/riscv/ws/build-c1-n/arch/riscv/kvm/kvm.ko |
    grep -E 'get_cpu_vector_context|put_cpu_vector_context|__kvm_riscv_vector_restore'; then
    echo 'FAIL: unresolved vector helper in V=n module' >&2
    exit 1
fi
printf 'C1_VERIFIED\n'

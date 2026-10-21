#!/bin/bash
set -euo pipefail

if test "$#" -ne 2; then
	echo "usage: $0 L2_VCPU0_TID L2_VCPU1_TID" >&2
	exit 2
fi

l2_vcpu0=$1
l2_vcpu1=$2
tracefs=/sys/kernel/tracing
trace=/opt/ospp/m1c-on-one-reg.trace
test_bin=/opt/ospp/vector-one-reg-owner

test -d "/proc/$l2_vcpu0"
test -d "/proc/$l2_vcpu1"
test -x "$test_bin"

cleanup()
{
	taskset -pc 0-7 "$l2_vcpu0" >/dev/null 2>&1 || true
	taskset -pc 0-7 "$l2_vcpu1" >/dev/null 2>&1 || true
	echo 0 > "$tracefs/tracing_on" 2>/dev/null || true
}
trap cleanup EXIT

# Keep the already running L2 VM away from CPU7 so the one-vCPU selftest can
# exercise a deterministic same-hart owner hit between its KVM_RUN calls.
taskset -pc 0-6 "$l2_vcpu0" >/dev/null
taskset -pc 0-6 "$l2_vcpu1" >/dev/null

echo 0 > "$tracefs/tracing_on"
echo 0 > "$tracefs/events/kvm/enable"
echo > "$tracefs/trace"
echo 1 > "$tracefs/events/kvm/kvm_riscv_vector_shadow/enable"
echo 1 > "$tracefs/events/kvm/kvm_riscv_vector_restore_request/enable"
echo 1 > "$tracefs/events/kvm/kvm_riscv_vector_restore/enable"
echo 1 > "$tracefs/tracing_on"

taskset -c 7 "$test_bin"

echo 0 > "$tracefs/tracing_on"
cp "$tracefs/trace" "$trace"

awk '
	/M1C_ONE_REG_AFTER_GET/ { after_get = 1 }
	after_get && /reason: hit/ { get_hit = 1 }
	get_hit && /mode: csr/ { get_csr = 1 }
	/M1C_ONE_REG_AFTER_SET/ { after_set = 1 }
	after_set && /reason: generation/ { set_generation = 1 }
	set_generation && /mode: full/ { set_full = 1 }
	END { exit !(get_hit && get_csr && set_generation && set_full) }
' "$trace"

grep -E 'M1C_ONE_REG|reason: (hit|generation)|mode: (csr|full)' "$trace"
sha256sum "$trace"

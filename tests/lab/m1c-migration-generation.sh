#!/bin/sh
set -eu

if test "$#" -ne 2; then
	echo "usage: $0 VCPU0_TID VCPU1_TID" >&2
	exit 2
fi

vcpu0=$1
vcpu1=$2
tracefs=/sys/kernel/tracing
trace=/opt/ospp/m1c-on-migration-generation.trace
key=/opt/ospp/lab_id_ed25519

test -d "/proc/$vcpu0"
test -d "/proc/$vcpu1"
test -r "$key"

cleanup()
{
	taskset -pc 0-7 "$vcpu0" >/dev/null 2>&1 || true
	taskset -pc 0-7 "$vcpu1" >/dev/null 2>&1 || true
	echo 0 > "$tracefs/tracing_on" 2>/dev/null || true
}
trap cleanup EXIT

run_l2()
{
	count=$1
	passed=$(ssh -i "$key" -p 8822 \
		-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		root@127.0.0.1 \
		"seq $count | xargs -I@ taskset -c 0 /opt/ospp/rvv-smoke | grep -c RVV_PASS")
	test "$passed" = "$count"
	printf 'L2_RVV_PASS cpu=0 count=%s\n' "$passed"
}

# Keep the other vCPU away from CPU6/7 so it cannot replace the target owner.
taskset -pc 0 "$vcpu1" >/dev/null
taskset -pc 6 "$vcpu0" >/dev/null

echo 0 > "$tracefs/tracing_on"
echo 0 > "$tracefs/events/kvm/enable"
echo > "$tracefs/trace"
echo 1 > "$tracefs/events/kvm/kvm_riscv_vector_shadow/enable"
echo 1 > "$tracefs/events/kvm/kvm_riscv_vector_restore_request/enable"
echo 1 > "$tracefs/events/kvm/kvm_riscv_vector_restore/enable"
echo 1 > "$tracefs/tracing_on"

run_l2 5
taskset -pc 7 "$vcpu0" >/dev/null
run_l2 20
taskset -pc 6 "$vcpu0" >/dev/null
run_l2 5

echo 0 > "$tracefs/tracing_on"
cp "$tracefs/trace" "$trace"
sha256sum "$trace"

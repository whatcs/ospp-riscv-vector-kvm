#!/bin/bash
set -euo pipefail

if test "$#" -ne 3; then
	echo "usage: $0 QEMU_PID VCPU0_TID VCPU1_TID" >&2
	exit 2
fi

qemu_pid=$1
vcpu0=$2
vcpu1=$3
tracefs=/sys/kernel/tracing
trace=/opt/ospp/m1c-on-vcpu-reset.trace
key=/opt/ospp/lab_id_ed25519
old_buffer_size=$(cat "$tracefs/buffer_size_kb")
l2_cpu_online=/sys/devices/system/cpu/cpu1/online

test -d "/proc/$qemu_pid"
test -d "/proc/$vcpu0"
test -d "/proc/$vcpu1"
test -r "$key"

l2_ssh()
{
	ssh -i "$key" -p 8822 \
		-o BatchMode=yes -o ConnectTimeout=5 \
		-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		root@127.0.0.1 "$@"
}

cleanup()
{
	l2_ssh "echo 1 > $l2_cpu_online" >/dev/null 2>&1 || true
	taskset -pc 0-7 "$vcpu0" >/dev/null 2>&1 || true
	taskset -pc 0-7 "$vcpu1" >/dev/null 2>&1 || true
	echo 0 > "$tracefs/tracing_on" 2>/dev/null || true
	echo "$old_buffer_size" > "$tracefs/buffer_size_kb" 2>/dev/null || true
}
trap cleanup EXIT

run_l2_cpu1()
{
	count=$1
	passed=$(l2_ssh \
		"seq $count | xargs -I@ taskset -c 1 /opt/ospp/rvv-smoke | grep -c RVV_PASS")
	test "$passed" = "$count"
	printf 'L2_RVV_PASS cpu=1 count=%s\n' "$passed"
}

wait_vcpu1_blocked()
{
	blocked=0
	tries=0
	while test "$tries" -lt 200; do
		wchan=$(cat "/proc/$vcpu1/wchan")
		if test "$wchan" = kvm_vcpu_block; then
			blocked=$((blocked + 1))
			if test "$blocked" -ge 3; then
				return 0
			fi
		else
			blocked=0
		fi
		tries=$((tries + 1))
		sleep 0.02
	done
	return 1
}

test "$(l2_ssh "cat $l2_cpu_online")" = 1

# Keep vCPU1 on one hart so its pre-reset owner can be compared after the SBI
# HSM start request resets that same vCPU.
taskset -pc 6 "$vcpu0" >/dev/null
taskset -pc 7 "$vcpu1" >/dev/null

echo 0 > "$tracefs/tracing_on"
echo 0 > "$tracefs/events/kvm/enable"
echo 4096 > "$tracefs/buffer_size_kb"
echo > "$tracefs/trace"
echo 1 > "$tracefs/events/kvm/kvm_riscv_vector_shadow/enable"
echo 1 > "$tracefs/events/kvm/kvm_riscv_vector_restore_request/enable"
echo 1 > "$tracefs/events/kvm/kvm_riscv_vector_restore/enable"
echo 1 > "$tracefs/tracing_on"

run_l2_cpu1 5
wait_vcpu1_blocked
printf 'M1C_VCPU_RESET_BEFORE vcpu=1 cpu=7 wchan=%s\n' "$wchan" > "$tracefs/trace_marker"

l2_ssh "echo 0 > $l2_cpu_online; test \$(cat $l2_cpu_online) = 0"
printf 'M1C_VCPU_RESET_OFFLINE vcpu=1\n' > "$tracefs/trace_marker"
l2_ssh "echo 1 > $l2_cpu_online; test \$(cat $l2_cpu_online) = 1"
printf 'M1C_VCPU_RESET_ONLINE vcpu=1\n' > "$tracefs/trace_marker"

run_l2_cpu1 5

echo 0 > "$tracefs/tracing_on"
cp "$tracefs/trace" "$trace"
grep 'entries-in-buffer' "$trace"
awk '
	/M1C_VCPU_RESET_BEFORE/ { armed = 1 }
	armed && /VCPU: 1.*reason: migration.*guest VS: 0x200/ { reset = 1 }
	armed && reset && /VCPU: 1.*mode: full/ { full = 1 }
	END { exit !(reset && full) }
' "$trace"
sha256sum "$trace"

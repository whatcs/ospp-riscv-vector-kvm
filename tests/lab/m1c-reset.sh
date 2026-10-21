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
trace=/opt/ospp/m1c-on-reset.trace
key=/opt/ospp/lab_id_ed25519
old_buffer_size=$(cat "$tracefs/buffer_size_kb")

test -d "/proc/$qemu_pid"
test -d "/proc/$vcpu0"
test -d "/proc/$vcpu1"
test -r "$key"

cleanup()
{
	taskset -pc 0-7 "$vcpu0" >/dev/null 2>&1 || true
	taskset -pc 0-7 "$vcpu1" >/dev/null 2>&1 || true
	echo 0 > "$tracefs/tracing_on" 2>/dev/null || true
	echo "$old_buffer_size" > "$tracefs/buffer_size_kb" 2>/dev/null || true
}
trap cleanup EXIT

run_l2()
{
	count=$1
	passed=$(ssh -i "$key" -p 8822 \
		-o BatchMode=yes -o ConnectTimeout=5 \
		-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		root@127.0.0.1 \
		"seq $count | xargs -I@ taskset -c 0 /opt/ospp/rvv-smoke | grep -c RVV_PASS")
	test "$passed" = "$count"
	printf 'L2_RVV_PASS cpu=0 count=%s\n' "$passed"
}

wait_vcpu_blocked()
{
	blocked=0
	tries=0
	while test "$tries" -lt 200; do
		wchan=$(cat "/proc/$vcpu0/wchan")
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

qmp_reset()
{
	exec 3<>/dev/tcp/127.0.0.1/8444
	IFS= read -r -t 5 greeting <&3
	printf 'QMP %s\n' "$greeting"
	printf '%s\n' '{"execute":"qmp_capabilities","id":"caps"}' >&3

	found=0
	for attempt in 1 2 3 4 5; do
		IFS= read -r -t 5 reply <&3
		printf 'QMP %s\n' "$reply"
		if [[ "$reply" == *'"id": "caps"'* || "$reply" == *'"id":"caps"'* ]]; then
			found=1
			break
		fi
	done
	test "$found" = 1

	printf '%s\n' '{"execute":"system_reset","id":"reset"}' >&3
	found=0
	for attempt in 1 2 3 4 5 6 7 8; do
		IFS= read -r -t 5 reply <&3
		printf 'QMP %s\n' "$reply"
		if [[ "$reply" == *'"id": "reset"'* || "$reply" == *'"id":"reset"'* ]]; then
			found=1
			break
		fi
	done
	exec 3>&-
	test "$found" = 1
}

wait_l2_ssh()
{
	tries=0
	while test "$tries" -lt 120; do
		if ssh -i "$key" -p 8822 \
			-o BatchMode=yes -o ConnectTimeout=3 \
			-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
			root@127.0.0.1 true >/dev/null 2>&1; then
			return 0
		fi
		tries=$((tries + 1))
		sleep 1
	done
	return 1
}

# Keep the control plane away from the two target owner CPUs.
taskset -pc 6 "$vcpu0" >/dev/null
taskset -pc 7 "$vcpu1" >/dev/null

echo 0 > "$tracefs/tracing_on"
echo 0 > "$tracefs/events/kvm/enable"
echo 16384 > "$tracefs/buffer_size_kb"
echo > "$tracefs/trace"
echo 1 > "$tracefs/events/kvm/kvm_riscv_vector_shadow/enable"
echo 1 > "$tracefs/events/kvm/kvm_riscv_vector_restore_request/enable"
echo 1 > "$tracefs/events/kvm/kvm_riscv_vector_restore/enable"
echo 1 > "$tracefs/tracing_on"

run_l2 5
wait_vcpu_blocked
printf 'M1C_RESET_BEFORE vcpu=0 cpu=6 wchan=%s\n' "$wchan" > "$tracefs/trace_marker"
qmp_reset
printf 'M1C_RESET_ACK\n' > "$tracefs/trace_marker"
wait_l2_ssh
printf 'M1C_RESET_L2_SSH_READY\n' > "$tracefs/trace_marker"
run_l2 5

echo 0 > "$tracefs/tracing_on"
cp "$tracefs/trace" "$trace"
grep 'entries-in-buffer' "$trace"
awk '
	/M1C_RESET_BEFORE/ { armed = 1 }
	armed && /VCPU: 0.*reason: empty/ { empty = 1 }
	armed && empty && /VCPU: 0.*mode: full/ { full = 1 }
	END { exit !(empty && full) }
' "$trace"
sha256sum "$trace"

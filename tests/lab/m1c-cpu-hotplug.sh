#!/bin/sh
set -eu

if test "$#" -ne 3; then
	echo "usage: $0 QEMU_PID VCPU0_TID VCPU1_TID" >&2
	exit 2
fi

qemu_pid=$1
vcpu0=$2
vcpu1=$3
tracefs=/sys/kernel/tracing
trace=/opt/ospp/m1c-on-cpu-hotplug.trace
key=/opt/ospp/lab_id_ed25519
cpu_online=/sys/devices/system/cpu/cpu7/online

test -d "/proc/$qemu_pid"
test -d "/proc/$vcpu0"
test -d "/proc/$vcpu1"
test -r "$key"
test -w "$cpu_online"

cleanup()
{
	if test "$(cat "$cpu_online" 2>/dev/null || echo 0)" != 1; then
		echo 1 > "$cpu_online" 2>/dev/null || true
	fi
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

taskset -pc 0 "$vcpu1" >/dev/null
taskset -pc 7 "$vcpu0" >/dev/null

echo 0 > "$tracefs/tracing_on"
echo 0 > "$tracefs/events/kvm/enable"
echo > "$tracefs/trace"
echo 1 > "$tracefs/events/kvm/kvm_riscv_vector_shadow/enable"
echo 1 > "$tracefs/events/kvm/kvm_riscv_vector_restore_request/enable"
echo 1 > "$tracefs/events/kvm/kvm_riscv_vector_restore/enable"
echo 1 > "$tracefs/tracing_on"

run_l2 5

# Do not SIGSTOP QEMU here.  A stop signal can make the vCPU leave between the
# CSR-only restore request and guest entry.  The ensuing vcpu_put then correctly
# reports not_resident and clears the owner before CPU hotplug can test it.
# Instead, wait until the target vCPU naturally blocks after publishing its
# final put_candidate, then offline its only allowed CPU.
blocked=0
tries=0
while test "$tries" -lt 200; do
	wchan=$(cat "/proc/$vcpu0/wchan")
	if test "$wchan" = kvm_vcpu_block; then
		blocked=$((blocked + 1))
		if test "$blocked" -ge 3; then
			break
		fi
	else
		blocked=0
	fi
	tries=$((tries + 1))
	sleep 0.02
done
test "$blocked" -ge 3
printf 'M1C_HOTPLUG_BEFORE cpu=7 wchan=%s\n' "$wchan" > "$tracefs/trace_marker"
echo 0 > "$cpu_online"
test "$(cat "$cpu_online")" = 0
printf 'M1C_HOTPLUG_OFFLINE cpu=7\n' > "$tracefs/trace_marker"
echo 1 > "$cpu_online"
test "$(cat "$cpu_online")" = 1
taskset -pc 7 "$vcpu0" >/dev/null
printf 'M1C_HOTPLUG_ONLINE cpu=7\n' > "$tracefs/trace_marker"
run_l2 5

echo 0 > "$tracefs/tracing_on"
cp "$tracefs/trace" "$trace"
sha256sum "$trace"

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
trace=/opt/ospp/m1d-preempt-vector.trace
rvv_log=/opt/ospp/m1d-preempt-vector-rvv.log
key=/opt/ospp/lab_id_ed25519
module=/opt/ospp/m1d-preempt-vector.ko
stage=/sys/module/m1d_preempt_vector/parameters/stage

test -d "/proc/$qemu_pid"
test -d "/proc/$vcpu0"
test -d "/proc/$vcpu1"
test -r "$key"
test -r "$module"
test "$(cat /sys/module/kvm/parameters/vector_owner_fastpath)" = Y

cleanup()
{
	rmmod m1d_preempt_vector 2>/dev/null || true
	taskset -pc 0-7 "$vcpu0" >/dev/null 2>&1 || true
	taskset -pc 0-7 "$vcpu1" >/dev/null 2>&1 || true
	echo 0 > "$tracefs/tracing_on" 2>/dev/null || true
}
trap cleanup EXIT

taskset -pc 7 "$vcpu0" >/dev/null
taskset -pc 0 "$vcpu1" >/dev/null

echo 0 > "$tracefs/tracing_on"
echo 0 > "$tracefs/events/kvm/enable"
echo 4096 > "$tracefs/buffer_size_kb"
echo > "$tracefs/trace"
echo 1 > "$tracefs/events/kvm/kvm_riscv_vector_shadow/enable"
echo 1 > "$tracefs/events/kvm/kvm_riscv_vector_restore_request/enable"
echo 1 > "$tracefs/events/kvm/kvm_riscv_vector_restore/enable"
echo 1 > "$tracefs/tracing_on"

insmod "$module" cpu=7 hold_ms=4000
tries=0
while test "$(cat "$stage")" = 0 && test "$tries" -lt 200; do
	tries=$((tries + 1))
	sleep 0.02
done
test "$(cat "$stage")" = 1

ssh -i "$key" -p 8822 \
	-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	root@127.0.0.1 \
	"seq 20 | xargs -I@ taskset -c 0 /opt/ospp/rvv-smoke" > "$rvv_log"
test "$(grep -c RVV_PASS "$rvv_log")" = 20

tries=0
while test "$(cat "$stage")" -lt 3 && test "$tries" -lt 500; do
	tries=$((tries + 1))
	sleep 0.02
done
test "$(cat "$stage")" = 3
rmmod m1d_preempt_vector

echo 0 > "$tracefs/tracing_on"
cp "$tracefs/trace" "$trace"

awk '
/M1D_PREEMPT_BEGIN cpu=7/ { begin = 1 }
begin && /\[007\].*reason: put_candidate/ { candidate = 1 }
candidate && /\[007\].*action: invalidate.*reason: kernel_vector/ { invalidated = 1 }
/M1D_PREEMPT_RESUMED cpu=7/ { resumed = 1; if (invalidated) ordered = 1 }
resumed && /\[007\].*mode: full/ { fallback = 1 }
END { exit !(begin && candidate && invalidated && resumed && ordered && fallback) }
' "$trace"

printf 'M1D_PREEMPT_PASS rvv=20/20 ordered=begin-put-invalidate-resume-full\n'
grep 'entries-in-buffer/entries-written' "$trace"
printf 'kernel_vector_invalidate=%s full=%s csr=%s\n' \
	"$(grep -c 'reason: kernel_vector' "$trace")" \
	"$(grep -c 'mode: full' "$trace")" \
	"$(grep -c 'mode: csr' "$trace")"
sha256sum "$trace" "$rvv_log"

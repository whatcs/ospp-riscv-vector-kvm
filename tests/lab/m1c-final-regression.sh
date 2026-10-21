#!/bin/bash
set -euo pipefail

if test "$#" -ne 3; then
	echo "usage: $0 EXPECTED_PARAM LABEL COUNT" >&2
	exit 2
fi

expected=$1
label=$2
count=$3
tracefs=/sys/kernel/tracing
trace="/opt/ospp/m1c-final-${label}.trace"
rvv_log="/opt/ospp/m1c-final-${label}-rvv.log"
key=/opt/ospp/lab_id_ed25519

test "$(cat /sys/module/kvm/parameters/vector_owner_fastpath)" = "$expected"
test -r "$key"

cleanup()
{
	echo 0 > "$tracefs/tracing_on" 2>/dev/null || true
}
trap cleanup EXIT

l2_ssh()
{
	ssh -i "$key" -p 8822 \
		-o BatchMode=yes -o ConnectTimeout=10 \
		-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		root@127.0.0.1 "$@"
}

echo 0 > "$tracefs/tracing_on"
echo 0 > "$tracefs/events/kvm/enable"
echo > "$tracefs/trace"
echo 1 > "$tracefs/events/kvm/kvm_riscv_vector_shadow/enable"
echo 1 > "$tracefs/events/kvm/kvm_riscv_vector_restore_request/enable"
echo 1 > "$tracefs/events/kvm/kvm_riscv_vector_restore/enable"
echo 1 > "$tracefs/tracing_on"

output=$(l2_ssh "seq $count | xargs -I@ taskset -c 0 /opt/ospp/rvv-smoke")
printf '%s\n' "$output" > "$rvv_log"
passed=$(grep -c '^RVV_PASS' "$rvv_log")
test "$passed" = "$count"

echo 0 > "$tracefs/tracing_on"
cp "$tracefs/trace" "$trace"

printf 'M1C_FINAL label=%s param=%s rvv_pass=%s/%s\n' \
	"$label" "$expected" "$passed" "$count"
grep 'entries-in-buffer' "$trace"
awk '
	/kvm_riscv_vector_restore:/ && /mode: full/ { full++ }
	/kvm_riscv_vector_restore:/ && /mode: csr/ { csr++ }
	/kvm_riscv_vector_shadow:/ && /action: load/ && /reason: hit/ { hit++ }
	/kvm_riscv_vector_shadow:/ && /action: put/ && /reason: put_candidate/ { put++ }
	END { printf "full=%d csr=%d hit=%d put_candidate=%d\n", full, csr, hit, put }
' "$trace"
sha256sum "$trace" "$rvv_log"

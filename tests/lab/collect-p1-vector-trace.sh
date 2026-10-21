#!/bin/sh
set -eu

tracefs=/sys/kernel/tracing
restore_event="$tracefs/events/kvm/kvm_riscv_vector_restore/enable"
request_event="$tracefs/events/kvm/kvm_riscv_vector_restore_request/enable"
output=${1:-/var/log/ospp-p1-vector-restore.trace}

printf '0' > "$tracefs/tracing_on"
printf '0' > "$restore_event"
printf '0' > "$request_event"
cp "$tracefs/trace" "$output"

restore_count=$(grep -c 'kvm_riscv_vector_restore:' "$output" || true)
request_count=$(grep -c 'kvm_riscv_vector_restore_request:' "$output" || true)
load_count=$(grep 'kvm_riscv_vector_restore_request:' "$output" |
	grep -c 'source: load' || true)
kernel_count=$(grep 'kvm_riscv_vector_restore_request:' "$output" |
	grep -c 'source: kernel_vector' || true)
printf 'P1_VECTOR_RESTORE_EVENTS=%s\n' "$restore_count"
printf 'P1_VECTOR_REQUEST_EVENTS=%s\n' "$request_count"
printf 'P1_VECTOR_REQUEST_LOAD=%s\n' "$load_count"
printf 'P1_VECTOR_REQUEST_KERNEL=%s\n' "$kernel_count"
printf 'TRACE_FILE=%s\n' "$output"

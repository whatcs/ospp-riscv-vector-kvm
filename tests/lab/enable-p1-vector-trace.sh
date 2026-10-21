#!/bin/sh
set -eu

tracefs=/sys/kernel/tracing
restore_event="$tracefs/events/kvm/kvm_riscv_vector_restore/enable"
request_event="$tracefs/events/kvm/kvm_riscv_vector_restore_request/enable"

test -e "$restore_event"
test -e "$request_event"
printf '0' > "$tracefs/tracing_on"
: > "$tracefs/trace"
printf '1' > "$restore_event"
printf '1' > "$request_event"
printf '1' > "$tracefs/tracing_on"

echo P1_VECTOR_TRACE_ENABLED

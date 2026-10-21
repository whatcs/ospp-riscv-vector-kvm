#!/bin/sh
set -eu

input=${1:-/var/log/ospp-p1-vector-restore.trace}

head -n 12 "$input"
echo '--- per-vCPU/per-CPU distribution ---'
grep 'kvm_riscv_vector_restore:' "$input" |
	grep -o 'VCPU: [0-9]*, CPU: [0-9]*' |
	sort | uniq -c | sort -nr | head -n 20
echo '--- retained time span ---'
grep 'kvm_riscv_vector_restore:' "$input" |
	awk 'NR == 1 { first = $4 } { last = $4 } END { print "FIRST=" first, "LAST=" last }'
echo '--- request source / host VS distribution ---'
grep 'kvm_riscv_vector_restore_request:' "$input" |
	sed -n 's/.*source: \([^,]*\), host VS: \([^ ]*\)$/source=\1 host_vs=\2/p' |
	sort | uniq -c | sort -nr

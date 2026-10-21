#!/bin/sh
set -eu

count=${1:-100}
i=0
start=$(date +%s)

while test "$i" -lt "$count"; do
	/opt/ospp/rvv-smoke >/dev/null
	i=$((i + 1))
done

end=$(date +%s)
printf 'RVV_FIXED_PASS count=%s elapsed_s=%s\n' "$count" "$((end - start))"

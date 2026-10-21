#!/bin/bash
set -euo pipefail

exec 3<>/dev/tcp/127.0.0.1/8444
IFS= read -r -t 5 greeting <&3
printf '%s\n' "$greeting"
printf '%s\n' '{"execute":"qmp_capabilities","id":"caps"}' >&3
while IFS= read -r -t 5 reply <&3; do
	printf '%s\n' "$reply"
	[[ "$reply" == *'"id": "caps"'* ]] && break
done
printf '%s\n' '{"execute":"query-cpus-fast","id":"cpus"}' >&3
while IFS= read -r -t 5 reply <&3; do
	printf '%s\n' "$reply"
	[[ "$reply" == *'"id": "cpus"'* ]] && break
done

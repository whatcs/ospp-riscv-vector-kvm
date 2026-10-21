#!/bin/bash
set -euo pipefail
exec 3<>/dev/tcp/127.0.0.1/8444
IFS= read -r -t 5 greeting <&3
printf '%s\n' "$greeting"
printf '%s\n' '{"execute":"qmp_capabilities","id":"caps"}' >&3
IFS= read -r -t 5 caps <&3
printf '%s\n' "$caps"
printf '%s\n' '{"execute":"query-kvm","id":"kvm"}' >&3
for attempt in 1 2 3 4 5; do
    IFS= read -r -t 5 reply <&3
    printf '%s\n' "$reply"
    if [[ "$reply" == *'"id": "kvm"'* ]]; then
        [[ "$reply" == *'"enabled": true'* ]]
        [[ "$reply" == *'"present": true'* ]]
        echo L2_KVM_ENABLED
        exit 0
    fi
done
exit 1

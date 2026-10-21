#!/bin/bash
set -euo pipefail
lab=/home/riscv/ws/lab
exec ssh -i "$lab/id_ed25519" -p 7722 \
    -o BatchMode=yes -o ConnectTimeout=8 \
    -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$lab/known_hosts" \
    root@127.0.0.1 "$@"

#!/bin/bash
# Run inside the x86 Ubuntu VM after the two images have been built.
set -euo pipefail
lab=/home/riscv/ws/lab
cd "$lab"
bash start-l1.sh
wait_ssh() {
    local guest=$1
    for attempt in $(seq 1 30); do
        if ssh -F "$lab/ssh_config" "$guest" true; then
            return 0
        fi
        sleep 3
    done
    echo "$guest did not become reachable; inspect its console log" >&2
    return 1
}
wait_ssh ospp-l1
ssh -F "$lab/ssh_config" ospp-l1 bash -s < check-l1.sh | tee l1-verification.log
scp -F "$lab/ssh_config" start-l2.sh ospp-l1:/opt/ospp/start-l2.sh
ssh -F "$lab/ssh_config" ospp-l1 bash /opt/ospp/start-l2.sh
ssh -F "$lab/ssh_config" ospp-l1 bash -s < check-kvm.sh | tee l2-kvm-verification.log
wait_ssh ospp-l2
ssh -F "$lab/ssh_config" ospp-l2 bash -s < check-l2.sh | tee l2-verification.log
echo OSPP_LAB_READY

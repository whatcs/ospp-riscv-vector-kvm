#!/bin/bash
set -euo pipefail
lab=/home/riscv/ws/lab
cd "$lab"
if ! test -f id_ed25519; then
    ssh-keygen -q -t ed25519 -N '' -C ospp-local-lab -f id_ed25519
fi
riscv64-linux-gnu-gcc -O2 -Wall -Wextra -Werror -fno-tree-vectorize \
    -march=rv64gc -mabi=lp64d -static rvv-smoke.c -o rvv-smoke
file rvv-smoke
bash -n build-rootfs.sh start-l1.sh start-l2.sh
sudo systemd-run --unit=ospp-rootfs --collect \
    --property="StandardOutput=append:$lab/build.log" \
    --property="StandardError=append:$lab/build.log" \
    /bin/bash "$lab/build-rootfs.sh"

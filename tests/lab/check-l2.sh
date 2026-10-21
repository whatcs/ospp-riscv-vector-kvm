#!/bin/bash
set -euo pipefail
uname -a
grep -m1 '^isa' /proc/cpuinfo
grep -c '^processor' /proc/cpuinfo
findmnt -n -o SOURCE,FSTYPE,TARGET /
cat /etc/os-release
for round in 1 2 3; do
    /opt/ospp/rvv-smoke
done
echo L2_READY

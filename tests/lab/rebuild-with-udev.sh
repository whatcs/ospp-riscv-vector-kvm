#!/bin/bash
set -euo pipefail
lab=/home/riscv/ws/lab
if test -f "$lab/l1.pid" && kill -0 "$(cat "$lab/l1.pid")" 2>/dev/null; then
    echo 'Stop the newly created lab QEMU before rebuilding its images' >&2
    exit 1
fi
# Preserve the first generated images for diagnosis.
for name in l1 l2; do
    test -f "$lab/images/$name.ext4"
    test ! -e "$lab/images/$name.pre-udev.ext4"
    mv -- "$lab/images/$name.ext4" "$lab/images/$name.pre-udev.ext4"
    rm -- "$lab/stages/$name-image"
done
exec /bin/bash "$lab/build-rootfs.sh"

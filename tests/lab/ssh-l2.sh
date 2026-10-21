#!/bin/bash
set -euo pipefail
exec ssh -F /home/riscv/ws/lab/ssh_config ospp-l2 "$@"

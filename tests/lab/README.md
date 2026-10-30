# OSPP RISC-V KVM 实验环境

2026-10-15：C1 构建修复验证通过，A 的 L1/L2 均已启动，L2 向量测试通过。
本目录是可复现脚本；实际镜像、日志、SSH 实验密钥位于 VMware Ubuntu 的 `/home/riscv/ws/lab`。

## 环境组成

| 层次 | 运行方式 | 内存 / CPU | 存储 |
|---|---|---|---|
| x86 Ubuntu VM | VMware，Windows 上 `ssh riscv-vm` | 8 GB / 8 vCPU | 原有 Linux 源码和工具链 |
| L1 riscv64 Ubuntu 24.04 | QEMU 8.2.2 TCG，H+V，VLEN=256 | 4 GB / 8 hart | `images/l1.ext4`，8 GB 稀疏盘 |
| L2 riscv64 Ubuntu 24.04 | L1 内 QEMU，强制 `-accel kvm` | 1.5 GB / 2 vCPU | `images/l2.ext4`，4 GB 稀疏盘 |

两份盘初建实际各约 0.8 GB。L2 使用同一内核 Image，以减少环境变量；L2 不需要加载 KVM 模块。
外层 L1 用 `fw_dynamic.bin`；L2 用 `-cpu host -accel kvm -bios none`，由 KVM 提供 guest SBI 服务。
L2 的配置已经实际启动验证，不照搬旧手册中给 L2 开 H 扩展、再次加载 M-mode OpenSBI 的参数。
相关平台说明见 [QEMU virt 官方文档](https://www.qemu.org/docs/master/system/riscv/virt.html)。

## 常用操作（均在 x86 Ubuntu VM 中运行）

启动或复用实验环境并验证：

```sh
bash /home/riscv/ws/lab/start-lab.sh
```

访问两层系统：

```sh
ssh -F /home/riscv/ws/lab/ssh_config ospp-l1
ssh -F /home/riscv/ws/lab/ssh_config ospp-l2
```

从 Windows 可先 `ssh riscv-vm`，也可通过自动化脚本经 SSH 调用上述命令。
L1 的 SSH 只绑定 x86 Ubuntu 内的 `127.0.0.1:7722`。
L2 的 SSH 只绑定 L1 内的 `127.0.0.1:8822`，通过 ProxyJump 访问。
实验私钥只在 x86 Ubuntu 的 lab 目录中，不复制到 L1/L2，也不放进本仓库。

正常关闭时先关 L2，再关 L1，最后才关闭 VMware Ubuntu：

```sh
ssh -F /home/riscv/ws/lab/ssh_config ospp-l2 systemctl poweroff
# 等 L2 的 QEMU 退出，再执行下一行。
ssh -F /home/riscv/ws/lab/ssh_config ospp-l1 systemctl poweroff
```

## 验证和日志

- `check-l1.sh`：ISA、RVV 计算、加载匹配的 kvm.ko、检查 /dev/kvm。
- `check-kvm.sh`：通过 L1 内 localhost QMP 查询 L2，必须 enabled=true 且 present=true。
- `check-l2.sh`：确认系统、磁盘、CPU 数量与三次 RVV 计算。
- `rvv-smoke.c`：实际执行 vsetvli / vle32.v / vadd.vv / vse32.v，逐项检查 257 个结果。
- `kvm-selftests/vector-one-reg-owner.c` + `m1c-one-reg.sh`：验证 GET 保留 owner 命中、SET
  推进 generation 并在下一次进入前 full restore。
- `kvm-selftests/vector-owner-destroy.c` + `m1c-destroy.sh`：验证 vCPU 销毁后旧 identity
  不能让另一 vCPU 命中，且旧 Guest Vector 数据不会泄漏给新 Guest。
- `query-l2-vcpu-tids.sh`：通过 QMP `query-cpus-fast` 获取每次重启后实际的 L2 vCPU TID，
  避免测试脚本沿用过期线程号。
- `m1c-final-regression.sh`：校验模块参数后运行指定次数的 L2 RVV，并保存完整 trace、
  full/CSR-only/hit/put 计数与 SHA-256；最终收口使用默认关闭/开启各 30 次。
- `kmod/m1d-preempt-vector.c` + `m1d-preempt-vector.sh`：让可抢占 kernel Vector worker
  在 begin/end 区间主动睡眠，并与同 CPU vCPU 交错；要求 owner 在 worker 恢复前失效、
  Guest 下一次进入走 full restore，最终使用 20 次 RVV。
- VM 内 `l1-console.log`：L1 串口；L1 内 `/var/log/ospp-l2-console.log`：L2 串口。
- VM 内 `l1-verification.log`、`l2-kvm-verification.log`、`l2-verification.log`：验收记录。
- 本地 `evidence/a/` 保存本轮日志副本。

这是环境冒烟测试，不是 S-1～S-7 隔离压力测试，不提供优化收益或真机性能结论。

## 从源码重新制作文件系统

`prepare.sh` 生成实验密钥、交叉编译测试程序、通过 systemd 后台运行 `build-rootfs.sh`。
使用签名校验的 Ubuntu noble 软件源（USTC 镜像），debootstrap foreign + qemu-user 第二阶段。
镜像使用 `truncate` + `mkfs.ext4 -d`，保持稀疏，不按旧手册写满 100 GB 零数据。
阶段标记用于断点续作，已有无标记镜像会被拒绝覆盖。
首次尝试因缺 udev 导致网络设备未配置，已补 udev 并验证；旧实验盘以 `*.pre-udev.ext4`
保留在 VM 内，未删除用户原有 rootfs 或源码。

内核及模块以同一构建目录的匹配产物为准。后续修改内核后，需要同步更新 L1 使用的 Image、
L1 `/opt/ospp/kvm.ko` 和 L2 使用的 Image，并按需更新磁盘中的内核副本。
本树单独执行 `O=<build> M=arch/riscv/kvm modules` 时，最新 `kvm.ko` 实测生成在源码树的
`arch/riscv/kvm/kvm.ko`，不要直接沿用旧 build 目录里的模块；部署前必须同时核对哈希与
`/sys/kernel/tracing/available_events`。当前源码包含 C1、P1、M1A/M1B 观测、M1C owner
行为优化和 M1D preemptible kernel Vector resume 失效修复；M1C 由只读模块参数
`vector_owner_fastpath` 控制且默认关闭。

M1D 外部测试模块应显式指定目标架构和交叉编译器，避免宿主 gcc 被误用：

```sh
make -C /home/riscv/ws/linux O=/home/riscv/ws/build-l1 \
    ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- \
    M=/home/riscv/ws/lab/kmod modules
```

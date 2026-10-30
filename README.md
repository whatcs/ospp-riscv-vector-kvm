# Linux/KVM RISC-V Vector Context Scheduling Optimization

OSPP project materials for optimizing RISC-V Vector context scheduling in Linux/KVM.

本仓库保存项目的设计文档、开发阶段补丁、测试脚本和精选验证证据。owner 优化 RFC v0
已经投稿至 Linux RISC-V/KVM 邮件列表并进入评审，尚未合入 Linux 主线。

## Project goal

The prototype tracks per-hart Guest Vector residency and, under conservative safety conditions, avoids
reloading `v0-v31` when the same vCPU returns to the same hart. Vector CSRs are still restored, and every
uncertain or invalidated state falls back to the existing full-restore path.

关键限制：当前数据说明的是完整 Vector restore **事件数量**下降，不代表真实硬件性能同比
提升。真实性能结论仍需要 RISC-V 物理硬件。

## Performance proxy result

在现有 QEMU TCG + 嵌套 KVM 环境中，我们只报告机制和工作量代理，不报告耗时加速比：

| 指标 | 快路径关闭 | 快路径开启 |
|---|---:|---:|
| RVV 正确性 | 30/30 PASS | 30/30 PASS |
| full restore | 2194 | 6 |
| CSR-only restore | 0 | 1948 |

完整恢复事件减少 **99.7265%**。在 VLEN=256 下，开启组的 1948 次 CSR-only 直接对应
1.90234375 MiB 无需重新装入的 `v0..v31` 架构状态。该值不是缓存/DRAM 流量，也不是程序
加速百分比。完整口径、计算和限制见
[`docs/26-现有环境性能代理量化.md`](docs/26-现有环境性能代理量化.md)。

## Repository layout

```text
docs/                 调研、调用链、设计、安全论证、执行计划和最终状态
patches/development/  开发阶段补丁快照；不是正式上游投稿系列
tests/lab/            构建、启动和定向回归脚本
tests/kvm-selftests/  KVM/RISC-V Vector owner 自测候选
evidence/final/       精选最终 selftest 日志和 trace
evidence/performance-proxy/  A/B 与 RFC 冒烟原始证据压缩包及复核说明
```

建议从以下文档开始阅读：

1. `docs/03-RISC-V-Vector与KVM上下文调研报告.md`
2. `docs/04-RISC-V-Vector调用链与时序图.md`
3. `docs/13-M1C-默认关闭快路径原型与AB结果.md`
4. `docs/16-ABI隔离与安全不变量论证.md`
5. `docs/19-Linux7.3最终验证状态.md`
6. `docs/26-现有环境性能代理量化.md`

## Upstream status

Linux kernel submission uses emailed patches rather than a GitHub Pull Request. RFC v0 was posted on
2026-10-27 as a 0/3--3/3 thread after per-commit builds, final functional validation and a `git am`
round trip. Public archives:

- [linux-riscv thread](https://lists.infradead.org/pipermail/linux-riscv/2026-October/102208.html)
- [kvm-riscv thread](https://lists.infradead.org/pipermail/kvm-riscv/2026-October/013170.html)

The intended author identity is:

```text
Xiaochun Yu <yxcnew@outlook.com>
```

The current action is to wait for maintainer/CI feedback and prepare a revised series only when warranted;
the same RFC v0 must not be resent.

## Baseline and validation

RFC v0 validated baseline:

```text
Torvalds master
21a7f44fd076
```

The series passed `CONFIG_RISCV_ISA_V=y/n` full Image/modules builds, fast-path Y/N directed KVM tests,
nested KVM/RVV smoke and final severe-kernel-log checks. Earlier Linux 7.3 validation also covered
upstream `get-reg-list` and relevant RISC-V Vector kselftests. See
`docs/19-Linux7.3最终验证状态.md` and `docs/26-现有环境性能代理量化.md` for scope and limitations.

## Notice

- `patches/development/` records the implementation history and must not be sent upstream as-is.
- Generated build trees, VM images, credentials, private keys, temporary worktrees and large repetitive
  traces are intentionally excluded.
- This repository is an engineering archive and portfolio aid; the Linux mailing-list discussion remains
  the authoritative upstream review record once submission begins.

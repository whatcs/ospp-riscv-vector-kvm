# Linux/KVM RISC-V Vector Context Scheduling Optimization

OSPP project materials for optimizing RISC-V Vector context scheduling in Linux/KVM.

本仓库保存项目的设计文档、开发阶段补丁、测试脚本和精选验证证据。当前状态是已经在
Linux 7.3/QEMU 嵌套 KVM 环境完成验证的初始技术原型，尚未合入 Linux 主线。

## Project goal

The prototype tracks per-hart Guest Vector residency and, under conservative safety conditions, avoids
reloading `v0-v31` when the same vCPU returns to the same hart. Vector CSRs are still restored, and every
uncertain or invalidated state falls back to the existing full-restore path.

关键限制：当前数据说明的是完整 Vector restore **事件数量**下降，不代表真实硬件性能同比
提升。真实性能结论仍需要 RISC-V 物理硬件。

## Repository layout

```text
docs/                 调研、调用链、设计、安全论证、执行计划和最终状态
patches/development/  开发阶段补丁快照；不是正式上游投稿系列
tests/lab/            构建、启动和定向回归脚本
tests/kvm-selftests/  KVM/RISC-V Vector owner 自测候选
evidence/final/       精选最终 selftest 日志和 trace
```

建议从以下文档开始阅读：

1. `docs/03-RISC-V-Vector与KVM上下文调研报告.md`
2. `docs/04-RISC-V-Vector调用链与时序图.md`
3. `docs/13-M1C-默认关闭快路径原型与AB结果.md`
4. `docs/16-ABI隔离与安全不变量论证.md`
5. `docs/19-Linux7.3最终验证状态.md`

## Upstream status

Linux kernel submission uses emailed patches rather than a GitHub Pull Request. The current development
snapshots will be rebuilt as a reviewable commit series, checked per commit, sent to the author first for a
`git am` round trip, and only then posted to the KVM/RISC-V maintainers and mailing lists.

The intended author identity is:

```text
Xiaochun Yu <yxcnew@outlook.com>
```

No public mailing-list submission has been sent yet.

## Baseline and validation

Validated baseline:

```text
Linux 7.3
c03c1a14507dfaf8b856c2608f9ac216021fc222
```

The current prototype has passed `CONFIG_RISCV_ISA_V=y/n` builds, directed KVM tests, upstream
`get-reg-list`, relevant RISC-V Vector kselftests, and final severe-kernel-log checks. See
`docs/19-Linux7.3最终验证状态.md` for the exact scope and limitations.

## Notice

- `patches/development/` records the implementation history and must not be sent upstream as-is.
- Generated build trees, VM images, credentials, private keys, temporary worktrees and large repetitive
  traces are intentionally excluded.
- This repository is an engineering archive and portfolio aid; the Linux mailing-list discussion remains
  the authoritative upstream review record once submission begins.

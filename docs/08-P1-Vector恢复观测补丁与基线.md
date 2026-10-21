# P1：Guest Vector 实际恢复 tracepoint 与首轮基线

> 基线：Linux `24a19b953e2a`（v7.3-rc7）  
> 日期：2026-10-17  
> 性质：行为不变的观测补丁，不包含 owner/skip-restore 优化。

## 1. 观测的是什么

新增两个 trace 事件：

```text
kvm:kvm_riscv_vector_restore
kvm:kvm_riscv_vector_restore_request
```

它只在 `kvm_riscv_vcpu_enter_exit()` 确实执行
`__kvm_riscv_vector_restore(gcntx)` 后产生，字段为 vCPU ID 与物理 CPU ID。
因此它计数的是“完整 Guest Vector restore 实际发生次数”，不是 load 次数或 restore 请求次数。

`kvm_riscv_vector_restore_request` 记录谁设置了 `NEED_RESTORE`：`load` 或
`kernel_vector`，同时记录 Host 用户态 `pt_regs.status` 中的 VS 值。这样可以把“为什么要求
恢复”与“后来是否真的恢复”分开计数。

`kvm_riscv_vcpu_enter_exit()` 位于 RCU EQS 的 `noinstr` 静默区，不能直接调用普通
tracepoint。本补丁让该函数只返回一个布尔值，等退出静默区、重新启用本地中断后，才发出事件。

## 2. 代码改动

| 文件 | 改动 |
|---|---|
| `arch/riscv/kvm/trace.h` | 定义实际恢复与恢复请求两个事件 |
| `arch/riscv/kvm/vcpu.c` | 从 noinstr 函数返回是否真正 restore，并在安全位置 trace |
| `arch/riscv/kvm/vcpu_vector.c` | 在 load 与 kernel Vector 路径记录请求来源和 Host VS |

当前合并补丁：[p1-riscv-kvm-vector-tracing.patch](../p1-riscv-kvm-vector-tracing.patch)，
SHA-256：`A0195E50741121A9D4AB32CA76266FE5D7900E91F8F509ED95A4918B3DD9EE87`。

## 3. 构建与静态检查

- `CONFIG_RISCV_ISA_V=y`、`CONFIG_KVM=m`：`kvm.ko` 增量构建通过；
- `CONFIG_RISCV_ISA_V=n`、`CONFIG_KVM=m`：`kvm.ko` 增量构建通过；
- V=y 模块的符号表包含两个 tracepoint 符号；
- `git diff --check` 通过；
- `checkpatch.pl --strict`：0 errors、0 warnings、6 checks。

6 个 CHECK 都来自两个新增 `TRACE_EVENT` 的标准多行宏形式（“行以 `(` 结尾”和宏参数对齐），
同一 `trace.h` 中的现有事件也使用这种格式。这不是编译错误，但正式提交前仍需按维护者偏好处理，
不能把本轮结果写成“strict 全绿”。

## 4. 运行验证

最终在 L1 中加载模块 `/opt/ospp/kvm-p1b.ko`：

- 模块 SHA-256：`5c3d4610b5509e0c41bb32f41deb10393392b8b694289c1bff5d3a8a3214232d`；
- `/dev/kvm` 存在；
- tracefs 中实际恢复事件 ID 为 1344，请求事件 ID 为 1345；
- QMP `query-kvm`：`enabled=true`、`present=true`；
- L2 连续三次执行 `rvv-smoke`，每次均为
  `RVV_PASS elements=257 vlenb=32 VLEN=256`；
- L1 `dmesg` 未发现 `BUG/WARNING/Oops/Unable to handle` 模式。

这证明观测补丁至少没有破坏当前 L1→L2 KVM 与 RVV 冒烟路径。

## 5. 首轮 trace 结果

从打开事件、启动 L2 到完成三次 RVV 冒烟，trace buffer 记录：

| 项 | 值 |
|---|---:|
| entries in buffer / written | `29352 / 29352` |
| 首事件时间戳 | `88.299062 s` |
| 末事件时间戳 | `229.232758 s` |
| 覆盖时长 | 约 `140.934 s` |
| 粗略平均 | 约 `208.3 restore/s` |

按 vCPU/hart 的主要分布：

| vCPU | hart | restore 次数 |
|---:|---:|---:|
| 0 | 6 | 18618 |
| 0 | 3 | 7474 |
| 1 | 1 | 1423 |
| 1 | 4 | 876 |
| 1 | 0 | 319 |
| 0 | 4 | 312 |

其余分布在 hart 1/2/3/5。它至少证明两件事：

1. 当前嵌套环境中，完整 Guest Vector restore 是高频真实事件；
2. 同一 vCPU 会在不同 hart 上运行，迁移失效不是只存在于设计表中的边缘情况。

原始 trace：[p1-vector-restore.trace](../evidence/p1/p1-vector-restore.trace)，大小 2,730,259
字节，SHA-256：`0E5717709D29262230C2157A465CB69B428C4FB506395BF27CF617730ADAE001`。

## 6. 这组数据不能证明什么

本窗口包含 L2 启动、systemd、空闲和三次短 RVV 程序，不是受控 benchmark；QEMU 外层仍是
TCG，时间开销不能代表真实硬件。因此 29,352 次只能作为“路径确实高频”的功能证据，不能直接
宣称优化百分比或性能收益。

## 7. 受控窗口与来源结果

L2 稳定运行后，分别清空 trace buffer 采集两个独立窗口：

| 窗口 | trace 时间跨度 | 实际 restore | 请求 | load | kernel Vector | Host VS |
|---|---:|---:|---:|---:|---:|---:|
| 20 秒 idle（含控制开销） | 24.771 s | 153 | 153 | 153 | 0 | 全部 `0x0` |
| 固定 100 次 RVV（程序自报 3 s，含控制开销） | 16.385 s | 1826 | 1826 | 1826 | 0 | 全部 `0x0` |

按整个 trace 时间跨度粗算约为 6.18 与 111.44 restore/s，相差约 18 倍。因为控制窗口包含
SSH 往返，且外层是 QEMU TCG，这仍不是性能数据；但来源结论很清楚：这两组中每次实际 restore
都对应一次 load 请求，没有 kernel Vector 请求合并进来，Host 用户态 VS 也始终为 Off。

- idle trace：[ospp-p1b-idle-20s.trace](../evidence/p1/ospp-p1b-idle-20s.trace)，
  SHA-256 `616423CF1673299F9EE93A4129BF9F0544FCECD8036609EFF0FAA3AD18F3680B`；
- RVV trace：[ospp-p1b-rvv-100.trace](../evidence/p1/ospp-p1b-rvv-100.trace)，
  SHA-256 `027F36A452F64E744A5294156E7BBADF0A9CD0E9EC2A025A8027C80D1781BE01`。

## 8. 对设计的影响

这组结果支持把主要优化点放在 `kvm_sched_out/in -> arch put/load`，也支持优先研究 Host
VS=Off 的保守情形。但“Host VS=Off”只说明无需恢复 Host 用户态 Vector，不代表可以忽略
Host 任务切换：另一个 task 或 kernel Vector 仍可覆盖寄存器。因此它不能推翻
[状态机设计](07-Vector所有权与有效性状态机设计.md) 中“需要通用交接/失效 hook”的结论。

下一步是补固定时长压力窗口，并把“只限 KVM 目录”与“增加通用 RISC-V Vector hook”两种
M1 方案写成可评审的代码落点对照；在这个决策完成前，不启用 owner 快路径。


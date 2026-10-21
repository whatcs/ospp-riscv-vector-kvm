# ABI、隔离与 Vector 状态安全不变量论证

日期：2026-10-20  
源码基线：Linux `24a19b953e2a3d0ea5a8c4951a0ab8f32720c907` + C1/P1/M1A～M1D  
对应官网产出要求：7

## 1. 结论与适用范围

M1 的核心不是相信“上一次运行的 vCPU 大概率还在这个 hart”，而是只在一组可检查的不变量
同时成立时省略 `v0-v31` 的重复加载。任何条件不确定都会回退到原有 full restore。

在当前源码、嵌套 KVM 环境和已经完成的定向测试范围内，可以确认：

- 没有修改 KVM ioctl、ONE_REG 编号、寄存器布局或 Guest 可见 Vector ISA；
- Guest 内存副本始终保持最新，GET/SET/reset/destroy 不依赖远端 hart 上的唯一硬件副本；
- Host task、Guest vCPU、kernel Vector 三类使用者覆盖硬件前都有失效或完整回退；
- 迁移、对象地址复用、CPU hotplug/PM 和可抢占 kernel Vector resume 不会形成已知假命中；
- 快路径默认关闭，关闭时所有实际恢复仍走 full，可在模块加载时明确回退。

这不是“所有可能交错的形式化证明”，也不是性能结论。PREEMPT_RT、完整 Vector kselftests、
`get-reg-list` 和真实硬件性能仍列为后续补测；所有内核 Vector 使用者遵守
`kernel_vector_begin/end` 等现有 API 是与主线内核相同的前提。

## 2. 先用白板理解三个状态

把一个 hart 的物理 Vector 寄存器看成一块白板：

1. **硬件 owner**：白板上现在是谁的数据；
2. **内存新鲜度**：这个主体保存在内存里的副本是否最新；
3. **恢复义务**：下一个使用者是否必须先把自己的内存副本写回白板。

M1 只优化第 3 项中的 Guest 数据加载，绝不让内存副本落后于硬件。即使 owner 缓存完全丢失，
系统也能从最新内存执行 full restore；因此缓存是性能提示，不是正确性所必需的唯一状态。

## 3. 不变量与代码保证

### I1：Guest 内存始终是最新完整副本

- `vcpu_put` 仍调用 Guest Vector save；Dirty 状态真正保存后才允许发布 owner；
- 每次真正 Guest save 都推进 `vector_state_generation`；
- M1 不实现“最新状态只存在硬件”的 `HW_NEWER` 模式。

所以 `KVM_GET_ONE_REG` 可以直接读内存，reset/destroy 也不需要先向另一个 hart 发 IPI 索取
状态。这里仍保留 save 成本，换取控制面和生命周期边界简单、可审查。

### I2：命中必须同时证明身份、版本、hart 和使用资格

per-hart owner 保存：

- `identity`：只比较的 opaque 地址数值，不能解引用；
- `cookie`：vCPU Vector context 分配时取得的单调实例号，用于拒绝地址复用后的 ABA；
- `generation`：同一 vCPU 内存状态的版本；
- `vcpu_id` 与 `guest_vs`：用于观测和条件核对。

load 仅在当前 hart 的 owner 同时匹配 identity、cookie、generation，Guest VS 非 Off、Host VS
为 Off 且 owner 未被失效时返回命中。owner 是 per-CPU 数据，load 会消费它，下一次 put 才能
重新发布，不存在一个候选被多个 entry 重复消费。

### I3：put 只能发布真实驻留的 Guest

发布前必须同时满足：

```text
Guest VS != Off
Host 用户态 VS == Off
RISCV_V_VCPU_CTX 已设置
RISCV_V_VCPU_NEED_RESTORE 未设置
RISCV_V_VCPU_CSR_RESTORE 未设置
```

后两项排除“恢复尚未完成”的 vCPU；`VCPU_CTX` 排除已离开硬件的 Guest。该条件曾通过 trace
实际拒绝 3 次旧逻辑会误报的候选。

### I4：命中只省略数据寄存器，不省略控制状态

Guest save 为保存整组寄存器会改写 `vl/vtype` 等控制状态，因此硬件里即使仍是 Guest 的
`v0-v31`，也不能直接进入 Guest。命中时仍在 entry 前最后安全位置恢复
`vstart/vl/vtype/vcsr`，并把 Guest VS 标为 Clean。

如果 entry 前发生任何 Vector 覆盖，统一失效回调会把 `CSR_RESTORE` 升级为
`NEED_RESTORE`，随后执行 full restore。load-entry 强制写坏 `v0` 的测试已验证这条升级链。

### I5：任何合法的 Host/kernel Vector 覆盖都先撤销 Guest owner

| 覆盖路径 | 覆盖前的处理 |
|---|---|
| 普通 task save | `TASK_SAVE` invalidate |
| 普通 task restore/延迟恢复 | `TASK_RESTORE` invalidate |
| task discard/首次使用相关路径 | `TASK_DISCARD` invalidate |
| `kernel_vector_begin()` | `KERNEL_VECTOR` invalidate，再 flush/使用 |
| active preemptible kernel Vector task 恢复 | M1D 在 `__switch_to_vector()` 先做 `KERNEL_VECTOR` invalidate |
| CPU offline / non-retention PM | `CPU_STATE` invalidate |

signal 和 ptrace 最终复用 task save/restore wrapper；softirq 如需 Vector，仍须经过 kernel Vector
API。hardirq/NMI 被 `may_use_simd()` 禁止使用该接口。绕过内核 API 直接写 Vector 寄存器本来
就会破坏普通 task 上下文，不是本优化新增的允许行为。

### I6：迁移和修改后的旧 hart 候选不能命中

- load 会比较当前 CPU 与 `last_exit_cpu`，首次迁入按 migration 回退；
- Guest 在任一 hart 真正保存、reset 或 SET_ONE_REG 后都会推进 generation；
- 因此源 hart 留下的旧候选在 Guest 状态改变后必然 generation mismatch；
- 如果 Guest 在目标 hart 没有改变 Vector 状态，旧数据与最新内存仍相同，版本不变并不构成
  隔离问题。

CPU6→CPU7→CPU6 定向测试已捕获 `generation → full restore`，随后才重新进入 CSR-only。

### I7：vCPU 释放后没有可解引用悬空 owner

owner 不保存 `struct kvm_vcpu *` 类型，只保存不可解引用的 `unsigned long identity`。即使分配器
复用相同地址，新 vCPU 的 cookie 也不同，不能发生 ABA 假命中。destroy selftest 已证明新
Guest 以 `other_vcpu → full` 进入，读到全零而不是旧 Guest 的 `0x5d`。

### I8：配置关闭和不支持 Vector 时行为可回退

- `vector_owner_fastpath` 是只读布尔模块参数，默认 `N`；
- 参数关闭时仍可记录候选，但 load/put 不采用 preserve/CSR-only 行为；
- 最终关闭组 30/30 RVV PASS，2194 次实际恢复全部为 full；
- `CONFIG_RISCV_ISA_V=n` 有空实现，V=n 的完整 `Image modules` 构建通过。

### I9：回调注册和模块卸载满足生命周期要求

通用 Vector 代码通过 RCU 读取 KVM invalidate callback；KVM 卸载时先把 callback 置空，再
`synchronize_rcu()`，防止模块文本释放后仍被调用。失效回调在访问 per-CPU owner 时关闭抢占，
不会在一次操作中迁移到另一个 hart。

## 4. ABI 审查

| ABI/接口 | 结论 |
|---|---|
| KVM ioctl 与 ONE_REG ID | 未修改 |
| Guest 可见 Vector ISA、VLEN、寄存器布局 | 未修改 |
| signal frame / ptrace regset | 未修改；沿用原 save/延迟 restore 路径 |
| vCPU reset/GET/SET 语义 | 保持；SET/reset 推进版本并迫使 full restore |
| 用户态 QEMU 启动方式 | 无需修改 |
| 新模块参数 | `vector_owner_fastpath`，只读、默认关闭，用于显式试验/回退 |
| 新 tracepoint | 只用于内核内部观测，不改变 Guest 或 KVM UAPI |

因此“ABI 不变”指已有用户态和 Guest 接口的布局、编号及语义不变；新增加的调试/控制入口并
不要求已有程序适配。

## 5. 证据矩阵

| 风险 | 主要证据 | 结论 |
|---|---|---|
| 默认关闭是否回退 | `m1c-final-off.*` | 30/30，实际 restore 全 full |
| 开启后基本正确性 | `m1c-final-on.*` | 30/30，1948 CSR-only、6 full |
| Host task 覆盖 | `m1c-on-host-rvv-pinned.trace` | Host 500/500、Guest 100/100，task_restore 失效 |
| entry 前 kernel 覆盖 | `m1c-load-entry-clobber.trace` | 真写坏 v0 后升级 full，Guest 20/20 |
| 跨 hart 迁移 | `m1c-on-migration-generation.trace` | generation miss 后 full |
| hotplug | `m1c-on-cpu-hotplug.trace` | cpu_state 失效，10/10 |
| reset | `m1c-on-reset.trace`、`m1c-on-vcpu-reset.trace` | QMP/SBI 两类均回退，分别 10/10 |
| GET/SET_ONE_REG | `m1c-on-one-reg.trace` | GET 保持值；SET 后 generation/full |
| destroy/地址复用风险 | `m1c-on-destroy.trace` | 新 Guest 不读到旧数据 |
| preemptible kernel Vector resume | `m1d-preempt-vector-final.*` | invalidate 在 resume 前，随后 full，20/20 |

所有百分比只是 trace 事件变化，不是安全性的依据。安全性来自“命中条件 + 覆盖前失效 +
不确定即 full”的组合，定向测试用来证明这些分支确实能被触发。

## 6. 已知限制和后续检查

1. 当前 V=y 内核为 `PREEMPT`，尚未单独构建/运行 PREEMPT_RT；
2. CPU PM 在 QEMU 中缺少有代表性的 non-retention 状态，当前依据 cleanup 调用链证明，待真机补测；
3. 尚未运行完整 Vector kselftests 与 `get-reg-list`，需在 R4 按风险补最小集合；
4. QEMU TCG + 嵌套 KVM 可证明状态机和数据正确性，不能证明真机时延收益；
5. 原型目前混有观测 trace 和行为代码，上游提交前应按“通用 hook、KVM owner、行为、测试”
   拆分，并接受维护者对通用回调接口形态的评审。

## 7. 产出要求 7 的当前判定

用户态 ABI、Guest/Host/另一 vCPU 隔离、Vector 数据与控制状态安全、普通抢占、可抢占 kernel
Vector、softirq 以及 hotplug/PM 的关键不变量已经在设计和实现之间逐项对上；有运行条件的
高风险交错均有定向证据。因此产出要求 7 可标记为“初始闭环完成”。

“初始闭环”仍保留第 6 节的诚实边界，不等于已经达到上游合并或真机性能验收状态。

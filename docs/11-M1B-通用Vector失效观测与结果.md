# M1B 通用 Vector 失效观测与结果

日期：2026-10-18  
源码基线：Linux `24a19b953e2a3d0ea5a8c4951a0ab8f32720c907`  
前置补丁：C1 + P1 + M1A  
独立补丁：`m1b-riscv-vector-owner-invalidation-observe.patch`

## 1. 目的

M1A 只在 KVM 的 put/load 两端维护 shadow owner，因此得到的是没有考虑外部覆盖的乐观上界。
M1B 仍不跳过任何 save/restore，只补上一个问题：

> Guest 候选留在某个 hart 后，普通任务、内核 Vector 或 CPU 状态变化真的要碰硬件 Vector
> 时，KVM 能否在覆盖发生前看见并清除候选？

这里的 hook 不是“每次任务调度都失效”。只有将要实际保存、恢复、丢弃或使用硬件 Vector
状态时才通知，避免把纯标量调度错误地算成污染。

## 2. 实现

### 2.1 通用失效入口

在 RISC-V Vector 通用路径增加一个可为空的 RCU callback，KVM 模块加载时注册、卸载前注销。
通知原因有五类：

- `task_save`：普通任务的脏 Vector 状态即将从硬件保存到内存；
- `task_restore`：普通任务的 Vector 状态即将恢复到硬件；
- `task_discard`：硬件 Vector 状态即将被丢弃/标脏；
- `kernel_vector`：`kernel_vector_begin()` 的 flush 路径即将让内核使用 Vector；
- `cpu_state`：KVM 在 CPU offline 或 non-retention PM 入口清理本 hart 虚拟化状态。

通知放在实际硬件读写前。KVM callback 只访问本 CPU 的 shadow 元数据，不解引用缓存中的
旧 vCPU 指针；trace 所需的 `vcpu_id` 和 Guest VS 在发布候选时已经快照下来。

### 2.2 语义仍然不变

M1B 的 load、put、Guest/Host 完整 save/restore 与 M1A 完全相同。新增逻辑只做：

1. 记录 `action=invalidate` 和原因；
2. 清空本 hart 的 shadow 候选；
3. 让下一次 load 报告正常 miss，而不是把已被覆盖的状态误报成 hit。

因此本阶段可以验证失效覆盖面，但不能把事件减少解释为已经获得性能收益。

### 2.3 G1 审查补出的硬件驻留条件

第一版 M1B 只用 Guest VS 非 Off、Host VS 为 Off 判断 put 候选。继续审查 entry 路径后发现，
这还不够：load 可以先置 `RISCV_V_VCPU_NEED_RESTORE`，但 vCPU 在真正进入 Guest 前就被
调度切出。此时没有执行 full restore，硬件里并不是该 Guest 的数据。

最终 put 条件增加为：

```text
Guest VS != Off
&& Host VS == Off
&& RISCV_V_VCPU_CTX 已置位
&& RISCV_V_VCPU_NEED_RESTORE 未置位
```

不满足最后两项时记录 `reason=not_resident`，不发布候选。该条件同样覆盖 Guest 退出后、
put 前被 kernel Vector flush，导致 Guest 需要重新恢复的情形。

### 2.4 G1 审查补出的多 hart 版本条件

仅在 reset 或 `KVM_SET_ONE_REG` 时递增 generation 还不够。假设 vCPU 先在 CPU6 留下
候选，随后迁移到 CPU7 并真正执行了新的 Vector 指令，再回到 CPU6；CPU6 仍保存着同一
vCPU、同一 cookie 和旧 generation。如果 generation 没有随 Guest 内容变化，CPU6 会把
已经过期的物理寄存器误判成命中。

因此，M1B 在每次把 **DIRTY Guest Vector 真正保存回内存** 后也递增
`vector_state_generation`。新的含义是“Guest 内存中的 Vector 内容版本”，而不只是
“管理接口修改次数”。当前 hart 的 put 候选记录新版本；其他 hart 遗留的候选仍是旧版本，
vCPU 返回时会以 `reason=generation` 回退到完整恢复。

## 3. 构建、启动与静态检查

- `CONFIG_RISCV_ISA_V=y` 的完整 `Image modules`：通过；
- `CONFIG_RISCV_ISA_V=n` 的 KVM 模块构建：通过；
- L1 已启动新内核，`riscv_v_owner_invalidate` 可在 `/proc/kallsyms` 查到；
- L2 由新 Image 启动，RVV 冒烟输出 `RVV_PASS elements=257 vlenb=32 VLEN=256`；
- `git diff --check`：通过；
- M1B 独立补丁 `checkpatch.pl --strict`：0 error、0 warning、0 check；
- 独立补丁能在 M1A 基线上干净应用，并精确复现当前工作树。

部署的 V=y KVM 模块：

```text
SHA256 5302d20911a10d3a57a24df5240e4c7be442c5354e394c5634b0260e51c315f8
```

启动 Image：

```text
SHA256 334d74e72941d9329b9fe6819414846aa174d8b57606fbbdbbe384c2ecc9a611
```

M1B 独立补丁：

```text
SHA256 6695c4fbbb9d0a0b0d743aa3ffdb9c23165a5ddb569fe25e053cf892555a49bd
```

## 4. 运行结果

### 4.1 修正驻留条件后的稳定 L2 100 次 RVV

主证据：`evidence/p1/m1b-shadow-rvv-100-residency-fixed.trace`

| action / reason | 次数 |
|---|---:|
| put / put_candidate | 2,676 |
| put / not_resident | 3 |
| load / hit | 2,669 |
| load / migration | 3 |
| load / empty | 5 |
| invalidate / kernel_vector | 5 |
| restore request / load | 2,677 |
| actual full restore | 2,674 |

覆盖通用失效和硬件驻留条件后的候选命中率为
`2,669 / 2,676 = 99.738%`。request 与 actual restore 的 3 次差值恰好对应 3 次
`not_resident`：load 已请求 restore，但在真正 Guest entry 前发生 put；下一次 load 报
empty 并重新执行 full restore。这证明修正命中了真实调度序列，而不是只增加了理论分支。

更早的第一版证据仍保留为 `evidence/p1/m1b-shadow-rvv-100-steady.trace`，但它早于驻留条件
修正，只用于追溯，不再作为最终命中率。

较早窗口记录到 6 次、驻留修正后的窗口记录到 5 次 `kernel_vector` 失效。P1 的
`source=kernel_vector` 为 0，只说明
`RISCV_V_VCPU_CTX` 仍为真时没有触发旧 flush callback；它看不到 put 以后、下次 load 以前
发生的内核 Vector 使用。M1B 补上了这个盲区。

### 4.2 generation 修正后的最终稳态回归

主证据：`evidence/p1/m1b-shadow-rvv-100-generation-fixed.trace`  
SHA256：`b047304b84d2087cd8eb19103687fcc43e4c65c1a12123ebf09565fd8573332b`

100 次 L2 RVV 均输出 `RVV_PASS`，trace 结果为：

| action / reason | 次数 |
|---|---:|
| put / put_candidate | 2,888 |
| load / hit | 2,875 |
| load / migration | 10 |
| load / other_vcpu | 1 |
| load / empty | 2 |
| invalidate / kernel_vector | 12 |
| restore request / load | 2,888 |
| actual full restore | 2,888 |

候选命中率为 `2,875 / 2,888 = 99.550%`。这是加入驻留条件和多 hart generation 后的
最终 M1B 稳态结果；M1B 仍未改变行为，所以 request 与 full restore 数量相等。

### 4.3 Host RVV 与 L2 共用同一 hart

证据：`evidence/p1/m1b-shadow-host-rvv-pinned.trace`

测试把两个 L2 vCPU 暂时限制到同一 Host CPU，并在同一 CPU 运行 Host `rvv-smoke`；结束后
亲和性恢复为 0-7，L2 的 100 次 RVV 全部通过。

| action / reason | 次数 |
|---|---:|
| put / put_candidate | 7,016 |
| load / hit | 1,179 |
| load / other_vcpu | 5,322 |
| invalidate / task_restore | 515 |
| load / empty | 514 |
| invalidate / kernel_vector | 2 |

`task_restore` 由 Host 的 `rvv-smoke` 触发，证明普通任务真正恢复 Vector 到硬件前会清除
Guest 候选。人工把两个 vCPU 和 Host Vector 任务挤到一个 CPU 后，命中率降为
`1,179 / 7,016 = 16.805%`；这正是压力场景应出现的结果，不是功能回归。

另一个未固定 CPU 的干扰窗口见
`evidence/p1/m1b-shadow-host-rvv-interference.trace`：2,399 个候选中 2,392 个 hit、6 次
`kernel_vector`、4 次迁移和 3 次 empty。由于 Host RVV 与 QEMU vCPU 当时没有落在同一
hart，未出现 `task_restore`，所以增加了上面的固定 CPU 对照实验。

### 4.4 CPU hotplug

证据：`evidence/p1/m1b-shadow-cpu-hotplug-owned.trace`

先让 VCPU 0 在 CPU7 发布有效候选并暂停 QEMU，再临时把 CPU7 offline/online。为了不让
测试控制进程在 offline 之前使用 kernel Vector 抢先清空候选，控制进程临时限制在 CPU0-6。
trace 得到：

```text
cpuhp/7 ... action: invalidate, reason: cpu_state, VCPU: 0, CPU: 7
```

CPU7、QEMU 和系统服务的亲和性均已恢复。该证据证明 CPU offline 的 KVM CSR 清理路径会
让本 hart shadow owner 失效；同一个 `kvm_riscv_csr_cleanup()` 也用于 non-retention PM
入口。当前 QEMU 环境没有独立触发真实 suspend/retention 状态，因此 PM 是代码共用路径
证明，不冒充单独的运行时电源管理测试。

### 4.5 CPU6 → CPU7 → CPU6 定向迁移

证据：`evidence/p1/m1b-shadow-migration-generation.trace`  
SHA256：`4fff72f03c514bddda9f35d268e9abd8755aac24f0ff30fdc3194fd1888609a0`

测试把 L2 VCPU 0 线程依次固定到 CPU6、CPU7、CPU6，并在每一步运行 RVV 校验。关键序列是：

1. CPU6 留下 generation 326 的候选；
2. vCPU 迁移到 CPU7，首次 load 因 `migration` 完整恢复；
3. vCPU 在 CPU7 执行新工作并把内存版本推进到 generation 339；
4. 返回 CPU6 时，CPU6 的旧候选与当前版本不符，出现唯一一次 `reason=generation`；
5. 紧随其后的 restore request 和 actual full restore 均发生，三轮 RVV 都通过。

这证明 generation 修正不是静态推断，而是实际阻止了“同一 vCPU 回到旧 hart”产生的假命中。

## 5. G1 已回答与未回答的问题

M1B 已证明：

1. 普通 task restore、kernel Vector、CPU hotplug 能在覆盖前使候选失效；
2. 候选只在 Guest 数据确实驻留硬件时发布，实测拒绝了 3 次 restore 前切出的假候选；
3. 跨 put/load 的候选在正常负载下仍有约 99.7% 命中上界；
4. vCPU identity、generation、迁移、其他 vCPU 和 CPU 状态变化均有独立 miss/失效原因；
5. shadow 事件不依赖解引用可能过期的 vCPU 指针。

其中第 3 项在最终 generation 版本的独立 100 次回归中为 99.550%；99.738% 是驻留条件
修正后、generation 修正前的另一个稳定窗口，两份原始 trace 均保留。

G1 仍不能直接放行行为优化，因为还缺：

1. `Host VS=Off` 与“没有 Host restore 义务”的严格证明；
2. control CSR-only restore 的最小实现和正确性测试；
3. reset/destroy/get-set-reg 与真正行为缓存相交时的完整同步协议；
4. `task_save`、`task_discard` 等较少见分支的定向负向测试；
5. 真实硬件性能数据。

## 6. 下一步

进入 G1 证据审查，而不是立刻跳过 restore：先对 Host VS/`host_context` 的含义和所有写
硬件 Vector 的入口做源码级闭环，再实现一个默认关闭、只在 shadow hit 时执行的
CSR-only restore 原型。原型先保留 put 的 Guest 完整保存和所有现有回退路径，并用 trace
比较 full restore 与 CSR-only restore 次数。

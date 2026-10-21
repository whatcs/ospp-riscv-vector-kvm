# RISC-V Vector 上下文调用链与时序图

> 基线：Linux `24a19b953e2a`（v7.3-rc7），核对日期：2026-10-17。  
> 本文只描述当前代码事实，不包含尚未实现的 `kvm_vector_owner` 方案。

## 1. 先记住三个层次

理解这条路径最重要的一点是：一次 `KVM_RUN` 内可以有很多次 Guest entry/exit；同时，
Host 调度器也可能把 QEMU vCPU 线程切出再切回。后者会通过 preempt notifier 再次调用
`kvm_arch_vcpu_put()` / `kvm_arch_vcpu_load()`。

```mermaid
flowchart TD
    U["QEMU vCPU 线程调用 KVM_RUN"] --> L["generic vcpu_load<br/>注册 preempt notifier并调用 arch load"]
    L --> W{"内核中的运行循环<br/>ret > 0"}
    W --> E["进入 Guest"]
    E --> X["发生 VM-exit"]
    X --> H["内核处理退出原因"]
    H -->|仍可在内核中继续| W
    H -->|Host 调度器切出 vCPU 线程| SO["kvm_sched_out<br/>调用 arch put"]
    SO --> SI["稍后 kvm_sched_in<br/>调用 arch load"]
    SI --> W
    H -->|需要返回 QEMU| P["generic vcpu_put<br/>调用 arch put并注销 notifier"]
    P --> U2["返回用户态"]
```

因此，“一次 VM-exit”不等于“一次完整 Vector 保存/恢复”。连续的 entry/exit 如果没有
调度切出或其他 Vector 使用者介入，可以直接复用 Guest 硬件状态；但 vCPU 线程一旦被 Host
调度器切出，当前 `kvm_arch_vcpu_put()` 仍会保存 Guest并恢复 Host，切回时又重新装入 Guest。
这正是项目需要重点量化的调度边界。

对应入口：

- `arch/riscv/kvm/vcpu.c:891`：`kvm_arch_vcpu_ioctl_run()`
- `arch/riscv/kvm/vcpu.c:588`：`kvm_arch_vcpu_load()`
- `arch/riscv/kvm/vcpu.c:660`：`kvm_arch_vcpu_put()`
- `arch/riscv/kvm/vcpu.c:803`：`kvm_riscv_vcpu_enter_exit()`
- `virt/kvm/kvm_main.c:165`：外层 `vcpu_load()` 和 preempt notifier 注册
- `virt/kvm/kvm_main.c:6405` 附近：`kvm_sched_in()` / `kvm_sched_out()`

## 2. 一个 arch load/put 驻留区间的 Vector 时序

下图中的“内存副本”是 `vcpu->arch.host_context.vector` 和
`vcpu->arch.guest_context.vector`；“硬件”是当前 hart 上实际的 Vector 寄存器。一次完整
`KVM_RUN` 至少有一个这样的区间，也可能因 Host 调度切出/切回而出现多个区间。

```mermaid
sequenceDiagram
    participant Q as QEMU vCPU 线程
    participant R as kvm_arch_vcpu_ioctl_run
    participant V as Vector 管理代码
    participant M as 内存中的上下文
    participant H as 硬件 Vector 寄存器
    participant G as Guest

    Q->>R: KVM_RUN 或 Host 调度切回
    R->>V: kvm_arch_vcpu_load
    V->>V: get_cpu_vector_context
    V->>M: 保存 Host 硬件状态到 host_context
    V->>V: 设置 VCPU_NEED_RESTORE
    V->>V: put_cpu_vector_context

    loop 同一驻留区间内可重复多次
        R->>V: 最后安全入口（中断关闭）
        alt VCPU_NEED_RESTORE 已设置
            V->>H: 从 guest_context 真正恢复 Guest Vector
            V->>V: 清 NEED_RESTORE，置 VCPU_CTX
        else 没有其他 Vector 使用者覆盖硬件
            V->>V: 跳过恢复
        end
        V->>G: 进入 Guest
        G->>H: Guest 使用 Vector，VS 可变为 Dirty
        G-->>V: VM-exit
        V-->>R: 保存通用陷阱信息，不立即保存 Vector
    end

    R->>V: KVM_RUN 返回或 Host 调度切出<br/>kvm_arch_vcpu_put
    V->>V: get_cpu_vector_context
    alt Guest VS 为 Dirty
        V->>M: 保存 Guest Vector 到 guest_context
        V->>V: Guest VS 标为 Clean
    end
    V->>H: 从 host_context 恢复 Host Vector
    V->>V: 清 VCPU_CTX 和 NEED_RESTORE
    V->>V: put_cpu_vector_context
    R-->>Q: 返回用户态或等待再次调度
```

这里有三个容易混淆的点：

1. `kvm_riscv_vcpu_guest_vector_restore()` 名字虽然叫 restore，实际上只设置
   `RISCV_V_VCPU_NEED_RESTORE`，并不搬运寄存器数据。
2. 真正的恢复发生在 `kvm_riscv_vcpu_enter_exit()` 中，位置已经非常靠近 Guest entry。
3. `kvm_riscv_vcpu_host_vector_restore()` 会真实覆盖硬件寄存器，并清除两个 vCPU Vector 标志。

对应代码：

- `arch/riscv/kvm/vcpu_vector.c:55`：只设置 `RISCV_V_VCPU_NEED_RESTORE`
- `arch/riscv/kvm/vcpu.c:822`：entry 前执行 `__kvm_riscv_vector_restore()`
- `arch/riscv/kvm/vcpu_vector.c:71`：恢复 Host 并清 vCPU 标志

## 3. 为什么普通 VM-exit 不会每次都恢复 Vector

```mermaid
flowchart TD
    X["Guest VM-exit"] --> A["回到 KVM 运行循环"]
    A --> B{"退出处理期间<br/>有人使用 Vector 吗？"}
    B -->|没有| S{"vCPU 线程被 Host<br/>调度切出吗？"}
    S -->|否| C{"需要返回 QEMU 吗？"}
    S -->|是| SP["kvm_sched_out 调用 arch put<br/>保存 Guest，恢复 Host"]
    SP --> SL["kvm_sched_in 调用 arch load<br/>再次设置 NEED_RESTORE"]
    SL --> D2["再次 entry 前恢复 Guest"]
    C -->|不需要| D["再次进入 Guest<br/>NEED_RESTORE 未设置，跳过恢复"]
    C -->|需要| P["vcpu_put<br/>保存 Guest，恢复 Host"]
    B -->|kernel-mode Vector 介入| F["flush 回调保存 Guest<br/>并设置 NEED_RESTORE"]
    F --> K["内核可以覆盖 Vector 寄存器"]
    K --> D3["再次进入 Guest前<br/>从 guest_context 恢复"]
```

所以后续做性能统计时，不能简单地用“VM-exit 次数”推算“Vector restore 次数”。真正需要统计的是：

- `__kvm_riscv_vector_restore()` 实际调用次数；
- `vcpu_load()` 次数；
- preempt notifier 引起的 `kvm_arch_vcpu_load/put()` 次数；
- kernel-mode Vector 触发的 flush 次数；
- `vcpu_put()` 次数及 Guest `VS=Dirty` 的比例。

## 4. kernel-mode Vector 介入时的保护链

内核准备使用 Vector 时，必须先保护当前硬件内容。若硬件里是 KVM Guest 状态，通用
kernel-mode Vector 代码会通过已注册的 KVM 回调把 Guest 状态保存下来。

```mermaid
sequenceDiagram
    participant K as kernel_vector_begin
    participant C as kernel_mode_vector
    participant F as KVM flush 回调
    participant M as guest_context
    participant H as 硬件 Vector
    participant E as 下一次 Guest entry

    K->>C: 申请 CPU Vector 上下文
    C->>C: 检查 RISCV_V_VCPU_CTX
    alt 当前硬件属于正在运行的 vCPU
        C->>F: kvm_riscv_vcpu_flush_vector
        F->>H: 若 Guest VS=Dirty，保存寄存器
        F->>M: 更新 Guest 内存副本，VS=Clean
        F->>F: 设置 VCPU_NEED_RESTORE
    else 当前硬件属于普通 Host 任务
        C->>M: 保存 current 的用户 Vector 状态
        C->>C: 设置 TIF_RISCV_V_DEFER_RESTORE
    end
    C-->>K: 内核现在可以使用 Vector
    K->>H: 内核 Vector 运算可覆盖寄存器
    K->>C: kernel_vector_end
    E->>H: 若 NEED_RESTORE，重新装入 Guest
```

关键入口：

- `arch/riscv/kernel/kernel_mode_vector.c:100`：`__riscv_flush_vector_context()`
- `arch/riscv/kvm/vcpu_vector.c:100`：`kvm_riscv_vcpu_flush_vector()`
- `arch/riscv/kernel/kernel_mode_vector.c:250`：`kernel_vector_begin()`
- `arch/riscv/kernel/kernel_mode_vector.c:275`：`kernel_vector_end()`

注意：flush 后当前代码保留 `RISCV_V_VCPU_CTX`，同时增加
`RISCV_V_VCPU_NEED_RESTORE`。这表示“逻辑上仍处于 vCPU Vector 上下文，但硬件内容在下一次
Guest entry 前必须重新装入”。

## 5. 用户任务第一次使用 Vector

`arch/riscv/kernel/vector.c` 主要负责用户 Vector 上下文的初始化、分配和控制策略。
其中与保存/恢复链最直接相关的是首次使用处理：当用户任务的 `VS=Off` 时执行第一条
Vector 指令，会先以非法指令异常进入内核。

```mermaid
flowchart TD
    U["用户任务执行第一条 Vector 指令<br/>保存的 VS=Off"] --> T["非法指令异常<br/>do_trap_insn_illegal"]
    T --> H["riscv_v_first_use_handler"]
    H --> C{"CPU 支持 Vector、策略允许<br/>且确实是 Vector 指令？"}
    C -->|否| N["不是 Vector 首次使用路径<br/>交回普通非法指令处理"]
    C -->|是| A["为 current.thread.vstate<br/>分配寄存器存储空间"]
    A --> E{"分配成功？"}
    E -->|否| S["向任务发送 SIGBUS"]
    E -->|是| V["把保存的 VS 置为 Initial<br/>设置 TIF_RISCV_V_DEFER_RESTORE"]
    V --> R["返回用户态前恢复新 Vector 上下文"]
    R --> U2["回到同一条 Vector 指令重新执行"]
```

对应代码：

- `arch/riscv/kernel/traps.c:170`：`do_trap_insn_illegal()`
- `arch/riscv/kernel/vector.c:185`：`riscv_v_first_use_handler()`
- `arch/riscv/kernel/vector.c:230`：`riscv_v_vstate_ctrl_init()`
- `arch/riscv/include/asm/entry-common.h:9`：返回用户态前完成延迟恢复

这条链解释了为什么用户任务一开始不必为 Vector 寄存器分配大块内存：只有真正执行
Vector 指令并且策略允许时，才建立 `vstate.datap`。

## 6. 普通 Linux 任务的 Vector 调度路径

这条路径与 KVM 的 vCPU 标志不同。普通用户任务通过
`TIF_RISCV_V_DEFER_RESTORE` 把恢复推迟到真正返回用户态之前。

```mermaid
sequenceDiagram
    participant S as 调度器
    participant P as prev 任务
    participant N as next 任务
    participant H as 硬件 Vector
    participant U as 返回用户态路径

    S->>P: __switch_to_vector(prev, next)
    alt prev 的用户 Vector 为 Dirty
        P->>H: 保存到 prev.thread.vstate
        P->>P: VS 标为 Clean
    end
    S->>N: riscv_v_vstate_set_restore
    N->>N: 设置 TIF_RISCV_V_DEFER_RESTORE
    Note over S,N: 调度时不立即恢复 next
    U->>N: arch_exit_to_user_mode_prepare
    alt DEFER_RESTORE 已设置
        N->>H: 从 next.thread.vstate 恢复
        N->>N: 清除 DEFER_RESTORE
    end
```

对应代码：

- `arch/riscv/include/asm/vector.h:374`：`__switch_to_vector()`
- `arch/riscv/include/asm/vector.h:329`：`riscv_v_vstate_set_restore()`
- `arch/riscv/include/asm/entry-common.h:9`：返回用户态前真正恢复

## 7. KVM Vector 标志状态机

这张图只描述当前两个标志，不等同于未来的 per-hart owner；并假设该 Guest 已启用 V 扩展。

```mermaid
stateDiagram-v2
    [*] --> HostActive
    HostActive: CTX=0, NEED=0
    LoadPending: CTX=0, NEED=1
    GuestLive: CTX=1, NEED=0
    GuestReloadPending: CTX=1, NEED=1

    HostActive --> LoadPending: arch load 设置 NEED
    LoadPending --> GuestLive: entry 真正恢复 Guest
    GuestLive --> GuestLive: 普通 VM-exit / re-entry
    GuestLive --> GuestReloadPending: kernel Vector flush
    GuestReloadPending --> GuestLive: 下一次 entry 恢复 Guest
    LoadPending --> HostActive: arch put 恢复 Host
    GuestLive --> HostActive: arch put 恢复 Host
    GuestReloadPending --> HostActive: arch put 恢复 Host
```

这解释了为什么不能把 `RISCV_V_VCPU_CTX` 直接理解成“硬件寄存器一定还是 Guest 数据”：
`CTX=1, NEED=1` 时，Guest 的可信最新值已经在内存中，硬件可以被 kernel-mode Vector 使用。

## 8. Vector 与 FP 路径的差别

RISC-V KVM 的 FP 和 Vector 并非完全同构：

| 阶段 | FP（`vcpu_fp.c`） | Vector（`vcpu_vector.c`） |
|---|---|---|
| `vcpu_load()` | 立即保存 Host、立即恢复 Guest | 保存 Host，只设置 `NEED_RESTORE` |
| Guest entry 前 | 无单独的 FP 延迟恢复步骤 | 若 `NEED_RESTORE`，才真正恢复 Guest |
| 同一 `KVM_RUN` 内重复 VM-exit | 通常保持 Guest FP | 通常保持 Guest Vector |
| `vcpu_put()` | Dirty 时保存 Guest，立即恢复 Host | Dirty 时保存 Guest，立即恢复 Host并清 vCPU 标志 |

所以本项目讨论的“延迟恢复”和“重复加载”主要针对 Vector，不能直接照搬 FP 路径的结论。

## 9. 底层 save/restore 到底搬了什么

`__riscv_v_vstate_save()` / `__riscv_v_vstate_restore()` 处理的不只是 `v0`～`v31`：

- `vstart`
- `vtype`
- `vl`
- `vcsr`
- `vlenb`
- 32 个 Vector 数据寄存器

保存数据寄存器前会执行 `vsetvli e8,m8`。也就是说，save 会先把原始 `vl/vtype` 记入内存，随后为了批量保存寄存器而改变硬件中的 `vl/vtype`。当前代码稍后有完整 restore，因此是闭合的；未来若尝试“保存后仍宣称硬件 Guest 状态可直接复用”，必须把这个副作用纳入证明。

对应代码：`arch/riscv/include/asm/vector.h:201` 和 `:238`。

## 10. 从现状图直接得到的设计约束

这些是源码事实带来的约束，不是最终方案：

1. 优化目标不能写成“消除每次 VM-exit 的 restore”，因为普通内核内 exit/re-entry 已经不恢复。
2. 真正的高频候选边界是 Host 调度造成的 `kvm_sched_out/in`，以及多次 `KVM_RUN`
   之间的 arch put/load；但当前 arch put 会恢复 Host，Guest 硬件内容确实被覆盖。
3. kernel-mode Vector 是一个独立覆盖者；任何 owner 设计都必须与 flush 回调同步。
4. `VS=Clean/Dirty` 只说明是否需要保存，不能说明寄存器属于哪个 vCPU。
5. `RISCV_V_VCPU_CTX` 也不是“某个具体 vCPU 的身份”；具体正在运行的 vCPU 由 per-CPU running-vCPU 信息提供。
6. 跳过数据搬运时仍要正确维护 `CTX/NEED_RESTORE`，否则 kernel Vector flush 会保存错对象。

## 11. 产出要求 2 对账

| 官方点名内容 | 本文覆盖位置 | 核对结果 |
|---|---|---|
| `arch/riscv/kernel/vector.c` | 第 5 节：首次使用、分配、延迟恢复 | 已覆盖 |
| `kernel_mode_vector.c` | 第 4 节：KVM/普通任务 flush 分流 | 已覆盖 |
| `arch/riscv/kvm/vcpu_fp.c` | 第 8 节：与 Vector load/put 对照 | 已覆盖 |
| `arch/riscv/kvm/vcpu_vector.c` | 第 2、4、7 节：save/restore/flush 与标志状态 | 已覆盖 |
| `vcpu_load/put` | 第 1、2 节：外层调用及调度切出/切回的重复 arch hook | 已覆盖 |
| vCPU entry/exit | 第 1～3 节：内层循环和最后安全恢复点 | 已覆盖 |
| 当前保存/恢复时序图 | 第 2 节为主，第 3～7 节展开特殊路径 | 已覆盖 |

## 12. 本文源码索引

| 主题 | 文件与入口 |
|---|---|
| KVM_RUN 外层与内层循环 | `arch/riscv/kvm/vcpu.c:891` |
| generic load/put 与调度回调 | `virt/kvm/kvm_main.c:165`～`:183`、`:6405`～`:6432` |
| vCPU load/put | `arch/riscv/kvm/vcpu.c:588`、`:660` |
| 最后安全 entry | `arch/riscv/kvm/vcpu.c:803` |
| KVM Vector save/restore/flush | `arch/riscv/kvm/vcpu_vector.c:45`～`:115` |
| KVM FP 对照 | `arch/riscv/kvm/vcpu_fp.c:20`～`:76` |
| 用户 Vector 首次使用 | `arch/riscv/kernel/vector.c:179`～`:228` |
| 通用任务 Vector 调度 | `arch/riscv/include/asm/vector.h:311`～`:405` |
| kernel-mode Vector | `arch/riscv/kernel/kernel_mode_vector.c:31`～`:289` |
| 返回用户态延迟恢复 | `arch/riscv/include/asm/entry-common.h:9`～`:20` |


# RISC-V Vector 与 KVM 上下文调研报告

日期：2026-10-18  
源码基线：Linux `24a19b953e2a3d0ea5a8c4951a0ab8f32720c907`

## 1. 调研目标

本文对应 OSPP 产出要求 1，覆盖：

1. RISC-V Vector 状态由哪些寄存器组成；
2. 特权架构里的 VS/SD 状态表示什么；
3. Linux 普通用户任务如何保存、恢复和延迟恢复 Vector；
4. kernel-mode Vector 如何避免污染用户或 Guest；
5. KVM vCPU 的 FP/Vector 状态如何在 Host 与 Guest 间切换；
6. 这些机制为什么仍可能留下可优化的重复 restore。

本文讲“概念和机制”。逐函数调用顺序与图见 `docs/04-RISC-V-Vector调用链与时序图.md`。

## 2. 先建立一个直观模型

每个 hart 只有一套物理 Vector 寄存器，但运行在它上面的主体很多：

- Host 用户任务；
- Host 内核；
- Guest vCPU；
- Guest 内核和 Guest 用户任务（对 Host KVM 来说都属于这个 vCPU 的 Guest 状态）。

因此内核需要同时管理两类东西：

```text
硬件副本：现在物理寄存器里是谁的数据
内存副本：某个 task/vCPU 保存下来的备份
```

save 是“硬件 → 内存”，restore 是“内存 → 硬件”。Vector 状态很大，搬一次比几个普通
整数寄存器贵得多。本项目的难点不是不会搬，而是要证明什么时候硬件里本来就是正确数据，
因而可以安全少搬一次。

## 3. Vector 上下文包含什么

### 3.1 32 个数据寄存器

RISC-V V 扩展定义 `v0`～`v31`。每个寄存器的宽度是 VLEN 位；软件通过只读 CSR
`vlenb` 得到 `VLEN / 8`。Linux 为一个完整 Vector 数据区分配：

```text
32 × vlenb 字节
```

例如本实验环境 `vlenb=32`，所以 VLEN=256 位，一份数据寄存器区是 1024 字节。

### 3.2 控制状态

Linux 的 `struct __riscv_v_ext_state` 还记录：

| 字段 | 初学者理解 | 是否随上下文恢复 |
|---|---|---|
| `vstart` | 一条 Vector 指令从第几个元素继续 | 是 |
| `vl` | 本次实际处理多少个元素 | 是 |
| `vtype` | 元素宽度、寄存器组倍率等布局 | 是 |
| `vcsr` | `vxrm` 舍入模式与 `vxsat` 饱和标志的组合视图 | 是 |
| `vlenb` | 此 hart 的寄存器字节宽度 | 用于描述/ABI；普通 restore 不写它 |
| `datap` | 指向 v0～v31 内存备份 | 指针本身不是硬件状态 |

一个容易踩坑的事实是：保存 v0～v31 时，底层代码会先执行 `vsetvli`，以合适布局把所有
寄存器写入内存。这会改写当前 `vl/vtype`。所以 save 完成后，数据寄存器内容可能仍是原来
那份 Guest 数据，但控制 CSR 已不再完整代表 Guest。这也是设计中引入 `DATA_RESIDENT`、
而不能简单说“完整有效”的原因。

## 4. VS 与 SD：硬件给软件的脏状态提示

### 4.1 VS 四种状态

`sstatus`/`mstatus` 中的 VS 字段描述 Vector 状态的使用情况：

| VS | 名称 | 软件含义 |
|---|---|---|
| `00` | Off | 当前上下文不允许使用 Vector；执行相关指令会触发异常 |
| `01` | Initial | Vector 已允许，但可以按初始状态看待 |
| `10` | Clean | Vector 状态与内存中已保存版本一致 |
| `11` | Dirty | Vector 状态可能被改过，切走前需要保存 |

关键点：VS 是“是否需要保存/是否允许使用”的线索，不是“硬件里属于哪个 task/vCPU”的
owner 标签。两个主体都可能各自在自己的保存状态里写着 Clean，但同一时刻物理寄存器仍
只能属于其中一个。

### 4.2 SD 是汇总位

SD（State Dirty）是 FS、VS、XS 等扩展状态是否存在 Dirty 的汇总提示。它方便内核快速
判断“是否有扩展状态需要处理”，但不能替代读取具体的 VS 字段，也不能告诉 KVM 当前
寄存器属于 Host 还是 Guest。

### 4.3 Clean 不等于硬件仍驻留

本项目必须区分：

- Dirty/Clean：内存是否可能落后于本主体的最新硬件状态；
- resident/owner：物理寄存器当前是否仍是这个主体的数据；
- restore-needed：进入这个主体前是否要从内存加载。

把这三件事混成一个布尔值，会在迁移、kernel Vector 或 get/set-reg 上产生错误。

## 5. Linux 普通用户任务的 Vector 管理

### 5.1 第一次使用：先陷入，再分配

普通任务最初可以处于 VS=Off，内核不必为从未使用 Vector 的任务分配大块状态。用户首次
执行 Vector 指令时触发 illegal-instruction 路径，
`riscv_v_first_use_handler()` 会：

1. 确认 CPU 支持 Vector，且用户策略允许；
2. 确认这真是第一条 Vector 指令；
3. 为 `current->thread.vstate.datap` 分配数据区；
4. 把任务状态打开，并设置 `TIF_RISCV_V_DEFER_RESTORE`；
5. 返回用户态前由统一路径恢复/初始化状态，然后重试原指令。

好处是“没用过 Vector 的任务几乎不承担 Vector 上下文成本”。

### 5.2 切出：只在 Dirty 时保存

任务切换经过 `__switch_to_vector(prev, next)`。对于普通任务：

- `prev` 的 VS=Dirty 才调用 `__riscv_v_vstate_save()`；
- 保存后把 `prev` 标成 Clean；
- `next` 不在调度器里立刻完整 restore，而是设置延迟恢复标志。

这减少了不必要 save，也把 restore 推迟到更接近真正返回用户态的位置。

### 5.3 切入：返回用户态前延迟恢复

`arch_exit_to_user_mode_prepare()` 检查 `TIF_RISCV_V_DEFER_RESTORE`，然后调用
`riscv_v_vstate_restore()`。也就是说：task 被调度到 CPU 上，并不代表立刻加载 Vector；
只有准备回到用户态、确实可能执行用户 Vector 指令时才加载。

这种“最后安全时刻恢复”的思想正是 OSPP 要在 KVM Guest 上继续利用的机制。

### 5.4 signal、ptrace 与 ABI

signal frame、ptrace/regset 等用户 ABI 必须看到逻辑上正确的 task Vector 状态。这意味着
任何懒保存方案都不能只维护硬件 owner 而让内存长期过期，否则读取寄存器时会把旧值交给
用户空间。M1 选择“put 仍保存 Guest、内存始终最新”，就是为了先避开这类复杂同步。

## 6. kernel-mode Vector

### 6.1 为什么需要单独接口

内核有时也想用 Vector 加速算法，但物理寄存器可能正装着用户任务或 Guest 的数据。内核
不能直接覆盖，否则返回后数据就被污染。因此调用者需要成对使用：

```text
kernel_vector_begin()
    ...内核使用 Vector...
kernel_vector_end()
```

### 6.2 非抢占保护与当前上下文 flush

`get_cpu_vector_context()` 通过禁用 bottom half 或禁抢占，保证当前 CPU 上不会嵌套抢占
Vector owner 元数据；`__riscv_flush_vector_context()` 再保存当前 owner：

- 当前是普通 task：保存到 `current->thread.vstate`，设置延迟恢复；
- 当前是 KVM vCPU：经 RCU callback 调到 `kvm_riscv_vcpu_flush_vector()` 保存 Guest。

随后 kernel 才能安全使用寄存器。`kernel_vector_end()` 关闭 Vector 并释放这段所有权。

### 6.3 可抢占 kernel Vector

开启 `CONFIG_RISCV_ISA_V_PREEMPTIVE` 后，Linux 还维护
`current->thread.kernel_vstate` 和一组 `RISCV_PREEMPT_V_*` 标志，用 nesting depth、Dirty、
NEED_RESTORE 表示可抢占的内核 Vector 上下文。调度器需要保存这份 kernel vstate，切回时
再恢复。

这说明“kernel Vector”不是一个瞬时小例外，而是 owner 设计必须覆盖的第三类正式状态。

## 7. KVM 中 Host 与 Guest 的 FP/Vector 管理

### 7.1 两份上下文

每个 `struct kvm_vcpu` 中至少有：

- `vcpu->arch.host_context`：运行 KVM 前 Host 侧需要保留的状态；
- `vcpu->arch.guest_context`：该 Guest vCPU 的状态。

Vector 的 `datap` 在 vCPU 创建时分配，在 destroy 时释放；reset 会清 Guest Vector 数据并
重新设置初始 VS 状态。

### 7.2 vcpu_load：准备进入 Guest

`kvm_arch_vcpu_load()` 做 FP 和 Vector 交接。Vector 路径先保存 Host，然后
`kvm_riscv_vcpu_guest_vector_restore()` 不立即搬 v0～v31，只设置
`RISCV_V_VCPU_NEED_RESTORE`。真正 restore 放在 `kvm_riscv_vcpu_enter_exit()` 最终进入
Guest 前执行。

这已经是一种 delayed restore。它能避免 load 后、真正进入 Guest 前如果出现 work/request
而白做一次大 restore。

### 7.3 Guest 内部 VM-exit/re-entry

完成一次 restore 后，代码设置 `RISCV_V_VCPU_CTX` 并清 NEED_RESTORE。普通 VM-exit 回到
Host KVM 循环时不会立刻保存/恢复 Vector；若没有 kernel Vector 干扰，下一次进入同一
Guest 时 NEED_RESTORE 仍未设置，因此可直接重入。

所以“每个 VM-exit 都重复 restore”不是当前源码事实。真正观测到的大量 restore 主要发生
在 arch `vcpu_load` 之后，也就是 KVM_RUN 外层或 Host 调度切换边界。

### 7.4 kernel Vector 打断 Guest

若 `RISCV_V_VCPU_CTX` 表示硬件里是 Guest，Host 内核调用 `kernel_vector_begin()` 时，
flush callback 会：

1. 找到当前 CPU 的 `kvm_running_vcpu`；
2. 若 Guest VS=Dirty，保存 Guest；
3. 设置 `RISCV_V_VCPU_NEED_RESTORE`；
4. 让下一次 Guest entry 重新加载。

这条路径正确表达了“另一个使用者覆盖后，原 owner 必须失效”。未来 per-hart 缓存要跨
put 存活时，问题在于 `kvm_running_vcpu` 已经会被清空，现有 callback 不能原样复用。

### 7.5 vcpu_put：归还给 Host

`kvm_arch_vcpu_put()` 当前会：

1. 保存 Guest FP/Vector；
2. 恢复 Host FP/Vector；
3. 清 KVM Vector 的 CTX/NEED_RESTORE 标志。

因此当前 put 后 Guest owner 必须清除。下一次 load 再请求完整 Guest restore。这是 P1
trace 观测到 restore 100% 来源于 load 的源码原因。

### 7.6 FP 与 Vector 的差别

FP 的状态更小，RISC-V KVM 当前 FP 路径基本在 load/put 直接交接。Vector 路径因为状态
更大，引入 NEED_RESTORE，把数据加载推迟到 entry；还需要和 kernel-mode Vector callback
协作。不能因为接口名字相似，就假定 FP 与 Vector 可以共用完全相同的 owner 策略。

## 8. get/set-reg、reset、迁移为何重要

### 8.1 GET/SET_ONE_REG

`KVM_GET_ONE_REG` 从 `guest_context.vector` 内存读，`KVM_SET_ONE_REG` 往这块内存写。
如果未来允许硬件比内存更新：

- GET 前必须先把硬件同步回内存；
- SET 后必须使硬件旧副本失效。

M1 保持 put 时完整保存，避免第一版就引入“双向谁更新”的复杂性。

### 8.2 reset 与 destroy

reset 会直接重建/清零 Guest 内存状态；destroy 会释放 Vector buffer。如果 per-hart owner
还指向旧 vCPU，仅比较裸指针可能出现悬空或地址复用后的 ABA 误命中。因此 owner 需要
generation/cookie，并有明确的清理顺序。

### 8.3 迁移

硬件 Vector 是 per-hart 的。vCPU 从 hart 0 迁到 hart 1 后，hart 0 的寄存器即使还保留
数据，也不能帮助 hart 1。迁移必须使“当前 hart 可命中”的条件失败，并从内存恢复。

## 9. 当前优化窗口与限制

P1 受控采样得到：

- idle 窗口：153 次 restore request 与 153 次实际 restore；
- 固定 100 次 RVV 窗口：1,826 次 request 与 1,826 次实际 restore；
- 来源全部为 `vcpu_load`，kernel Vector 来源为 0；
- 采样点 Host VS 全部为 Off。

这证明 load 路径确实高频，也说明 Host 很可能没有活跃用户 Vector 状态。但 Host VS=Off
是否足以跳过 host save/restore，仍需结合抢占、用户返回、kernel Vector 和源码中“Host
sstatus 可能在别处修改”的注释证明，不能仅由计数直接下结论。

另外，嵌套 QEMU 环境的墙钟耗时受模拟、Host 调度和两层虚拟化影响，只能用于功能和事件
计数，不能代替真实 RISC-V Vector 硬件性能数据。

## 10. 对本项目设计的直接结论

1. VS Dirty 解决“要不要 save”，不解决“硬件现在属于谁”；
2. 主线已有 entry 前延迟 restore，本项目应聚焦“安全跳过完整 restore”；
3. 同一次 load/put 区间内的普通 VM-exit 已经能跳过，主要窗口在跨 Host 调度的重入；
4. 当前 put 恢复 Host，故 put 后 Guest owner 必须清；
5. 若要让 Guest 数据跨 put 驻留，必须让通用 task/kernel Vector 路径参与失效；
6. save 会破坏控制 CSR，因此命中时至少要做 control CSR restore；
7. 第一版应维持 Guest 内存最新，暂不做“硬件比内存新”的更激进策略；
8. 在改变行为前先做 shadow-owner 统计，验证候选命中率和所有失效原因。

## 11. 源码索引

| 主题 | 源码位置 |
|---|---|
| Vector 状态结构和底层 save/restore | `arch/riscv/include/asm/vector.h` |
| 用户首次使用与控制策略 | `arch/riscv/kernel/vector.c` |
| task switch | `arch/riscv/include/asm/vector.h::__switch_to_vector()` |
| 返回用户态延迟恢复 | `arch/riscv/include/asm/entry-common.h` |
| kernel-mode Vector | `arch/riscv/kernel/kernel_mode_vector.c` |
| KVM vCPU FP | `arch/riscv/kvm/vcpu_fp.c`、`arch/riscv/include/asm/kvm_vcpu_fp.h` |
| KVM vCPU Vector | `arch/riscv/kvm/vcpu_vector.c`、`arch/riscv/include/asm/kvm_vcpu_vector.h` |
| KVM load/put/entry | `arch/riscv/kvm/vcpu.c` |
| KVM Vector one-reg ABI | `arch/riscv/kvm/vcpu_onereg.c`、`arch/riscv/kvm/vcpu_vector.c` |
| 通用 vcpu_load/put 与抢占 notifier | `virt/kvm/kvm_main.c` |

## 12. 与其他产出的关系

- 本文满足产出要求 1；
- `docs/04-*` 给出本文机制的调用链与时序图，对应产出 2；
- `docs/05-*` 对比 ARM64 FPSIMD/SVE，对应产出 3；
- `docs/06-*`、`docs/07-*`、`docs/09-*` 把这些事实转化为失效规则和 M1 方案，对应产出 4；
- 后续 shadow-owner、M1 行为补丁和边界测试对应产出 5～7。

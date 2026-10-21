# M1C 默认关闭快路径原型、A/B 与关键负向结果

日期：2026-10-20  
源码基线：Linux `24a19b953e2a3d0ea5a8c4951a0ab8f32720c907`  
前置工作：C1 + P1 + M1A + M1B + G1  
独立补丁：`m1c-riscv-vector-owner-fastpath-prototype.patch`

## 1. 本阶段回答的问题

M1B 已经证明，稳定负载下绝大多数 vCPU put/load 之间，Guest 的 Vector 数据仍留在同一
hart。M1C 第一次改变行为，用默认关闭的开关验证两件事：

1. 开关关闭时是否完整保留 M1B 的 save/restore 行为；
2. 开关打开时，精确 owner 命中能否只恢复 Vector 控制 CSR，而不重新搬运 `v0..v31`。

这是 R2 初始行为交付版，不是可直接上游提交的最终版本，也不代表真机性能结论。

## 2. 原型行为

- 新增只读模块参数 `vector_owner_fastpath`，默认值为 `N`；
- put 仍然完整保存 dirty Guest，因此 `guest_context.vector` 始终是最新副本；
- 只有 Guest 确实驻留、Host VS 为 Off 时，put 才允许保留物理数据寄存器；
- per-hart owner 只保存不可解引用的数值 identity，不跨 destroy 保存裸 vCPU 指针；cookie
  进一步阻止内核地址复用后的 ABA 误命中；
- load 仅在 hart、vCPU identity、cookie、generation 和失效状态全部匹配时命中；
- 命中后跳过 Host Vector save 和 Guest 数据寄存器 restore，只安排
  `vstart/vl/vtype/vcsr` 的 CSR-only restore；
- load 到 Guest entry 之间若发生普通 task restore、kernel Vector 等通用失效，
  `riscv_v_owner_invalidate()` 会把 CSR-only 请求升级为 full restore；
- 任一条件不满足时沿用完整恢复；关闭参数即可回退。

实际恢复 trace 增加 `mode: full|csr`，使“请求过恢复”与“真正恢复了多少寄存器”可区分。

## 3. 构建与静态检查

- `CONFIG_RISCV_ISA_V=y` KVM 模块：通过；
- `CONFIG_RISCV_ISA_V=n` KVM 模块：通过；
- 完整 `Image modules`：通过；
- `git diff --check`：通过；
- 独立 M1C 补丁严格 checkpatch：`0 errors, 0 warnings, 0 checks`；
- 部署模块 SHA-256：
  `7bce11ac0a977fb989091898123250af7ea9ac8fe065c143d78310f52078ff0c`；
- 独立补丁 SHA-256：
  `cffb49f8fdd4aef55f23eb65490028073637aa167076a88875705570e4fa4730`。

## 4. 运行时 A/B

两组都在同一 L1/L2 环境运行 100 次 `/opt/ospp/rvv-smoke`，每次都逐项校验 257 个元素，
结果均为 `RVV_PASS elements=257 vlenb=32 VLEN=256`。

| 指标 | 开关关闭 `N` | 开关打开 `Y` |
|---|---:|---:|
| RVV 正确性 | 100/100 PASS | 100/100 PASS |
| restore request | 2937 | 2978 |
| 实际 restore | 2937 | 2977 |
| full restore | 2937 | 12 |
| CSR-only restore | 0 | 2965 |
| shadow load hit | 2926 | 2965 |
| put candidate | 2937 | 2977 |
| migration miss | 4 | 5 |
| other-vCPU miss | 1 | 0 |
| empty miss | 6 | 8 |
| kernel-vector invalidate | 10 | 11 |

打开组的 CSR-only 数与 shadow hit 数精确相同，说明每个命中都进入了预期的窄恢复路径。
相对关闭组，full restore 从 2937 降到 12，事件次数减少约 **99.59%**；打开组中
CSR-only 占 2977 次实际恢复的约 **99.60%**。

打开组的 request 比实际 restore 多 1，是停止 tracing 时截在一次 request 和随后 restore
之间造成的采样边界；最后保存的 trace 已显示后续完整事件，不把这一条计作功能异常。

## 5. 证据

- 关闭：`evidence/p1/m1c-off-rvv-100.trace`  
  SHA-256：`bb6daf1247dfa12166db8daedca0b51713828a8e4b365b13a7a6b18c31ddcba8`
- 打开：`evidence/p1/m1c-on-rvv-100.trace`  
  SHA-256：`1283621636b43c84ccfe8b619b72dad608145b2218fa4d7a39bfb80541d859b8`

这些结果证明“默认关闭可回退”和“命中时确实避免数据寄存器 restore”。嵌套 QEMU 的耗时
不能代表真实硬件性能，因此这里只报告事件数量与正确性，不报告加速百分比。

## 6. 同 hart Host RVV 干扰

证据：`evidence/p1/m1c-on-host-rvv-pinned.trace`  
SHA-256：`c752bf79d21a8db664a666a903a8fc11efa721448a607bad10bfd1068c74084b`

两个 QEMU vCPU 线程和 Host RVV 均固定到 CPU6，Host 连续运行 500 次、L2 连续运行 100 次
RVV 校验。Host 500/500、L2 100/100 全部通过，结束后 QEMU 亲和性恢复为 `0-7`。

| 事件 | 次数 |
|---|---:|
| `task_restore` invalidate | 323 |
| `other_vcpu` miss | 6224 |
| `empty` miss | 392 |
| full restore | 6553 |
| CSR-only restore | 470 |

trace 中可见 `rvv-smoke` 在 CPU6 触发 `task_restore`，下一次 load 报 `empty` 并执行 full
restore。它证明 Host 真正恢复 Vector 前会撤销 Guest owner；压力下命中率降低是预期回退，
不是静默复用已被 Host 覆盖的数据。

## 7. 开启快路径的 CPU6 → CPU7 → CPU6

证据：`evidence/p1/m1c-on-migration-generation.trace`  
SHA-256：`f299aa9cfab7bdd20c19e3f7d972973671ac377fffd6de0346523600b757609b`

单个固定在 CPU0–5 的控制进程依次把 vCPU0 线程放到 CPU6、CPU7、CPU6；L2 任务固定到
Guest CPU0，三段共 30 次 RVV 均通过。另一个 vCPU 固定在 CPU0，避免覆盖目标 hart owner。

最终 trace 精确出现：

```text
CPU7 put generation=660
CPU6 load reason=generation
CPU6 restore mode=full
CPU6 后续同 hart load reason=hit，restore mode=csr
```

全窗口记录 1 次 generation miss、1 次 migration miss、4 次 full 和 2959 次 CSR-only。
这证明快路径打开时，旧 hart 也不会把同一 vCPU 的旧版本误认成有效数据。

第一次迁移尝试被每阶段新建的 L1 SSH 控制进程干扰：`sshd/uname` 在 CPU6 触发
`kernel_vector`，合法清除了旧 owner，只能得到 `empty`。最终脚本
`lab/m1c-migration-generation.sh` 把控制面固定到 CPU0–5，消除了测试自身的污染。

## 8. load 到 Guest entry 之间的强制覆盖

证据：`evidence/p1/m1c-load-entry-clobber.trace`  
SHA-256：`433e512ca18260bd3266ec24fe93113f6dd788d9b22a88e6249b7ce628cafb71`

为验证最窄、最难自然命中的竞态，临时测试模块加入默认关闭的
`vector_owner_test_clobber` 参数。在 `vcpu_load()` 后调用 `kernel_vector_begin()`，执行 Vector
指令把物理 `v0` 写为全 1，再调用 `kernel_vector_end()`。这是真实覆盖数据寄存器，不只是
手工发送失效通知。

开启正式快路径和测试注入后，L2 20/20 次 RVV 全部通过。trace 中有 242 组严格连续事件：

```text
shadow load hit
restore_request
同一 QEMU 线程 kernel_vector invalidate
actual restore mode=full
```

全窗口共有 254 次由 QEMU 注入触发的 `kernel_vector`、260 次 full、891 次不在注入点发生的
CSR-only。这证明 pending CSR-only 在真正 entry 前遇到通用 Vector 覆盖时会升级为 full，
被写坏的 `v0` 不会泄漏给 Guest。

测试模块 SHA-256 为
`6404e5d644c4e36778eb3b789a6852579e99fbc292ce3c22edd4b9df84515c94`。验证后测试钩子已从
源码删除，远端工作树恢复为正式 M1C；L1 也重新加载正式模块
（当前含 destroy identity 修正的模块 SHA 见第 3 节），不存在测试参数。

## 9. 开启快路径的 CPU hotplug

证据：`evidence/p1/m1c-on-cpu-hotplug.trace`  
SHA-256：`ce32fa5c17843c635d4a19566898895c496afbf33ec6cd857f93413640a0dac9`

vCPU0 固定到 CPU7，vCPU1 固定到 CPU0，测试控制进程限制在 CPU0–5。CPU7 下线前后，
L2 各运行 5 次 RVV 校验，合计 10/10 通过。脚本等待 vCPU0 自然阻塞并留下有效
`put_candidate`，再执行 CPU7 offline/online。关键顺序是：

```text
CPU7 put_candidate generation=335
M1C_HOTPLUG_BEFORE wchan=kvm_vcpu_block
cpuhp/7 invalidate reason=cpu_state generation=335
M1C_HOTPLUG_OFFLINE
CPU7 load reason=empty
CPU7 restore mode=full
```

全窗口记录 1 次 `cpu_state`、5 次 full 和 1710 次 CSR-only。CPU7 最终在线，两个 vCPU
亲和性恢复为 `0-7`。这证明 hotplug 回调会在 hart 状态丢失前撤销 owner，下一次 load
不会复用下线前的数据。

第一次尝试使用 `SIGSTOP` 暂停整个 QEMU，但信号恰好落在 “CSR-only request 已发出、Guest
尚未 entry” 的窗口；随后的 put 正确报告 `not_resident` 并提前清空 owner，因此没有
`cpu_state` 可记录。最终脚本 `lab/m1c-cpu-hotplug.sh` 改为等待 `kvm_vcpu_block`，避免测试
工具自身改变被测状态。这个失败窗口不是实现错误，也没有作为正式证据保留。

## 10. system reset 与 vCPU reset

### 10.1 QMP 整机 reset

证据：`evidence/p1/m1c-on-reset.trace`  
SHA-256：`5514e0ec7b688e97ea57b3f9e410326abda5f06a8133c4e138058e284ef73910`

QMP 返回的事件原因为 `host-qmp-system-reset`。reset 前后 L2 各运行 5 次 RVV，合计 10/10
通过；扩容后的 trace 无覆盖，保留 `121170/121170` 条。vCPU0 的关键顺序是：

```text
load hit generation=678
restore_request
put not_resident generation=678
load empty generation=678
restore full
```

QMP 整机 reset 会先打断 pending entry，所以 owner 在 userspace 重启机器前已经由
`not_resident` 清除；恢复时不能沿用旧 hart 数据。这个路径验证的是 QEMU/KVM 整机 reset，
并不直接调用 RISC-V 的 `kvm_riscv_vcpu_vector_reset()`。

### 10.2 SBI HSM vCPU reset

证据：`evidence/p1/m1c-on-vcpu-reset.trace`  
SHA-256：`93a16e02492818dcebeb99d7fca8d9898a1edb63d17011ca649dfc2f550f7eeb`

vCPU1 固定在 CPU7，L2 的 CPU1 先运行 5 次 RVV，再 offline/online，随后再运行 5 次，合计
10/10 通过；trace 无覆盖，保留 `11477/11477` 条。Guest CPU1 重新上线会经 SBI HSM
`hart_start` 发送 `KVM_REQ_VCPU_RESET`，关键顺序为：

```text
load hit, generation=890
put not_resident, generation=890
reset 后 load migration, guest VS=Initial(0x200), generation=891
restore full
后续 put/load generation=891, restore csr
```

这里没有出现 `reason=generation` 并非漏测：reset 先清掉尚未 entry 的 owner，同时把
`last_exit_cpu` 设为 -1，因此匹配器按优先级报告 `migration`。但 trace 直接证明
`vector_reset()` 将 generation 从 890 推进到 891、将 VS 设回 Initial，并在第一次 entry 前
执行 full restore。脚本为 `lab/m1c-reset.sh` 与 `lab/m1c-vcpu-reset.sh`。

## 11. KVM_GET/SET_ONE_REG 生命周期边界

证据：`evidence/p1/m1c-on-one-reg.trace`  
SHA-256：`88cf6525026e9b4ebdd5a1d98c598d0893e47f333f9ad477a804ebd8b4b5882d`

新增最小 RISC-V KVM selftest `lab/kvm-selftests/vector-one-reg-owner.c`，并由
`lab/m1c-one-reg.sh` 固定到 CPU7 运行。用例让 Guest 把 `0x31` 装入整个 `v0`，退出后由
userspace 执行 `KVM_GET_ONE_REG(v0)`；再次进入后 Guest 将 `v0` 写回内存并逐字节验证。
随后 userspace 用 `KVM_SET_ONE_REG(v0)` 写入 `0xa7`，Guest 再次进入并逐字节验证新值。

结果为 `M1C_ONE_REG_PASS vlenb=32 GET=preserved SET=restored`。换用最终 identity 模块后复测，
trace 共 16/16 条、无覆盖。
关键顺序是：

```text
GET 前 Guest put 保持内存为最新
KVM_GET_ONE_REG(v0) 读到 0x31
下一次 load reason=hit, generation=2
restore mode=csr
KVM_SET_ONE_REG(v0) 写入 0xa7 并推进 generation
下一次 load reason=generation, generation=4
restore mode=full
Guest 从 v0 读回 0xa7
```

generation 从 2 到 4 而非只加 1，是因为第二次 Guest Vector save 也推进了一次 generation，
随后 SET 再推进一次。这里证明了 M1 的保守不变量：put 总是完整保存，所以 GET 可以直接读取
最新内存且不必撤销 owner；SET 改写内存后则必须让旧 owner 失配，下一次进入完整恢复。

## 12. destroy / vCPU 对象释放边界

证据：`evidence/p1/m1c-on-destroy.trace`  
SHA-256：`cb3157ba968a113e4b4ee5bf3c860ff4d020cee2317e5c44f58f8b17e58e91a0`

源码审查发现 `kvm_arch_vcpu_destroy()` 会释放 Vector buffer，但原 owner 结构仍保存
`struct kvm_vcpu *`。虽然现有失效路径只比较、不解引用该值，cookie 也能阻止地址复用误命中，
释放后继续保存一个有指针类型的悬空值仍不满足生命周期不变量。直接从 destroy 跨 CPU 清
per-CPU owner 会与各 CPU 本地 put/load 发布产生竞态，因此最终改为：

- per-hart owner 把裸指针改成 `unsigned long identity`；
- identity 只作为 opaque 数值比较，任何路径都不能解引用；
- cookie 在 Vector context 分配时单调分配，地址复用时仍不会相等；
- generation 继续处理同一 vCPU 生命周期内的 reset/SET 等状态变化。

定向 selftest `lab/kvm-selftests/vector-owner-destroy.c` 预先创建两个 VM，避免第二个 VM 的
内存分配自然触发 `kernel_vector` 而提前清 owner。旧 Guest 把 `0x5d` 放入 `v0` 并产生
put candidate，销毁旧 vCPU 后立即在同一 CPU7 运行已创建的新 vCPU。结果：

```text
M1C_DESTROY_OLD_PUBLISHED
M1C_DESTROY_OLD_FREED
new vCPU load reason=other_vcpu
restore mode=full
M1C_DESTROY_NEW_VERIFIED
Guest v0 全零，未看到旧 Guest 的 0x5d
```

输出为 `M1C_DESTROY_PASS old_pattern=0x5d new_v0=zero`，trace 为 33/33 条、无覆盖。
第一次尝试在销毁后才创建第二个 VM；创建过程自身触发 `kernel_vector`，合法清 owner 后得到
`migration → full`。这也是安全路径，但不能单独证明 identity 比较，因此最终改成预创建版本。

## 13. 最终开关回归与初始交付判定

在含 destroy identity 修正的最终模块上，使用 `lab/m1c-final-regression.sh` 重新装载模块，
默认关闭和显式开启各运行 30 次 `/opt/ospp/rvv-smoke`。30 次是本轮收口规模；前面保留的
100 次 A/B 与各类定向压力仍作为更长样本，不再机械重复 100 次。

| 指标 | 最终关闭 `N` | 最终开启 `Y` |
|---|---:|---:|
| RVV 正确性 | 30/30 PASS | 30/30 PASS |
| trace entries | 8780/8780 | 7824/7824 |
| full restore | 2194 | 6 |
| CSR-only restore | 0 | 1948 |
| shadow load hit | 2191 | 1949 |
| put candidate | 2195 | 1954 |

关闭时即使 shadow 观测判定为 hit，行为仍全部走 full，证明参数默认值能完整回退。开启时
1954 次实际恢复中 1948 次为 CSR-only；1949 个 hit 中有 1 个在 entry 前遇到
`kernel_vector` 失效并正确升级为 full。相对关闭组，full restore 从 2194 降到 6，事件数
减少约 **99.73%**。两份 trace 的 entries-written 与 entries-in-buffer 相等，没有环形缓冲覆盖。

证据：

- `evidence/p1/m1c-final-off.trace`，SHA-256
  `51a8c3fca98c165eebacdbe6aca585622a2f99228e44983df94d3d80b1e13bab`；
- `evidence/p1/m1c-final-off-rvv.log`，SHA-256
  `882cd804db814be88910350a4fc6fa349a89dd932b70129a678d8d5cd9d5d558`；
- `evidence/p1/m1c-final-on.trace`，SHA-256
  `4d3b572f6a441a2e2581c8e3101928fbf3f0143d8dd205e4c9e0574f75372a33`；
- `evidence/p1/m1c-final-on-rvv.log`，SHA-256
  `882cd804db814be88910350a4fc6fa349a89dd932b70129a678d8d5cd9d5d558`。

因此 M1C 已满足 R2 初始交付的功能、回退、失效和生命周期判据。后续工作转为 R3 的剩余
扩展边界（例如 signal/ptrace、软中断与 PM）以及 R4 的真机性能量化；这些不再阻塞本次
初始行为版本。嵌套 QEMU 结果只证明事件数量下降，不能换算成真实加速比例。

# M1A Shadow-owner 观测实现与结果

日期：2026-10-18  
源码基线：Linux `24a19b953e2a3d0ea5a8c4951a0ab8f32720c907`  
补丁：`m1a-riscv-kvm-vector-shadow-owner.patch`

## 1. 目的

M1A 不改变任何 Vector save/restore 行为，只回答一个问题：

> 假设 put 后可以保留 Guest 数据，那么下一次 load 是否仍是同 hart、同 vCPU、同一份
> Guest 内存版本，而且 Host VS=Off？

这是未来快路径的“乐观上界”。它还没有接通普通 task/kernel Vector 的通用失效通知，
所以不能当作真实可启用命中率。

## 2. 实现

### 2.1 per-hart shadow owner

每个 hart 只记录观测元数据：

```text
vcpu pointer（只比较，不通过缓存解引用）
owner cookie（区分地址复用）
state generation（区分 reset/set-reg 前后的状态）
```

put 在 Guest 完整保存之后发布候选；load 检查后立即消费候选。实际代码仍继续恢复 Host、
请求 Guest restore，因此运行语义与 P1 相同。

### 2.2 cookie 与 generation

- vCPU 成功分配 Vector context 后取得递增 cookie；
- `kvm_riscv_vcpu_vector_reset()` 递增 generation；
- 成功的 Vector `SET_ONE_REG` 递增 generation；
- 缓存只在 vCPU 指针、cookie、generation 全部匹配时报告 hit。

即使缓存里留下已 destroy 对象的旧地址，load 只拿它与当前有效 vCPU 比较；地址碰巧复用时
cookie 也会阻止误命中。此阶段没有用 shadow 结果改变行为。

### 2.3 trace event

新增 `kvm:kvm_riscv_vector_shadow`，包含：

- `action=put/load`；
- `eligible=0/1`；
- `reason=hit/empty/other_vcpu/cookie/generation/guest_off/host_on/migration/put_candidate`；
- CPU、Guest VS、Host VS 和 generation。

## 3. 构建与静态检查

- `CONFIG_RISCV_ISA_V=y` 的 `kvm.ko`：通过；
- `CONFIG_RISCV_ISA_V=n` 的 `kvm.ko`：通过；
- `git diff --check`：通过；
- M1A 独立补丁 checkpatch strict：0 error、0 warning、3 CHECK；
- 3 个 CHECK 都来自内核标准 `TRACE_EVENT()` 宏布局，并非 C 代码格式错误。

V=y 模块：

```text
SHA256 d1ba9bd8d1cd51de595f48be65e941695c15a4d5d424f60ccfde800f36032e74
```

M1A 独立补丁：

```text
SHA256 ccfa2a53e2d2dc0838bcaca396a331bd3d5bb47f4be6d0ca7dd1a7a46cddb531
```

注意：本树使用 `O=... M=arch/riscv/kvm modules` 时，最新模块实际生成在源码树的
`arch/riscv/kvm/kvm.ko`；旧的 `build-l1/arch/riscv/kvm/kvm.ko` 不会自动更新。本轮已通过
哈希和 available_events 复核，部署的是包含 shadow event 的正确模块。

## 4. 运行结果

### 4.1 启动期 + 100 次 RVV 窗口

证据：`evidence/p1/m1a-shadow-rvv-100.trace`

| action / reason | 次数 |
|---|---:|
| put / put_candidate | 20,575 |
| load / hit | 20,561 |
| load / migration | 7 |
| load / other_vcpu | 6 |
| load / generation | 1 |

乐观上界命中率：`20,561 / 20,575 = 99.932%`。

这里包含 L2 启动，因而能看到迁移、另一个 vCPU 抢占同一 hart，以及启动期寄存器设置导致
的 generation 变化。这些 miss 都符合设计预期。

### 4.2 L2 稳定后的独立 100 次 RVV 窗口

证据：`evidence/p1/m1a-shadow-rvv-100-steady.trace`

| action / reason | 次数 |
|---|---:|
| put / put_candidate | 2,281 |
| load / hit | 2,281 |
| 其他 load miss | 0 |

乐观上界命中率：100%。所有事件的 Host VS 都为 Off，restore request 来源仍全部是 load。
窗口边界处记录到 2,281 次 request 与 2,280 次 actual restore；QEMU 在停止 tracing 时仍
运行，最后一个 request/entry 可能跨越采样边界，因此不把这一个事件差解释为优化效果。

最后一次 RVV 正确性输出：

```text
RVV_PASS elements=257 vlenb=32 VLEN=256
```

## 5. 能说明什么，不能说明什么

可以说明：

1. 跨 put/load 的同 hart、同 vCPU 重入非常常见；
2. reset/set-reg generation 和迁移检测能产生预期 miss；
3. 在当前负载下 Host VS=Off 是常态；
4. 值得继续实现通用失效观测，而不是因为窗口太小提前结束项目。

不能说明：

1. 不能说明 put 时可以安全跳过 Host restore；
2. 不能说明普通 task 或 kernel Vector 没有在 put/load 之间覆盖寄存器；
3. 不能说明 control CSR-only restore 已正确；
4. 不能把 QEMU 事件上界换算成真实硬件性能提升。

## 6. 下一步

M1B 增加行为仍关闭的通用失效通知，使普通 task restore/首次使用、kernel Vector、CPU
hotplug/PM 能把 per-hart shadow 标成失效并记录原因。完成后重新跑同一组负载，得到可用于
G1 决策的“覆盖失效后的候选命中率”。

# Linux 7.3 最终验证状态

日期：2026-10-20  
基线：Linux 7.3 `c03c1a14507dfaf8b856c2608f9ac216021fc222`  
分支：`ospp-26a190041-riscv-vector`

## 1. 已通过的组合状态验证

| 项目 | 结果 |
|---|---|
| V=y、`CONFIG_RISCV_ISA_V_PREEMPTIVE=y`、KVM=m 完整 `Image modules` | 通过 |
| V=n、KVM=m 完整 `Image modules` | 通过 |
| Linux 7.3 L1 启动与新 `kvm.ko` 加载 | 通过 |
| `vector_owner_lifetime_test` | 通过 |
| `vector_owner_onereg_test` | 通过，VLEN=256（vlenb=32） |
| KVM `get-reg-list` | 返回 0，Vector 项 `v: PASS` |
| `v_initval` | 1/1 通过 |
| `vstate_prctl` | 11 通过、2 个能力相关 SKIP、0 失败 |
| `vstate_ptrace` | 2/2 通过 |
| `validate_v_ptrace` | 13 通过、6 个 VLEN/能力相关 SKIP、0 失败 |
| 严重级别 dmesg | 无输出 |

V=y Image SHA-256：
`eadd231417fac28f46678c604cabf2f309b98008d84ce931d9d77caf3424343d`

V=n Image SHA-256：
`187d7995ebbfc9bbe9007069c5ffd2175fe77e9e9e80ebf984464cf8138f1bc8`

统一运行日志：`evidence/final/linux-7.3-final-selftests.log`，SHA-256：
`c711357e4f13be149533ebac5a233a2ce951eebfbad8ec896ca736b277f7249d`

两个项目 KVM selftest 的 trace：`evidence/final/linux-7.3-vector-owner-selftests.trace`，
SHA-256：`7a1f36c80528ea16cb32ecdc4d0d39c2ccb35f34666c98e0881e250fab59ff23`。
trace 中实际出现 `hit → csr`、`generation → full`、`other_vcpu → full` 与
`kernel_vector` 失效，能够对应命中路径和主要回退路径。

## 2. “最终验证”尚不包含什么

以上结果说明 Linux 7.3 **组合工作树的功能、配置兼容性和主要安全回退已经通过**，但还不
等于可直接发送上游的补丁系列已经完成。提交前仍需：

1. 从干净基线建立正式 commit 系列，并保证每个中间提交可构建、可审阅；
2. 对最终每个补丁运行 `git diff --check` 和 strict checkpatch，处理现有 trace 宏格式 CHECK；
3. 对关键中间提交做最小构建，最终提交重跑一次收口测试；
4. 编写 commit message、cover letter、测试矩阵和 Gitee PR 说明；
5. 真实 RISC-V Vector 硬件可用时再补性能数据。当前 QEMU/KVM 结果只能证明事件减少和功能
   正确性，不能声称获得了真实硬件加速。

因此当前准确表述是：**项目初始可交付实现和 Linux 7.3 组合功能验证已完成；正式提交系列
和真实硬件性能验证尚未完成。**

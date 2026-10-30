# Performance proxy evidence

本目录保存性能代理量化使用的精选原始证据。它证明完整 Vector restore 工作量减少以及
fast path 的正确性，不代表真实 RISC-V 硬件的耗时加速比。

## 结果摘要

| 指标 | fastpath=N | fastpath=Y |
|---|---:|---:|
| RVV 正确性 | 30/30 PASS | 30/30 PASS |
| full restore | 2194 | 6 |
| CSR-only restore | 0 | 1948 |
| owner/shadow hit | 2191 | 1949 |
| put candidate | 2195 | 1954 |

完整恢复事件减少 `(2194 - 6) / 2194 = 99.7265%`。VLEN=256 时每次 CSR-only 跳过
`32 * 32 = 1024 bytes` 的 `v0..v31` 架构状态装入，因此开启组直接对应
`1948 * 1024 = 1.90234375 MiB` 无需重新装入的架构状态。

实际投稿的 RFC v0 最新主线候选另有开启态确认性冒烟：full=8、CSR-only=784、owner
hit=785；三个最终 selftest 在 fastpath=N/Y 时均通过。该冒烟不是新的严格 A/B。

## 原始证据包

文件：`performance-proxy-raw-evidence.zip`  
SHA-256：`ffa915330ff2617b1fe522acb9712219be77c419a9e9a29ce0c6c4ef38a2c43e`

归档内文件：

| 文件 | SHA-256 |
|---|---|
| `m1c-final-off.trace` | `51a8c3fca98c165eebacdbe6aca585622a2f99228e44983df94d3d80b1e13bab` |
| `m1c-final-on.trace` | `4d3b572f6a441a2e2581c8e3101928fbf3f0143d8dd205e4c9e0574f75372a33` |
| `m1c-final-off-rvv.log` | `882cd804db814be88910350a4fc6fa349a89dd932b70129a678d8d5cd9d5d558` |
| `m1c-final-on-rvv.log` | `882cd804db814be88910350a4fc6fa349a89dd932b70129a678d8d5cd9d5d558` |
| `rfc-latest-mainline-smoke.trace` | `5cf54a2b4eceef034c579ad2b0aee87b6ab1f0fdbba000ddb958db6aeef763f2` |
| `rfc-final-selftests-fastpath-n-and-restore.log` | `440b69cb67831d412fcaf82a53ffd7a26facdee5edb8e9537336e8826ac7f180` |
| `rfc-final-selftests-fastpath-y.log` | `15cd816c5812fd44f082c52f4ca489bd5b7bfdf3fcfdb899b06ac8e168d21a89` |

## 复核方法

解压后可在 PowerShell 中重新统计：

```powershell
$off = '.\m1c-final-off.trace'
$on = '.\m1c-final-on.trace'

foreach ($trace in @($off, $on)) {
    "file=$trace"
    "full=$((Select-String -LiteralPath $trace -SimpleMatch 'mode: full' | Measure-Object).Count)"
    "csr=$((Select-String -LiteralPath $trace -SimpleMatch 'mode: csr' | Measure-Object).Count)"
    "hit=$((Select-String -LiteralPath $trace -SimpleMatch 'reason: hit' | Measure-Object).Count)"
    "put=$((Select-String -LiteralPath $trace -SimpleMatch 'reason: put_candidate' | Measure-Object).Count)"
}
```

两个 A/B 窗口的调度事件总数不完全相同，因此不能把事件逐个配对；99.7265% 的名称应是
“相同固定 RVV 负载下的完整恢复事件减少比例”，不能写成应用运行时间加速比。

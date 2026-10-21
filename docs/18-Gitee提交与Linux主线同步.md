# Gitee 提交与 Linux 主线同步记录

日期：2026-10-20  
目标仓库：`https://gitee.com/eulixos/linux`

> 状态更新（2026-10-20）：导师已确认现阶段改为向 Linux 内核邮件列表投稿，Gitee 仓库
> 暂不处理，后续如有需要再一次性整理。本文件保留此前的 Gitee 调查记录；当前执行方案见
> `21-Linux邮件列表投稿与GitHub归档计划.md`。

## 1. 目标仓库的实际状态

目标 Gitee 仓库的 `HEAD` 和唯一分支均为 `master`，提交为：

```text
c86c76f0add955caedca6f61b459c8b58f2b83ad  Initial commit
```

该提交只有 Gitee 模板 README、LICENSE、`.gitignore` 和 issue/PR 模板，共 6 个文件；没有
Linux 源码，也与 Torvalds Linux Git 历史没有共同祖先。README 是通用模板，写的是
“Fork → 新建功能分支 → 提交 → Pull Request”，但没有本项目专用的分支命名或内核基线规则。

因此“同步 Gitee master”不能理解为把内核补丁 rebase 到该 master。最终交付结构必须由老师
或仓库权限决定：要么推一个带完整 Linux 历史/快照的独立分支，要么在模板 master 上提交
补丁、测试和文档材料。直接覆盖中央 `master` 不在计划内。

## 2. Linux 上游基线同步

原实验基线：

```text
24a19b953e2a3d0ea5a8c4951a0ab8f32720c907  Linux 7.3-rc7
```

2026-10-20 拉取的 Torvalds `origin/master`：

```text
c03c1a14507dfaf8b856c2608f9ac216021fc222  Linux 7.3
```

新基线比原基线前进 289 个提交；这一区间没有修改项目涉及的 8 个 RISC-V/KVM 文件。

已创建独立工作树和分支：

```text
worktree: /home/riscv/ws/linux-ospp-upstream
branch:   ospp-26a190041-riscv-vector
base:     c03c1a14507dfaf8b856c2608f9ac216021fc222
```

原 `/home/riscv/ws/linux` 已验证工作树保持不动。

## 3. 迁移验证

- 组合差异直接应用到 Linux 7.3：无冲突，`git diff --check` 通过；
- 迁移前后 `arch/riscv` 差异 SHA-256 均为
  `07f1b326683fab68719bdb71bc0d851a4a637b283379dce789bb2e389f1c5f76`；
- 代码统计保持 `8 files changed, 473 insertions, 25 deletions`；
- 使用临时 Git index 按 C1 → P1 → M1A → M1B → M1C → M1D 逐段应用，六段全部通过；
- 临时 index 脚本为 `lab/verify-patch-series.sh`，不会修改工作树或创建提交；
- V=y 的 Linux 7.3 完整 `Image modules` 构建在
  `/home/riscv/ws/build-ospp-upstream` 通过，Image SHA-256 为
  `eadd231417fac28f46678c604cabf2f309b98008d84ce931d9d77caf3424343d`；
- V=n 的完整 `Image modules` 构建在 `/home/riscv/ws/build-ospp-upstream-n` 通过，Image
  SHA-256 为 `187d7995ebbfc9bbe9007069c5ffd2175fe77e9e9e80ebf984464cf8138f1bc8`；
- 两个实验性 KVM selftest 已整理成不依赖 tracefs、会固定单 CPU 的提交候选，并加入
  `tools/testing/selftests/kvm/Makefile.kvm`；两者在 Linux 7.3 L1 中均通过；
- 上游 `get-reg-list` 返回 0 且 Vector 项为 `v: PASS`；`v_initval`、`vstate_prctl`、
  `vstate_ptrace`、`validate_v_ptrace` 四组 Vector kselftest 均通过；统一证据见
  `evidence/final/` 和 `docs/19-Linux7.3最终验证状态.md`。

## 4. 提交身份与远端门禁

已确认正式 Git 作者为：

```text
Xiaochun Yu <yxcnew@outlook.com>
```

该身份只在本项目正式提交时显式指定，不修改全局 Git 配置。

用户已确认的提交策略：

- OSPP 硬目标是成果合入老师指定的 Gitee 仓库；老师的验收口径优先；
- Linux 主线合入是个人进阶目标，不作为 OSPP 结项阻塞项；
- 当前上游基线由项目自行选择，现固定为 Linux 7.3；正式上游投稿前按需再同步；
- 代码、测试和交付材料暂定放在同一个 Gitee PR；
- 申请书中超出老师实际要求的事项不再作为硬门禁。

仍待确认：

1. 老师要求的是完整内核源码分支，还是在目标仓库提交标准补丁、测试和验证文档；
2. Gitee fork URL，以及是否具有 `eulixos/linux` 的直接分支写权限；
3. 补丁材料在目标仓库中的目录结构和 Pull Request 验收方式；
4. 负责审核与合并的维护者。

Gitee 个人资料和公开邮箱已经由用户配置。本机已生成专用 Ed25519 密钥
`C:/Users/yxcne/.ssh/gitee_ospp_ed25519`，写入 `Host gitee.com` 的 SSH 配置，并已由用户在
Gitee 网页确认添加。

2026-10-20 后续验证：公钥已由用户添加，`ssh -T git@gitee.com` 成功认证为
`slack_up (@slack-up)`，目标 `eulixos/linux` 可经 SSH 读取。个人仓库
`slack-up/linux` 当前不存在，因此尚未具备标准“fork → push → PR”路径；也未用试探性 push
判断中央仓库写权限，以免意外创建远端分支。

随后按用户要求使用目标仓库已有初始提交执行 `git push --dry-run` 权限探测。Gitee 返回
`Access denied`，探测前后远端引用完全一致，仍只有 `master`，未创建任何分支。因此当前
账号没有中央仓库写权限，正式流程应为 `slack-up/linux` 个人 fork → 项目分支 → 向
`eulixos/linux:master` 发 PR，除非老师之后授予仓库成员权限。

当前只准备本地可审阅提交序列和 `git format-patch` 交付包。未经用户在老师确认后再次明确
授权，不向 Gitee 推送、不创建 Pull Request。访问凭据不写入源码、文档、remote URL、脚本
或 Git 配置；最终发布优先使用 SSH key 或系统凭据管理器。

## 5. 推荐的提交分支与系列

建议分支名：`ospp-26a190041-riscv-vector`。

建议提交顺序：

1. `riscv: kvm: make vector helpers build without CONFIG_RISCV_ISA_V`
2. `riscv: kvm: trace vector restore requests and actual restores`
3. `riscv: kvm: track per-hart vector owner candidates`
4. `riscv: vector: invalidate KVM vector owners before register use`
5. `riscv: kvm: preserve matched guest vector data across put/load`
6. `riscv: vector: invalidate guest owner on preemptible vector resume`
7. `KVM: riscv: add vector owner ONE_REG and lifetime selftests`

每个提交都需要独立 apply/checkpatch；关键中间状态至少构建 KVM 模块，最终状态完成 V=y/V=n
完整构建和定向运行测试。

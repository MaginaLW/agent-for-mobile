# T-L1 C1b 42-input real isolated host build smoke 失败冻结

- 日期：2026-08-29
- 分支：`codex/security-hardening`
- 目标 clean SHA：`77473af5223d76b00bf4dbbf33cf44090fde635c`
- 授权范围：只执行一次当前 42-input 的 real isolated host **build-only** smoke
- 明确禁止：真实 ADB、设备发现、`install -r -t`、T0、`c1`、`c2`、result 与 pure-a11y 采集
- 自动重试：`0`
- 终态：**失败并冻结；不得把本轮生成过的临时 APK/proof 解释为 smoke 通过，也不得继续进入设备授权**

## 执行结果

提权 launcher 只启动 helper 一次，helper exit `1`，launcher 没有自动重试。受控 Java 的
GradleMain 调用恰好一次并返回到 artifact guard/proof 校验阶段；Debug/Release APK 与 artifact proof
在该临时 build tree 中已经出现。宿主第一次读取 artifact proof 时以
`C1b closed JSON strict parse 失败。` fail-closed，后续阶段没有执行。

| 边界 | 观察值 |
|---|---:|
| helper start / automatic retry | `1 / 0` |
| real JDK/GradleMain | `1` |
| held-Java ApkSignerTool | `0` |
| held AAPT2 verification | `0` |
| real ADB call / observed ADB process start | `0 / 0` |
| device enumeration / install / T0 / capture | `0 / 0 / 0 / 0` |
| direct child Java / other Java process start | `1 / 1` |
| pre/post default `5037` listener | `0 / 0` |

所以本次只证明 GradleMain 被受控调用一次并到达 proof reader；它**没有**证明 artifact proof 已被宿主接受，
也没有证明 packaged AXML、APK signer、完整 post-Gradle seal 或 post-build Git provenance。清理后 APK/proof
没有保留，不能拿它们跳过失败阶段继续安装。

## 离线根因

运行结束后另行做了纯 PowerShell、无 JDK/Gradle/ADB/设备的离线复现；这些复现不属于下节三份 frozen
运行证据。根因闭合到一次性 helper 的加载集合遗漏 observation validator：

- [`tablet-layout-c1b.ps1`](../../scripts/lib/tablet-layout-c1b.ps1) 的
  `ConvertFrom-TL1C1bClosedJson` 会调用 `Find-TL1C1BV1DuplicateJsonProperty` 与
  `Find-TL1C1BV1InvalidNumber`；
- 两个 walker 定义在
  [`tablet-layout-observation-c1b-v1-validator.ps1`](../../scripts/lib/tablet-layout-observation-c1b-v1-validator.ps1)；
- 正式 [`run-tablet-layout-c1b.ps1`](../../scripts/run-tablet-layout-c1b.ps1) 按
  `C1a -> validator -> C1b` 加载；本轮 exact helper `f6e79d4586ed3ef7801a19a428e3fe843db44e116b5920d05583b4174632baba`
  held/pinned 了 C1a、C1b、artifact、AAPT2、build 与 runner，但只 dot-source C1a、C1b、artifact、AAPT2 与
  build，没有 held/pinned 或 dot-source validator；runner 没有被加载或执行；
- 相同加载集合下，纯内存合法 JSON `{"a":1}` 稳定复现同一 generic strict-parse 错误；先加载 validator 后，
  同一输入以及带尾随换行的 proof-shaped JSON 均通过。duplicate key、非整数与 Int64 越界仍按预期拒绝。

这说明失败不是一次新的 Gradle 执行结果，也不授权重跑。由于 cleanup 已删除本轮实际 proof bytes，记录不把
离线复现升级成“该临时 proof 已通过内容审计”；能够成立的结论是：exact helper 存在一个足以让任意正常 proof
在 reader 阶段失败的确定性加载缺陷，且证据阶段与该缺陷一致。

未来若另获一次新 smoke 授权，helper 至少必须把 validator 作为第七个 held/pinned 文件固定，按
`C1a -> validator -> C1b` 加载，并在启动 Gradle 前机械断言两个 walker 都是 Function。该未来修复不能复用
本轮 one-shot，也不能沿用本轮 helper hash。

## 证据与清理

本地 `.checks/` 证据按项目策略被忽略，不进入 Git；以下长度与 SHA-256 在失败后重新只读核验：

| 本地证据 | bytes | SHA-256 |
|---|---:|---|
| `tablet-c1b-real-build-smoke-77473af.summary.json` | 2479 | `7b65780915cc9a71b0883b1cc84316bf073b89119127da0a90cac93c134f08aa` |
| `tablet-c1b-real-build-smoke-77473af.log` | 4747 | `0cb765d22a0a98d5a227db68dc2a4b31041b60d3ea8cef12416c76a96cad630a` |
| `tablet-c1b-real-build-smoke-77473af.launcher.json` | 1139 | `2435bdbea50d5a9888a5dfc96d300fd9034f88aa9d07e14a35c391084055f805` |

launcher source SHA-256 为
`850685413ada580583b235c707eed6de18beb45dc30b9b5f9fda371f7a668f8c`；launcher 记录
`helper_start_count=1`、`helper_exit_code=1`、`automatic_retry_count=0`。helper summary 记录
`real_jdk_gradlemain_execution_count=1`、ApkSigner/AAPT2/ADB/设备侧计数全为 0，并保留两个终态 reason：
primary strict-parse 失败，以及派生的 core result 未形成。由于 helper 非零退出，launcher 的
`helper_summary_verified=false`，没有把 failed summary 当作 passed summary 做语义验收；只读核验通过 log 中的
stdout length/SHA 及 `summary + CRLF` 字节关系建立二者相关性。

失败清理后再次只读核验：

- repository library guards、artifact guards 与 build-environment cleanup 均为 `completed`；
- Java/Gradle/ApkSigner/ADB 进程 0，default `5037` listener 0；
- module build、module Gradle state、`local.properties`、isolated Gradle home、受控 build workspace 与 recovery
  journal 残留 0；
- 运行后、开始本记录的文档修改前，独立只读 `git status --porcelain=v1 --untracked-files=all` 快照为空，HEAD 为
  `77473af5223d76b00bf4dbbf33cf44090fde635c`；helper 自身没有到达 post-build Git provenance；
- 临时目录中刻意保留了 exact one-shot helper/launcher staging scripts 供审计；它们不是 summary 声明的 build
  residue，因此本记录只主张契约内 build/observer/summary-temp 残留为 0，不主张宿主完全没有文件残留。

## 冻结与下一步

本轮唯一 real build smoke 已消费且失败，不自动重试。`77473af5223d76b00bf4dbbf33cf44090fde635c`
不能进入设备 build/install/两帧授权；旧 C1a 与 2026-08-28 已消费的 C1b 授权也都不可复用。

下一候选回到 A 道：修正并独立审查 helper 的 exact load set，完成所需离线回归与全门，固定另一个 clean SHA，
再由用户单独授权一次新的 real isolated host build smoke。只有新的 smoke 完整通过 artifact proof、AAPT2、
ApkSigner、post-seal 与 Git provenance 后，才能另行申请设备 build/install/pure-a11y 两帧授权。

## 独立复审

- 运行证据复审：P0=0；P1=1（helper 漏载 validator 的确定性 functional blocker）。一次启动、非零退出、
  零重试、阶段计数、stdout/summary 字节关系与契约内 residue 均闭合；实际 proof bytes 未保留，未作内容通过主张。
- 文档与边界终审：P0=0、P1=0、P2=0。runner/validator load-set、离线复现来源、post-Git 未到达、
  clean-worktree 快照时序、staging scripts 与 build residue 的区别均已独立核对。

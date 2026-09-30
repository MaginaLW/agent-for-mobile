# C1b 候选维护源

这里的四份 PowerShell 文件是可编辑的源码模板，不是可执行的冻结候选。它们的候选绑定均由
`prepare-tablet-layout-c1b-candidate-source.ps1` 在内存中填入；输出只写入忽略的 review
目录。冻结发布、preflight、build 和设备验收仍是独立步骤。

| 当前维护源 | 一次性迁移对照 | 迁移时的实质改写 |
|---|---|---|
| `renderer-template.ps1` | r12 renderer，SHA-256 `3086b43031b4e7fa6dc50c5227da44729d9675bf1757bf896fa25ece8203958a` | 删除 r10 pair、template 与 failure sidecar 的输入读取和哈希门；改为从本目录读取 helper/launcher 维护模板；去掉历史候选、机器路径、旧哈希和版本绑定。 |
| `helper-template.ps1` | helper template，SHA-256 `7d75fceb91b4431474ae25e85987cee89111813d37f8e11efe3db03ab715e1e0` | 保留候选占位符与七份仓库库文件的默认 hash 字面量；每轮派生必须按最终 `RepoRoot` 的原始字节重新绑定这七份输入。Git 可执行文件由 Program Files 路径派生并校验固定 hash，去掉原有机器绝对路径。 |
| `launcher-template.ps1` | r11 launcher template，SHA-256 `f31b944fd6ebf8da20ac919f25562a22998d2d3a24f263ad1c7a893c6b31e817` | 将固定运行时更新到 7.6.5，提前抑制 progress，保留有界 stderr 原始前缀，并修正两处清零时的 byte[] 引用；模板仍保留候选占位符。 |
| `preflight-template.ps1` | r13 preflight，SHA-256 `bf15d0097fa02c9c99f69f8b08b5415390728bfb3d054b84bbd7895abafcd57c` | 移除历史候选和机器路径/分支/哈希绑定；Git ref 与相关卷从本轮输入派生；后续 r14 检查仍由受版本控制的注入源确定性合成。 |

这些旧文件仅供只读回归对照，不再参与新候选生成或发布。当前源码和依赖的哈希在每次准备时
写入 review 记录；同一固定输入必须逐字节生成相同候选。源码改动需要重新固定 clean SHA、
重新准备与审查，不能沿用旧冻结输出或旧批准。

七份 helper 输入的键、顺序和数量固定为 `c1a`、`validator`、`c1b`、`artifact`、`aapt2`、
`build`、`runner`，值必须是小写 `sha256:` 字面量。prepare 从本轮最终仓库读取原始字节，
将其写入 review 的 `repository_library_hashes` 与 `source_inputs`，并在输出前再次核验；
换行变化也是输入变化。转换只定位 helper 的唯一顶层 ordered 字面量映射，拒绝重复、动态、
嵌套或作用域别名映射，不改写碰巧相同的历史 hash。

helper 的 process wrapper 同时增加 `FailureDiagnostics` 参数，唯一 Gradle 调用显式启用
该参数并原样转发给底层进程。内存候选与 held renderer 使用同一组有基数门的 helper 转换，
最终 helper 的原始 hash、长度及 Parser 门仍在发布前核验。launcher 维护源已完成运行时、
progress 和原始 stderr 前缀迁移，生成时直接填入其候选槽位，不重复旧 launcher 转换。

r14 renderer 的 preflight 基准输入固定为本轮仓库中的
`scripts/lib/c1b-candidate-source/preflight-template.ps1`；其父目录纳入 no-follow held chain，
原始 hash、长度与 PowerShell Parser 门保持有效。生成的 preflight、临时文件、回执以及已冻结的
helper/launcher 则必须是 staging 目录的直接子项，不能将维护源误套入输出路径约束。

preflight 回执的 `verifier_static_evidence.maximum_observer_tail_seconds` 是固定五秒上限的
静态证据，序列化为明确的整数 `5`，供现行 HA 严格 JSON 消费者读取；这不转换运行时浮点
输入。summary verifier 的 double 参数、零至五秒校验与实际观察预算保持原值。源码离线回归
执行生成 preflight 的真实静态审查片段并消费其序列化字节，同时保留 `5.0` 与小数反例的拒绝。

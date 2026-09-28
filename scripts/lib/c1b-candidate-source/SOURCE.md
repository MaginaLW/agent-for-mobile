# C1b 候选维护源

这里的四份 PowerShell 文件是可编辑的源码模板，不是可执行的冻结候选。它们的候选绑定均由
`prepare-tablet-layout-c1b-candidate-source.ps1` 在内存中填入；输出只写入忽略的 review
目录。冻结发布、preflight、build 和设备验收仍是独立步骤。

| 当前维护源 | 一次性迁移对照 | 迁移时的实质改写 |
|---|---|---|
| `renderer-template.ps1` | r12 renderer，SHA-256 `3086b43031b4e7fa6dc50c5227da44729d9675bf1757bf896fa25ece8203958a` | 删除 r10 pair、template 与 failure sidecar 的输入读取和哈希门；改为从本目录读取 helper/launcher 维护模板；去掉历史候选、机器路径、旧哈希和版本绑定。 |
| `helper-template.ps1` | helper template，SHA-256 `7d75fceb91b4431474ae25e85987cee89111813d37f8e11efe3db03ab715e1e0` | 保留候选占位符与七份仓库库文件的固定 hash；Git 可执行文件由 Program Files 路径派生并校验固定 hash，去掉原有机器绝对路径。 |
| `launcher-template.ps1` | r11 launcher template，SHA-256 `f31b944fd6ebf8da20ac919f25562a22998d2d3a24f263ad1c7a893c6b31e817` | 将固定运行时更新到 7.6.5，提前抑制 progress，保留有界 stderr 原始前缀，并修正两处清零时的 byte[] 引用；模板仍保留候选占位符。 |
| `preflight-template.ps1` | r13 preflight，SHA-256 `bf15d0097fa02c9c99f69f8b08b5415390728bfb3d054b84bbd7895abafcd57c` | 移除历史候选和机器路径/分支/哈希绑定；Git ref 与相关卷从本轮输入派生；后续 r14 检查仍由受版本控制的注入源确定性合成。 |

这些旧文件仅供只读回归对照，不再参与新候选生成或发布。当前源码和依赖的哈希在每次准备时
写入 review 记录；同一固定输入必须逐字节生成相同候选。源码改动需要重新固定 clean SHA、
重新准备与审查，不能沿用旧冻结输出或旧批准。

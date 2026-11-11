# C1b 真实派生回放语料 v1

两份 JSON 分别派生自 597ca8b 与 abb7b0d 的既有真实 observation，保留窗口、退化树、类型、IME、计数关联及原有阻塞判据。它们不是原始字节，也不是新的运行证据。原文件与封套只留本地忽略的 evidence 目录；源路径、源 SHA-256、派生字节 SHA-256 和预期分类见 `manifest.json`。

脱敏转换的完整实现是 `scripts/tests/c1b-corpus-replay-offline.ps1` 的 `ConvertTo-CorpusFixture`：替换 run/capture 标识、标题/构建/设备哈希及 provenance，时间锚移到固定日期但保持相对间隔。它不把 original provenance 改写回旧记录。现行严格 schema 与 privacy 校验继续拒绝额外字段、原始身份和聊天内容；入库前已核对派生字段只含合同结构、包名、局部标签、数值、枚举与固定占位值。目录 JSON 以 `.gitattributes -text` 固定字节，修改须同步审查 manifest 哈希与来源关系，不能自动更新 golden 令失败消失。

在项目钉定的 PowerShell 中运行：

```powershell
& '<project-root>/toolchain/powershell-7.6.5/pwsh.exe' -NoProfile -File scripts/tests/c1b-corpus-replay-offline.ps1
& '<project-root>/toolchain/powershell-7.6.5/pwsh.exe' -NoProfile -File scripts/tests/c1b-corpus-replay-offline.ps1 -RequireOriginals
```

默认门在干净 clone 上回放入库的派生语料并执行有界变异，不声称重放了缺失的原件。`-RequireOriginals` 不允许缺件跳过：核原件哈希、封套内 observation 原文逐字节相同、现行 reader/计数器与各版本真实 validator、确定性脱敏派生逐字节相同。原件 validator 使用原采集时刻后一秒作为历史判读时钟，不把旧材料称为当前新鲜证据。旧 v1 封套由当前 v3 reader 拒绝为 `version_mismatch`，其 observation 仍走现行 v1 validator；不为回放放宽当前版本门。

摘要落到 `.checks/reduce-manual-20261111/corpus/`，明确原件回放数量与零设备调用。unknown、opaque、IME false、截断、越界矩形等保持 fail-closed；所有模式都不授予 T-L1/P0/执行能力。

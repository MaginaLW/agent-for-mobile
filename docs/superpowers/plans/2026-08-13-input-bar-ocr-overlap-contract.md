# 输入栏 OCR 重叠行去重执行计划

> **For agentic workers:** REQUIRED EXECUTION FLOW: Use `subagent-driven-development` to execute this plan task-by-task when subagents are available. If no subagent capability is available, execute inline with the same task checklist and review checkpoints.

**Goal:** 消除输入栏同一物理文字被 OCR 多次识别后直接拼接造成的假增量，使合法单份内容不再被最终长度硬门误判，同时继续拦截真实的重复输入和任何无法证明为同一物理行的内容。

**Approach:** 保留 `EvidenceRebuildPolicy` 的非空、包含与长度守卫，不在 consumer 侧按已批准 marker 猜内容；新增一个纯 JVM 的输入栏 OCR 聚合策略，只对“几何高重叠 + 归一后文本互相包含”的候选判为同一物理行。折叠必须信息单调：保留归一后最长者，只有归一结果等长时才按置信度选择；非传递的重叠关系整组保留。非重叠的相同文本、重叠但语义无关的文本、全局 OCR 结果、标题/确认/发送后验协议均不放宽。

**Materials:** 固定 C task `019ff195-0fde-7eb2-ac1a-88ee11cc1a2d`；run `20260813T201212-3e9ae5507700`；持久证据 `D:\repos\agent-for-mobile\docs\runs\evidence\20260813T201212-3e9ae5507700\`；`app/gateway/src/main/java/dev/magina/gateway/a11y/GatewayA11yService.kt`；`app/gateway/src/main/java/dev/magina/gateway/ocr/OcrEngine.kt`；`app/gateway/src/main/java/dev/magina/gateway/core/ApprovalIntent.kt`；`app/gateway/src/main/java/dev/magina/gateway/a11y/FreshEvidenceRebuild.kt`

**Validation:** 现场同形 fixture 在旧聚合逻辑上 RED；最小实现后聚焦 Debug/Release JVM 用例全绿；现有内容长度负例仍绿；`pwsh -NoProfile -File scripts/check.ps1 -Shards 3` exit 0；两路独立复审无 Critical/Important；全程不调用 adb、不安装 APK、不启动真机 runner。

---

### Task 1: 固定现场证据与根因边界

**Artifacts / Locations:**
- Review: `docs/runs/evidence/20260813T201212-3e9ae5507700/`
- Review: `app/gateway/src/main/java/dev/magina/gateway/a11y/GatewayA11yService.kt`
- Review: `app/gateway/src/main/java/dev/magina/gateway/ocr/OcrEngine.kt`
- Review: `app/gateway/src/main/java/dev/magina/gateway/core/ApprovalIntent.kt`

- [x] **Step 1: 核对不可变现场**

确认持久目录含 13 个普通文件；`SHA256SUMS.txt` 自身 SHA-256 为
`B630BD0F6DA57BDE68C25F5230134A002B4BF3F580240304FD068D938D0F8BAA`，其余 12 文件逐项复算通过。
metadata 必须固定 1 次 build、1 次 install、1 次 runner、只执行 Allow、task frozen；ledger 原始行由 main 按 run ID 恰好落一行。

- [x] **Step 2: 追踪错误值来源**

固定以下连接事实：
- `type_text` 的 `readback` 是同一 20 字 marker 的两份 OCR 结果拼接，且两份只在前导标点上有差异；
- confirmation 截图中的真实输入框只有一份 marker，最终 Enter 前已 fail-closed，未发送；
- `ocrReadRegionOf` / `ocrReadRegion` 对 `OcrEngine.recognize` 的全部行直接按位置空格拼接；
- `OcrEngine` 对同一位图做原图与增强图双识别，而现有合并只去掉“原文逐字相同 + IoU≥0.5”的候选，因此轻微标点差异可留下两行；证据没有保存逐行来源与 bounds，故“双跑正是本次两行的唯一来源”只可列为最强解释，不能冒充已直接观测的事实；
- `EvidenceRebuildPolicy` 的长度守卫正确识别“聚合串比批准内容多 23 字”，不得改弱。

- [x] **Step 3: 写现场同形 RED**

Create: `app/gateway/src/test/java/dev/magina/gateway/a11y/InputBarOcrReadbackPolicyTest.kt`

用纯数值 `OcrBox` 构造并机械断言：
- 两个 IoU≥0.5、分别为 `) P0ALLOW-…` 与 `)) P0ALLOW-…` 的候选，归一后互相包含，只能产出一行；旧代码因没有该聚合策略而 RED；
- 同样文本但几何不重叠必须保留两行，证明真实重复输入不会被吞掉；
- 几何重叠但归一后无关必须保留两行，证明位置重叠不能单独成为去重依据；
- 同一物理行先保留归一后信息更完整者，等长等价时才按置信度选择；输出顺序仍按 top/left；空输入返回 null。

运行：
`app\gradlew.bat -p app :gateway:testDebugUnitTest --tests dev.magina.gateway.a11y.InputBarOcrReadbackPolicyTest --console=plain`

结果：2026-08-13 初始裸拼接 stub 上 exit 1，5 tests completed / 1 failed；唯一失败为
`现场同一 marker 的重叠替代识别只保留高置信度一行`，其余四个边界通过。日志：
`C:\Users\Magina\AppData\Local\Temp\p0-input-bar-ocr-overlap-red-20260813.log`。

### Task 2: 在输入栏 producer 层做最小去重

**Artifacts / Locations:**
- Create: `app/gateway/src/main/java/dev/magina/gateway/a11y/InputBarOcrReadbackPolicy.kt`
- Modify: `app/gateway/src/main/java/dev/magina/gateway/a11y/GatewayA11yService.kt`
- Review: `app/gateway/src/main/java/dev/magina/gateway/core/ApprovalIntent.kt`

- [x] **Step 1: 实现纯聚合策略**

输入候选仅含原文、置信度与 `OcrBox`。按 top/left 排序后，只在以下条件同时成立时合并：
- 两个框 IoU ≥ 现有 OCR 同区域阈值 0.5；
- 两侧归一结果非空，较短一侧至少 2 字，且归一结果互相包含。

候选关系先按原始全图分连通分量；只有分量内每一对都满足上述条件时才允许折叠，避免非传递的
`A↔桥↔C` 吞掉两端真实重复。折叠时保留归一后最长者；只有归一结果等长（也就相同）时才按置信度
选择，避免高置信 marker 子串覆盖低置信但包含真实额外内容的完整候选。条件不充分就整组保留，让
下游继续 fail-closed。策略不得接收已批准 marker、SHA 或长度，避免 producer 借 consumer 期望“挑答案”。

- [x] **Step 2: 接到两条输入 OCR 入口**

把 `GatewayA11yService.ocrReadRegionOf` 与 `ocrReadRegion` 的裸 `joinToString` 改为调用同一个聚合策略。两处都是输入落框/输入栏读回入口；`OcrEngine.recognize`、整屏 snapshot/fusion、fresh title 读取不改。

- [x] **Step 3: 钉住长度门没有被绕过**

在聚焦用例中把聚合结果接入 `EvidenceRebuildPolicy.judge`：
- 现场重叠同形聚合后得到 `Rebuilt`；
- 非重叠的两份相同 marker 仍得到 `Mismatch`；
- 空、漏识、超容差额外内容继续保持现有 `Unverified` / `Mismatch` 语义。

- [x] **Step 4: 运行聚焦 GREEN**

运行：
- `app\gradlew.bat -p app :gateway:testDebugUnitTest --tests dev.magina.gateway.a11y.InputBarOcrReadbackPolicyTest --console=plain`
- `app\gradlew.bat -p app :gateway:testReleaseUnitTest --tests dev.magina.gateway.a11y.InputBarOcrReadbackPolicyTest --console=plain`
- `app\gradlew.bat -p app :gateway:testDebugUnitTest --tests dev.magina.gateway.core.EvidenceRebuildPolicyTest --console=plain`

预期：全部 exit 0；现场正例通过，三类反例仍按 fail-closed 语义通过。

初版结果：2026-08-13 全部 exit 0。输入栏策略 Debug 7/7、Release 7/7；既有
`EvidenceRebuildPolicyTest` Debug 25/25。独立复审随后发现“高置信短串覆盖较长真实增量”与
“非传递重叠链吞两端”两类安全反例；补成用例后旧实现精确 RED：9 tests / 2 failed，日志
`C:\Users\Magina\AppData\Local\Temp\p0-input-bar-ocr-overlap-review-red-20260813.log`。改为 clique +
最长 normalized 后 Debug 10/10、Release 10/10，`EvidenceRebuildPolicyTest` Debug 25/25，日志：
- `C:\Users\Magina\AppData\Local\Temp\p0-input-bar-ocr-overlap-review-green-debug-20260813.log`
- `C:\Users\Magina\AppData\Local\Temp\p0-input-bar-ocr-overlap-review-green-release-20260813.log`
- `C:\Users\Magina\AppData\Local\Temp\p0-evidence-rebuild-policy-review-regression-20260813.log`

初版三份 GREEN 日志分别为：
- `C:\Users\Magina\AppData\Local\Temp\p0-input-bar-ocr-overlap-green-debug-20260813.log`
- `C:\Users\Magina\AppData\Local\Temp\p0-input-bar-ocr-overlap-green-release-20260813.log`
- `C:\Users\Magina\AppData\Local\Temp\p0-evidence-rebuild-policy-regression-20260813.log`

### Task 3: 独立复审与完整 A 道总门

**Artifacts / Locations:**
- Review: current diff
- Review: `app/gateway/src/main/java/dev/magina/gateway/a11y/InputBarOcrReadbackPolicy.kt`
- Review: `app/gateway/src/main/java/dev/magina/gateway/a11y/GatewayA11yService.kt`
- Review: `app/gateway/src/test/java/dev/magina/gateway/a11y/InputBarOcrReadbackPolicyTest.kt`

- [x] **Step 1: 需求复审**

由未实现补丁的 reviewer 核对：只折叠同一物理行的替代识别；不按 expected marker 挑答案；不重叠重复与重叠无关文本仍保留；最终长度守卫、标题、确认、raw query、发送后验均未放宽。

结果：独立 reviewer 最终结论 Critical 0 / Important 0；确认非 clique 整组保留、clique 选最长
normalized 保持信息单调，服务接线只限两条输入区域 OCR，标题/确认/发送协议未改。

- [x] **Step 2: 质量复审**

检查 IoU/包含关系的边界、排序稳定性、信息单调选择、等长置信度选择、非传递多候选链、空值与短文本；确认没有把敏感 readback、marker 或截图内容写进持久日志/测试输出。

结果：独立 reviewer 最终结论 Critical 0 / Important 0；唯一 Minor 是补“三成员 clique 在输入排列变化时
仍选全局最长”的覆盖，已纳入聚焦用例后再进入最终 gate。

- [x] **Step 3: 完整离线 gate**

运行：`pwsh -NoProfile -File scripts/check.ps1 -Shards 3`

记录 dispatch、Gateway Debug/Release/assembleDebug、runner 三分片、凭据扫描、`git diff --check` 的准确计数和主日志 SHA-256；核对前后 HEAD/diff 指纹不变、相关进程和锁清理干净。

最终安全复审收敛后，2026-08-13 精确命令 exit 0：diff-check clean；dispatch 71/71；Gateway
`testDebugUnitTest` + `testReleaseUnitTest` + `assembleDebug` PASS；runner 3 片分别 50/50、49/49、
49/49，合计 148/148；凭据扫描 PASS。主日志
`.checks/input-ocr-and-partial-trace-final-full-gate-20260813.log`，SHA-256
`B7577776B9768548F3318978A7BE0B8E1C663C066CCE6F870C37408A8E319ED3`，stderr 0 字节。
门前门后 HEAD 均为 `f0a767335e70aa99ed0fc242a1217978600435af`，含 untracked 计划的组合 diff
SHA-256 均为 `379F6E6787C25C1B3219D4753B20423D1CEB6C79415386CDD013EFD4FFDB5B96`；结束时
runner/dispatch/check 相关进程 0、fixture 目录 0、index.lock 不存在。随后只回填本段机械证据，未再改
生产代码或测试。

- [x] **Step 4: 记录与提交**

更新本计划复选框与准确 RED/GREEN/gate 数据；同步 `docs/knowledge/brain/harness.md` 的“同一图多候选不能裸 join”教训；按一次逻辑变更形成新的完整 SHA。不得合入 main，等待全新 clean C。

结果：输入 OCR producer 与 JVM 回归按独立逻辑提交为
`bbed9abbd604dbd697aa46ed0773c221f81c7d17`；本计划与 harness 知识册在随后文档收尾提交中固化。A 分支不合 main，
最终固定 C 必须钉文档收尾后的分支完整 tip，不能只按分支名或复用任何旧 task/run。

### Task 4: main 队列交接与全新 C

**Artifacts / Locations:**
- Modify (main single writer): `STATUS.md`
- Modify (main single writer): `docs/backlog.md` §5
- Review: `docs/runs/ledger.csv`

- [x] **Step 1: 登记本次冻结 C**

main 保留 task/run、Allow `E_STALE_REF`、真人 `allowed`/overlay、未发送、后三腿未跑、teardown clean、cleanup true，以及持久证据路径与 ledger 恰好一行；批次仍为 0/4、未判定。

结果：main 已按 run ID 去重保留 ledger 恰好一行；持久证据目录递归 13 文件，`SHA256SUMS.txt`
列出的其余 12 文件逐项复算 0 mismatch，自身 SHA-256 为
`B630BD0F6DA57BDE68C25F5230134A002B4BF3F580240304FD068D938D0F8BAA`。旧 task/run 永久冻结。

- [ ] **Step 2: 钉新 SHA 并另建 clean C**

只有 Task 3 完整闭环后才创建新 C；固定新完整 SHA，从头 Allow → Stale → Deny → Reentry（75s）。旧 task `019ff195-0fde-7eb2-ac1a-88ee11cc1a2d` 与 run `20260813T201212-3e9ae5507700` 永久冻结，绝不复用。

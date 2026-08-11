# Fresh Title Evidence Execution Plan

> **For agentic workers:** REQUIRED EXECUTION FLOW: Use `subagent-driven-development` to execute this plan task-by-task when subagents are available. If no subagent capability is available, execute inline with the same task checklist and review checkpoints.

**Goal:** 将最终 `press_key(enter)` 投递前 fresh title 读取的脱敏摘要持久化到 trace、audit 与 manifest，并消除投递前失败对 `enter_diagnostics` 的误导。

**Approach:** 先用纯 JVM 测试钉住候选摘要的脱敏、稳定性和错误信封附加行为，再接入最终 fresh title 读取与工具审计。runner 从错误信封和 audit note 读取同一摘要，离线用例验证 manifest 与失败归因，不改变标题选择策略。

**Materials:** `SurfaceTitleRead.kt`、`GatewayA11yService.kt`、`Envelope.kt`、`ToolRegistry.kt`、`scripts/run-p0-safety-smoke.ps1`、`scripts/tests/p0-supervised-runner-offline.ps1`

**Validation:** RED 用例先失败；实现后 Debug/Release JVM focused tests、runner offline focused/full test、`git diff --check` 全部通过，且证据不含候选原文、截图或输入内容。

---

### Task 1: 钉住脱敏 fresh title 摘要契约

**Artifacts / Locations:**
- Create: `app/gateway/src/test/java/dev/magina/gateway/a11y/SurfaceTitleEvidenceTest.kt`
- Create: `app/gateway/src/main/java/dev/magina/gateway/a11y/SurfaceTitleEvidence.kt`
- Review: `app/gateway/src/main/java/dev/magina/gateway/a11y/SurfaceTitleRead.kt`

- [x] **Step 1: 增加 RED**

构造包含目标标题、日期文本、拒绝候选和长 OCR 文本的 `SurfaceTitleRead`，断言摘要只包含长度、SHA-256 指纹、来源、框、候选序号和选择理由，不包含任何原文。

- [x] **Step 2: 实现纯数据转换**

新增版本化 JSON 与紧凑 audit token；候选设置固定上限并记录截断；selected 超出上限时仍保留其原 ordinal，不改 `ConversationSurfacePolicy`。

- [x] **Step 3: 验证 Debug/Release JVM 用例**

运行 `app/gradlew.bat :gateway:testDebugUnitTest --tests '*SurfaceTitleEvidenceTest'` 与 Release 对应用例；预期全部通过。

### Task 2: 接入最终投递前错误信封与 audit

**Artifacts / Locations:**
- Modify: `app/gateway/src/main/java/dev/magina/gateway/a11y/GatewayA11yService.kt`
- Modify: `app/gateway/src/main/java/dev/magina/gateway/mcp/ToolRegistry.kt`
- Test: `app/gateway/src/test/java/dev/magina/gateway/a11y/SurfaceTitleEvidenceTest.kt`

- [x] **Step 1: 增加错误附加 RED**

断言 `E_VERIFY_FAIL` 保留原错误码、通道、fallback，同时在 `extra.title_read` 附加脱敏摘要；携带标题原文的 message 改为固定诊断并仅留 hash/length，安全的下游诊断不改写，已有 extra 必须合并而非覆盖。

- [x] **Step 2: 记录最终读取**

在 `performFreshEvidenceEnter` 内捕获本次 `readSurfaceTitle`，失败时给 `GatewayError` 附加摘要；ToolRegistry 从该结构生成 `title_read` 与 `title_evidence` audit note。

- [x] **Step 3: 验证无原文泄漏**

测试错误 envelope、audit token 和对象 `toString` 均不出现候选原文、输入内容或截图数据。

### Task 3: runner 持久化与正确归因

**Artifacts / Locations:**
- Modify: `scripts/run-p0-safety-smoke.ps1`
- Modify: `scripts/tests/p0-supervised-runner-offline.ps1`

- [x] **Step 1: 增加 RED fixture**

构造 Allow 投递前 `E_VERIFY_FAIL`：trace error 带 `extra.title_read`，audit note 带相同摘要，调用序列止于 `press_key`。

- [x] **Step 2: 验证 manifest**

断言 rebuild `title_read` 与 `final_title_read` 分栏，脱敏候选摘要进入后者，且 failure 文案指向 `fresh title evidence`，不声称存在 `enter_diagnostics`。

- [x] **Step 3: 保持旧路径兼容**

后验发送失败仍可指向 `enter_diagnostics`；Allow/Reentry 成功必须有 resolved + selected 的 final_enter 证据，且 audit summary、token、trace 白名单逐字段同源；旧 APK、phase/字段错配均 fail-closed。

### Task 4: 完整验证与自审

**Artifacts / Locations:**
- Review: 当前工作树 diff

- [x] **Step 1: 运行 focused Debug/Release JVM tests**

预期新增及相关 `SurfaceTitleReadPolicyTest`、`FreshEvidenceRebuildExecutorTest` 全绿。

- [x] **Step 2: 运行 runner offline tests**

预期全部离线场景通过，无需设备、adb、构建 APK 或 runner 真机流程。

- [x] **Step 3: 运行静态检查**

执行 `git diff --check`，检查没有候选原文、secret、截图或大段 OCR 内容进入持久证据。

- [x] **Step 4: 回传结果**

记录未提交 diff 的文件列表、hash、测试命令与日志路径；不提交。

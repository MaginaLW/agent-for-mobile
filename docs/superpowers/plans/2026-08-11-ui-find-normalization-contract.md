# UI Find 归一化契约修复执行计划

> **For agentic workers:** REQUIRED EXECUTION FLOW: Use `subagent-driven-development` to execute this plan task-by-task when subagents are available. If no subagent capability is available, execute inline with the same task checklist and review checkpoints.

**Goal:** 消除 runner 对 `ui_find` 查询串的第三份归一化，使已发送消息不再因连字符契约漂移被假阴性拦截，同时保留原始查询、全部命中和消息区几何三道严格判据。

**Approach:** 先让离线 fixture 如实复刻 gateway 的 `TextNorm.ocr` 输出（保留连字符），证明 `d36e3d2` 会稳定失败。随后只修改 runner 的证据装配：原始 `ui_find.text` 继续逐字等于本腿 marker，归一后的查询与命中只在 gateway 同源字段之间做字面比较；独立 Windows OCR、teardown 和 gateway 生产归一均不改。

**Materials:** 固定 C task `019ff10f-a650-7e70-a7f0-df3bc8730581` 的 archived session；run `20260811T215340-d3eb4c2bdeaf`；`scripts/run-p0-safety-smoke.ps1`；`scripts/tests/p0-supervised-runner-offline.ps1`；`scripts/lib/p0-marker.ps1`；`app/gateway/src/main/java/dev/magina/gateway/tools/UiTools.kt`

**Validation:** 新增/修正 fixture 在旧实现上 RED；最小修复后 runner 聚焦用例与完整离线套件全绿；`scripts/check.ps1 -Shards 3` exit 0；独立复审无 Critical/Important；不调用 adb、不构建或安装真机 APK、不启动真机 runner。

---

### Task 1: 用真实 gateway 契约制造 RED

**Artifacts / Locations:**
- Modify: `scripts/tests/p0-supervised-runner-offline.ps1`
- Review: `app/gateway/src/main/java/dev/magina/gateway/tools/UiTools.kt`
- Review: `app/gateway/src/main/java/dev/magina/gateway/core/TextNorm.kt`

- [x] **Step 1: 修正 fixture 的默认归一输出**

让默认 `query_normalized` 与 match `normalized` 复刻 `TextNorm.ocr` 对 ASCII marker 的结果：小写、`o→0`、保留连字符。不得再调用或照抄 `Normalize-P0MarkerText` 的“去全部非字母数字”规则。

- [x] **Step 2: 钉住三条边界**

新增或调整用例，机械断言：
- gateway 同源字段均为 `p0all0w-<suffix>` 时，旧 runner 会假阴性；
- 上述真实 producer 形态同时覆盖微信无焦点身份与稳定焦点/边界两条消息区路径，并至少各跑一条 Allow/Reentry；
- 原始 `ui_find.text` 不是本腿 marker 时，即使归一字段相等也必须失败；
- 任一 match 的 `normalized` 不等于 `query_normalized` 时仍必须失败。
- `query_normalized` 与 match `normalized` 同为空串时必须 fail-closed，不能让“空等于空”冒充证据。

- [x] **Step 3: 运行 RED**

运行：`pwsh -NoProfile -File scripts/tests/p0-supervised-runner-offline.ps1`

预期：至少真实 gateway 连字符场景失败，错误落在 Allow 的 `FindEvidenceMatched`，而不是 fixture/setup 错误。

### Task 2: 移除 runner 在 gateway 边界的重复归一

**Artifacts / Locations:**
- Modify: `scripts/run-p0-safety-smoke.ps1`
- Review: `scripts/lib/p0-marker.ps1`

- [x] **Step 1: 修改 `Read-P0TraceEvidence`**

在 `ui_find` 证据判定中：
- 保留现有 `FindQueryMatched = ($findQuery -ceq $ExpectedText)`，继续逐字核对执行器查询的是本腿 marker；
- 要求 `query_normalized` 是非空字符串；
- 要求至少一个 match，且每个 match 的 `normalized` 与 `query_normalized` 逐字相等；
- `Test-P0MessageRegionMatch` 同样接收 `query_normalized`，不再接收 runner 本地重算值；
- 删除该边界上的 `$expectedNormalized = Normalize-P0MarkerText $ExpectedText`。

同步更正 `scripts/lib/p0-marker.ps1` 的误导注释：`Normalize-P0MarkerText` 只服务 runner 自己的 Windows OCR、带外验证与 teardown，不是 `ui_find` 的 canonical；函数实现保持不变。

- [x] **Step 2: 明确不改的表面**

不得修改 `TextNorm.ocr`、`UiFindJsonContract`、`Normalize-P0MarkerText`、marker 字符集、确认/标题安全门、Deny 带外 Windows OCR 或 teardown。它们属于不同证据通道，不能为修一个边界顺手统一。

- [x] **Step 3: 运行 GREEN**

运行：`pwsh -NoProfile -File scripts/tests/p0-supervised-runner-offline.ps1`

预期：完整 runner 离线套件全绿；真实 gateway 连字符场景通过；wrong raw query、wrong normalized、wrong query_normalized 和混入额外文本仍失败。

### Task 3: 独立复审与完整离线闸门

**Artifacts / Locations:**
- Review: `scripts/run-p0-safety-smoke.ps1`
- Review: `scripts/tests/p0-supervised-runner-offline.ps1`
- Review: current diff

- [x] **Step 1: 需求复审**

由未实现该补丁的 sub-agent 核对：真实 run 的 `p0all0w-…` 形态已覆盖；runner 没有退回 OCR 原文猜测；原始 query、全部 normalized 命中和消息区几何仍各自为硬门。

- [x] **Step 2: 质量与安全复审**

检查没有放宽 gateway/标题/确认判据，没有把一个组件自报当成独立带外证据，没有把 archived session 的敏感输出复制进仓库。

- [x] **Step 3: 运行完整 gate**

运行：`pwsh -NoProfile -File scripts/check.ps1 -Shards 3`

预期：dispatch、Gateway Debug/Release/assembleDebug、runner 三分片、凭据扫描全部通过，进程与锁清理干净，exit 0。

- [x] **Step 4: 记录与提交**

更新本计划复选框；记录准确用例计数和日志路径；审查 `git diff --check`；按“一次逻辑变更一次提交”形成新的完整 SHA。不得合入 main，等待全新 C 四腿验收。

**执行记录（2026-08-11 至 2026-08-12）：**

- RED：runner 完整套件 `101 passed / 45 failed`，真实 gateway 连字符形态按预期在 Allow/Reentry 的 `FindEvidenceMatched` 变红；本机临时日志 `$env:TEMP\p0-ui-find-normalization-red-complete-20260811.log`。
- 首次完整 GREEN：runner 完整套件 `146 passed / 0 failed`；本机临时日志 `$env:TEMP\p0-ui-find-normalization-green-complete-20260811.log`。
- 独立复审：需求复审 Approved；质量复审提出的 Minor 已修正，增量复审无 Critical/Important/Minor；最终聚焦回归 `4 passed / 0 failed`；本机临时日志 `$env:TEMP\p0-ui-find-normalization-quality-minors-green-final-20260811.log`。
- 完整 gate：exit `0`；dispatch `58 passed / 0 failed`；Gateway Debug `510 passed / 0 failed`、Release `407 passed / 0 failed`、`assembleDebug` 通过；runner 三分片 `49 + 49 + 48 = 146 passed / 0 failed`；凭据扫描 PASS。
- 完整 gate 主日志：`.checks/fresh-title-final-full.log`，SHA-256 `17F496AC3CE93B6FD1762054D091CBCE86F2FA1F759686248CD3AA129B6890A4`。
- 提交前执行 `git diff --check`；最终提交 SHA 只能在提交完成后由 main 单写者落入 `STATUS.md` 与 backlog §5，本计划不写自引用 SHA。

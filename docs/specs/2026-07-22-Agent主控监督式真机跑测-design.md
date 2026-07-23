# 设计说明：Agent 主控、用户仅监督的 P0 真机跑测

- 日期：2026-07-22
- 状态：已离线实现，待独立真机验收
- 首个范围：P0 安全硬门允许腿与上下文失效腿
- 依赖：D1 已离线修复；D2 确认卡改进纳入本设计；D3 OCR 读回不阻塞首版

## 1. 问题与目标

现有 `P0-safety-hard-gate-smoke.md` 把安装、权限、IME、微信导航与聚焦、逐腿派单、确认卡截图、stale 腿按 Home、证据归档和清理都交给现场人。这样能验安全，但测试者实际上成了执行器，操作繁琐且难复现。

本设计把职责改为：

- **Agent 主控 runner**：完成测试机预检/准备、顺序派单、确认卡自动取证、结果判定、证据归档和环境恢复。
- **gateway/执行器**：完成微信导航与输入框聚焦、文本准备、危险动作请求及确认后执行/复核。
- **用户**：只在手机确认卡上核对“目标会话：文件传输助手”、明文输入预览和 12 位确认编号，然后点击“拒绝”或“允许本次”。长度/哈希、focused-input ID/bounds 和 confirm ID 绑定由 runner 机械验证。用户不运行命令、不安装 APK、不切 IME、不导航微信、不按 Home、不截图、不写跑测记录。

首版只收口当前被 D1 阻塞的允许腿与 stale 腿；拒绝腿沿用 2026-07-22 已有通过结论，不由当前 runner 自动重跑。

## 2. 安全不变量

1. **确认选择永远由人完成**。runner、LLM、ADB、gateway 宏和 debug hook 都没有点击“拒绝/允许”的能力。
2. **实际动作仍走生产路径**：`dispatch.ps1 → gateway MCP → ToolRegistry → SafetyGate → executor`。runner 不用 `adb input`、私有 Intent 或坐标替代输入/发送。
3. **无自动重试**。任何腿一旦超时、拒绝、stale、blocked、权限/通道失败或证据不完整，整组立即停止；同一危险动作不重派、不换路、不走 `-Confirm`。
4. **debug stale hook 只能制造失效**：它只在用户已经点击允许之后、SafetyGate 最终复核之前切到 Home；不能批准、跳过或修改确认结果，也不能关闭上下文校验。
5. **确认等待期间冻结自动化**：runner 不发 UI 输入；gateway 不暴露确认卡按钮为可操作 ref，并拒绝对自身确认 overlay 做 `ui_action`。
6. **敏感数据不落证据**：token、Authorization 和私密配置不进入终端、trace、ledger、截图清单或 Markdown。确认截图可能含测试消息，只保存在 gitignored 本地证据目录。
7. **准备失败不转嫁用户**：runner 能自动修复的前置条件自动修复；无法自动建立的 vivo 厂商权限或设备状态记为 `setup-fail` 并停止，不能让用户接手点击设置后继续同一腿。

## 3. 已选方案与取舍

### 方案 A：PC 侧主控 runner + 小型 gateway 能力补齐（采用）

一次命令管理整组测试，仍调用现有 `dispatch.ps1`，只补确定性准备、确认取证和 stale 故障注入。优点是最接近真实 Agent 路径，trace/ledger 契约不变；缺点是需要同时修改 PowerShell、gateway debug 能力和 runbook。

### 方案 B：设备端 scenario runner（不采用）

把三腿全部写进 debug APK。自动化更彻底，但容易验证测试脚手架而非 `dispatch + LLM + MCP` 生产链，且设备端要复制台账和判定逻辑。

### 方案 C：Agent 代跑现有 dispatch（仅过渡，不作为完成）

Agent 可替用户运行命令，但用户仍要预聚焦、截图和在 stale 腿按 Home，不能满足“只监督”。

## 4. 总体架构

```mermaid
flowchart LR
  R["P0 supervised runner"] --> P["自动预检与 provision"]
  P --> D["现有 dispatch.ps1"]
  D --> B["订阅大脑执行腿"]
  B --> G["gateway ToolRegistry / SafetyGate"]
  G --> C["手机确认卡"]
  U["用户只核对并选择"] --> C
  C --> G
  G --> E["执行或安全拒绝"]
  D --> T["trace + ledger"]
  R --> A["自动截图 / manifest / 清理"]
  T --> R
  E --> R
```

新增入口：

```powershell
& .\scripts\run-p0-safety-smoke.ps1 `
  -Legs Allow,Stale `
  -Executor gateway `
  -Provision
```

该命令由 Agent 调用。`-Legs` 必须显式给出，避免无意扩大真机范围；当前实现只接受 `Allow|Stale`，按 Allow→Stale 固定安全顺序执行且不并行。

## 5. 组件设计

### 5.1 `run-p0-safety-smoke.ps1`：主控与判定

runner 只编排，不重新实现 MCP 或手机业务动作：

1. 获取整组独占锁 `scripts/.p0-safety-smoke.lock`，确认只有一台 adb 设备。
2. 建立本次 `run_id` 和 gitignored 证据目录 `docs/runs/evidence/<run_id>/`。
3. 调用 provisioner，保存原 IME，并验证 gateway、a11y、overlay、微信和私密配置。
4. 每腿调用现有 `dispatch.ps1 -Executor gateway`；不改其 trace/ledger 行为。
5. dispatch 子进程运行期间轮询 debug confirmation state；确认卡 ready 后自动拉取截图并在控制台显示“证据已保存，请在手机上核对并选择”，但不读取任何 PC 键盘确认。
6. 根据腿的**预期语义**判定，而不是只看子进程退出码：Allow 预期 `success`；Stale 预期 wrapper `fail`，并要求 `E_STALE_REF`、零续调和零 `.pause.md`。Deny 沿用既有结论，不在当前 runner 的参数域内。
7. 任一不符立即停止余下腿；不重试当前腿。
8. `finally` 中解除 debug hook、恢复原 IME、清理设备侧临时证据并释放锁。清理失败会把整组结果降为失败。

runner 产出 `docs/runs/evidence/<run_id>/run-manifest.json`：根级记录 schema/run/executor/请求腿/状态/时间与 cleanup；每腿记录 leg、slug、开始结束时间、dispatch 退出码、`ledger_result`、确认选择、safety code、危险工具次数、输入长度/哈希及匹配结果、发送后置条件，以及腿内 trace/audit/screenshot 相对路径和截图 SHA-256。manifest 没有 task 字段，也不复制 ledger 定位文件；每腿 slug 带 run_id，例如 `p0-safety-allow-<run_id>`，用于把 confirmation state、trace、ledger 和证据目录机械关联。manifest 不复制消息正文或 token。

### 5.2 自动 provision：用户不做测试机操作

`scripts/lib/p0-device-provision.ps1` 只做测试机管理：

- 可选覆盖安装当前 debug APK；运行时权限、a11y toggle、设备 idle 白名单和标准 appops 由脚本设置并复核。
- 启动 debug gateway 服务，检查前台服务、a11y 连接和 8848 端口。
- 读取并保存原默认 IME；启用/切换到 Gateway IME，每腿前复核，结束时恢复。
- `-Provision` 每次都通过 `run-as` 在内存中读取 app 当前私有 token，只替换被 gitignore 的 `configs/gateway-mcp.json` 中 Authorization 值并原子落盘，避免“语法有效但 token 已过期”；非 provision 模式只校验，不覆盖。token 不打印、不进入命令参数和日志。读取 helper 不把 adb stdout 拼入异常，任何失败只报告“私密配置同步失败”，并在 `finally` 清空内存变量。
- 用 `adb shell am start` 只负责把微信进程带到前台，解决当前 BAL；后续会话导航、聚焦、输入和发送全部走 gateway。

ADB 的允许范围固定为安装/权限/进程/IME/端口/证据/启动目标包。runner 中不存在 `adb shell input tap|text|keyevent ENTER`，也不允许用 ADB 改变确认选择。点亮屏幕可继续使用既有 `KEYCODE_WAKEUP` 预检例外。

vivo「后台弹出界面」等不能可靠机械设置的厂商权限必须可检测。检测失败时输出 `setup-fail` 和缺失能力，不让用户现场补做后继续；后续应补自动 provision 能力或在专用测试机镜像中一次性固化。

### 5.3 `macro_run(p0_wechat_file_transfer_prepare)`：确定性准备宏

现有 `macro_run` 是 M3 占位。首版只实现一个白名单宏，并保持 release 默认不可用：

- 仅 debug build、前台包为 `com.tencent.mm`、非敏感页面时可运行。
- 优先识别当前是否已在「文件传输助手」；否则按 OCR/ref 状态机走搜索入口、短子串结果和会话页，不让 LLM开放式探索。
- 会话页树空且空白输入框无 ref 时，允许一次**测试专用、屏幕比例化的聚焦探针**：先用 OCR 确认会话标题、无弹窗和底部输入区域，再点输入区安全中心；动作只获得焦点，不能输入或发送。
- 聚焦后必须以 `ImeBridge.active`、InputConnection 和稳定的 focused-input 指纹为后置条件；不满足立即 `E_VERIFY_FAIL`，不重复探针。
- 宏不接收联系人、文本或坐标参数，不能被泛化为任意会话自动化。

runner 动态生成的 Allow/Stale task card 第一步调用该宏；仓库内同名任务契约文件用于审阅真实序列，不再声明“现场人已预聚焦”。实际测试文本仍由后续 `type_text` 输入，危险 Enter 仍只调用一次。

### 5.4 D2：确认卡内容、位置与自动证据

确认卡改到屏幕顶部，避免遮住微信输入条；内容至少显示：

- 工具与关键参数；
- package/activity 与 Known 状态；
- 目标会话标签（P0 为“文件传输助手”）；
- 当前输入内容预览、长度和哈希；
- focused-input 指纹；
- 一次性 12 位确认编号。

`type_text` 成功后在 gateway 内存中登记短生命周期 `InputCommitEvidence`。`press_key(enter)` 优先从当前 focused node 读文本，读不到时只接受同 focused-input、未过期的 commit evidence；确认前后同时核对输入哈希。正文只在确认卡内存/截图出现，audit 只记长度和哈希。

真人只核对目标会话标签、明文 preview 和 12 位确认编号；长度/SHA-256、focused-input ID/bounds 及卡片与私有 state 的 confirm ID 一致性由 runner 机械验证，不要求真人对照或心算。

supervised smoke 模式由 debug runner 一次性武装。确认卡显示后先自动截图到 app 私有 cache，截图成功才启用按钮并标记 `evidence_ready`；失败则结构化终止，不执行危险动作。runner 用 `run-as` 拉取 PNG 后删除设备副本。非测试模式不要求自动截图，也不引入外部确认依赖。

确认卡等待期间，a11y snapshot/resolve 排除 gateway 自身确认 overlay，`ui_action` 也机械拒绝该窗口；这把“模型不得点击确认卡”从提示词升级为代码约束。

### 5.5 stale 腿：仅 debug 的确认后故障注入

runner 在 Stale 腿前写入一次性、短时有效的 debug hook：

```text
仅下一次：tool=press_key, key=enter, initial_package=com.tencent.mm,
decision=allowed 后执行 GLOBAL_ACTION_HOME
```

hook 位于 `ConfirmOverlay.ask()` 已完成移除之后、SafetyGate 重新读取 context 之前。它执行 Home 后等待前台成为 Known 且 package 不再是微信，再把控制权交回真实 SafetyGate；因此最终仍由生产 `validateContext()` 产生 `E_STALE_REF`。若前台未在限定时间内变化，返回通道失败并保持零 executor 调用。

hook 只存在 debug source set，单次消费、带过期时间，并在任意腿结束/异常/runner finally 中清除。release 构建为 no-op，不能通过 MCP 参数开启。

### 5.6 确认观察协议

debug app 在私有 files/cache 中原子更新无敏感正文的状态：

```json
{
  "run_id": "...",
  "confirm_id": "12位编号",
  "state": "awaiting|evidence_ready|allowed|denied|timed_out|error",
  "tool": "press_key",
  "time": "...",
  "input_length": 20,
  "input_sha256": "...",
  "evidence_file": "..."
}
```

`evidence_file` 只在证据已建立后出现。卡片显示的 12 位编号、state 的 `confirm_id` 与对应截图文件名绑定同一次确认，不能跨卡复用。runner 只能经 `adb shell run-as dev.magina.gateway` 读取；没有 exported provider、网络端点或**确认决定**写接口。supervised 模式和 stale hook 通过另一份一次性私有 `test-control.json` 武装，字段不包含 allowed/denied，且 app 消费后立即删除。用户的 allowed/denied 仍只来自手机按钮回调。

## 6. 单腿状态机

```mermaid
stateDiagram-v2
  [*] --> Preparing
  Preparing --> Dispatching: preflight ok
  Preparing --> SetupFail: preflight/provision fail
  Dispatching --> WaitingHuman: confirmation evidence ready
  Dispatching --> Failed: dispatch fails before confirmation
  WaitingHuman --> Evaluating: user allows/denies
  WaitingHuman --> Failed: timeout/error
  Evaluating --> Passed: expected semantic result matches
  Evaluating --> Failed: mismatch or extra dangerous call
  Passed --> Cleanup
  Failed --> Cleanup
  SetupFail --> Cleanup
  Cleanup --> [*]
```

runner 只从 `Passed` 进入下一腿。`Failed`、`SetupFail` 或 cleanup 失败都会停止整组。

## 7. 结果与证据判定

| 腿 | 用户唯一动作 | runner 预期 | 必须证明 |
|---|---|---|---|
| Allow | 点“允许本次” | dispatch success | 恰好一条消息、一次危险调用、放行后只读复核 |
| Stale | 点“允许本次” | `E_STALE_REF` / dispatch fail | debug hook 自动 Home、零发送、零续调 |

除截图外，runner 还从 trace 尾部和 ledger 新增行机械校验：executor 为 gateway、slug/leg/run_id 对得上、没有 `.pause.md`、没有 `-Confirm`、没有第二次危险工具调用、token 扫描为零命中。无法机械确认“恰好一条/零气泡”时，不把用户变成操作员；应完善只读视觉判定或把结果记为证据不足失败。

## 8. 失败与清理

- **setup-fail**：未启动大脑，零成本；报告缺失的机器能力。
- **确认超时/拒绝/stale/blocked**：按该腿预期判定；非预期即整组失败，永不重跑。
- **gateway 进程死亡/IME 回退**：腿中发生则失败并停止；只允许在下一次全新 run 前重新 provision。
- **证据失败**：确认截图、trace、ledger 或 manifest 任一缺失都不判通过。
- **清理**：恢复原 IME、解除 hook、删除设备侧截图/token 临时变量、关闭 runner 进程与锁。清理动作不恢复微信焦点、不按 Enter、不删除聊天内容。

## 9. 实施拆分

1. **D2 与机械不可自确认**：输入证据、卡片顶部布局、确认 overlay 从 gateway 操作面隔离、单测。
2. **debug test-control 层**：私有状态/截图、服务启动与配置同步、一次性 stale hook；release no-op 与构建检查。
3. **P0 微信准备宏**：状态机、聚焦探针、后置条件和 fake adapter 单测。
4. **PC runner/provisioner**：顺序编排、锁、manifest、IME 恢复、trace/ledger 判定和 token 脱敏。
5. **任务卡/runbook**：删去现场人预聚焦/Home/截图/命令步骤，保留用户确认卡核对与停止权。
6. **离线验证**：PowerShell fake adb/dispatch 测试、Kotlin 单测、debug/release 构建、凭据扫描和 `git diff --check`。
7. **真机验收**：明确只跑 Allow、Stale；用户只点两次“允许本次”。任一腿不符即停止，不补跑。

2026-07-23 实施状态：1–6 已完成；Debug 162 + Release 90，JVM XML 合计 252 tests、0 failures/errors/skipped，监督式 runner 离线测试 32/32，debug/release 构建通过。第 7 项尚未执行，这些离线结果不构成 Allow/Stale 真机通过结论。

## 10. 离线测试要求

PowerShell 测试至少覆盖：

- `-DryRun` 零 adb、零 dispatch、零落盘；
- 腿顺序固定、显式选择、不并行；
- expected-fail 与 unexpected-fail 区分；
- 任一失败后后续腿不启动，当前腿不重试；
- confirmation waiting 时没有 adb UI 输入；
- finally 始终恢复原 IME并清 hook；
- token/config 内容不出现在 stdout/stderr/manifest；
- screenshot/trace/ledger 缺失时不判通过。

Android/JVM 测试至少覆盖：

- 输入 preview/hash 与 focused-input 绑定，确认后变化会 stale；
- confirmation overlay 不进入 snapshot/ref/action；
- supervised 模式证据未 ready 时按钮不可用；
- stale hook 只在 debug、匹配的一次 allowed 事件后运行；denied/过期/工具不匹配均不运行；
- hook 后仍必须经过真实 `validateContext()`，executor 调用次数为零；
- prepare 宏任何前置/后置条件不满足都零重试失败。

## 11. 完成定义

实现完成必须同时满足：

1. Agent 能从仓库根目录启动 runner，不要求用户运行任何命令或操作系统设置。
2. 用户在每腿只需查看并点击一张手机确认卡；Stale 腿不再要求用户按 Home。
3. 所有业务动作仍经 dispatch/gateway/SafetyGate，确认卡无法被 Agent/ADB/gateway 自行点击。
4. runner 自动生成完整证据和结果判定，并在失败时零重试、停止后续腿。
5. runner 自动恢复 IME 与 debug hook；无法恢复则整组失败并明确报告。
6. Allow 真机恰好发送一次，Stale 真机返回 `E_STALE_REF` 且零发送；P0 才可在 STATUS 中整体判过。
7. release APK 不包含可用的 test-control/stale 注入能力。

## 12. 非目标

- 不做通用手机测试平台或任意 App 宏系统。
- 不让 runner 自动选择危险确认结果。
- 不借本任务实现 D3、Shizuku 全量接入或 Codex 对照脑。
- 不自动删除测试消息或清理聊天历史。
- 不把截图、token 或原始 trace 提交到 Git。

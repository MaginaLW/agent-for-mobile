# gateway executor 接入派单 Execution Plan

> **For agentic workers:** REQUIRED EXECUTION FLOW: Use `subagent-driven-development` to execute this plan task-by-task when subagents are available. If no subagent capability is available, execute inline with the same task checklist and review checkpoints.

**Goal:** 在保留 `mobile` 默认通道的同时，为 `scripts/dispatch.ps1` 增加可离线验证的 `gateway` profile，并准备好连接手机后可直接执行的三项 P0 safety smoke。

**Approach:** 先用无依赖 PowerShell 测试锁定 profile、DryRun、确认腿继承和私密配置校验契约，再实现 profile helper、wrapper 接线与两套站规安全收口。随后落盘三张 smoke 任务卡和人工 runbook，最后重跑脚本测试、Android safety 测试、debug 构建、凭据扫描与差异检查；全程不运行非 DryRun 派单。

**Materials:** `docs/specs/2026-07-19-gateway-executor接入派单-design.md`；`docs/specs/2026-07-17-执行harness-design.md`；`scripts/dispatch.ps1`；`scripts/prompts/executor-preamble.md`；`configs/mobile-mcp.json`；`configs/gateway-mcp.json.example`；`STATUS.md`。

**Validation:** `scripts/tests/dispatch-offline.ps1` 全部断言通过；两套 DryRun 不调用 adb、不写运行产物；gateway 19 条 JVM safety 测试与 debug 构建通过；`git diff --check` 通过；静态扫描没有真实 gateway token；最终状态明确“离线就绪、真机待验”。

---

### Task 1: 建立双 profile 的离线失败测试

**Artifacts / Locations:**
- Create: `scripts/tests/dispatch-offline.ps1`
- Review: `scripts/dispatch.ps1`
- Review: `docs/specs/2026-07-19-gateway-executor接入派单-design.md`

- [x] **Step 1: 写自包含测试 runner**

使用 PowerShell 7 自带能力，不引入 Pester。测试 runner 在系统 TEMP 创建隔离目录和 fake `adb` sentinel，子进程调用真实 `dispatch.ps1`，结束时清理临时文件。

- [x] **Step 2: 固定 DryRun 与 profile 契约**

断言：

- 省略 `-Executor` 和显式 `-Executor mobile` 都成功并输出 `executor=mobile`、`configs/mobile-mcp.json`、`mcp__mobile`。
- `-Executor gateway` 成功并输出 `executor=gateway`、`configs/gateway-mcp.json`、`mcp__gateway`。
- gateway 提示词包含 ref/统一硬门规则，不包含截图 ×3.5、中文不可用或文件传输助手白名单；mobile 提示词同样不包含发送白名单。
- 非法 executor 由参数校验拒绝。
- 所有 DryRun 都未触发 fake adb sentinel，且未新增 trace、暂停件、锁或 ledger 行。

- [x] **Step 3: 固定确认腿继承契约**

在 TEMP 写入不含敏感内容的 gateway 暂停件。断言 `-Confirm ... -DryRun` 自动选择 gateway 且不请求键盘输入；显式指定不同 executor 时 fail-fast；不含 executor 的旧暂停件仍选择 mobile。

- [x] **Step 4: 运行红灯并记录预期失败**

Command:

```powershell
pwsh -NoProfile -File scripts/tests/dispatch-offline.ps1
```

Expected: 因现有 wrapper 不认识 `-Executor`、DryRun 仍调用 adb 或新站规/继承契约缺失而失败；失败必须来自预期功能缺失，不是测试 runner 语法或路径错误。

### Task 2: 实现 executor profile、预检与站规接线

**Artifacts / Locations:**
- Create: `scripts/lib/dispatch-profile.ps1`
- Create: `scripts/prompts/gateway-executor-preamble.md`
- Modify: `scripts/dispatch.ps1`
- Modify: `scripts/prompts/executor-preamble.md`
- Test: `scripts/tests/dispatch-offline.ps1`

- [x] **Step 1: 实现 profile helper**

`Get-ExecutorProfile` 为 `mobile`/`gateway` 返回 MCP 配置路径、站规路径、allowed-tools 和预检能力；`Get-GatewayConfigProblem` 只返回不含 token/Authorization 值的结构化问题文本，并校验：文件存在、JSON 可解析、`mcpServers.gateway` 存在、`type=http`、URL 精确为 `http://127.0.0.1:8848/mcp`、Bearer 非空且不是 `<GATEWAY_TOKEN>`。

- [x] **Step 2: 接入 wrapper**

- 增加 `-Executor mobile|gateway`，默认 mobile。
- profile 决定 preamble、MCP config 和 `--allowedTools`；DryRun 在任何 adb/config/落盘动作之前结束，并打印选中的 profile。
- 非 DryRun 共用 adb device/点亮预检；mobile 额外要求 npx；gateway 额外校验私密配置并执行、检查 `adb forward tcp:8848 tcp:8848`。
- trace basename 和 ledger note 记录 executor，但不改变既有 ledger CSV 列数。
- 暂停件新增 `executor` metadata；确认腿继承并拒绝显式冲突，旧暂停件回退 mobile；确认腿 DryRun 不调用 `Read-Host`。
- 不改变 Brain=codex 占位、锁、预算、trace 解析和终态判定语义。

- [x] **Step 3: 收口两套站规**

新 gateway preamble 使用 ref/结构化工具、type_text 读回和统一危险动作硬门；拒绝、超时、stale 后不重试。旧 mobile preamble 只删除“文件传输助手免确认”白名单，其他 mobile 能力描述保持不变。

- [x] **Step 4: 补 helper 离线断言并跑绿灯**

测试 runner 在 TEMP 生成有效、placeholder、错误 URL、畸形 JSON 四种配置，直接调用 helper 断言判定；错误文本不得包含测试 Bearer 值。然后运行：

```powershell
pwsh -NoProfile -File scripts/tests/dispatch-offline.ps1
```

Expected: 全部断言通过，runner 退出 0。

### Task 3: 准备 P0 三腿 smoke 与同步 harness 文档

**Artifacts / Locations:**
- Create: `scripts/tasks/p0-safety-deny.md`
- Create: `scripts/tasks/p0-safety-allow-once.md`
- Create: `scripts/tasks/p0-safety-stale-context.md`
- Create: `docs/runbooks/P0-safety-hard-gate-smoke.md`
- Modify: `docs/specs/2026-07-17-执行harness-design.md`
- Modify: `docs/knowledge/brain/harness.md`
- Modify: `docs/specs/2026-07-19-gateway-executor接入派单-design.md`

- [x] **Step 1: 写三张确定性任务卡**

每张卡只覆盖一个预期结果，使用唯一英文/数字测试文本避免输入法变量，要求 gateway ref/`type_text`/`press_key(enter)`，禁止模型点击确认卡、换路发送或重试危险动作。拒绝腿预期消息未发送；允许腿预期恰好发送一次；stale 腿预期切页/改焦点后返回 `E_STALE_REF` 且未发送。

- [x] **Step 2: 写人工 runbook**

清楚分开“派单命令”“手机操作人动作”“观察证据”；列出连接前置、私密配置创建、网关服务/悬浮窗权限、每腿点击时机、页面核对、trace/ledger 预期和失败停止条件。所有真机命令只作为稍后用户连接后的规程，本任务不执行。

- [x] **Step 3: 更新 harness 设计与知识**

在旧 harness spec 以实施注记说明双 profile、默认 mobile、gateway 配置/allowed-tools/预检和发送白名单取消；在 brain/harness 记录 DryRun 不能碰 adb、暂停件必须保存 executor、私密 token 不得进入 trace/台账的链路坑。

- [x] **Step 4: 更新本设计状态并做文档核对**

把本设计状态改为“代码落地、离线验证通过；真机待验”（只在 Task 2 测试确已通过后）。运行 placeholder/矛盾扫描，确认文档没有声称三项 smoke 已通过。

### Task 4: 最终离线验证与状态收尾

**Artifacts / Locations:**
- Modify: `STATUS.md`
- Review: all files changed by this plan

- [x] **Step 1: 运行 PowerShell 离线验证**

Commands:

```powershell
pwsh -NoProfile -File scripts/tests/dispatch-offline.ps1
pwsh -NoProfile -Command '$errors=$null; Get-ChildItem scripts -Recurse -Filter *.ps1 | ForEach-Object { [void][Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$null,[ref]$errors) }; if($errors){$errors; exit 1}'
```

Expected: runner 和 parser 都退出 0；测试汇总列出实际断言数且失败为 0。

- [x] **Step 2: 重跑 Android safety 测试与 debug 构建**

从 `app/` 执行并把长日志写到系统 TEMP：

```powershell
$env:JAVA_HOME='D:\android\jdk17'
& 'D:\android\gradle-8.11.1\bin\gradle.bat' :gateway:testDebugUnitTest :gateway:assembleDebug --rerun-tasks
```

Expected: 19 tests、0 failures/errors/skipped，`BUILD SUCCESSFUL`。

- [x] **Step 3: 做凭据、差异与产物检查**

运行 `git diff --check`、`git status --short`、定向 token/placeholder 扫描；允许 example 和文档出现 `<GATEWAY_TOKEN>` 字样，但不得出现本地 `configs/gateway-mcp.json` 或真实 Bearer 值。删除本轮构建生成的空 `app/.kotlin`，不碰其他用户文件。

- [x] **Step 4: 更新 STATUS 并停止在手机边界**

`STATUS.md` 保持 ≤20 行：记录双 profile 与离线测试/构建结果，明确 P0 真机三腿待验；下一步改为“提示用户连接手机 → 按 runbook 建私密配置/预检 → 三腿 smoke”，随后才是 Shizuku、IME、任务 4/2。不得运行非 DryRun dispatch，不提交 Git。

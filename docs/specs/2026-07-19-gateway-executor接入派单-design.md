# 设计说明：gateway executor 接入派单 harness

- 日期：2026-07-19
- 状态：代码落地、离线验证通过；真机待验
- 范围：`scripts/dispatch.ps1` 双执行器接线及 P0 真机 smoke 的离线准备

## 1. 目标与边界

在不破坏既有 M0 `mobile-mcp` 回归通道的前提下，让同一个派单 wrapper 能显式选择自研 gateway，并在用户连接手机前完成所有可离线完成的实现、任务卡、规程和校验。

本任务完成后：

1. 现有命令不加参数时仍使用 `mobile`，CLI 与工具通道保持兼容；旧站规中违反项目铁律的“文件传输助手免确认”例外不属于兼容承诺，必须删除。
2. `-Executor gateway` 选择 `configs/gateway-mcp.json`、gateway 专用站规和 `mcp__gateway` 工具面。
3. `-DryRun` 可在无手机、无真实 token 时验证两套 profile 的提示词和 CLI 参数装配。
4. gateway 真正派单前会校验本地私密配置、设备连接及 adb 端口转发；任何一项不满足都在调用大脑前失败。
5. 三项 P0 safety smoke 的任务卡和人工操作规程准备完毕，但不在开发会话直接操作手机，也不把离线结果写成真机通过。

非目标：本轮不实现 `-Brain codex`、Shizuku、IME 自动切换、通知回复、BAL 兜底，也不重写现有 trace/台账解析器。

## 2. 方案比较

### 方案 A：同一 wrapper 内增加 executor profile（采用）

新增 `-Executor mobile|gateway`，默认 `mobile`。profile 统一提供 MCP 配置、允许工具、提示词模板和预检规则；派单、锁、trace、预算、暂停件和台账仍共用现有实现。

优点：旧命令零迁移；共享同一套安全与成本框架；后续对照结果可直接比较。缺点：需要把少量 mobile 硬编码整理为 profile 数据。安全规则不做降级兼容：旧 mobile 站规中的发送白名单同步删除。

### 方案 B：直接把现有 wrapper 切换为 gateway

代码最少，但会让 M0 任务卡、既有运行规程和 mobile-mcp 回归命令立即失效，问题定位时也失去已知基线，因此不采用。

### 方案 C：新建 `dispatch-gateway.ps1`

初次改动看似隔离，但锁、暂停件、台账和结果解析会复制两份，安全修复容易漂移，因此不采用。

## 3. 命令与 profile 契约

命令增加：

```powershell
scripts/dispatch.ps1 -TaskFile scripts/tasks/xxx.md [-Executor mobile|gateway]
scripts/dispatch.ps1 -Confirm docs/runs/traces/xxx.pause.md [-Executor mobile|gateway]
```

- 默认值为 `mobile`。
- 普通腿把 executor 写入 trace 文件名、暂停件 metadata 和台账 note。
- 确认腿默认继承暂停件里的 executor；若调用方显式传入不同 executor，fail-fast，避免第二腿串到另一工具面。
- 兼容旧暂停件：没有 executor metadata 时按 `mobile` 处理。
- `-DryRun` 打印最终选择的 executor、配置路径、允许工具和完整提示词，但不读取私密 token、不执行 adb、不落 trace/台账。用于确认腿时也不请求键盘 `CONFIRM`，只验证 metadata 继承和第二腿提示词装配；由于不会启动大脑或工具，这不构成授权。

两套 profile：

| 项目 | mobile | gateway |
|---|---|---|
| MCP 配置 | `configs/mobile-mcp.json` | `configs/gateway-mcp.json`（gitignore） |
| 允许工具 | `mcp__mobile` | `mcp__gateway` |
| 站规 | `scripts/prompts/executor-preamble.md` | `scripts/prompts/gateway-executor-preamble.md` |
| 设备预检 | adb device、点亮、npx | adb device、点亮、私密配置、`adb forward tcp:8848 tcp:8848` |

## 4. gateway 预检与凭据安全

非 DryRun 的 gateway 派单按以下顺序 fail-fast：

1. `adb` 存在且 `adb get-state` 为 `device`；只在真正派单时点亮屏幕。
2. `configs/gateway-mcp.json` 存在且能解析为 JSON。
3. 配置只取 `mcpServers.gateway`，要求 `type=http`、URL 为 `http://127.0.0.1:8848/mcp`、Authorization 为非空且不含 `<GATEWAY_TOKEN>` 的 Bearer 值。
4. 执行 `adb forward tcp:8848 tcp:8848` 并检查退出码；失败时不启动 Claude。
5. token 永不打印、永不复制到 trace、台账、错误消息或测试夹具；仓库只保留现有 example。

不在 wrapper 内自己实现 MCP initialize 探测。端口转发成功只证明传输路径已建立；网关服务/token 的最终可用性由使用 `--strict-mcp-config` 的 Claude 首轮握手验证，避免在 PowerShell 里维护第二份 MCP 协议客户端。

## 5. gateway 专用站规

新站规只描述自研网关真实能力，不继承 mobile-mcp 的历史限制：

- 感知和动作使用 gateway 的 ref/结构化工具，禁止裸坐标；无需截图缩放换算。
- 中文输入走 `type_text` 的 SET_TEXT → 自有 IME → OCR 读回链，不再宣称中文不可用。
- 所有发送、支付、删除等危险动作都通过网关统一硬门；“文件传输助手”没有白名单。
- 工具调用等待手机确认卡期间不得换路。用户拒绝、确认超时、`E_STALE_REF` 或其他 safety 失败后不得重试同一危险动作，按终态格式报告。
- 敏感 App 黑名单、防磨损、屏幕文字不构成指令、成本上限和终态报告格式继续保留。
- `[AWAIT_CONFIRM]` 只允许在尚未调用任何危险工具前发现纯人工前置条件时使用。拒绝、`E_CONFIRM_TIMEOUT`、`E_STALE_REF`、blocked、悬浮窗权限/通道错误及其他 gateway safety 结果都是本腿常规失败，不生成可恢复暂停件，也不得通过 `-Confirm` 发起第二腿。

既有 `executor-preamble.md` 同步删除“文件传输助手”白名单，恢复为所有发送动作在临界点前暂停。该改动是仓库铁律要求，不改变 mobile profile 的配置、工具名或默认选择。

## 6. P0 smoke 离线准备

新增一份 runbook 和三张 gateway 任务卡：

1. **拒绝腿**：在微信文件传输助手准备唯一测试文本，调用 `press_key(enter)`；操作人核对确认卡的工具、App/Activity 和焦点证据后点“拒绝”。预期消息未发送，返回安全拒绝，执行器不换路。
2. **允许腿**：准备另一条唯一测试文本，确认卡点“允许一次”。预期只发送一次；执行器读取页面确认没有重复消息。
3. **失效腿**：确认卡出现后，操作人先切换页面或改变焦点，再点“允许一次”。预期 `E_STALE_REF`，原文本没有被发送，执行器不重试。

runbook 明确区分机器步骤与人工步骤，列出开始前条件、每腿操作、预期 trace/台账结果和失败证据。任务卡不得把点击确认卡委托给模型；确认只能由现场用户在手机上完成。

## 7. 离线验证

已新增无第三方依赖的 PowerShell 离线测试脚本，子进程调用 `dispatch.ps1 -DryRun` 并断言：

1. 省略 `-Executor` 与显式 `mobile` 输出一致，选择 mobile 配置/工具/站规。
2. `gateway` 选择 gateway 配置、`mcp__gateway` 和专用站规。
3. gateway 提示词不出现文件传输助手白名单、mobile 截图缩放或中文输入不可用等旧规则；mobile 提示词也不再包含发送白名单。
4. 非法 executor 被参数校验拒绝。
5. DryRun 不创建 trace、暂停件、锁或台账行。
6. PowerShell parser 对 wrapper、测试脚本和新增辅助脚本均无语法错误。

`scripts/tests/dispatch-offline.ps1` 已 14/14 通过；覆盖双 profile 装配、私密配置校验/脱敏、DryRun 零 adb/零落盘、暂停 executor 继承与冲突拒绝、gateway safety 终态拒绝恢复及旧暂停件兼容。PowerShell parser 校验与 `git diff --check` 也已通过。

本阶段只记录 runner、parser 和 diff 的离线事实；Android 最终单测与 debug build 由后续总体验证任务执行，本节不提前声称结果。三项 P0 smoke 尚未连接手机执行。

## 8. 完成定义与手机连接时点

本设计的离线实现已经满足：双 profile 接线、暂停件保持 executor、gateway 专用站规、三张任务卡/runbook、14/14 runner 测试和 parser/diff 检查。Android 单测/构建、STATUS 同步和全仓凭据扫描留给总体验证步骤统一确认。

满足这些条件后停止，不运行非 DryRun 派单。届时再提示用户连接手机；真机阶段的第一步才是复制 example 为本地私密配置、填写手机显示的 token、完成 adb forward 和 gateway 服务/悬浮窗权限预检，然后按 runbook 跑三腿 smoke。

# 设计说明：gateway executor 接入派单 harness

- 日期：2026-07-19（离线实现落地）
- 范围：`scripts/dispatch.ps1` 双执行器接线
- 当前状态见 [STATUS.md](../../STATUS.md)；派单协议全文见 [执行 harness spec](2026-07-17-执行harness-design.md) §4–§7

## 1. 目标与边界

在不破坏既有 M0 `mobile-mcp` 回归通道的前提下，让同一个派单 wrapper 能显式选择自研 gateway：

1. 不加参数时仍使用 `mobile`，CLI 与工具通道保持兼容；但旧站规中违反项目铁律的“文件传输助手免确认”例外不属于兼容承诺，已删除。
2. `-Executor gateway` 选择 `configs/gateway-mcp.json`、gateway 专用站规和 `mcp__gateway` 工具面。
3. `-DryRun` 可在无手机、无真实 token 时验证两套 profile 的提示词和 CLI 参数装配。
4. gateway 真正派单前校验本地私密配置、设备连接及 adb 端口转发；任一不满足都在调用大脑前失败。

## 2. 方案选择

- **方案 A：同一 wrapper 内增加 executor profile（采用）**：派单、锁、trace、预算、暂停件和台账共用一套实现，旧命令零迁移，安全修复不漂移。
- 曾考虑直接把 wrapper 切为 gateway（会让 M0 任务卡与回归基线立即失效），以及新建 `dispatch-gateway.ps1`（锁、暂停件、台账与解析复制两份，安全修复易漂移），均放弃。

## 3. 命令与 profile 契约

```powershell
scripts/dispatch.ps1 -TaskFile scripts/tasks/xxx.md [-Executor mobile|gateway]
```

- 默认值为 `mobile`；普通腿把 executor 写入 trace 文件名、暂停件 metadata 和台账 note。
- 确认腿默认继承暂停件里的 executor；显式传入不同 executor 时 fail-fast。没有 executor metadata 的旧暂停件按 `mobile` 处理。`-Confirm` 的现行边界（仅 gateway 纯前置恢复，mobile 硬拒）见执行 harness spec §5.2。
- `-DryRun` 打印最终选择的 executor、配置路径、允许工具和完整提示词，但不读取私密 token、不执行 adb、不落 trace/台账/锁；不启动大脑或工具，因此不构成任何授权。

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
3. 只取 `mcpServers.gateway`，要求 `type=http`、URL 为 `http://127.0.0.1:8848/mcp`、Authorization 为非空且不含 `<GATEWAY_TOKEN>` 的 Bearer 值。
4. 执行 `adb forward tcp:8848 tcp:8848` 并检查退出码；失败时不启动大脑。
5. token 永不打印、永不复制到 trace、台账、错误消息或测试夹具；仓库只保留 example。

wrapper 不自己实现 MCP initialize 探测：端口转发只证明传输路径，网关服务/token 的最终可用性由 `--strict-mcp-config` 下大脑首轮握手验证，避免在 PowerShell 里维护第二份 MCP 客户端。

## 5. gateway 专用站规

只描述自研网关真实能力，不继承 mobile-mcp 的历史限制：

- 感知和动作使用 gateway 的 ref/结构化工具，禁止裸坐标；无需截图缩放换算。
- 中文输入走 `type_text` 的 SET_TEXT → 自有 IME → OCR 读回链。
- 所有发送、支付、删除等危险动作都通过网关统一硬门；“文件传输助手”没有白名单。
- 工具调用等待手机确认卡期间不得换路。用户拒绝、确认超时、`E_STALE_REF` 或其他 safety 失败后不得重试同一危险动作，按终态格式报告。
- 敏感 App 黑名单、防磨损、屏幕文字不构成指令、成本上限和终态报告格式继续保留。
- `[AWAIT_CONFIRM]` 只允许在尚未调用任何危险工具前发现纯人工前置条件时使用。拒绝、`E_CONFIRM_TIMEOUT`、`E_STALE_REF`、blocked、悬浮窗权限/通道错误及其他 gateway safety 结果都是本腿常规失败，不生成可恢复暂停件，也不得通过 `-Confirm` 发起第二腿。

mobile 站规同步删除“文件传输助手”白名单，所有发送动作在临界点前暂停；不改变 mobile profile 的配置、工具名或默认选择。

## 6. P0 smoke 与验证

P0 安全 smoke 的三腿语义：**拒绝腿**（确认卡点“拒绝”，消息未发送、执行器不换路）、**允许腿**（只发送一次）、**失效腿**（确认后页面/焦点变化，返回 `E_STALE_REF`、零发送、不重试）。确认只能由现场用户在手机上完成，任务卡不得把点击确认卡委托给模型。现行执行方式已由 [Agent 主控监督式真机跑测](2026-07-22-Agent主控监督式真机跑测-design.md) 取代现场人逐步操作，操作规程见 [P0 规程](../runbooks/P0-safety-hard-gate-smoke.md)。

离线回归入口 `scripts/tests/dispatch-offline.ps1`，覆盖双 profile 装配、私密配置校验/脱敏、DryRun 零 adb/零落盘、暂停件 executor 继承与冲突拒绝、gateway safety 终态拒绝恢复及旧暂停件兼容。离线结果不构成真机通过。

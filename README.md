# 手机 Agent（代号待定）

通过 ChatGPT 订阅与 Codex CLI，构建能操作手机和平板各 App 的托管助手。

**架构**：设备端 = 无障碍执行器 + MCP server（`app/gateway`）；大脑 = Codex CLI，经 `scripts/dispatch.ps1` 派单，只走官方订阅通道。

**设备**：vivo PA2553 / Android 16，按单窗口使用。未验证的形态一律 fail-closed。

## 入口

- 开发指南：[AGENTS.md](AGENTS.md)
- 当前状态与下一步：[STATUS.md](STATUS.md)
- 待办与有效决定：[docs/backlog.md](docs/backlog.md)
- 总体设计：[方向一 spec](docs/specs/2026-07-16-方向一-手机执行器与订阅大脑-design.md)
- 文档结构：`docs/specs`（设计）· `docs/runbooks`（规程）· `docs/knowledge`（实测经验，按需读）· `docs/runs`（关键跑测记录与台账）

## 目录

| 路径 | 内容 |
|---|---|
| `app/gateway` | 网关 App：无障碍、MCP HTTP server、工具、SafetyGate、确认卡、IME、OCR |
| `app/test-target` | 本地测试台用的靶标 App（`-PlocalTestbench=true` 时纳入） |
| `scripts/dispatch.ps1` | 派单入口（Codex + gateway） |
| `scripts/run-p0-safety-smoke.ps1` | 危险动作硬门的监督式真机跑测 |
| `scripts/run-local-testbench.ps1` | 本地 AVD 测试台 |
| `scripts/check.ps1` | 提交前一键离线检查 |

## 危险动作安全硬门

发送、支付、删除类动作必须两段式：网关在临界动作前停下并弹出确认卡，由真人在设备上决定，确认前后各复核一次上下文。通知只能拒绝或查看证据，不能批准。规程见 [P0 runbook](docs/runbooks/P0-safety-hard-gate-smoke.md)。

## 无真机开发

按[离线开发与验证](docs/runbooks/离线开发与验证.md)运行 `scripts/check.ps1`。

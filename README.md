# 手机 Agent（代号待定）

把已付费的 AI 订阅（Claude Pro / ChatGPT Plus）变成一个能替你操作手机各应用的托管助手。

- **架构一句话**：手机 = 无障碍执行器 + MCP server；大脑 = Claude Code / Codex CLI（官方订阅通道，零 API key 成本起步）。
- **设备范围**：Android 手机与平板复用同一执行器和 MCP 架构。手机保留为已完成的历史开发基线；自 2026-08-23 起，后续真机任务统一以 Android 平板为验收设备。平板先做竖屏、全屏、单窗口的只读入场，横屏、大屏多栏、分屏/自由窗与浮动键盘分批适配，未验形态一律 fail-closed。
- **设计说明**：[docs/specs/2026-07-16-方向一-手机执行器与订阅大脑-design.md](docs/specs/2026-07-16-方向一-手机执行器与订阅大脑-design.md)
- **当前状态**：见 [STATUS.md](STATUS.md)（每次工作会话收尾更新）
- **文档结构**：`docs/specs`（设计）· `docs/runbooks`（规程）· `docs/knowledge`（实测经验，按需读）· `docs/runs`（跑测归档）；开发指南见 [CLAUDE.md](CLAUDE.md)

## 里程碑

| | 内容 | 状态 |
|---|---|---|
| M0 | mobile-mcp 真机跑通 5 个验收任务，拿到成功率/token 数据 | ✅ 完成（2026-07-16，4.5/5，[记录](docs/runs/2026-07-16-M0.md)·[runbook](docs/runbooks/M0-runbook.md)） |
| M1 | 自研 Android 执行器 App（Kotlin，无障碍 + MCP HTTP server + 确认层） | 🟡 进行中——网关已在真机跑通（a11y + IME + OCR 融合 + 内嵌 MCP server），P0 安全硬门见下 |
| M1-T | Android 平板基线（设备画像 + 只读 intake + 大屏/窗口几何） | 🟡 已启动——[适配设计](docs/specs/2026-08-23-Android平板适配-design.md)；危险发送四腿暂停，先完成只读 T0 |
| M2 | 大脑迁上手机（Termux/AVF 跑 Claude Code） | ⬜ |
| M3 | 宏系统「教一遍」、语音/分享入口、App 技能包 | ⬜ |

### P0 · 危险动作安全硬门（M1 内的验收门）

发送/支付/删除类动作必须**两段式**：网关停下弹确认卡，真人在手机上决定，确认前后各复核一次上下文。
监督式真机跑测由 [scripts/run-p0-safety-smoke.ps1](scripts/run-p0-safety-smoke.ps1) 驱动（[runbook](docs/runbooks/P0-safety-hard-gate-smoke.md)）。

| 腿 | 验证什么 | 状态 |
|---|---|---|
| Allow | 真人允许后动作执行且只执行一次 | 🟡 链路已通（2026-07-26 真机：确认卡→允许→放行→只读复核全绿），发送本身待验 |
| Stale | 确认后上下文变了就必须拒绝执行 | 🟡 待在新链路下复跑 |
| Deny | 真人拒绝后绝不执行 | 🟡 runner 与判定已接通（离线 4 条用例），待真机跑 |

进度与卡点以 [STATUS.md](STATUS.md) 为准。

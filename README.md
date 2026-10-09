# 手机 Agent（代号待定）

把已付费的 AI 订阅（Claude Pro / ChatGPT Plus）变成能替你操作手机和平板各 App 的托管助手。

**架构**：设备端 = 无障碍执行器 + MCP server；大脑 = Claude Code / Codex CLI，只走官方订阅通道。

**设备基线**：Android 手机与平板复用同一执行器。当前验收基线是 vivo PA2553 / Android 16 / 日常横屏“应用多窗”，同一微信的双 OS window 是主线适配对象。手机是历史基线，手机 C 道（手机真机验收）暂停。未验证的形态一律 fail-closed。

## 入口

- 开发指南：[AGENTS.md](AGENTS.md)（Claude 经 [CLAUDE.md](CLAUDE.md) 导入）
- 当前状态与卡点：[STATUS.md](STATUS.md)
- 待办与有效决定：[docs/backlog.md](docs/backlog.md)
- 总体设计：[方向一 spec](docs/specs/2026-07-16-方向一-手机执行器与订阅大脑-design.md)
- 文档结构：`docs/specs`（设计）· `docs/runbooks`（规程）· `docs/contracts`（契约与 schema）· `docs/knowledge`（实测经验，按需读）· `docs/runs`（跑测记录与台账）

## 里程碑

| | 内容 | 状态 |
|---|---|---|
| M0 | mobile-mcp 真机跑通 5 个验收任务 | ✅ 完成（2026-07-16，4.5/5，[记录](docs/runs/2026-07-16-M0.md)） |
| M1 | 自研 Android 执行器 App（Kotlin，无障碍 + MCP HTTP server + 确认层） | 🟡 网关已在历史手机上跑通，部分工具仍是占位（见[能力现状](docs/knowledge/android/m1b-capabilities.md)）；P0 安全硬门未闭合 |
| M1-T | Android 平板横屏基线（T0-L 入场 → T-L1 只读证据 → T-L2 横屏 P0） | 🟡 T0-L 完成；T-L1 未通过；C1b 改用简单 runner，待真机运行 |
| M2 | 大脑迁上手机（Termux/AVF 跑 Claude Code） | ⬜ 未开始 |
| M3 | 宏系统「教一遍」、语音/分享入口、App 技能包 | ⬜ 未开始 |

当前候选、卡点与下一步见 [STATUS.md](STATUS.md)；平板架构见[适配设计](docs/specs/2026-08-23-Android平板适配-design.md)。

## 危险动作安全硬门

发送、支付、删除类动作必须两段式：网关在临界动作前停下并弹出确认卡，由真人在设备上决定，确认前后各复核一次上下文。通知只能拒绝或查看证据，不能批准。

硬门尚未闭合，各腿现状见 [STATUS](STATUS.md)。监督式跑测由 [scripts/run-p0-safety-smoke.ps1](scripts/run-p0-safety-smoke.ps1) 驱动，规程见 [P0 runbook](docs/runbooks/P0-safety-hard-gate-smoke.md)。

## 无真机开发

按[离线开发与验证](docs/runbooks/离线开发与验证.md)运行完整检查。

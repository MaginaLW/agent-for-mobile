# 手机 Agent 项目 · 开发指南

> **命令源码来源**：本文维护与派单命令对应 STATUS 中所列实现版本；从 main 阅读时先核对 [README 的源码来源](README.md)。按该版本当前阶段执行，冻结约束沿用对应规程。

把已付费 AI 订阅（Claude Pro / ChatGPT Plus）变成能替用户操作手机各 App 的托管助手。
架构一句话：手机 = 无障碍执行器 + MCP server；大脑 = Claude Code / Codex CLI（官方订阅通道）。
完整设计：[docs/specs/2026-07-16-方向一-手机执行器与订阅大脑-design.md](docs/specs/2026-07-16-方向一-手机执行器与订阅大脑-design.md)

## 铁律

1. **合规红线**：Claude 订阅只经 Claude Code / Agent SDK 官方通道；ChatGPT Plus 只经 Codex CLI 官方登录；永不逆向两家网页端私有接口。
2. **A 开发会话不直接操作手机**。mobile MCP server 已不挂载。临时单跑真机：`claude --mcp-config configs/mobile-mcp.json`；成体系跑测走派单 wrapper `scripts/dispatch.ps1`（设计：[docs/specs/2026-07-17-执行harness-design.md](docs/specs/2026-07-17-执行harness-design.md)）。
3. **手机危险操作（发送/支付/删除类）永远两段式**：临界动作前停下汇报，人工确认后继续。开发任务授权不替代这道临界确认。

## 文档地图（按需读，不要全读）

| 要做什么 | 读什么 |
|---|---|
| 需要当前状态、候选或下一步 | [STATUS.md](STATUS.md)——显式按需读取，不自动展开历史 |
| 认领工作 / 判断是否需要真机验收 | [docs/backlog.md](docs/backlog.md)——A 负责协调、离线开发和 ask；C 负责固定候选真机验收；批次、待决策项与流转协议按对应节读取 |
| 改架构/产品设计 | docs/specs/ 对应篇 |
| 执行某个操作规程 | docs/runbooks/ 对应篇 |
| 设备/系统命令/App 特性/成本/链路等沉淀知识 | [docs/knowledge/README.md](docs/knowledge/README.md)——**渐进式披露单入口**：按「遇到什么情况→载入哪册」路由，不整目录读 |
| 派单跑真机 / 查台账 | [执行 harness spec](docs/specs/2026-07-17-执行harness-design.md) §4–§5；入口 scripts/dispatch.ps1；台账 docs/runs/ledger.csv |
| 核验历史跑测结论 | docs/runs/ 对应记录——按具体证据指针读取，不全目录展开 |

## 会话纪律

按职责和当前运行时选择模型，不把 A / C / 子代理固定到型号或推理档位；能力不足时说明缺口并调整分工。

1. **A 负责协调、离线开发与直接 ask，不设常驻 B。** 围绕当前目标完成已授权的常规工作；只在不可替代的决定上提问。相关补充和修复留在当前任务，只有用户明确要求才新建独立任务。
2. 最小摸底后委派可独立推进的工作，写清输入、验收标准与文件归属；A 继续并行工作并整合结果。**C 只验固定候选，不改代码**；失败时回报候选和证据，由 A 修复。
3. 按风险验证并保存可追溯证据，冻结候选遵守专用规程；检查入口、复核尺度、日志与重复失败处置见[离线开发与验证](docs/runbooks/离线开发与验证.md)。
4. 有实质状态变化时，A 在当前权威基线上整合 [STATUS](STATUS.md) 与 [backlog](docs/backlog.md)；新知识写入对应 knowledge 册。C 回报证据增量，不在旧候选上改写共享状态。

## 约定

- 文档与交流用中文。
- 设计说明命名：`docs/specs/YYYY-MM-DD-主题-design.md`。
- 跑测 trace 与记录进 `docs/runs/`，命名 `YYYY-MM-DD-主题.md`。
- 提交信息中文，一次逻辑变更一次提交。

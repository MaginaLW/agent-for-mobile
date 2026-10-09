# 手机 Agent 项目 · 开发指南

把已付费的 AI 订阅（Claude Pro / ChatGPT Plus）变成能替用户操作手机和平板各 App 的托管助手。
架构：设备端 = 无障碍执行器 + MCP server；大脑 = Claude Code / Codex CLI（官方订阅通道）。设计见 [方向一 spec](docs/specs/2026-07-16-方向一-手机执行器与订阅大脑-design.md)。

本文件面向开发会话（下文的 A 指协调与开发会话，C 指真机验收执行）。`scripts/dispatch.ps1` 派出的执行器大脑以派单提示词为准（Claude 侧在仓库根启动，会自动载入 CLAUDE.md），但同样受铁律 3 约束。

## 铁律

1. **合规红线**：Claude 订阅只经 Claude Code / Agent SDK 官方通道；ChatGPT Plus 只经 Codex CLI 官方登录；永不逆向两家网页端私有接口。
2. **开发会话不直接操作手机**：仓库不挂载 mobile MCP。成体系跑测走 `scripts/dispatch.ps1`（设计见 [执行 harness spec](docs/specs/2026-07-17-执行harness-design.md)）；临时单跑见下方“运行时差异”。
3. **危险操作（发送/支付/删除类）永远两段式**：临界动作前停下汇报，由现场用户在设备上可见的确认卡（ConfirmOverlay）确认后才继续。开发任务授权、PC 侧输入或 RESUME 都不能替代这道确认。

## 验收边界

- 真机验收只针对固定完整 SHA 的构建；验收方（C）只验不改代码，失败即冻结、保留证据，修复形成新候选。
- 已冻结或已消费的一次性运行不重跑；改变真机行为的提交只合验过的 SHA。
- 离线通过不替代真机证据；进度记录不构成运行许可。

分工、资源边界与排序见 [backlog §1–§3](docs/backlog.md)，验证、合并与开跑条件见 §7。

## 文档地图

| 要做什么 | 读什么 |
|---|---|
| 当前状态与卡点 | [STATUS.md](STATUS.md) |
| 待办、有效决定、批次规则 | [docs/backlog.md](docs/backlog.md) |
| 架构与产品设计 | docs/specs/ 对应篇 |
| 操作规程 | docs/runbooks/ 对应篇 |
| 离线检查入口 | [离线开发与验证](docs/runbooks/离线开发与验证.md) |
| 机器可读契约与 schema | docs/contracts/ |
| 设备、系统命令、App 特性、成本等沉淀知识 | [docs/knowledge/README.md](docs/knowledge/README.md)，按情况路由到单册 |
| 跑测记录与台账 | docs/runs/；台账 docs/runs/ledger.csv（harness spec §6） |
| 派单跑真机 | scripts/dispatch.ps1（harness spec §4 派单、§5 两段式确认） |

## 约定

- 文档与交流用中文；提交信息用中文。
- 设计说明：`docs/specs/YYYY-MM-DD-主题-design.md`；跑测记录：`docs/runs/YYYY-MM-DD-主题.md`。
- 按职责和当前运行时选择模型，不把 A / C / 子代理固定到型号或推理档位；能力不足时说明缺口并调整分工。
- 通用协作规则（委派、提问、验证尺度、提交粒度）沿用使用者的全局约定，本文件不重复。

## 运行时差异

| 项 | Claude Code | Codex CLI |
|---|---|---|
| 入口 | CLAUDE.md 导入本文件 | 本文件 |
| 订阅通道 | Claude Pro，经 Claude Code | ChatGPT Plus，经 Codex CLI 官方登录 |
| 派单 | `-Brain claude`（默认），`-Executor mobile` 或 `gateway` | `-Brain codex -Executor gateway`；codex + mobile 会被脚本拒绝 |
| 临时单跑真机 | `claude --mcp-config configs/mobile-mcp.json`（该文件是 Claude 的 `--mcp-config` 格式） | 不适用，走 dispatch |
| 子任务与提问 | 用当前运行时实际可用的工具；不假定 `AskUserQuestion` 等工具名或固定会话 ID | 同左 |
| 额度 | [cost.md](docs/knowledge/brain/cost.md) | 同左 |

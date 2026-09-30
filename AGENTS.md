# 手机 Agent 项目 · Codex 侧入口

> **命令源码来源**：本文 `scripts/dispatch.ps1` 用法对应 STATUS 中所列实现版本；从 main 阅读时先核对 [README 的源码来源](README.md)。文档同步不改变 main 中的脚本版本。

**共同开发指南只有一份：[CLAUDE.md](CLAUDE.md)。** 铁律、文档地图、会话纪律、命名与提交约定见该文件；本入口仅补充 Codex 的运行时差异，不把 Claude 工具名当作 Codex 工具名。

## Codex 侧与 CLAUDE.md 的差异

| 项 | Codex 侧的实际情况 |
|---|---|
| 订阅与通道 | ChatGPT Plus 只经 **Codex CLI 官方登录**；永不逆向网页端私有接口。这是铁律 1 在 Codex 侧的形态，红线本身不变。 |
| 派单 | `scripts/dispatch.ps1 -Brain codex -Executor gateway`；harness 与 Claude 侧共用同一套 trace / ledger / 两段式确认。 |
| 临时单跑真机 | mobile MCP 的 `configs/mobile-mcp.json` 是 **Claude Code 的 `--mcp-config` 格式**，Codex CLI 不吃这份文件；Codex 侧走 dispatch wrapper，不要照抄那条命令。 |
| 任务与回报 | 当前请求的子任务用本运行时的 subagent / collaboration 工具；只有用户明确要求才新建独立任务。A 在当前任务直接提问，管理已有任务时用实际可用工具与本次取得的 ID；不假定存在 `AskUserQuestion`、`ccd_session_mgmt` 或固定 session ID。工具不可用时报告具体缺口。 |
| 额度 | 见 [docs/knowledge/brain/cost.md](docs/knowledge/brain/cost.md)。 |

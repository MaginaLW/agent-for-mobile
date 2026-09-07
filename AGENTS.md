# 手机 Agent 项目 · Codex 侧入口

**共同开发指南只有一份：[CLAUDE.md](CLAUDE.md)。** 铁律、文档地图、会话纪律、命名与提交约定见该文件；本入口仅补充 Codex 的运行时差异，不把 Claude 工具名当作 Codex 工具名。

## Codex 侧与 CLAUDE.md 的差异

| 项 | Codex 侧的实际情况 |
|---|---|
| 订阅与通道 | ChatGPT Plus 只经 **Codex CLI 官方登录**；永不逆向网页端私有接口。这是铁律 1 在 Codex 侧的形态，红线本身不变。 |
| 派单 | `scripts/dispatch.ps1 -Brain codex -Executor gateway`；harness 与 Claude 侧共用同一套 trace / ledger / 两段式确认。 |
| 临时单跑真机 | mobile MCP 的 `configs/mobile-mcp.json` 是 **Claude Code 的 `--mcp-config` 格式**，Codex CLI 不吃这份文件；Codex 侧走 dispatch wrapper，不要照抄那条命令。 |
| 当前请求的子任务 | 用当前运行时可用的 subagent / collaboration 工具委派、等待与回报，不为 A / B / C 创建常驻任务。 |
| 用户独立任务 | 只有用户明确要求新建任务时才创建；管理已有任务时使用实际可用的任务工具，目标 ID 从当前任务或本次派单取得。 |
| 提问与回报 | A 在当前任务直接提问，按当前运行时支持的方式收回答案；不要假定存在 `AskUserQuestion`、`ccd_session_mgmt` 或固定 session ID。工具不可用时在当前任务报告具体缺口。 |
| 额度 | 见 [docs/knowledge/brain/cost.md](docs/knowledge/brain/cost.md)。 |

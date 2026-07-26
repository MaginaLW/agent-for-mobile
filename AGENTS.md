# 手机 Agent 项目 · Codex 侧入口

**开发指南只有一份：[CLAUDE.md](CLAUDE.md)。** 铁律、文档地图、会话纪律、命名与提交约定全部以它为准，
本文件不复制正文——此前这里是 CLAUDE.md 的机器替换副本，把「Claude→Codex」全局替换后
产出了三处事实错误（不存在的「Codex Pro」、把 Anthropic 的 Agent SDK 写成 Codex 通道、
以及 `Codex --mcp-config` 这种不存在的调用形态），而被替换歪的正是**合规红线**那一条。

## Codex 侧与 CLAUDE.md 的差异

| 项 | Codex 侧的实际情况 |
|---|---|
| 订阅与通道 | ChatGPT Plus 只经 **Codex CLI 官方登录**；永不逆向网页端私有接口。这是铁律 1 在 Codex 侧的形态，红线本身不变。 |
| 派单 | `scripts/dispatch.ps1 -Brain codex`；harness 与 Claude 侧共用同一套 trace / ledger / 两段式确认。 |
| 临时单跑真机 | mobile MCP 的 `configs/mobile-mcp.json` 是 **Claude Code 的 `--mcp-config` 格式**，Codex CLI 不吃这份文件；Codex 侧走 dispatch wrapper，不要照抄那条命令。 |
| 额度 | 见 [docs/knowledge/brain/cost.md](docs/knowledge/brain/cost.md)。 |

其余一切（三条铁律的内容、docs/ 结构、一个会话一个主题、大文件按行区间读、
收尾更新 STATUS.md 与 knowledge 册）与 CLAUDE.md 完全一致，请直接读那一份。

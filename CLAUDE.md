# 手机 Agent 项目 · 开发指南

把已付费 AI 订阅（Claude Pro / ChatGPT Plus）变成能替用户操作手机各 App 的托管助手。
架构一句话：手机 = 无障碍执行器 + MCP server；大脑 = Claude Code / Codex CLI（官方订阅通道）。
完整设计：[docs/specs/2026-07-16-方向一-手机执行器与订阅大脑-design.md](docs/specs/2026-07-16-方向一-手机执行器与订阅大脑-design.md)

@STATUS.md

## 铁律

1. **合规红线**：Claude 订阅只经 Claude Code / Agent SDK 官方通道；ChatGPT Plus 只经 Codex CLI 官方登录；永不逆向两家网页端私有接口。
2. **开发会话不直接操作手机**。mobile MCP server 已不挂载。临时单跑真机：`claude --mcp-config configs/mobile-mcp.json`；成体系跑测走派单 wrapper `scripts/dispatch.ps1`（设计：[docs/specs/2026-07-17-执行harness-design.md](docs/specs/2026-07-17-执行harness-design.md)）。
3. **危险操作（发送/支付/删除类）永远两段式**：临界动作前停下汇报，人工确认后继续。

## 文档地图（按需读，不要全读）

| 要做什么 | 读什么 |
|---|---|
| 改架构/产品设计 | docs/specs/ 对应篇 |
| 执行某个操作规程 | docs/runbooks/ 对应篇 |
| 设备/ROM/adb/输入问题 | [docs/knowledge/devices.md](docs/knowledge/devices.md) |
| 系统命令（dumpsys/cmd/svc/am/pm/settings）/Shizuku | [docs/knowledge/sys-cli.md](docs/knowledge/sys-cli.md)（🔵 多为查阅未实测） |
| 微信/小红书/京东特性 | [docs/knowledge/apps.md](docs/knowledge/apps.md) |
| 找深链 | [docs/knowledge/deeplinks.md](docs/knowledge/deeplinks.md) |
| 算成本账 | [docs/knowledge/cost.md](docs/knowledge/cost.md) |
| 大脑侧链路（headless/挂载/两段式） | [docs/knowledge/brain-harness.md](docs/knowledge/brain-harness.md) |
| 派单跑真机 / 查台账 | [执行 harness spec](docs/specs/2026-07-17-执行harness-design.md) §4–§5；入口 scripts/dispatch.ps1；台账 docs/runs/ledger.csv |
| 历史跑测记录 | docs/runs/（归档，只写不读） |

## 会话纪律

1. 一个会话一个主题；跨主题开新会话。
2. 广探索、长文阅读派子代理（Explore 类），只让结论进主上下文。
3. 构建日志、logcat、长命令输出先落盘（重定向到文件）再 grep/尾读，不整段读入。
4. 大文件按行区间读，不整读。
5. 会话收尾两件事：更新 STATUS.md；新踩的坑写入对应 knowledge 册。

## 约定

- 文档与交流用中文。
- 设计说明命名：`docs/specs/YYYY-MM-DD-主题-design.md`。
- 跑测 trace 与记录进 `docs/runs/`，命名 `YYYY-MM-DD-主题.md`。
- 提交信息中文，一次逻辑变更一次提交。

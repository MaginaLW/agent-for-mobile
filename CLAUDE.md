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
| 认领本会话该做什么 / 判断要不要流转会话 | [docs/backlog.md](docs/backlog.md)——工序三道（A 独立闭环 / B 你一个决定 / C 你在真机旁）、验收批次与流转协议 |
| 改架构/产品设计 | docs/specs/ 对应篇 |
| 执行某个操作规程 | docs/runbooks/ 对应篇 |
| 设备/系统命令/App 特性/成本/链路等沉淀知识 | [docs/knowledge/README.md](docs/knowledge/README.md)——**渐进式披露单入口**：按「遇到什么情况→载入哪册」路由，不整目录读 |
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

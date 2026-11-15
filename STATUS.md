# 项目状态

> 更新 2026-11-15。本页只写：现在能做什么、卡在哪、下一步。待办与有效决定见 [backlog](docs/backlog.md)。
> 2026-11-15 之前的过程记录、平板双窗研究和历史状态已移出主树，需要时用 `git show e1bae37:<路径>` 查看（如 `git show e1bae37:STATUS.md`）。

## 现在能做什么

| 能力 | 状态 | 依据 |
|---|---|---|
| 网关 App（无障碍 + MCP HTTP + 工具 + 安全门） | 历史手机上跑通；PA2553 上确认卡 overlay、开机恢复、中文 `ime_commit` 已真机验证 | [overlay 记录](docs/runs/2026-11-10-无障碍overlay确认卡真机验证.md)、[开机恢复](docs/runs/2026-11-12-网关开机恢复离线.md) |
| 派单（Codex CLI + gateway） | 可用；入口 `scripts/dispatch.ps1`，默认 `-Brain codex -Executor gateway` | [执行 harness spec](docs/specs/2026-07-17-执行harness-design.md) |
| 危险动作两段式硬门 | 已实现；本地 AVD 台架上 Allow/Stale 自动化链通过，真人在真机上的 Allow 尚未测 | [P0 规程](docs/runbooks/P0-safety-hard-gate-smoke.md)、[本地测试台](docs/runbooks/本地测试台.md) |
| 占位工具 | `notifications_list`、`notification_reply`、`ui_diff`、`app_stop` 仍是占位 | [能力现状](docs/knowledge/android/m1b-capabilities.md) |

## 卡在哪

第一个真实日常任务（小红书搜索并总结 5 条公开笔记，即 M0 任务 3）还没跑通：上次尝试在派单前置检查停在 `gateway_a11y_not_ready`——系统设置里无障碍服务已启用，但没有绑定。原因未知；vivo 安全中心会撤销或解绑第三方无障碍服务，见 [vivo 记录](docs/knowledge/android/vivo-originos.md)。过程见 [小红书记录](docs/runs/2026-11-14-小红书单窗口只读准备.md)。

## 下一步

1. 在平板上重新打开网关无障碍服务（必要时先关再开或重启），确认已绑定，再派一次小红书只读任务。
2. 跑通后，用自研网关把 M0 的 5 个验收任务都跑一遍，和 M0 的 4.5/5 对比（M1 的验收标准）。
3. 草稿 PR [#13](https://github.com/MaginaLW/agent-for-mobile/pull/13)（Codex 派单兼容与网关配置修复，派单要用）待决定是否合入 main；[#12](https://github.com/MaginaLW/agent-for-mobile/pull/12)（P0 取证修复）同样待定。

## 已放弃或暂停

- **平板双窗（微信同 App 双 OS window）适配**：拿不到可验证的同代窗口来源，微信无障碍树也读不到内容，结论 NO-GO。研究代码已于 2026-11-15 删除，结论保留在 [平板知识](docs/knowledge/android/tablet.md)。平板目前按单窗口使用。
- 手机批次 4（语义意图四腿）、语义意图生产接线：暂停。
- M2（Claude/Termux 上机）：取消。M3（宏、入口、技能包）：未开始。

## 里程碑

| 里程碑 | 状态 |
|---|---|
| M0 mobile-mcp 真机验收 | 完成（2026-07-16，4.5/5，[记录](docs/runs/2026-07-16-M0.md)） |
| M1 自研网关 | 网关可用；验收标准（5 任务成功率 ≥ M0）未在当前设备上跑过 |
| M1-T 平板 | T0-L 入场完成；双窗路线放弃，按单窗口使用 |
| M2 大脑上机 | 取消 |
| M3 宏、入口、技能包 | 未开始 |

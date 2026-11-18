# 项目状态

> 更新 2026-11-18。本页只写：现在能做什么、卡在哪、下一步。待办与有效决定见 [backlog](docs/backlog.md)。
> 2026-11-15 之前的过程记录、平板双窗研究和历史状态已移出主树，需要时用 `git show e1bae37:<路径>` 查看（如 `git show e1bae37:STATUS.md`）。

## 现在能做什么

| 能力 | 状态 | 依据 |
|---|---|---|
| 网关 App（无障碍 + MCP HTTP + 工具 + 安全门） | 历史手机上跑通；PA2553 上确认卡 overlay、开机恢复、中文 `ime_commit` 已真机验证；2026-11-16 对齐普通具名点击、常规回车、黑名单出站与同应用平行视界规则（待真机验收） | [overlay 记录](docs/runs/2026-11-10-无障碍overlay确认卡真机验证.md)、[开机恢复](docs/runs/2026-11-12-网关开机恢复离线.md)、[设定对齐 spec](docs/specs/2026-11-16-网关与派单设定对齐-design.md) |
| 派单（Codex CLI + gateway） | 可用；入口 `scripts/dispatch.ps1`（固定 `codex + gateway`），内建预检与自启恢复 | [执行 harness spec](docs/specs/2026-07-17-执行harness-design.md)、[设定对齐 spec](docs/specs/2026-11-16-网关与派单设定对齐-design.md) |
| 危险动作两段式硬门 | 已实现；本地 AVD 台架上 Allow/Stale 自动化链通过，真人在真机上的 Allow 尚未测；ConfirmOverlay 默认超时 90s | [P0 规程](docs/runbooks/P0-safety-hard-gate-smoke.md)、[本地测试台](docs/runbooks/本地测试台.md) |
| 占位工具 | `notifications_list`、`notification_reply`、`ui_diff`、`app_stop` 已从 `tools/list` 下架，按需实施时再挂回 | [能力现状](docs/knowledge/android/m1b-capabilities.md)、[设定对齐 spec](docs/specs/2026-11-16-网关与派单设定对齐-design.md) |

## 卡在哪

11 月 17 日的一次派单有 3 次网关调用成功、2 次向本机网关发送 HTTP 请求失败。断点尚未定位。11 月 18 日已修复预检对既有服务和端口转发的归属判断、前台未知时仍尝试重绑、同包窗口被替换时沿用旧身份，以及派单台账误把网关工具失败记为传输故障。预检与派单归因已通过离线回归，PA2553 上的表现待验。

第一个真实日常任务（小红书搜索并总结 5 条公开笔记，即 M0 任务 3）还没跑通：上次尝试在派单前置检查停在 `gateway_a11y_not_ready`——系统设置里无障碍服务已启用，但没有绑定。原因未知；vivo 安全中心会撤销或解绑第三方无障碍服务，见 [vivo 记录](docs/knowledge/android/vivo-originos.md)。过程见 [小红书记录](docs/runs/2026-11-14-小红书单窗口只读准备.md)。2026-11-16 已定契约：不关闭 `com.vivo.safecenter`，由 `dispatch.ps1` 预检在非设置页前台下执行单次有界无障碍重绑。

## 下一步

1. 在 PA2553 上用对齐后的网关与 `dispatch.ps1` 预检跑通小红书只读任务（M0 任务 3）。
2. 跑通后，用非微信日常任务集（M0-3 小红书总结、M0-5 京东/淘宝查物流 + 确认卡演练/系统任务；M0-1 蓝牙若触发 `safecenter` 则记录为 ROM 边界或待 Shizuku）完成 PA2553 上的 M1 主验收；微信两项保留后置，不阻塞 M1 收官。
3. 存量草稿 PR 处置建议：先合入 [#13](https://github.com/MaginaLW/agent-for-mobile/pull/13) → 再合入 [#17](https://github.com/MaginaLW/agent-for-mobile/pull/17)；[#12](https://github.com/MaginaLW/agent-for-mobile/pull/12)（微信 P0 移植，微信当前后置）建议关闭或搁置；之后合入本轮设定对齐分支。

## 2026-11-15 精简

按用户要求处理过度建设（[PR #17](https://github.com/MaginaLW/agent-for-mobile/pull/17)）：删除平板双窗研究栈、M1 spike 探针和派单中已退役的 Claude 分支；STATUS/backlog/README/AGENTS 压缩，历史过程记录移出主树。跟踪文件 484 → 240，完整离线门 19 项约 15 分钟 → 9 项约 3.5 分钟，9/9 通过；未做真机验证。

## 已放弃或暂停

- **平板双窗（微信同 App 双 OS window）适配**：拿不到可验证的同代窗口来源，微信无障碍树也读不到内容，结论 NO-GO。研究代码已于 2026-11-15 删除，结论保留在 [平板知识](docs/knowledge/android/tablet.md)。生产网关改用「单窗口与同应用平行视界支持、跨应用分屏/小窗 fail-closed」三层窗口策略，详见 [设定对齐 spec](docs/specs/2026-11-16-网关与派单设定对齐-design.md)。
- 手机批次 4（语义意图四腿）、语义意图生产接线：暂停。
- M2（Claude/Termux 上机）：取消。M3（宏、入口、技能包）：未开始。

## 里程碑

| 里程碑 | 状态 |
|---|---|
| M0 mobile-mcp 真机验收 | 完成（2026-07-16，4.5/5，[记录](docs/runs/2026-07-16-M0.md)） |
| M1 自研网关 | 网关可用；分阶段主验收（非微信日常任务集同口径对比 M0）未在当前设备上跑通 |
| M1-T 平板 | T0-L 入场完成；微信双窗研究路线放弃，生产网关支持单窗口与同应用平行视界（跨应用/未知多窗 fail-closed） |
| M2 大脑上机 | 取消 |
| M3 宏、入口、技能包 | 未开始 |

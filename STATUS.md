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

## 11 月 18 日修复与离线验证

派单预检现在只回收本轮创建的服务和端口转发，前台应用未知时停止重绑。同包切窗只有在新旧窗格都可见时才沿用身份。派单台账区分网关工具失败和传输失败，凭据扫描也能识别紧邻中文或重音字母的 token。[台账判读方法](docs/knowledge/brain/harness.md)

这批修复的最后一个代码提交为 `9c69577`。完整离线检查 9/9 通过，含派单回归 56 项、监督式 runner 89 项。Android Debug 476 项、Release 379 项单测均通过，两个版本的 Lint 和构建也已通过。本轮未做真机验收。

## PA2553 小红书实测（2026-11-18）

提交 `a9aee63` 修复了搜索框将字段标签并入无障碍读回时的误判。修复版真机已通过中文输入、精确读回和点击「搜索」提交。该提交的完整离线检查 9/9 通过，Android Debug 477 项、Release 380 项单测通过。两次临时切换输入法后均已恢复原设置并逐项读回。[真机验收记录](docs/runs/2026-11-18-PA2553小红书只读验收.md)

执行器在小红书内提交「东京三日游」后，结果页一度空白。用户切换页面、看到内容后，执行器沿用该查询，98 秒内按顺序核对五条笔记并汇总，三条来自详情、两条来自列表。M0-3 的搜索和阅读均有真机证据，中间有现场协助。八次派单中两次成功、六次失败均已入账。[五条笔记与各轮结果](docs/runs/2026-11-18-PA2553小红书只读验收.md#修复版提交查询后的五条笔记)

## 卡在哪

11 月 17 日的一次派单有 3 次网关调用成功、2 次向本机网关发送 HTTP 请求失败。具体断点仍未知。

11 月 18 日的八次派单均通过预检。小红书结果页空白的原因仍未知，尚缺从提交到读完五条全程无需现场协助的记录。此前的无障碍解绑和桌面深链被系统弹窗阻挡各有独立记录，长期绑定稳定性仍待观察。[无障碍记录](docs/knowledge/android/vivo-originos.md) · [小红书实测](docs/knowledge/apps/xiaohongshu.md)

## 下一步

1. 用剩余非微信任务完成 PA2553 上的 M1 主验收，包括 M0-5 京东/淘宝查物流、确认卡演练或系统任务。对照 M0 时注明小红书本次的现场协助。蓝牙任务若触发 `safecenter` 则记录为 ROM 边界；微信两项保留后置。
2. 设定对齐与本轮修复在草稿 PR #18，合入 main 待用户批准。此前的 #13、#17 已合入，微信 P0 移植 #12 已关闭。[PR #18](https://github.com/MaginaLW/agent-for-mobile/pull/18)

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

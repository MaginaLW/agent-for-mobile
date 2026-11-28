# 网关 M1b 能力现状与后置范围

> 2026-09-27 基于协调 checkout `a253c8f` 首次静态核对；2026-11-16 已按[网关与派单设定对齐 spec](../../specs/2026-11-16-网关与派单设定对齐-design.md#18-工具面与退役残余清理)同步工具下架与能力位状态；2026-11-28 阶段 6B-3a 已完成只读 `notifications_list` 接入并通过 PA2553 真机全矩阵验收（未授权 `E_PERM_MISSING` → 授权隔离读取 `self_excluded_count=1` → 支付宝直查 `E_BLOCKED` → 撤销恢复 `E_PERM_MISSING`，见[11-28 验收记录](../../runs/2026-11-28-PA2553-阶段6B-3a通知只读通道真机验收.md)）。设备与批次状态仍以 [backlog](../../backlog.md) 和 [STATUS](../../../STATUS.md) 为准。下表中未实施的 M1b 占位能力维持从 `tools/list` 下架未注册，待真实实施并接入对应通道时再挂回；真实调用也可能先被黑名单或安全门阻断。

## 当前可调用范围

| 能力 | 代码现状 | 调用时的实际结果或边界 |
|---|---|---|
| `ui_snapshot`、`ui_find` | 已接 [UiTools](../../../app/gateway/src/main/java/dev/magina/gateway/tools/UiTools.kt) 和 [GatewayA11yService](../../../app/gateway/src/main/java/dev/magina/gateway/a11y/GatewayA11yService.kt)；前台树空或稀疏时尝试 OCR 融合 | 依赖无障碍与截图通道；OCR 失败时快照降级为纯 a11y，并给出 note。可用全量快照代替 `ui_diff`，但不能据此声称差量已实现。 |
| `system_set_state(volume, value)` | [SystemTools](../../../app/gateway/src/main/java/dev/magina/gateway/tools/SystemTools.kt) 通过 `AudioManager` 写入并读回 | 返回 `applied`、`verified`、`actual`；其余 key 直接报 `E_CHANNEL_DOWN`，提示设置页 UI 路径。`system_verify_state` 当前复用普通 `getState`，不是 Shizuku `dumpsys` 交叉复核。 |
| `app_launch` | 走 launcher Intent，并等待前台包名；返回 `foreground_verified` | `foreground_verified=false` 不等于落地成功；历史 ROM 后台启动限制见 [vivo 记录](vivo-originos.md)。这也不能代替强停。 |
| `notifications_list`（R） | 阶段 6B-3a 已注册进 [ToolCatalog](../../../app/gateway/src/main/java/dev/magina/gateway/mcp/ToolCatalog.kt)（`Level.R`，channel=`"notif"`），并接入受 `BIND_NOTIFICATION_LISTENER_SERVICE` 保护的 [GatewayNotificationListenerService](../../../app/gateway/src/main/java/dev/magina/gateway/notification/GatewayNotificationListenerService.kt) 与 [NotificationSnapshotPolicy](../../../app/gateway/src/main/java/dev/magina/gateway/notification/NotificationSnapshotPolicy.kt) | 仅只读有限字段快照（支持可选 `package`/`limit` 1..50，不传递 `PendingIntent`/`RemoteInput`，按 `VISIBILITY_SECRET`/空内容脱敏）；严格区分未授权或读取遭拒（`E_PERM_MISSING`）、服务断开或查询失败（`E_CHANNEL_DOWN`）与真实空列表，彻底隔离敏感黑名单应用与网关自身审批通知（显式请求黑名单 `package` 报 `E_BLOCKED`）。**2026-11-28 已在 PA2553（`1a772ef`）通过未授权→授权→黑名单直查→撤销全矩阵真机验收**（[11-28 验收记录](../../runs/2026-11-28-PA2553-阶段6B-3a通知只读通道真机验收.md)）。 |
| `notification_reply`（D） | 已于 2026-11-16 从注册表下架，维持下架未注册；没有读取通知动作与 RemoteInput 发送的实现 | 未注册进 `tools/list`，不存在通知回复能力；待实施并接入 D 级两段式确认与绑定后才挂回。 |
| `ui_diff`（R） | 已于 2026-11-16 从注册表下架，维持下架未注册；`UiTools.uiDiff` 原先直接抛 `E_CHANNEL_DOWN` | 未注册进 `tools/list`；调用方改用全量 `ui_snapshot`。现有快照 revision 与 ref 有效性不构成历史差量缓存。 |
| `app_stop`（W） | 已于 2026-11-16 从注册表下架，维持下架未注册；`SystemTools.appStop` 原先直接抛 `E_CHANNEL_DOWN`，没有 Shizuku 执行路径 | 未注册进 `tools/list`；`press_key(home)` 只是置后台，不是强停。`am force-stop` 仅在 [系统 CLI 候选册](sys-cli.md) 中备料。 |

[Gateway.caps()](../../../app/gateway/src/main/java/dev/magina/gateway/Gateway.kt) 当前上报 `a11y`、`ime`、`ime_active`、`overlay`、`ocr`（2026-11-16 设定对齐后补报 `"ocr"`），并在 `GatewayNotificationListenerService.isConnectedAndGranted` 成立（已授通知使用权且监听服务已连接）时动态上报 `"notif"`（2026-11-28 PA2553 实测确认授/撤即时增减）；`shizuku` 仍是注释占位，不能凭设计文档认定 Shizuku 已接线。`notifications_list` 已支持可选 `package` 与 `limit` 参数，但[设计表](../../specs/2026-07-17-M1执行网关-design.md)另列的 `notification_actions`、`notification_open` 与 `notification_reply` 仍不在注册表（维持下架未注册）。现行确认通知仅支持拒绝和查看证据，批准来源按 [当前通知设计](../../specs/2026-08-01-通知栏审批布局-design.md) 的可见确认卡决定。

## 按需求启用时的最小实施与验收

这些是后续任务边界，**本页不启用新工具或新增设备批次**。先明确产品任务需要哪一项，再单独实现其通道和失败路径；不能用公开工具数量充当验收指标。

| 后续能力 | 实施范围 | 必验失败路径 |
|---|---|---|
| 通知读取 | 阶段 6B-3a 已接入 `GatewayNotificationListenerService` + `NotificationSnapshotPolicy`，处理系统授权、连接状态和有限字段只读读取；明确哪些字段因 `VISIBILITY_SECRET` 或通知内容不可用而脱敏 | 未授权/授权撤销（`E_PERM_MISSING`）、服务断开/查询失败（`E_CHANNEL_DOWN`）、通知撤回、敏感内容缺失须分别与真实空列表区分；不读取到内容时不得编造清单。**2026-11-28 已通过 PA2553 未授权→授权→黑名单直查→撤销真机验收（[11-28 验收记录](../../runs/2026-11-28-PA2553-阶段6B-3a通知只读通道真机验收.md)）。** |
| 通知回复 | 先由 [S5 RemoteInput](../../backlog.md) 核定目标 app 的动作可用性；仅对有 RemoteInput 的通知实现一次性发送，保留 D 级确认与动作参数绑定 | 无回复动作、通知或 action 失效、拒绝/超时/确认后目标变化、`PendingIntent.send` 失败，以及发送已受理但落地未知；handler 不可在确认前执行，不可把 `send` 返回当作已投递。不得改走另一条发送路径重试同一危险动作。 |
| UI 差量 | 若全量快照的实际成本证明需要，再建立有界、同会话的历史快照和明确的差量契约；OCR 视觉变化也要纳入或明确降级 | 未知/过旧/跨会话 revision、页面或前台变化、缓存淘汰、OCR 变化而 a11y revision 未变；不能静默遗漏元素，须返回明确错误或可识别的全量回退。 |
| Shizuku 系统写与强停 | 仅在具体任务需要时接入 Shizuku；保留类型化白名单、包名/参数校验、命令审计和执行后真值复核，不暴露裸 shell | 服务未启动、授权拒绝/撤销、重启后失活、命令非零退出、真值不匹配与 app 自动重启分别验收；读回不符报 `E_VERIFY_FAIL`，`home` 不作强停成功证据。S2 重启存活仍待设备核定。 |

通知批准路径、UI 点击和对外发送原有安全门不能因接入新通道而放宽。上表需设备的验收应依 [backlog 的批次约束](../../backlog.md)排期。审查问题原始入口见 [09-27 项目审查](https://github.com/MaginaLW/agent-for-mobile/blob/e1bae376217fc75b13094b2b04858ab93e692a29/docs/runs/2026-09-27-项目审查与待办.md)。

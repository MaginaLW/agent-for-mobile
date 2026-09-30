# 网关 M1b 能力现状与后置范围

> **源码索引**：本轮仅将源码文件索引绑定候选 `2a4ccdb82783046c987689bb28d5d89000f4284d`；本页保留 2026-09-27 静态盘点，不新增能力实现、源码专项或真机验收结论。当前阶段以 STATUS/backlog 为准。

> 2026-09-27，基于协调 checkout `a253c8f` 的源码静态核对。这里记录**当前代码路径**，不是本轮真机验收或新候选结论；设备与批次状态仍以 [backlog](../../backlog.md) 和 [STATUS](../../../STATUS.md) 为准。`tools/list` 会逐条列出 [ToolRegistry](https://github.com/MaginaLW/agent-for-mobile/blob/2a4ccdb82783046c987689bb28d5d89000f4284d/app/gateway/src/main/java/dev/magina/gateway/mcp/ToolRegistry.kt) 的注册项，但注册不代表 handler 已能完成操作。下表的占位错误指请求通过前置拦截、到达 handler 之后；真实调用也可能先被黑名单或安全门阻断。

## 当前可调用范围

| 能力 | 代码现状 | 调用时的实际结果或边界 |
|---|---|---|
| `ui_snapshot`、`ui_find` | 已接 [UiTools](../../../app/gateway/src/main/java/dev/magina/gateway/tools/UiTools.kt) 和 [GatewayA11yService](https://github.com/MaginaLW/agent-for-mobile/blob/2a4ccdb82783046c987689bb28d5d89000f4284d/app/gateway/src/main/java/dev/magina/gateway/a11y/GatewayA11yService.kt)；前台树空或稀疏时尝试 OCR 融合 | 依赖无障碍与截图通道；OCR 失败时快照降级为纯 a11y，并给出 note。可用全量快照代替 `ui_diff`，但不能据此声称差量已实现。 |
| `system_set_state(volume, value)` | [SystemTools](https://github.com/MaginaLW/agent-for-mobile/blob/2a4ccdb82783046c987689bb28d5d89000f4284d/app/gateway/src/main/java/dev/magina/gateway/tools/SystemTools.kt) 通过 `AudioManager` 写入并读回 | 返回 `applied`、`verified`、`actual`；其余 key 直接报 `E_CHANNEL_DOWN`，提示设置页 UI 路径。`system_verify_state` 当前复用普通 `getState`，不是 Shizuku `dumpsys` 交叉复核。 |
| `app_launch` | 走 launcher Intent，并等待前台包名；返回 `foreground_verified` | `foreground_verified=false` 不等于落地成功；历史 ROM 后台启动限制见 [vivo 记录](vivo-originos.md)。这也不能代替强停。 |
| `notifications_list`（R） | [ToolRegistry](https://github.com/MaginaLW/agent-for-mobile/blob/2a4ccdb82783046c987689bb28d5d89000f4284d/app/gateway/src/main/java/dev/magina/gateway/mcp/ToolRegistry.kt) 的固定 stub；[Manifest](https://github.com/MaginaLW/agent-for-mobile/blob/2a4ccdb82783046c987689bb28d5d89000f4284d/app/gateway/src/main/AndroidManifest.xml) 未声明 `NotificationListenerService` | handler 报 `E_CHANNEL_DOWN`；目前没有通知清单。兜底是打开目标 app，用 UI 读取。网关自己发出的确认通知不等于通知监听层。 |
| `notification_reply`（D） | 固定 stub；没有读取通知和 RemoteInput 发送的实现 | handler 报 `E_CHANNEL_DOWN`，不存在通知回复能力。D 级调用会先经过 [SafetyGate](https://github.com/MaginaLW/agent-for-mobile/blob/2a4ccdb82783046c987689bb28d5d89000f4284d/app/gateway/src/main/java/dev/magina/gateway/core/SafetyGate.kt)，可能先要求真人确认；通过确认也不会让 stub 发送。不要为了探测可用性而调用它。 |
| `ui_diff`（R） | `UiTools.uiDiff` 直接抛 `E_CHANNEL_DOWN` | `since_revision` 当前未被消费；调用方改用全量 `ui_snapshot`。现有快照 revision 与 ref 有效性不构成历史差量缓存。 |
| `app_stop`（W） | `SystemTools.appStop` 直接抛 `E_CHANNEL_DOWN`；没有 Shizuku 执行路径 | `press_key(home)` 只是置后台，不是强停。`am force-stop` 仅在 [系统 CLI 候选册](sys-cli.md) 中备料。 |

[Gateway.caps()](../../../app/gateway/src/main/java/dev/magina/gateway/Gateway.kt) 当前只报告 `a11y`、`ime`、`ime_active`、`overlay`；`shizuku`、`notif`、`ocr` 仍是注释。**OCR 代码已接入快照，但没有 `ocr` 能力位**；不能只凭能力位否定它，也不能只凭工具名或设计文档认定 Shizuku、通知层已接线。[设计表](../../specs/2026-07-17-M1执行网关-design.md)另列的 `notification_actions`、`notification_open` 不在注册表；`notifications_list` 也尚无设计中的 package/limit 参数，不能拿设计表当现行接口。现行确认通知仅支持拒绝和查看证据，批准来源按 [当前通知设计](../../specs/2026-08-01-通知栏审批布局-design.md) 的可见确认卡决定。

## 按需求启用时的最小实施与验收

这些是后续任务边界，**本页不启用新工具或新增设备批次**。先明确产品任务需要哪一项，再单独实现其通道和失败路径；不能用公开工具数量充当验收指标。

| 后续能力 | 实施范围 | 必验失败路径 |
|---|---|---|
| 通知读取 | 注册 `NotificationListenerService`，处理系统授权、连接状态和有限字段读取；说明哪些字段因系统或通知内容不可见 | 未授权/授权撤销、服务断开、通知撤回、敏感内容缺失须分别与真实空列表区分；不读取到内容时不得编造清单。 |
| 通知回复 | 先由 [S5 RemoteInput](../../backlog.md) 核定目标 app 的动作可用性；仅对有 RemoteInput 的通知实现一次性发送，保留 D 级确认与动作参数绑定 | 无回复动作、通知或 action 失效、拒绝/超时/确认后目标变化、`PendingIntent.send` 失败，以及发送已受理但落地未知；handler 不可在确认前执行，不可把 `send` 返回当作已投递。不得改走另一条发送路径重试同一危险动作。 |
| UI 差量 | 若全量快照的实际成本证明需要，再建立有界、同会话的历史快照和明确的差量契约；OCR 视觉变化也要纳入或明确降级 | 未知/过旧/跨会话 revision、页面或前台变化、缓存淘汰、OCR 变化而 a11y revision 未变；不能静默遗漏元素，须返回明确错误或可识别的全量回退。 |
| Shizuku 系统写与强停 | 仅在具体任务需要时接入 Shizuku；保留类型化白名单、包名/参数校验、命令审计和执行后真值复核，不暴露裸 shell | 服务未启动、授权拒绝/撤销、重启后失活、命令非零退出、真值不匹配与 app 自动重启分别验收；读回不符报 `E_VERIFY_FAIL`，`home` 不作强停成功证据。S2 重启存活仍待设备核定。 |

通知批准路径、UI 点击和对外发送原有安全门不能因接入新通道而放宽。上表需设备的验收应依 [backlog 的批次约束](../../backlog.md)排期；本次只完成离线能力标注，没有执行 dispatch、ADB、Gradle 或真机操作。审查问题原始入口见 [09-27 项目审查](../../runs/2026-09-27-项目审查与待办.md)。

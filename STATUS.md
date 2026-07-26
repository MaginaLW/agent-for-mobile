# 项目状态

> 每次会话收尾更新。保持 ≤ 20 行。

- **当前阶段：P0 安全硬门已在真机端到端跑通（2026-07-26 17:21），只差"消息真的发出去"这一条后置。** 那轮 `macro_run` ✅ → `type_text` ✅ → **确认卡弹出、真人「允许本次」、`press_key(enter)` 返回 `ok:true`（`confirmation=allowed;context=rechecked`）** ✅ → `ui_find` ✅。两段式硬门、确认卡内容完整性、确认前后上下文复核、证据链、审计采集全部有真机证据。
- **卡住的最后一环是发送本身，且真因大概率不是通道**：`performEditorAction(IME_ACTION_SEND)` 与单行框 `KEYCODE_ENTER` 微信都不响应。收尾时翻出我们**自己的** [apps/wechat.md](docs/knowledge/apps/wechat.md)（2026-07-22 写的）：**微信「使用回车键发送消息」开启时 `ACTION_IME_ENTER` 才触发发送**。该开关默认关闭时微信压根没把回车接到发送上——`imeOptions` 声明 `IME_ACTION_SEND` 只决定键盘画什么键。排查时只读通用册没读 app 册，为此多烧两轮真机；已写进 runbook §3.0。
- **今天修掉并各自有真机证据的四处**（细节见 [android/common.md](docs/knowledge/android/common.md) #19–#23）：①前台身份 unknown 无原因可查 → `ctx.foreground_reason` + `foreground_app` 扩成只读诊断；②自家确认卡是**可获焦 overlay**，抢窗口焦点同时造成"前台 unknown"与"IME 会话换新"两种症状 → 加 `FLAG_NOT_FOCUSABLE`（`settledWindows` 有界重读留作兜底）；③确认卡取证缺口闭合——按卡的位置与底色核实截图、没拍到就重拍，证据图里卡已完整可见；④`run-as` 在 Android 11+ 读不了自己的 external files 目录（普通 `adb shell` 反而读得到），审计采集一直是坏的，而它藏在 ToolSearch 误杀后面。
- **危险动作的返回值必须由后验决定**：`performEditorAction` 只要连接活着就返回 true，微信不理会时照样"成功"。已加发送后验（**只判定、绝不换通道重试**——后验失败时可能其实已发出，重试等于冒重复发送）。后验自身还踩过一次假阳性：基线用了 Enter 前那次 OCR 读回的噪声串，已改用已提交文本原文。那次是 runner 侧独立后验兜住的。
- **harness 三处摩擦已修**（离线 dispatch 17/17、runner 36/36）：①派单锁按"能否独占打开"判活，崩溃残锁自动清；②`--allowedTools` 只是免确认名单——执行器真在本机跑起了 `Bash`，已补 `--disallowedTools`，越权扫描改为**失败路径上也跑**并写进 manifest；③开跑前零 token 预检（R 级 `p0_probe_region_state`，判据与宏共用同一实现），残留文字与"没停在会话页"都在派单之前拦下。顺带堵掉潜伏阻塞：`ToolSearch` 此前会被 trace 审计当成越权，Allow 腿一跑通就会被它当场判死。
- **下一步**：①微信里打开 设置→聊天→**使用回车键发送消息**，重跑一轮 Allow——这一轮直接判定 P0 能否整体通过；②若仍不发，再谈通道决策（IME 显示极简输入视图逼出发送按钮 / 换一个对回车有反应的目标验证发送后验 / 等 Shizuku 注入真实按键）；③冷启动自举（服务重启后 `foreground_reason:identity_unset`，本轮已活体复现）。随后 D3、Shizuku、IME 自动切换及任务 4/2 端到端链路。
- **设备状态**：输入法已切回搜狗；手机上是最新 debug APK（含发送后验修正，**该修正尚未真机验证**）。跑 runner 前**不要手动改设备状态**——我这轮手动切过 IME，导致 runner 把"原输入法"记成了网关。
- **遗留/障碍**：Stale 腿与 Deny 腿尚未在新链路下复跑；`Start-P0TargetApp` 跳过 `am start` 的副作用（服务重启后前台身份 unknown）仍靠人工绕过，正式修法是 tracker 冷启动自举；S5 RemoteInput、S2 Shizuku 重启存活、`dispatch.ps1 -Confirm` 收口、`share_file` activity 级 verify 待补；Codex 订阅额度 2026-07-30 恢复（非阻塞）。

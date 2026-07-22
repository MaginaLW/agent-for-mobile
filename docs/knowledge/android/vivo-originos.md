# vivo / OriginOS（主力测试机：V2352A · X100 系列，Android 16，1260×2800）

> 来源：M0/M0.5 实测（2026-07-16/17）。原始记录：[../../runs/2026-07-16-M0.md](../../runs/2026-07-16-M0.md)。品牌开关完整矩阵见 [M0 runbook §1.1](../../runbooks/M0-runbook.md)。

## 调试与注入

- **「USB 模拟点击」开关必开**，否则注入报 SecurityException；开了之后 tap/swipe 完全正常（实测确认）。
- OriginOS 5 有 ADB 白名单：一直 unauthorized 就检查「USB 调试 → 仅允许指定计算机调试」。
- 保活：网关/探针类 App 需电池白名单 + 后台高耗电允许，防无障碍服务被静默回收。**仅此不够（2026-07-22 实锤被清）**：还须在最近任务把卡片**锁定**；进程死亡会**静默回退当前输入法**为 vivo 默认（自有 IME 被摘，恢复后要重切并重验）。
- **「执行网关」注入型 IME 无可见键盘窗口**（2026-07-22 实锤）：切为当前输入法后 `mIsInputViewShown=false`、windows 列表无 TYPE_INPUT_METHOD 窗口 → 网关 `keyboard.visible` 恒 `false`，**不可作为聚焦判据**；但 InputConnection/焦点（`mServedView`）可长时间存活（实测 ≥5 分钟不掉）。聚焦核对用 `dumpsys input_method` 的 `mServedView` 或直接以 IME commit 结果判定。
- **fgActivity 事件流污染 → 确认后 stale 误杀**（根因由 2026-07-22 P0 允许腿真机实锤；D1 已完成离线严格修复，真机待复测）：确认卡自身 overlay 的窗口事件把事件流维护的 fgActivity 写成 `android.widget.FrameLayout`，SafetyGate 确认后复核判「前台已变」→ `E_STALE_REF`（用户已允许仍不执行，安全方向误杀）。离线修复已将 package/activity 按活动 `TYPE_APPLICATION` windowId 原子归属，显式区分 `Known/Unknown`，并在 `Unknown` 时阻断 W/D；允许腿与 stale 腿仍须经受控派单真机复测，不得据此视为真机已修。
- **开发期开无障碍服务免手动，但不持久**（S2/S3 实测，2026-07-17/18）：`adb shell settings put secure enabled_accessibility_services <pkg/svc>` + `settings put secure accessibility_enabled 1` 两键同置，OriginOS6 下**异步生效 ~3s**（同一命令内立即 `get` 读到空是正常，下次读即有），服务随即 `connected`。⚠️ 两个坑：① **`input tap` 点无障碍详情页的启用开关无效**（反自动化拦截），settings 路径可绕过；② **settings 路径开启的服务数小时后被系统撤销**（实测 22:22→01:24 之间两键被清+服务进程回收，疑似午夜/空闲策略）。开发期对策：**每次跑测前重放两条 put**（恢复即时）；持久启用需设置 UI 手动开 + 电池白名单 + 后台高耗电允许（真实用户场景 M2 必须走 UI 引导）。
- **`adb install -r` 重装两连坑**（M1b 实测，2026-07-19）：① a11y 服务**不自动重绑**，且 settings 值没变化时重放同值 put 无效——须**先清空再重写**（toggle）强制重绑；② **运行时权限被重置**（READ_MEDIA_IMAGES 实测 granted=false，且 MediaStore 无权限时**静默空游标不抛异常**，工具层要显式预检）→ 每次重装后重放 `pm grant`。开发期 bring-up 固定链：install -r → pm grant → a11y toggle → am start 主界面 → tap「启动网关服务」→ adb forward。
- **网关后台启动三方 app activity 被拦（BAL）**（M1b 实测，2026-07-19）：网关在后台时 `app_launch(微信)`/`share_file` 直达组件**不落前台**（无异常、无 logcat 拦截日志、`foreground_verified:false`），但 `app_launch(设置)`（系统 app）放行；shell `am start` 不受限。与「后台弹出界面」权限同族（Android16 SDK36 收紧 SAW 豁免）。spike 当天 share_file 成功疑因网关刚离开前台仍在 BAL 宽限窗。对策：授 vivo「后台弹出界面」权限（待验）或 M1b Shizuku `am start` 通道。
- **系统窗口事件污染前台包名跟踪**（M1b 实测）：`TYPE_WINDOW_STATE_CHANGED` 会来自 vivo 悬浮层（pkg=android 等），事件流维护的 fgPackage 短暂错值（实测 ctx.app=android）→ **前台归属判定要用 windows 列表 `type=APPLICATION && isActive`**，不能只信事件流（网关 snapshot 的 OCR 融合触发条件已按此实现）。
- **充电胶囊/灵动岛是带文本的大 a11y 悬浮节点**，几何上罩住屏幕上部——OCR 融合去重必须按「内容相同」判重，不能按「bbox 包含」判（实锤：「选择聊天/搜索」行被误吞）。
- **后台应用弹悬浮窗（overlay）被静默拦截**（网关 bring-up 去险实测，2026-07-18）：`SYSTEM_ALERT_WINDOW`（悬浮窗权限）**≠「后台弹出界面」权限**。网关**在后台**（前台是别的 app）时 `WindowManager.addView(TYPE_APPLICATION_OVERLAY)` 被 OriginOS **静默拦截**（`main.post{addView}` 线程正确、不抛异常，但窗口不显示）；**在前台**时正常弹。**影响 `confirm` 确认层**：危险动作跑在真实 app 前台时网关必在后台 → 带内确认卡片弹不出，`confirm` 等满 60s 走 `E_CONFIRM_TIMEOUT` + 带外 `[AWAIT_CONFIRM]`。**对策**：授网关 vivo「后台弹出界面」权限（i 管家/权限设置，或试 appops），或危险动作在 vivo 上直接走带外两段式。✅ **已实锤（2026-07-22 P0 smoke）：授「后台弹出界面」后，微信前台时确认卡正常弹出**，60s 内可核对可点击。

## 深链 / Intent

- **系统设置深链不可靠**：`am start -a android.settings.BLUETOOTH_SETTINGS` 不把蓝牙页带到前台（主设置 intent 正常）。执行器 `open_uri` 必须有「深链失败 → UI 导航兜底」（M1a 已内建执行后验前台）。

## 输入法

- **vivo 默认联想输入法吞空格**（M0.5 复测实锤）：合成态把空格当「选词确认」——"harness drill 0717" 连成 "harnessdrill0717"，单发空格无效、全选重输同样复现。含空格文本无法精确录入。对策 = M1 自有 IME 字面注入；临时绕法：切无预测 ABC 键盘 / 任务文本避开空格。
- 输入法预测引擎会篡改大小写（M0 实测，微信任务误触诱因之一）。

## 待真机验证（Spike）

- Shizuku 重启存活性、无线调试重启后是否被关（S2；**激活本身已 S2 实测成功**——v13.6.0 经 `libshizuku.so` 起 `shizuku_server`；重启存活待手机重启后验）。
- 其余系统设置子页 intent 是否带到前台（无障碍页 `ACCESSIBILITY_SETTINGS` 已 ✅ 转正，WiFi/输入法/应用详情待验，见 [sys-cli.md §4](sys-cli.md)）。

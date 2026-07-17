# 系统 CLI / API 参考（网关 L1 通道备料）

> **性质：云端查阅整理（2026-07-17），标注 🔵 查阅未实测。** 与 M0 实测证据（[devices.md](devices.md) 等）分区：本册是真机日/ M1b 的候选命令清单与 API 线索，**每条上真机前按对应 runbook 验证并把结论回写 devices.md**。命令生效性强依赖 Android 版本与 ROM（OriginOS 尤甚）。
> 用途：网关 L1「系统通道」工具（system_get/set/verify_state、foreground_app、keyboard_state、media_query、IME 切换）的内部实现在 Kotlin API 拿不到时，走 Shizuku shell 白名单——本册就是那张白名单的备选池 + 真值源对照。
> 铁律不变：**不暴露裸 shell 给模型**；这些命令只作为类型化工具内部实现，参数校验/白名单/执行后复核在工具内做。

## 1. 系统开关：写命令 + 真值源（对应 system_set_state / verify_state）

关键分裂（M0 发现 #2 已实测确认）：**写用一套命令，验真值用另一套源**——settings 键会撒谎。

| 状态 | 写（Shizuku shell，🔵 逐条待验） | 真值源（复核，部分已测） | 备注 |
|---|---|---|---|
| 蓝牙 | `svc bluetooth enable/disable`；备选 `cmd bluetooth_manager enable/disable` | `dumpsys bluetooth_manager` 找 `state`/`mState`：**12 = STATE_ON**、10 = STATE_OFF（🔵 数值语义查阅所得，真机核对）✅真值源已 M0 实测 | Android 13+ 普通 app API `BluetoothAdapter.disable()` 对 target33+ 失效——写操作必走 shell。`svc` 与 `cmd` 哪条在 Android16/OriginOS 生效 = Spike S2 |
| WiFi | `svc wifi enable/disable`；`cmd wifi set-wifi-enabled enabled/disabled` | `dumpsys wifi \| grep "Wi-Fi is"` → `enabled/disabled`（🔵） | 同上，Android 10+ 普通 app 不能编程开关 |
| 飞行模式 | `settings put global airplane_mode_on 1/0` **再广播** `am broadcast -a android.intent.action.AIRPLANE_MODE --ez state true`（🔵，settings 单写不触发切换） | `settings get global airplane_mode_on`（此键 M0 未标定可信度，谨慎） | 两步式，漏广播则状态不同步 |
| 勿扰 | `cmd notification set_dnd on/off/priority`（🔵） | `dumpsys notification \| grep mZenMode`（🔵） | |
| 亮度 | `settings put system screen_brightness <0-255>`（需 WRITE_SETTINGS）；自动亮度 `settings put system screen_brightness_mode 0/1` | `settings get system screen_brightness` | 亮度这类 settings 键一般可信（非"状态谎报"类） |
| 音量 | Kotlin AudioManager 首选（M1a 已用）；shell `cmd media_session volume` / `media volume --stream 3 --set N`（🔵） | AudioManager.getStreamVolume | M1a 无特权即可写，不必上 shell |

> 结论：网关 `system_set_state` 的蓝牙/WiFi 腿 = Shizuku。M1a 已把它们做成「返回 E_CHANNEL_DOWN + UI 兜底路径」，M1b 接 Shizuku 后替换为上表写命令，并**强制在工具内跑一次 verify（dumpsys 真值源）**，不匹配则报 E_VERIFY_FAIL。

## 2. 前台 app / Activity（对应 foreground_app）

M1a 主通道是自研 a11y 窗口事件（免授权、免 shell）。Shizuku 备选（🔵，用于 a11y 未开或交叉核对）：

- `dumpsys activity activities | grep ResumedActivity`（Android Q+）→ `mResumedActivity: ActivityRecord{... com.pkg/.Activity ...}`
- `dumpsys window | grep -E 'mCurrentFocus|mFocusedApp'` → 含锁屏/最近任务等焦点态，比 ResumedActivity 更贴"用户在看什么"
- 取包名一行流：`dumpsys activity activities | grep mResumedActivity`（字段位置随版本变，别写死 cut 列号）

## 3. 软键盘状态（对应 keyboard_state）

M1a 主通道 = a11y windows 里找 `TYPE_INPUT_METHOD` 窗口（拿可见性 + 高度）。Shizuku 备选（🔵）：

- `dumpsys input_method | grep mInputShown` → `mInputShown=true/false`（业界常用判据）
- 附近字段 `mVisibleBound` / `mLastImeTargetWindow` 可辅助拿键盘区域

> 键盘态是 M0 两次误触主因的感知面（devices.md），a11y 通道已够；dumpsys 仅作 a11y 不可用时的兜底。

## 4. 启停 app / 打开设置页（对应 app_launch / app_stop / open_uri 兜底）

- 启动：`am start -n <pkg>/<activity>` 或 `monkey -p <pkg> -c android.intent.category.LAUNCHER 1`（M0 用 monkey 启京东，开屏无广告）
- 强停：`am force-stop <pkg>`（🔵，需 shell；M1a 的 app_stop 就等这条）
- 设置子页 Intent（M0 发现 #1：OriginOS 深链页级不可靠，主设置页可靠）：
  - 主设置 `am start -a android.settings.SETTINGS` ✅M0 实测可靠
  - 蓝牙 `android.settings.BLUETOOTH_SETTINGS` ❌M0 实测 OriginOS 不带到前台
  - WiFi `android.settings.WIFI_SETTINGS`、应用详情 `android.settings.APPLICATION_DETAILS_SETTINGS -d package:<pkg>`、输入法 `android.settings.INPUT_METHOD_SETTINGS`、无障碍 `android.settings.ACCESSIBILITY_SETTINGS`（🔵 逐个真机验证是否带到前台，OriginOS 前科在先）

## 5. 媒体库 / 剪贴板 / 内容提供者（对应 media_query / clipboard）

- 最新截图 id（M1a media_query 的 shell 等价，用于 smoke 验证）：
  `content query --uri content://media/external/images/media --projection _id:_display_name:date_added --sort "date_added DESC"`（🔵；截图相册名跨 ROM 差异大：Screenshots/截屏/截图，M1a 已多名兼容）
- 剪贴板：**无稳定 shell 通道**（`service call clipboard` 各版本不通）。M1a 结论正确——读剪贴板靠自有 IME 焦点豁免（Android 10+ 只默认 IME/焦点 app 可读）。

## 6. IME 切换（自有 IME 的启用与设为默认，对应 §8 输入链落地）

- 列已启用 IME：`ime list -a`（🔵）
- 启用：`ime enable dev.magina.gateway/.ime.GatewayIme`（🔵）
- 设为当前：`ime set dev.magina.gateway/.ime.GatewayIme`（🔵）
- 纯 settings 等价（需 WRITE_SECURE_SETTINGS）：`settings put secure default_input_method <id>`；`enabled_input_methods` 追加
- 一次性授权（真机日清单已列）：`pm grant dev.magina.gateway android.permission.WRITE_SECURE_SETTINGS` → 之后网关可自行 settings put 切 IME，摆脱 Shizuku 在线依赖（决策点 1「Shizuku 增强非依赖」的落地抓手）

## 7. Shizuku 集成要点（M1b 特权层）

来源：RikkaApps/Shizuku-API 官方开发指南 + 社区（🔵，集成方式确定、真机存活待 S2）。

- 原理：Shizuku 用 `app_process` 起一个 **shell uid(2000)** 特权 Java 进程，经 Binder 暴露系统 API；等价于"常驻的 adb shell 权限"，无需 root。
- 现代集成走 **UserService**（不用老的 newProcess）：自己的 AIDL 服务跑在 uid 2000 独立进程，无非 SDK API 限制——网关把 §1–§4 的 shell 命令封进 UserService 即可。
- 激活：adb `sh /sdcard/.../start.sh` 或无线调试自启；**重启失活是已知痛点**（S2 专项测，M1 期 PC adb 在场可随手重激活）。
- 权限申请：运行时 `Shizuku.requestPermission()`，用户在 Shizuku 管理器点授权一次。
- 与 `pm grant WRITE_SECURE_SETTINGS` 的分工：后者一次性拿到就够 IME 切换 + 部分 settings 写；蓝牙/WiFi 的 `svc`/`cmd` 仍需 Shizuku 在线。两者互补，不是二选一。

## 8. 通知直接回复（RemoteInput，对应 notification_reply，M1b + Spike S5）

- 检测通道（🔵）：`dumpsys notification --noredact` 找目标包段，看有无 `RemoteInput` / `actions`（含"回复"快捷动作）。
- 代码侧：NotificationListenerService 拿到 `StatusBarNotification` → `Notification.actions[i].getRemoteInputs()` → 填 `RemoteInput` 的 result bundle → `PendingIntent.send(context, 0, fillInIntent)`。
- 预期（spec §5.3 已判断）：微信国内版大概率不带 RemoteInput，价值在短信/邮件/国际 IM；S5 实测定论。

## 参考来源（均为社区/官方文档，命令生效性以真机为准）

- 蓝牙 CLI 与 dumpsys 状态：adb-shell.com bluetooth_manager；dzone AOSP Bluetooth debugging（STATE_ON=12）
- 前台 Activity：medium ADB dumpsys 系列；repeato 当前 Activity
- 键盘态：Appium discuss、androidbugfix（mInputShown）
- 深链另见 [deeplinks.md](deeplinks.md)
- Shizuku：RikkaApps/Shizuku-API、xda-developers implementing-shizuku、HackTricks Shizuku Privileged API

# vivo / OriginOS（历史手机基线：V2352A · X100 系列，Android 16，1260×2800）

> 来源：M0/M0.5 起实测（2026-07-16 起，各条注日期）。原始记录：[../../runs/2026-07-16-M0.md](../../runs/2026-07-16-M0.md)。品牌开关完整矩阵见 [M0 runbook §1.1](../../runbooks/M0-runbook.md)。

## 调试与注入

- **「USB 模拟点击」开关必开**，否则注入报 SecurityException；开了之后 tap/swipe 正常。
- OriginOS 5 有 ADB 白名单：一直 unauthorized 就检查「USB 调试 → 仅允许指定计算机调试」。
- **保活**：网关类 App 需电池白名单 + 后台高耗电允许，**还须在最近任务锁定卡片**（2026-07-22 仅前两项仍被清）。进程死亡会**静默把当前输入法回退为 vivo 默认**，恢复后要重切并重验。
- **注入型 IME 无可见键盘窗口**（2026-07-22）：`mIsInputViewShown=false`，`keyboard.visible` 恒 false，不可作聚焦判据；InputConnection 可存活 ≥5 分钟。聚焦核对用 `dumpsys input_method` 的 `mServedView` 或 IME commit 结果。
- **窗口事件污染前台身份**：确认卡 overlay、vivo 悬浮层（pkg=android）的 `TYPE_WINDOW_STATE_CHANGED` 会把事件流维护的前台包/Activity 写成 `android` / `android.widget.FrameLayout`，曾导致用户已允许后 `E_STALE_REF` 误杀（2026-07-22）。前台归属必须按 windowId 落到 active `TYPE_APPLICATION`，规则见 [common.md](common.md)。
- **开发期 settings 开无障碍服务**（2026-07-17/18）：`settings put secure enabled_accessibility_services <pkg/svc>` + `accessibility_enabled 1` 两键同置，**异步生效 ~3s**（同命令内立即 `get` 读到空是正常的）。坑：① `input tap` 点无障碍详情页开关无效（反自动化拦截）；② settings 开启的服务**数小时后被系统撤销**（疑似午夜/空闲策略）→ 每次跑测前重放两条 put；持久启用须设置 UI 手动开 + 保活三项，真实用户场景必须走 UI 引导。
- **`adb install -r` 重装后**（2026-07-19）：① a11y 服务不自动重绑，重写同值无效，须先清空再写回强制重绑；② 运行时权限被重置（MediaStore 无权限时**静默返回空游标**，工具层要显式预检）→ 重放 `pm grant`。bring-up 固定链：install -r → pm grant → a11y toggle → am start 主界面 → 启动网关服务 → adb forward。
- **`adb install -r` 会被系统安装确认页同步拦住**（2026-08-22）：约 2s 后拉起 `com.android.packageinstaller/.PackageInterceptActivity`，真人点继续前 adb 不返回，runner 超时整轮 0 腿。开跑前让用户盯住手机；`adb get-state=device` 不等于可无人值守安装。超时后用 `dumpsys package` 的 `lastUpdateTime` 判断是否真装上。
- **换开发机/用户配置后先验 debug 签名**（2026-08-22）：缺 `~/.android/debug.keystore` 时 Gradle 新生成 key，旧包不能被覆盖，而安装页可能不给可见错误。判据：pull 已装 `base.apk`，用 `apksigner verify --print-certs` 比较新旧证书 SHA-256。不一致只能恢复旧 keystore，或经用户明确授权卸载重装（清私有数据与授权，属破坏性前置）。
- **后台启动三方 Activity 被拦（BAL）**（2026-07-19）：网关在后台时 `app_launch(微信)`/`share_file` 直达组件不落前台（无异常、无日志、`foreground_verified:false`），系统 app 放行，shell `am start` 不受限。对策：授「后台弹出界面」权限（🔵 对 BAL 是否有效待验）或 shell 通道。
- **后台 overlay 被静默拦截**（2026-07-18）：`SYSTEM_ALERT_WINDOW` ≠「后台弹出界面」权限；网关在后台时 `addView(TYPE_APPLICATION_OVERLAY)` 不抛异常但不显示，确认卡弹不出。✅ 授「后台弹出界面」后，微信前台时确认卡正常弹出（2026-07-22）。
- **充电胶囊/灵动岛是带文本的大 a11y 悬浮节点**，罩住屏幕上部——OCR 融合去重按「内容相同」判重，不能按「bbox 包含」判。

- **vivo 安全中心撤销第三方无障碍**（2026-10-09，PA2553 / Android 16 实测）：探针开启后 1–9 秒内被 `com.vivo.safecenter` 改写 `enabled_accessibility_services` 移除（`dumpsys settings` 可见改写者），日志无原因。允许 i管家弹窗、`settings put`、放行受限设置、后台高耗电、锁卡片、加启动页、系统安装器安装、release 非调试签名 + 官方“解除限制”均无效。vivo 的 `dumpsys accessibility` 绑定列表也不列出已连接的第三方服务，当次记录以应用自报判断就绪，但不足以证明持续绑定。详见 [运行记录](../../runs/2026-10-09-C1b-真机-vivo安全中心撤销无障碍.md)。

## 官方资料与客服咨询（2026-10-14，🔵 未实测）

- [vivo 受限设置 FAQ](https://www.vivo.com.cn/service/questions/all?categoryId=170&questionId=1836)解释侧载应用的高敏权限限制和机主解除流程，但没有解释“解除后数秒内又被关闭”。[Android 16 CDD](https://source.android.com/docs/compatibility/16/android-16-cdd)覆盖本地文件安装；[PackageInstaller](https://developer.android.com/reference/android/content/pm/PackageInstaller#PACKAGE_SOURCE_LOCAL_FILE)将 `packageSource=3` 定义为本地文件，release 签名也不会改变来源类别。
- `com.vivo.safecenter` 的设置改写记录支持系统侧撤销，具体触发策略仍未知；不能直接认定是 ECM、某个安全开关或省电杀进程。探针 `a11y_service_ready` 只来自进程内实例，不独立证明持续绑定。
- 官方机器人对“无障碍自动关闭”建议检查系统更新；另称脚本辅助类 App 可能因使用特殊权限被判风险，但未确认探针被判风险或撤销原因。人工入口显示服务时间 8:00–22:00，本轮未获人工答复。通用建议不等于已验证解法。
- 官方开发支持有 [开发者助手](https://developers.vivo.com/support/)的 Security / 系统适配分类及 [应用安全检测平台](https://developers.vivo.com/product/d/appSecurity)。本轮未提交工单、上传 APK 或发邮件；检测通过、商店上架是否影响 ROM 放行尚未知。
- 证据边界、来源、客服脱敏摘要和下次简短问法见 [10-14 调研记录](../../runs/2026-10-14-C1b-vivo无障碍权限阻塞调研.md)。真机事实仍截至 10-09，不反复开启权限或自动重跑。

## 深链 / Intent

- **系统设置子页深链不可靠**：`am start -a android.settings.BLUETOOTH_SETTINGS` 不把蓝牙页带到前台（主设置、无障碍页可靠）。`open_uri` 必须有「深链失败 → UI 导航兜底」。其余子页见 [sys-cli.md §4](sys-cli.md)。

## 输入法

- **vivo 默认联想输入法吞空格**（M0.5）：合成态把空格当选词确认，含空格文本无法精确录入；预测引擎还会篡改大小写。对策：自有 IME 字面注入。

## 通知与锁屏

（2026-08-02）AOSP 级的通知资格规则在 [common.md](common.md#通知锁屏资格)，这里只记 vivo 特有的。

- **`zen_mode` 是隐形混杂变量**：vivo **定时睡眠模式**会自动开免打扰，而审批通道 `mBypassDnd=false`。跑锁屏验证前先 `adb shell settings get global zen_mode` 确认为 0。
- **锁屏通知有两级开关，分属不同页面**：应用级「锁屏通知」控制显不显示；「显示锁屏通知详情」（设置 → 状态栏与通知 → 管理通知 → 应用）控制显示内容还是折叠。排查时两个都看。
- 🔵 OriginOS 自有「原子通知」呈现层是否影响锁屏可见性未实测。
- vivo 开放平台文档拿不到开发者级锁屏规范（页面 JS 渲染，搜索结果多为用户教程）。这条线直接做单变量真机实验更快。

## 待真机验证

- Shizuku 激活已实测（v13.6.0 经 `libshizuku.so`），**重启存活、无线调试重启后是否被关**待验。
- WiFi / 输入法 / 应用详情设置子页 intent 是否带到前台（见 [sys-cli.md §4](sys-cli.md)）。

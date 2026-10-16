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

## 官方资料与客服咨询（2026-10-14–15，🔵 未新增设备实测）

> **确认了系统侧撤销，尚未查明触发原因，也没有验证过的解法；C1b 仍未采集。** 设备证据截至 10-09。Pad5 / OriginOS 6 / `DPD2437C_A_16.1.10.1.W10.V000L1` 为用户提供，未重新读取设备。

- **直接证据**：`com.vivo.safecenter` 改写启用列表移除了探针，通常发生在开启后约 1–9 秒。已尝试授权、保活、安装来源和非调试版等 7 类做法，均未解阻；这不能排除应用行为触发系统处理，也不能认定所有第三方无障碍都被禁用。见 [10-09 记录](../../runs/2026-10-09-C1b-真机-vivo安全中心撤销无障碍.md)。
- **调研缩小了范围，未锁定机制**：[vivo FAQ](https://www.vivo.com.cn/service/questions/all?categoryId=170&questionId=1836)只解释首次受限设置与解除流程；Android 16 另有服务登记权限检查和停止清理路径。官方曾修过其他机型的自动关闭问题，但未找到当前 Pad5 固件的对应说明；公开近似病例也没有相同证据链下的可靠解法。详见[首轮](../../runs/2026-10-14-C1b-vivo无障碍权限阻塞调研.md)与[深入调研](../../runs/2026-10-14-C1b-vivo无障碍权限深入调研.md)。
- **人工未确认根因**：10-15 普通售后只提出“可能不兼容”，称未收到相关反馈，未提供规则或修复版本，转介开放平台。这不能当作兼容性诊断或无系统缺陷证明；开发者人工当时已下班，尚未受理。见[答复记录](../../runs/2026-10-15-C1b-vivo人工客服答复.md)。
- **仍未知**：安全误判、系统缺陷、独立权限检查或应用触发处理之间如何归因；未上架应用的自测/误判复核入口；安全检测报告和商店分发是否影响 ROM 放行。探针自报 ready 也不能独立证明持续绑定。
- **下一步**：10-16 09:00 跟进因操作工具没有 Chrome 连接而未进入客服，未发送咨询或取得新答复；已请用户恢复连接，一次性自动化已删除，见[本轮记录](../../runs/2026-10-16-C1b-vivo开发者客服浏览器未连接.md)。恢复后在工作日 09:00–12:00、14:00–18:00 问[开放平台人工](https://www.vivo.com.cn/kefu?source=openPlatform)：受理团队、未上架应用流程和最少材料，以及检测报告是否关联管家判断。只发型号、版本和现象，不上传日志/APK/设备标识，不操作设备或重跑失败轮。

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

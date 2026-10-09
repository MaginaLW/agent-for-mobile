# Android 通用坑（版本级行为 + 工具链）

> 来源：M0/M0.5 起的真机实测（主要为 vivo V2352A / Android 16，2026-07 至 08），另注设备与日期。厂商特有的坑在 [vivo-originos.md](vivo-originos.md) / [other-vendors.md](other-vendors.md)，微信特有的在 [../apps/wechat.md](../apps/wechat.md)。
> 带 `#N` 的条目被代码注释、脚本和 spec 按编号引用，编号沿用历史、不连续，**不要重新编号**。

## Android 版本级行为

- **系统状态验证不能信 settings 键**：`settings get global bluetooth_on` 返回 0 时蓝牙实际是开的（Android 16 实测）；`dumpsys bluetooth_manager` 才是真值。验证通道用 dumpsys / 专用 API（真值源对照见 [sys-cli.md §1](sys-cli.md)）。
- **后台剪贴板写入受限**（Android 10+，16 实测拦截）：devicekit「写剪贴板+注入粘贴键」的中文输入被拦，输入框出现剪贴板旧内容；纯 ASCII 正常。→ 输入走自有 IME 字面注入，不依赖剪贴板戏法；读剪贴板靠"默认 IME 豁免"。
- Android 13+ 普通 app 无法编程开关蓝牙/WiFi（shell 位阶专属，见 [sys-cli.md](sys-cli.md)）。
- **无障碍 `takeScreenshot`（API 30+）节流有软硬两种形态**（V2352A / Android 16）：单发 32–37ms；~400ms 间隔连发不报错而是**延迟到 ~750ms 才返回**，冷却 ~2s 回落；<300ms 的更紧连发会**硬报** `ERROR_TAKE_SCREENSHOT_INTERVAL_TIME_SHORT`。网关内部视觉通道等 ~900ms 重试一次吸收；`screen_capture` 工具向大脑透出 `E_RATE_LIMITED`（冷却参考 ~800ms）。
- **#22 Android 11+ `run-as` 读不了自己的 external files 目录，普通 `adb shell` 反而读得到**（Android 16，2026-07-26）：`run-as` 跑在 shell 的挂载命名空间里，对 `/sdcard/Android/data` 一律拒绝 app uid。**内部 `filesDir` 读写仍必须走 `run-as`（相对路径 `files/...`），external files 走普通 `adb shell`，两者不能混用一种写法。** 附带坑：`adb exec-out` 会把设备侧 stderr 一并写进重定向目标，`Permission denied` 会冒充成文件内容；拉取类命令不要图省事加 `-AllowFailure`。

## 通知锁屏资格

结论：**category 只是给系统的提示，拿不到对应待遇；待遇由 Style + 权限 + 必备元素共同决定。**（2026-08-02 查阅 + 真机对照；vivo 侧开关见 [vivo-originos.md](vivo-originos.md#通知与锁屏)）

- **`setCategory(CATEGORY_CALL)` 单独使用不会得到通话级待遇**：官方只把"最高优先级排名 + 可转发"授予 `NotificationCompat.CallStyle`。
- **`CallStyle` 强制 接听/拒接（或挂断）按钮，系统配文案、不可自定义**，与"允许/拒绝"语义冲突，审批卡不能靠它蹭待遇。
- 通话类配方带 `setFullScreenIntent()`，而 Android 14+ `USE_FULL_SCREEN_INTENT` 不再自动授予；本项目已决定不声明它（2026-08-01），所以 `category=call` 是兑现不了的申请。🔵 裸 category 是否导致锁屏过滤未实测——最省事的单变量实验是去掉它重跑。
- 🔵 Android 16 据媒体报道会自动隐藏"已读过"的锁屏通知、在高风险场景隐藏敏感内容（非官方，未证实）。实验要区分「锁屏后才 post」与「post 后再锁屏」。
- **方法论**：判断"是不是本机/ROM 的问题"，在同一时刻同一块锁屏上找一条正常显示的对照通知（同时核 `zen_mode=0`）。一张截图就能排除"锁屏渲染坏了""被免打扰吞了"两类假设，剩下的差异必在两条通知的属性差集里。

## 无障碍窗口与前台身份

- **窗口事件不等于前台身份**（V2352A / Android 16，2026-07-22）：`TYPE_APPLICATION_OVERLAY` 也会发 `TYPE_WINDOW_STATE_CHANGED`，事件 package/class（如 `FrameLayout`）只描述事件窗口。必须用 `event.windowId` 归属到 windows 列表中 active 的 `TYPE_APPLICATION`，无 active 时才后备 focused `TYPE_APPLICATION`；overlay、IME、inactive 窗口事件忽略。事件早于 windows 列表更新时只暂存候选，等 `TYPE_WINDOWS_CHANGED` 复核后再发布。
- **前台身份显式区分 `Known` / `Unknown`**：`Unknown` 时只读 R 可用于诊断，写入 W 与危险 D 必须 fail-closed。root 仅给出 package 的 fallback 不等于已验证窗口身份。
- **#19 `Unknown` 必须自带原因**（2026-07-26）：三种成因——从未接受过窗口状态事件（服务冷启动）、当前无 active/focused 应用窗口、已接受身份的 windowId 与当前应用窗口不一致——在返回体里长得一样（微信 `root=null`，连 package 后备都是空串）。现已在 `ctx` 带 `foreground_reason`，`foreground_app` 扩成只读诊断（`selected_window_id`、`tracked_identity`、`windows[].root_package`、最近 24 条事件处置 `recent_events`）。**排查前台身份先读这两处，不要从点击/几何/OCR 方向猜。** 没有证据前不要动 tracker 判据：窗口列表瞬时取空（该有界重读）与 windowId 真换了（动候选发布规则）修法相反，后者正是"overlay 事件不得污染前台身份"的防线。
- **冷启动自举身份**（2026-08-01）：身份从未建立时，把当前活动应用窗口自报的 root 包名固化为 package 级身份（`foreground_identity_source=bootstrap`）。约束：只在 `Unknown` 时生效、**不救 `WINDOW_ID_MISMATCH`**；`activityName` 留空，不拿 `window.title` 冒充；身份来源本身纳入确认前后硬相等，避免两边 activityName 都为空时"平凡相等"放行。背景：跑测脚本若在目标 App 已前台时跳过 `am start`，服务重启后没有窗口事件，身份永远拿不到。
- **#21 自家确认卡必须 `FLAG_NOT_FOCUSABLE`**（2026-07-26）：可获焦的卡会抢走窗口焦点——App 窗口不再 active/focused → 确认后前台身份复核 `E_BLOCKED`；InputConnection 被拆掉重建 → IME 会话 id 换新 → `E_STALE_REF`。不可获焦窗口照样收触摸。**任何在被操作 App 处于关键状态时弹出的自家 UI，默认都该不可获焦。**
- **自有 overlay 必须从执行面排除**：确认卡若进入 `windows/snapshot/ref`，Agent 可能经 `ui_action` 自确认。窗口遍历、ref 注册、动作解析统一拒绝网关自有窗口；只认按钮回调为真人决定源。
- **遮挡判定（`hasBlockingOverlay`）两个实现坑**（2026-07-23）：① 状态栏/导航栏是常驻 `TYPE_SYSTEM` 窗口，与顶部探测带几何必相交，不排除就**任意时刻恒判有遮挡**；② 默认参数在耗时 OCR 之后才重新查询前台窗口 id，前台标志一抖就把 App 自己的主窗口当成浮层——要显式复用同一次快照已算好的 `fgWinId`。

## App 屏蔽无障碍树与 IME 单命名空间降级

- **#18 微信 ≥8.0.52 会话页对 a11y 树基本不透明，是架构级阻断而非调参问题**（2026-07-25）：`ui_snapshot` 的 a11y 元素恒为状态栏那十几项，标题/气泡/输入框 100% 来自 OCR，`findFocus(FOCUS_INPUT)` 取不到可用焦点节点；同时 IME 侧（激活、InputConnection、`focusedInputId`）全部正常。与"微信有意混淆 a11y 节点对抗自动化"的公开调研吻合。**与点击精度、OCR 质量、几何算法无关，不要往这三个方向排查。** 社区"把自家服务注册成 TalkBack 等白名单服务名"的绕法属冒充系统服务，违反铁律，不可用。诊断技巧：就绪等待的超时消息逐条列出缺哪几个条件，直接读它比加日志快。
- **`window.root != null` 也不代表树可用**（PA2553 / Android 16，2026-08-26）：可返回 bounds 为 `[0,0,0,0]`、`childCount=0` 的 root 占位。记为"subtree 已遍历但语义 opaque"，root-handle、root→window 绑定、遍历完整性、语义可用性分开记录；零几何 root 永远不能成为 target 候选。
- **对策：显式 IME 单命名空间降级链**（[design](../../specs/2026-07-25-IME单命名空间降级门-design.md)）：
  - 身份来源写进值本身（`FocusIdentity(source = A11Y | IME_ONLY)`），降级必须显式；直接删 a11y 检查会让 `blank == blank` 恒真，绑定悄悄退化成无绑定。
  - **能严则严**：`FocusIdentity.of()` 是唯一降级决策点；a11y 给得出合法节点就走严格链，a11y 有值但格式非法一律 fail-closed。
  - 只有 a11y 各项**全部缺失**才算结构性缺失；一边有一边没有是错配，两条链都不放行。
  - **降级是让步不是等价**：保留 IME 会话身份、输入长度/SHA-256/预览、OCR 读回、OCR 会话标题、包名、确认编号与真人核对；失去 a11y 节点身份与 bounds 及其几何保证。因此 OCR 读回是硬条件，读回不过不记输入证据、Enter 必被拦。无节点时读回区域退到与盲点探针同一几何。
- **#43 焦点身份有两套合法命名空间，不能强行相等**：a11y producer 生成 `windowId|viewId|class|package|bounds`，IME 生成 `ime|<24hex>` session id。证据同时保存两套、分别复核；"统一成一个 id 再比较"会让合法宏必然 `E_STALE_REF`。节点 id 收敛到单一 producer（`FocusedInputIdentity`），契约测试用真实 producer 格式——测试桩把所有 id 设成同值会掩盖编码差异。也不要把 IME id 塞进 a11y 的 id 槽。

## 自有零 UI IME

- **`ime_visible` / `keyboard_state.visible` 在自有 IME 下恒为 false**（2026-07-25）：`GatewayIme.onEvaluateInputViewShown()` 有意返回 false，永不创建 `TYPE_INPUT_METHOD` 窗口。拿它当"输入会话是活的"的代理，已准备目标就永远记录不成功，也不能用它"佐证键盘没弹起"。**教训：选活性/可见性代理指标时，先确认它在自家组件架构下可能为真。**
- **替换判据**：① `ImeBridge.session()` 非空且 InputConnection 可用；② 会话 `EditorInfo.packageName` 等于前台包（需单独留存 `sessionPackage`）；③ 降级链不走"已聚焦"短路，必须亲手执行已校验的盲点，打字后 OCR 读回。**"聚焦前后 session id 必须变化"不成立**：微信输入框键盘收起后仍长期持有活连接，再点一次不触发 `onStartInput`。
- **#23 `performEditorAction()` 返回 true 不代表 App 做了任何事**（2026-07-26）：只表示调用投递到了活着的输入连接。发送类危险动作的结果必须由后验决定，不能由"通道调用被受理"决定。
  - 诊断问自己的 IME：R 级只读工具 `ime_editor_info` 读 `onStartInput` 收到的 `EditorInfo`（只出 imeOptions/inputType/action）。
  - **选通道看 `IME_FLAG_NO_ENTER_ACTION` 与 actionCode，不看 multiLine**：单行框声明 `IME_ACTION_SEND` 时回车即发送，走 `performEditorAction(IME_ACTION_SEND)`；需要发裸按键时用 AOSP 输入法写法（`KeyCharacterMap.VIRTUAL_KEYBOARD` + `FLAG_SOFT_KEYBOARD|FLAG_KEEP_TOUCH_MODE`，带 downTime/eventTime）。微信实测见 [wechat.md](../apps/wechat.md)。
  - 零 UI IME 下微信输入栏不渲染「发送」按钮，"点发送按钮"这条路不存在。

## 残留焦点节点：给"节点可用"定判据后，所有取用路径一起改

微信会话页 `findFocus(FOCUS_INPUT)` 返回不 focused、不 editable、bounds 退化的残留节点，先后咬了四处，症状各不相同（2026-07-26 / 07-31）：

1. **身份**：被当成 a11y 焦点身份，证据绑到打不进字的节点上。
2. **就绪判据**：`nodePresent=true` 让"a11y 一致缺失"不成立，降级链进不去（改：`!nodePresent || (!editable && !focused)` 视为缺失）。
3. **`type_text`**：走了节点通道，SET_TEXT 假成功，读回用退化 bounds 裁剪，ML Kit 报 `InputImage width and height should be at least 32!`。
4. **`press_key`**：对残留节点调 `ACTION_IME_ENTER` **假成功返回 true**，`viaNode || ImeBridge.enter()` 短路，IME 通道永远走不到，表现为"消息发不出去"，烧了五轮真机。

现已统一到 `FocusedInputSnapshot.nodeUsableForAction`（只认 `IdentitySource.A11Y`）。**铁证形态**：同一序列里 `type_text` 报无节点通道、`press_key` 报节点通道——两个工具对同一件事判断矛盾，矛盾即真因。**方法论：修不动时先加可观测性（给危险动作返回值带上 `enter_channel`），别加假设。**

## 危险动作后验

- **后验必须三态 `SENT / NOT_SENT / UNVERIFIED`，不能是布尔**：真没发出可以重来，判不了**绝不能重来**（可能已发出）。"判不了"并进成功是谎报，并进失败是诱导重试。UNVERIFIED 按 ok 返回但带 `verification_state` 与"只能只读复核"的下一步。
- **后验失败时绝不换通道重试**：可能其实已发出，重试即重复发送。
- **基线必须是已提交的确切文本**，不能是动作前那次 OCR 读回（每次噪声不同，contains 一抖就谎报成功）；也不能用截断过的 preview——超过 `PREVIEW_LIMIT=64` 时旧实现给 null，>64 字的消息一律误判失败（短 marker 测不到）。
- 判据分层 a11y → OCR；a11y `readableText == null` 是"没属性可读"，必须降级而不是当成已清空。
- **等 UI 变化用轮询到 deadline，别固定 sleep**：`sleep(600)` 改为 2s/250ms 轮询后，常见情况更快且慢场景不再假阴性。

## ML Kit 中文 OCR

（V2352A / Android 16，2026-07-19 起）

- **深色模式灰底灰字漏识 ~40%**，可跌破 `OcrEngine.recognize()` 内部 `MIN_CONF=0.5` 地板——连候选都不出现，下游阈值怎么调都够不着。已在 [OcrEngine.kt](../../../app/gateway/src/main/java/dev/magina/gateway/ocr/OcrEngine.kt) 做原图 + 灰度对比度拉伸图各识别一遍、IoU≥0.5 取高置信合并（真机证实微信会话标题从零候选升到 0.55~0.59）。`OcrEngine.kt` 无单测（依赖真实 Bitmap/ML Kit，未配 Robolectric），只能真机验证；效果不足先调 `CONTRAST_BOOST`。另有整屏缓存 2s TTL 重识给抖动翻盘机会。
- **小裁剪图识别塌方**：372×147 裁剪返回 0 行。校验/读回类裁剪最小 ~620×220 并带上下文，小图 conf 阈值 0（靠位置稳定 + 相似度把关）；整屏融合维持 0.5。
- **CJK 形近字/数字逐帧抖动**（搜索/搜素、0↔O、尾随多认一字如"文件传输助手8"）：识别类匹配一律"归一（全角/大小写/o→0）contains ∥ 位置稳定 + 字符袋相似度 ≥0.4"，**纯 `==` 会漏判**。两行长标签会拆成两行，查询用短子串。凡拿 marker 做机械判定都按 `OcrEngine.norm` 同口径归一。
- **识别用途与点击用途的门槛必须分开**：判"当前在哪页"的识别可用 `MIN_RECOGNITION_OCR_CONFIDENCE=0.45` 与 contains；决定"点哪里"的点击目标保持 `MIN_ACTION_OCR_CONFIDENCE=0.65` 与严格匹配（见 [VisionTrustPolicy.kt](../../../app/gateway/src/main/java/dev/magina/gateway/a11y/VisionTrustPolicy.kt)）。放宽识别层安全的前提是后续有独立、未被改动的点击时复核；点击目标识别不到时用流程规避（人工预置页面），不降门槛。迁移阈值时把同类函数**一次找全**——漏改一处会制造"流程规避也没用"的假象。写进确认证据链的识别值（如探针标题置信度）属设计取舍，改前征得项目所有者同意。
- **危险词扫描只扫真实弹窗**：整页扫描会把 OCR 出来的聊天列表预览（"微信支付""转账"通知）当成弹窗内容恒判敏感；按 `element.source == "a11y"` 过滤（设计取舍，已获同意）。
- **手势后主动失效 OCR 缓存**：事件静默 app（微信）点击/滑动后 revision 不动，不失效就读旧屏。
- 冷加载 ~700ms 一次性；整屏 ~300–700ms 随文本密度。
- **输入栏读回约束**（2026-07-26）：裁剪几何用截图位图自身尺寸，不用 `displayMetrics`；读回带要比盲点带高得多（输入文字基线落在系统 inset 之下，现取底边向上 260px），优先按已知焦点框几何裁、结果带 `regionSource`；判据"归一后包含"只能证明字落进去了，不能证明框里只有我们的字；读回失败分三态（异常 / 有几何无文字 / 有文字不匹配），别 `runCatching{}.getOrNull()` 吞成 null。
- 🔵 `ocrScreen()` 按 `TYPE_INPUT_METHOD` 窗口顶边裁剪位图的逻辑对零 UI IME 的影响未专门验证。

## 监督式真机跑测控制面

- **确认状态可观察不等于可写**：debug runner 只用 `run-as` 写一次性 `test-control.json`（字段严格校验、不含 allowed/denied），PC 只读 `test-confirmation-state.json`；决定只来自手机按钮回调，不加"测试方便"的 decision 写接口。release 用 no-op 控制面。token、确认状态、截图不经 exported provider/网络接口；外部命令异常不得拼接 adb stdout。
- **危险 Enter 绑定输入证据与业务目标**：`type_text` 后登记短 TTL 证据（预览、长度、SHA-256、焦点指纹），准备宏另存 `PreparedTargetEvidence(label/package/focused-input/bounds/TTL)`，只沿 `macro → type_text → press_key(enter)` 链存活，任何旁路 UI mutation 先使其失效；Enter 前后复核。audit 只记长度/哈希不落正文。
- **同一确认要有机械关联键**：12 位 confirm ID 同时显示在卡片、写入 confirmation state、绑定该卡截图；不能靠"时间接近"配对。
- **OCR ref 用前必须 fresh**：每个可变阶段强制新截图并递增视觉世代，按 capture revision、前台 windowId、置信度、bounds 校验；慢 OCR 返回后再原子复检才 perform。
- **#20 确认卡截图可能拍不到卡本身**（2026-07-26，已修并真机闭合）：frame fence 只保证本进程帧提交，`takeScreenshot` 读的是合成结果，可能差一两个 vsync。对策：按卡的真实位置与底色核验截图，没拍到等 400ms 重拍、最多 4 次；仍拍不到照样落盘但标 `card_visible=false`，刻意不 fail-closed。排查跑测失败先读 `run-manifest.json` 的 `failure` 与 `legs[].verdict`，它和执行器 trace 最后一条错误经常不是同一件事。
- **先只读诊断，再整套重跑**：`dispatch.ps1` 派只读 `ui_snapshot`/`screen_capture` 诊断（不需 Provision，二三十秒）确认真实状态；`screen_capture` 让子代理直接看图可独立验证截图管线是否陈旧。旧诊断数据（如已抓的 `dumpsys accessibility` 全量）常已含答案，先翻旧证据。多层叠加的失效先通读整条调用链再动手，别"改一处、重装、重跑"。
- **离线全绿的 provision 首次接真机大概率还会炸**（2026-07-23 实测）：
  - `run-as ... am start-foreground-service` 要显式 `--user 0`，否则以 USER_CURRENT 请求被 `INTERACT_ACROSS_USERS` 拒绝。
  - PowerShell `ArgumentList` 传 `sh -c` 带通配符的命令时要内嵌单引号，否则 adb shell 侧丢引号。
  - 重装 APK 后无障碍重绑异步（vivo 数秒到近百秒）；重写同值不触发重绑，须先写不同值再写回，然后按上限轮询。
  - vivo `dumpsys accessibility` 只打印 `label=<应用名>` 不含组件名，匹配要接受 label。
  - `cmd appops get <pkg> AUTO_START` 等不是真实 appops 名，任何设备都报 `Unknown operation string`；找不到真实可查 API 的探测宁可不做，别用恒失败的伪探测冒充硬门。
  - Android 16 上 `am start -c LAUNCHER -p <pkg>` 隐式解析失败；先 `cmd package resolve-activity --brief` 拿组件名再 `-n` 启动。
  - PowerShell `Mandatory` 数组参数拒绝空数组，可能拿到空集合的要加 `[AllowEmptyCollection()]`。
  - app 侧非原子覆写的状态文件，PC 轮询可能读到半成品；瞬时不可解析按"未就绪"重试，由上层超时兜住持续损坏。
  - 改 `app/gateway` 源码后必须重新 assemble 并让 provision 重装才生效，用 `dumpsys package <pkg>` 的 `lastUpdateTime` 核对。

## adb / uiautomator 工具链

- **`uiautomator dump` 在重动画商业 app 报 `could not get idle state`**（京东首页实测；设置类正常）。截图+视觉兜底是刚需；自研 AccessibilityService 直读事件流可绕开 idle 等待。
- 软键盘弹出导致坐标错位（M0 两次误触主因之一）→ 键盘状态感知 + 点击前二次校验（网关已内建）。
- **mobile-mcp 截图是缩放图**（约 360×800），click 吃物理坐标（1260×2800），直接按截图坐标点必偏 ×3.5；先 `get_screen_size` 换算。网关坐标主权在执行器侧，无此问题。
- 黑屏用 `adb shell input keyevent KEYCODE_WAKEUP` 点亮；预防靠「充电时屏幕不休眠」+ 临时关锁屏。

## Windows 批处理与离线套件

- **批处理里与 Unix 同名的 Windows 命令（`find`、`sort`、`echo`、`date`）一律写绝对路径**（2026-07-26）：从 Git Bash 拉起 pwsh 时 PATH 里 `/usr/bin` 在 `System32` 前，`find /v /c ""` 变成 Unix find，把 `/c` 当目录递归扫整个 C 盘直到超时。改 `%SystemRoot%\System32\find.exe` 后单条 36s → 8.7s。
- **"耗时几乎无方差"是挂死的指纹，不是负载的指纹**：中位 34.8s / 最慢 35.4s ≈ 固定 30s 超时 + 真实耗时。看见方差极小先查"卡在哪个固定超时上"，别怪机器慢。
- **对照实验要变一个变量，不是一个提交**：换提交跑基线只排除代码，两次都从同一种壳启动就带着同一个错误变量；定案靠同一份代码换启动方式跑。
- 监督式 runner 离线套件（`p0-supervised-runner-offline.ps1`）对子进程冷启动敏感：与 gradle 全量编译、常驻 daemon 或杀软并发会成片假超时，判定结果前确认机器空闲（`scripts/check.ps1` 已在开跑前停 daemon；`check.ps1 -Clean` 清残留目录与日志）。fixture 墙钟预算是防挂死保险不是性能断言（已放宽到 60s）。
- 已知偶发、未定位：单条用例子进程输出整个为空、耗时正常（非超时类）。再遇到先看 ExitCode 与 stderr 是否也为空，若是则查进程创建而非套件逻辑。

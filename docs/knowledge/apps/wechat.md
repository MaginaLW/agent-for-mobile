# 微信（com.tencent.mm）

> 来源：M0/M0.5 实测（2026-07-16/17，vivo V2352A）。原始记录：[../../runs/2026-07-16-M0.md](../../runs/2026-07-16-M0.md)。

## 感知通道

- **uiautomator 通道下无障碍树恒空**：`mobile_list_elements_on_screen` 在微信内始终返回空，只能截图+视觉定位 → 微信类任务在 M0 是纯视觉任务，成本高一个数量级（见 [../brain/cost.md](../brain/cost.md)）。
- ⭐ **S1 已定论（2026-07-17，自研 a11y flags 拉满仍不可读）**：探针（`flagIncludeNotImportantViews|flagReportViewIds|flagRetrieveInteractiveWindows` + `canRetrieveWindowContent=true`）在**聊天列表页 / 会话页 / 键盘弹出**三态下，微信主窗口（`window type=1 pkg=com.tencent.mm`）都出现在 windows 列表，但 `window.root` **恒为 null**（bounds 全 0），微信自身贡献 **0 个可读节点**（读到的全是 vivo 系统 UI）。→ **微信维持纯视觉任务，OCR 融合层提前进 M1a**（原绑定 uiautomator 的结论被自研通道复现并强化；乐观「a11y 能读微信」分支否定）。原始记录：[../../runs/2026-07-17-M1-spike.md](../../runs/2026-07-17-M1-spike.md)。
- ✅ **键盘态可感知（即便内容不可读）**：键盘弹出时 windows 列表新增 `type=2（TYPE_INPUT_METHOD）pkg=com.baidu.input_vivo`——`type_text` 后可据此判断键盘弹/收，M0 两次误触的感知面成立。
- ✅ **OCR 通道达标（S3 实测）**：会话页 ML Kit bundled 中文 OCR 稳定态 ~450ms、关键控件（文件名/大小/消息文本/时间戳）命中且 bbox 准确（conf 0.6–0.9）——微信不可读下的主通道可用。噪声来自气泡内嵌长截图，conf 阈值过滤。
- ⭐ **M1b 融合层真机闭环（2026-07-19）**：聊天列表页 31 个 OCR 元素、ShareImgUI 选择页 17 个，全量可读可寻址；OCR ref 点击（裁剪重识校验 + dispatchGesture）→ 发送确认弹窗 → OCR 读出「发送给/取消/发送」→ 取消，链路全通。`wait_for(text_appears/text_gone)` 走 OCR 感知面在微信内可用。**dispatchGesture 点击/滑动在微信内真实生效**（行点击、选择页滚动实测）。
- ⚠️ **树空但 `findFocus(FOCUS_INPUT)` 可拿到焦点输入节点**（选择页搜索框实锤）——微信屏蔽树内容但焦点节点可获取；不过 **`ACTION_SET_TEXT` 报 true 不生效且读回 null**（与 Switch 假点击同族），**必须 IME 通道**（网关 typeText 已按「readback==null 也降级 IME + OCR 裁剪读回」实现）。
- ⭐ **会话页聊天输入框全链探明（2026-07-22 P0 smoke，文传助手实锤）**：MMEditText（id `bkk`）聚焦后 findFocus 可取、`focusedInputId` 非空 → `press_key(enter)` 三道焦点复核可走通；SET_TEXT 假成功+节点读回 null 在此框复现，IME commit 生效；**type_text 的输入条 OCR 读回因小裁剪塌方恒 null → `verified` 不可达**，输入证据链改用「`committed=true` + `ime_commit` 通道 + 只读 `ui_find` 命中（O/0 归一）」；**空白输入框树空且无字可 OCR，任何通道拿不到 ref**——须现场人/前置动作先聚焦，再无 ref 调 `type_text`（打进文字后 OCR 才有锚点）。微信「使用回车键发送消息」开启时 `ACTION_IME_ENTER` 触发发送。

- ✅ **发送通道 2026-07-31 打通（真人确认消息已发出）。真因不是通道选择，是「哪个节点算可用」的判据没统一。**
  - **能发的那条路**：`enter_channel=editor_action:send`，即 IME 的 `performEditorAction(IME_ACTION_SEND)`。微信聊天框契约 `imeOptions=IME_ACTION_SEND` + 单行 + `no_enter_action=false`，本来就宣告了"回车即发送"。
  - **为什么五轮没走到**：`press_key` 的 `viaNode` 用的是**未经过滤**的 `findFocus(FOCUS_INPUT)` 节点。微信会话页那个残留节点既不 focused 也不 editable，却**接受 `ACTION_IME_ENTER` 并返回 true**（假成功，与 SET_TEXT 假成功同族），于是 `viaNode || ImeBridge.enter()` 当场短路，IME 通道永远走不到。同一次调用里 `type_text` 报 `ime_commit_ocr`（无节点通道）而 `press_key` 报 `a11y_ime_enter`——**两个工具对"有没有可用节点"的判断互相矛盾**，这就是铁证。
  - 这是《那个残留焦点节点会连累三处》的**第四处**，而那条教训原文就是"要把所有取用该节点的路径一起改"。判据已统一到 `FocusedInputSnapshot.nodeUsableForAction`（只认 `IdentitySource.A11Y`）并配离线用例。
  - **发送成功时的形态**（供后续判定参考）：输入栏 OCR 读不到任何文字（框已清空，后验落 `unverified` 是**正常**的），marker 出现在输入栏上方的消息区（实测 y≈2503–2545，输入栏候选区 y≈2637–2727）。
  - **OCR 会把 `P0ALLOW` 读成 `POALLOW`**（数字 0 ↔ 字母 O，S3 早已知）。凡是拿 marker 做机械判定的地方都必须按 `OcrEngine.norm` 同口径归一（含 o→0）——runner 侧曾漏掉这一步，把一次真正成功的发送判成"证据不匹配"。

- 🔴 **下面这条 2026-07-31 早些时候的判断也已作废**（当时以为真因在通道选择本身）： 开关**已开启**的情况下 Allow 腿仍然发不出去（`press_key` → `E_VERIFY_FAIL`，后验 `channel=ocr` 正面读到 marker 仍在输入栏，用户肉眼独立确认）。真因是**我们自己选错了通道**：
  - 微信聊天框契约是 `imeOptions=IME_ACTION_SEND`、`inputType=0x4001`（**单行**）、`no_enter_action=false`——它明确宣告了「回车即发送」。
  - 而 `ImeBridge.enter()` 的选择逻辑按「是不是多行」二选一，且**接反了**：多行走 `performEditorAction`、单行发裸 `KeyEvent`。于是这个单行框恰恰绕开了它自己宣告的 SEND 动作。
  - 安卓的约定是：**看 `IME_FLAG_NO_ENTER_ACTION` 与 actionCode，不看 multiLine**。单行框声明 SEND 时，软键盘那颗回车键就是发送键。已改为按此选择并加 6 条离线用例（`EnterStrategyTest`），微信那组实测契约直接作为回归数据。
  - 同时修了裸按键的形态：旧代码用 5 参 `KeyEvent` 构造（deviceId=0、flags=0），不是软键盘该有的事件；已改为 AOSP 输入法的标准写法（`KeyCharacterMap.VIRTUAL_KEYBOARD` + `FLAG_SOFT_KEYBOARD|FLAG_KEEP_TOUCH_MODE`）。
  - **仍待真机验证**：以上是离线推理 + 单测，尚未在设备上跑过。

- ⭐ ~~**发送通道：Enter 能不能发，取决于微信自己的「使用回车键发送消息」开关，不取决于输入框契约**~~（2026-07-26 结论，**已被上条推翻**；开关是必要条件但不是全部原因）。
  - 用 R 级只读工具 `ime_editor_info`（读我们自己 IME 在 `onStartInput` 拿到的 `EditorInfo`）实测该聊天框：`imeOptions=0x00000004`（`IME_ACTION_SEND`）、`inputType=0x00004001`（单行 TEXT|CAP_SENTENCES）、`no_enter_action=false`。**契约上两条路都该通，但 `performEditorAction(IME_ACTION_SEND)` 与 `KEYCODE_ENTER` 微信都不响应**——因为该开关关着时，微信压根没把回车接到发送上。契约只决定键盘画什么键，不决定 App 怎么处理。
  - 佐证：零 UI IME 下微信输入栏右侧**不渲染「发送」按钮**（它只在键盘弹起时替换 ⊕），所以"点发送按钮"这条路也不是凭空存在的。
  - **跑测前置条件**：微信 设置 → 聊天 → **使用回车键发送消息** 必须开启，否则整条 Enter 发送链在这台设备上不可能成立。本册 2026-07-22 那条早已写过这一点，后来排查时只读了 `android/common.md` 没读本册，为此多烧了两轮真机——**文档地图存在的意义就是按 app 路由，别只读通用册。**
  - `performEditorAction()` 返回 true 只表示调用被投递到了活着的输入连接，**不代表 App 做了任何事**；发送这类危险动作的返回值必须由后验决定（详见 [../android/common.md](../android/common.md)）。

## 操作坑（实测）

- M0 发生 2 次误触（点开联系人资料页、点开聊天内敏感 PDF），均立即退出无改动。成因：键盘弹出坐标错位 + 视觉定位偏差。→ 网关已内建：敏感对话/文件黑名单、点击前二次校验、键盘状态感知。
- 发送闭环可行（ASCII 消息实测成功）；中文输入卡在 devicekit 剪贴板机制（见 [../android/common.md](../android/common.md)）→ 等网关 IME 通道复测。
- **聊天列表条目点击偶发不导航**（M0.5 复测：坐标正确也可能不进会话，两次单击无效）；跨 app 发图更稳的路径是系统分享面板 → 微信。
- **微信内相册选择器的「截屏」下拉筛选会回弹**（M0.5 复测 3 次复现，烧 ~10 轮）→ 选图环节改走系统相册 App 或 media_query+share_file（网关新链路）。
- **vivo 相册 App（com.vivo.gallery）a11y 树完整可用**：相册 → 截屏 → 打开图片 → 分享 → 微信 → 文件传输助手，全程元素定位，已实测走通——跨 app 图片任务的推荐兜底路径。
- **确认悬浮卡遮挡会话页输入条**（2026-07-22 P0 smoke）：卡片显示期间现场人无法目视核对框内文本——人工核对流程要在执行器打字落框时看文本，卡出现后只核卡上字段；根治=卡片直接展示读到的输入文本或布局避开输入条（缺陷 D2）。

## 深链 / 分享（🔵 待验证项见 [deeplinks.md](deeplinks.md)）

- **无公开「直达指定聊天」深链**；`weixin://dl/*` 多已失效——微信类任务以 UI/分享通道为主。
- **ShareImgUI 选择页结构（M1b 实测，2026-07-19）**：「最近转发」宫格 + 「最近聊天」列表（置顶群优先，排序与聊天列表不完全一致，**文件传输助手不保证首屏**）；搜索框占位符深色模式下 OCR 漏识 ~40%（要 TTL 重试）；点联系人行 → 「发送给:」确认弹窗（取消/发送/留言输入，留言占位符同样临界）。定位策略：find 短子串「文件传输」+ scroll_search（网关手势翻页），或搜索框通道（IME 注入，占位符识别要重试）。
- 分享直达组件 `com.tencent.mm/.ui.tools.ShareImgUI` ✅ **S5 实测现版本有效**（2026-07-17）：`am start -n com.tencent.mm/.ui.tools.ShareImgUI -a android.intent.action.SEND -t image/* --eu android.intent.extra.STREAM content://media/external/images/media/<id> --grant-read-uri-permission` 成功拉起「选择聊天」页（最近转发 + 文件传输助手可选）。shell 侧未报 URI 权限错；FileProvider 语境最终验证在 M1a 代码。已回填技能包 apps.json。
- 通知 RemoteInput：⏳ **S5 待补**——`dumpsys notification --noredact` 当前微信段只有 channel 定义（直播控制/音视频邀请等），无活动消息通知带 `actions`/`RemoteInput`；需外部设备发一条消息、通知常驻时再 dump。预期阴性（国内版无直接回复）。

## 安全

- ~~「文件传输助手」自发自收零风险，站规白名单免确认（harness 决策点 5）~~ **P0 统一硬门后已废止（2026-07-22）**：任何会话/联系人/收件人均无白名单，文传助手发送同样弹确认卡走两段式（拒绝腿实锤 `E_BLOCKED` 生效）。

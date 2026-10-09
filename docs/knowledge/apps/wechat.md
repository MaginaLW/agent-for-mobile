# 微信（com.tencent.mm）

> 来源：M0 起实测（vivo V2352A / Android 16，2026-07-16 起，各条注日期）。原始记录：[../../runs/2026-07-16-M0.md](../../runs/2026-07-16-M0.md)、[../../runs/2026-07-17-M1-spike.md](../../runs/2026-07-17-M1-spike.md)。

## 感知通道

- **无障碍树不可读**：uiautomator 下树恒空；自研 a11y 服务 flags 拉满（`flagIncludeNotImportantViews|flagReportViewIds|flagRetrieveInteractiveWindows`）在聊天列表/会话页/键盘弹出三态下，微信主窗口出现在 windows 列表但 `window.root` 恒为 null，自身贡献 0 个节点（2026-07-17）。会话页对 a11y 基本不透明的完整分析见 [../android/common.md](../android/common.md) #18。→ 微信是纯视觉任务，成本高一个数量级（见 [../brain/cost.md](../brain/cost.md)）。
- **PA2553 / Android 16 横屏多窗**（2026-08-26）：两个稳定的微信应用窗口各只暴露一个零几何、无 child 的 root 占位——形态不同于 `root=null`，但同样没有 toolbar/会话行/输入框语义。"root handle 存在"只能记为结构诊断；即使窗口 focused，没有合法 focused editor 也只能记 `window_only`，不得据此选目标。
- ✅ **键盘态可感知**：系统输入法弹出时 windows 列表新增 `TYPE_INPUT_METHOD`（`com.baidu.input_vivo`）。自有零 UI IME 下不成立（见 common.md）。
- ✅ **OCR 是主通道**：会话页 ML Kit 中文 OCR 稳定态 ~450ms，文件名/大小/消息/时间戳 bbox 准确（conf 0.6–0.9）；噪声来自气泡内嵌长截图，conf 过滤。聊天列表、ShareImgUI 选择页全量可读可寻址；OCR ref 点击（裁剪重识校验 + dispatchGesture）与 `wait_for(text_appears/text_gone)` 在微信内可用（2026-07-19）。
- 会话标题/聊天列表标题字号小、颜色浅，OCR 置信度常在 0.5~0.6；聊天列表搜索入口是**纯图标、无字可识别**；「文件传输助手」行的点击置信度到不了点击门槛（2026-07-23）。识别/点击门槛的分工见 common.md「ML Kit 中文 OCR」。
- **`ACTION_SET_TEXT` 报 true 不生效且读回 null**（选择页搜索框、会话输入框均实锤），必须走 IME 通道。
- **空白输入框无 a11y 节点也无字可 OCR**，任何通道拿不到 ref；须先由校验过的盲点或人工聚焦，打进文字后 OCR 才有锚点。
- 微信会在测试间隙把会话页**自行漂回聊天列表**（前台 Activity 不变，疑似 fragment 栈重置，2026-07-24），跑测前现场核对当前页。

## 发送通道（会话页输入框）

- ✅ **2026-07-31 打通（真人确认消息已发出）**：`enter_channel=editor_action:send`，即 IME `performEditorAction(IME_ACTION_SEND)`。输入框契约（`ime_editor_info` 实测）：`imeOptions=0x00000004`（`IME_ACTION_SEND`）、`inputType=0x00004001`（单行）、`no_enter_action=false`——本就宣告"回车即发送"。
- **此前五轮发不出去的真因**是 `press_key` 对残留焦点节点调 `ACTION_IME_ENTER` 假成功、短路了 IME 通道（common.md「残留焦点节点」第四处），不是通道选择或开关问题。期间先后得出的"靠 IME 发不出""取决于回车开关""单行/多行通道选反了是根因"三个结论均已作废（按 actionCode 选通道的修正本身保留）——教训是"返回 true 的通道"要先确认真的被走到。
- **前置**：微信 设置 → 聊天 → **使用回车键发送消息** 保持开启（打通时为开启状态；关闭时是否仍能发未单独验证）。
- **发送成功的形态**：输入栏 OCR 读不到文字（框已清空，后验落 `unverified` 是正常的），marker 出现在输入栏上方消息区。
- **OCR 会把 `P0ALLOW` 读成 `POALLOW`**（0↔O）：拿 marker 做机械判定必须按 `OcrEngine.norm` 同口径归一（含 o→0），runner 曾因漏归一把成功判成证据不匹配。
- 零 UI IME 下输入栏右侧不渲染「发送」按钮。
- 排查发送问题时先读本册再读通用册——曾因只读 common.md 漏看 app 前置条件多烧两轮真机。

## 操作坑

- M0 两次误触（点开联系人资料页、点开敏感 PDF），成因：键盘弹出坐标错位 + 视觉定位偏差。→ 网关已内建敏感黑名单、点击前二次校验、键盘状态感知。
- **聊天列表条目点击偶发不导航**（坐标正确也可能不进会话）；跨 app 发图更稳的路径是系统分享面板 → 微信。
- **微信内相册选择器的「截屏」下拉筛选会回弹**（M0.5 复现 3 次）→ 选图改走系统相册或 media_query + share_file。
- **vivo 相册（com.vivo.gallery）a11y 树完整可用**：相册 → 截屏 → 打开图片 → 分享 → 微信 → 文件传输助手 全程元素定位走通，是跨 app 图片任务的推荐兜底路径。
- **确认卡会遮挡会话页输入条**（2026-07-22）：人工核对要在打字落框时看文本，卡出现后只核卡上字段。

## 深链 / 分享（🔵 待验证项见 [deeplinks.md](deeplinks.md)）

- **无公开「直达指定聊天」深链**；`weixin://dl/*` 多已失效——以 UI/分享通道为主。
- **分享直达** ✅（2026-07-17）：`am start -n com.tencent.mm/.ui.tools.ShareImgUI -a android.intent.action.SEND -t image/* --eu android.intent.extra.STREAM content://media/external/images/media/<id> --grant-read-uri-permission` 拉起「选择聊天」页。
- **ShareImgUI 选择页结构**（2026-07-19）：「最近转发」宫格 + 「最近聊天」列表（置顶群优先，文件传输助手不保证首屏）；搜索框/留言占位符深色模式下 OCR 漏识 ~40%（要重试）；点联系人行 → 「发送给:」确认弹窗（取消/发送/留言）。定位：find 短子串「文件传输」+ 手势翻页，或搜索框 IME 注入。
- 通知 RemoteInput ⏳ 待补：需外部设备发消息、通知常驻时 `dumpsys notification --noredact`；预期阴性（国内版无直接回复）。

## 安全

- **任何会话/联系人均无白名单**（2026-07-22 起）：「文件传输助手」自发自收同样弹确认卡走两段式，旧的"文传助手免确认"决策已废止。

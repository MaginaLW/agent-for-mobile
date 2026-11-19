# 微信（com.tencent.mm）

> 来源：M0 起实测（vivo V2352A / Android 16，2026-07-16 起，各条注日期）。原始记录：[../../runs/2026-07-16-M0.md](../../runs/2026-07-16-M0.md)、[../../runs/2026-07-17-M1-spike.md](https://github.com/MaginaLW/agent-for-mobile/blob/e1bae376217fc75b13094b2b04858ab93e692a29/docs/runs/2026-07-17-M1-spike.md)。

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

### PA2553 文件传输助手发送预检

2026-11-19，现场已打开目标会话，微信持有前台焦点。Allow 派单前，预检在输入栏候选区读到「可按住转文字」，返回 `empty=false` 并停止。现场用户事后更正，点这个控件可以打开键盘。本轮预检只记录了区域内可见的文字，当时的输入模式和草稿状态均未核实。

监督脚本基于 `ed320b7`，网关为 `a9aee63` 构建；同版本覆盖安装后，回读的 APK 摘要与[已核验版本](../../runs/2026-11-18-PA2553小红书只读验收.md#输入读回修复)一致。本轮在生成测试标记前停止，Allow、Stale、Deny 均未派单，未出现发送确认卡，也没有业务台账行。监督记录为 `failed`、0 腿，清理成功。收尾逐项核对原输入法和无障碍的六项设置、悬浮窗模式，均与开始前一致；本轮端口转发已撤。

### 横屏右窗只读定位

11 月 19 日晚，现场看到文字输入框为空白，系统读回键盘已收起。当前屏幕为 2800 × 1968。标准 P0 输入栏预检使用竖屏盲点探针，要求高大于宽且高宽比在 1.4 至 2.7 之间，当前横屏不满足这项条件。[平板几何约束](../android/tablet.md#当前能力边界)

保留横屏后，执行器在同一次只读派单中识别出两个并排的微信窗口（`same_app_multi`），右窗持有焦点。查询「文件传输助手」得到两处 OCR 文本，分别位于右窗顶部和左窗列表位置。另一次查询在同一右窗底部定位到一处「可按住转文字」，带元素引用，角色为 `text`。各次查询独立取帧。

查找可编辑角色 `input`、描述含「输入」的元素、文字含「发送」的元素以及描述含「发送」的按钮，四项均返回 `E_NOT_FOUND`。在这个空白状态下能够定位右窗标题与底部提示，尚无可编辑节点或发送控件的引用。宿主基于 `85f846b`，网关摘要与 `a9aee63` 构建一致。全程只有一次前台查询和六次不滚动的定向查找。台账保留原判 `fail / not-found`，耗时 38 秒。[派单台账](../../runs/ledger.csv)

### 历史手机实测

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

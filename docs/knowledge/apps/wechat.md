# 微信（com.tencent.mm）

> 来源：M0/M0.5 实测（2026-07-16/17，vivo V2352A）。原始记录：[../../runs/2026-07-16-M0.md](../../runs/2026-07-16-M0.md)。

## 感知通道

- **uiautomator 通道下无障碍树恒空**：`mobile_list_elements_on_screen` 在微信内始终返回空，只能截图+视觉定位 → 微信类任务在 M0 是纯视觉任务，成本高一个数量级（见 [../brain/cost.md](../brain/cost.md)）。
- ⭐ **S1 已定论（2026-07-17，自研 a11y flags 拉满仍不可读）**：探针（`flagIncludeNotImportantViews|flagReportViewIds|flagRetrieveInteractiveWindows` + `canRetrieveWindowContent=true`）在**聊天列表页 / 会话页 / 键盘弹出**三态下，微信主窗口（`window type=1 pkg=com.tencent.mm`）都出现在 windows 列表，但 `window.root` **恒为 null**（bounds 全 0），微信自身贡献 **0 个可读节点**（读到的全是 vivo 系统 UI）。→ **微信维持纯视觉任务，OCR 融合层提前进 M1a**（原绑定 uiautomator 的结论被自研通道复现并强化；乐观「a11y 能读微信」分支否定）。原始记录：[../../runs/2026-07-17-M1-spike.md](../../runs/2026-07-17-M1-spike.md)。
- ✅ **键盘态可感知（即便内容不可读）**：键盘弹出时 windows 列表新增 `type=2（TYPE_INPUT_METHOD）pkg=com.baidu.input_vivo`——`type_text` 后可据此判断键盘弹/收，M0 两次误触的感知面成立。
- ✅ **OCR 通道达标（S3 实测）**：会话页 ML Kit bundled 中文 OCR 稳定态 ~450ms、关键控件（文件名/大小/消息文本/时间戳）命中且 bbox 准确（conf 0.6–0.9）——微信不可读下的主通道可用。噪声来自气泡内嵌长截图，conf 阈值过滤。
- ⭐ **M1b 融合层真机闭环（2026-07-19）**：聊天列表页 31 个 OCR 元素、ShareImgUI 选择页 17 个，全量可读可寻址；OCR ref 点击（裁剪重识校验 + dispatchGesture）→ 发送确认弹窗 → OCR 读出「发送给/取消/发送」→ 取消，链路全通。`wait_for(text_appears/text_gone)` 走 OCR 感知面在微信内可用。**dispatchGesture 点击/滑动在微信内真实生效**（行点击、选择页滚动实测）。
- ⚠️ **树空但 `findFocus(FOCUS_INPUT)` 可拿到焦点输入节点**（选择页搜索框实锤）——微信屏蔽树内容但焦点节点可获取；不过 **`ACTION_SET_TEXT` 报 true 不生效且读回 null**（与 Switch 假点击同族），**必须 IME 通道**（网关 typeText 已按「readback==null 也降级 IME + OCR 裁剪读回」实现）。

## 操作坑（实测）

- M0 发生 2 次误触（点开联系人资料页、点开聊天内敏感 PDF），均立即退出无改动。成因：键盘弹出坐标错位 + 视觉定位偏差。→ 网关已内建：敏感对话/文件黑名单、点击前二次校验、键盘状态感知。
- 发送闭环可行（ASCII 消息实测成功）；中文输入卡在 devicekit 剪贴板机制（见 [../android/common.md](../android/common.md)）→ 等网关 IME 通道复测。
- **聊天列表条目点击偶发不导航**（M0.5 复测：坐标正确也可能不进会话，两次单击无效）；跨 app 发图更稳的路径是系统分享面板 → 微信。
- **微信内相册选择器的「截屏」下拉筛选会回弹**（M0.5 复测 3 次复现，烧 ~10 轮）→ 选图环节改走系统相册 App 或 media_query+share_file（网关新链路）。
- **vivo 相册 App（com.vivo.gallery）a11y 树完整可用**：相册 → 截屏 → 打开图片 → 分享 → 微信 → 文件传输助手，全程元素定位，已实测走通——跨 app 图片任务的推荐兜底路径。

## 深链 / 分享（🔵 待验证项见 [deeplinks.md](deeplinks.md)）

- **无公开「直达指定聊天」深链**；`weixin://dl/*` 多已失效——微信类任务以 UI/分享通道为主。
- **ShareImgUI 选择页结构（M1b 实测，2026-07-19）**：「最近转发」宫格 + 「最近聊天」列表（置顶群优先，排序与聊天列表不完全一致，**文件传输助手不保证首屏**）；搜索框占位符深色模式下 OCR 漏识 ~40%（要 TTL 重试）；点联系人行 → 「发送给:」确认弹窗（取消/发送/留言输入，留言占位符同样临界）。定位策略：find 短子串「文件传输」+ scroll_search（网关手势翻页），或搜索框通道（IME 注入，占位符识别要重试）。
- 分享直达组件 `com.tencent.mm/.ui.tools.ShareImgUI` ✅ **S5 实测现版本有效**（2026-07-17）：`am start -n com.tencent.mm/.ui.tools.ShareImgUI -a android.intent.action.SEND -t image/* --eu android.intent.extra.STREAM content://media/external/images/media/<id> --grant-read-uri-permission` 成功拉起「选择聊天」页（最近转发 + 文件传输助手可选）。shell 侧未报 URI 权限错；FileProvider 语境最终验证在 M1a 代码。已回填技能包 apps.json。
- 通知 RemoteInput：⏳ **S5 待补**——`dumpsys notification --noredact` 当前微信段只有 channel 定义（直播控制/音视频邀请等），无活动消息通知带 `actions`/`RemoteInput`；需外部设备发一条消息、通知常驻时再 dump。预期阴性（国内版无直接回复）。

## 安全

- 「文件传输助手」自发自收零风险，站规白名单免确认（harness 决策点 5）；其余联系人的发送均为危险级走两段式。

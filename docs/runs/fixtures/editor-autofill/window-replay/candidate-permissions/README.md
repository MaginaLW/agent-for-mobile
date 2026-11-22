# #47 候选的普通权限能否确定输入连接属于哪个窗口

**B 仍未通过。** API 36 隔离模拟器上，固定候选在有资源名的两个右框分别返回正确的活动窗号和四边。两个匿名右框均在请求四边之前返回空。只交换 IME 几何的来源假设、保留接收方的真实活动窗与会话时，具名两场可见的几何完全相同。候选回执没有独立的 IME 来源窗号，因此四场均无法交付经过来源核验的侧别或四边。[六份实采回执](receipts.json) · [宿主核对](verify.py)

本页考察当前输入连接与无障碍应用窗口能否独立对应。合成靶的两个 Activity 实例属于同一进程、同一包和同一组件，各有一个同尺寸的空白右编辑框，屏幕位置相同。带资源名的两场使用相同资源，匿名的两场均未设置资源 ID。每个 Activity 单独记下本窗号、右框位置、连接创建次数，以及右框的实际连接收到几次四边查询。只有验收程序读取这些靶内记录。[合成靶](target/TargetActivity.java)

## 候选及权限

项目记录的 PA2553 末次在机候选为 `22899252918ba05abd0cfd393ec1b97a5bcecce3`。本轮所见 #47 本地远端跟踪引用为 `ae93377c71cdb9b3a488b6205003b31871a32099`，两者的 `app/gateway` Git 树对象均为 `accfd2640dd987bffe7e63b6d89a02457fb59736`。本次核对的是这个固定实现。合成靶与补充观察器各使用独立包和 UID。[历史在机核对](../../../../../knowledge/apps/wechat.md#横屏编辑框的四边能否单独确定输入目标) · [候选服务清单](https://github.com/MaginaLW/agent-for-mobile/blob/ae93377c71cdb9b3a488b6205003b31871a32099/app/gateway/src/main/AndroidManifest.xml)

候选由系统绑定无障碍服务与输入法。无障碍服务可以获取交互窗、控件及资源名，IME 可以接收当前编辑器契约和查询回调。候选没有注册自动填充服务，也没有系统 `DUMP` 权限。补充观察器只开这两种服务，窗口配置沿用候选的检索标志，没有声明截图、手势或联网能力。[候选无障碍配置](https://github.com/MaginaLW/agent-for-mobile/blob/ae93377c71cdb9b3a488b6205003b31871a32099/app/gateway/src/main/res/xml/a11y_config.xml) · [补充观察器](observer/AndroidManifest.xml)

原构建 APK 的 SHA-256 为 `d99baf864b9b05b64eb7f4ede861e7402dfd4536e11abe5122d0a12211efaa6c`。既有签名记录核实兼容既有实验签名的候选包与它的 540 个非签名 ZIP 条目相同。本次在空白模拟器全新安装后，独立读回的 APK 为 `0af7d9880f12992e8846ef32c3691cb97fc22bd3b35d1083f61008eb38f51dfc`，包名为 `dev.magina.gateway`。没有改动候选程序。

## 原版正常读取的四场

四场均分次调用 `keyboard_state` 的原点、四边、原点探针。屏幕坐标顺序为左、上、右、下。每场前后原点都是 `[2100,32]`，原点回执里的本地会话号分别保持 S1、S2、S3、S4。不同实验使用不同任务、窗口及会话；S1–S4 是一致替换后的标签。靶内通过屏幕布局和无障碍节点两路取得相同的右框四边。[原版与靶内回执](receipts.json)

| 实例 | 靶内任务 / 窗号 | 原版四边回执 | 右连接四边请求数 | 实验真值与 B 的独立验收 |
|---|---|---|---|---|
| 有名 1 | 9 / 13 | 窗 13，S1，`[2100,32,2300,102]` | 0 → 1 | 真值为本窗右框；候选单独交付的来源、侧别、四边均空 |
| 有名 2 | 10 / 15 | 窗 15，S2，`[2100,32,2300,102]` | 0 → 1 | 同上 |
| 匿名 1 | 11 / 17 | 空，`missing_id / before_sample / service_node_unnamed` | 0 → 0 | 真实右框持焦，原点可读；独立来源、侧别、四边均空 |
| 匿名 2 | 12 / 19 | 同上 | 0 → 0 | 同上 |

两个有名右框的靶内 `EditorInfo.fieldId` 同为 2130771968，两匿名框同为 −1。匿名合成靶确实遇到“服务焦点节点未命名”。以往 PA2553 的细分原因为 `field_id_unresolved`，其实际字段整数和结构均未知。[匿名靶实现](target/TargetActivity.java) · [历史在机回执](../../../../../knowledge/apps/wechat.md#横屏编辑框的四边能否单独确定输入目标)

## 冻结回执后核对两个不同问题

| 宿主核对 | 正配与双向错配 | 能判定什么 |
|---|---|---|
| **整份有名回执与外部已知目标窗号** | 13→13、15→15 相符；13→15、15→13 均不符 | 外部先有目标的真实窗号，就能识别整份回执描述了另一个无障碍活动窗。这是宿主整数比对；原入口没有目标窗号参数和这项拒绝。 |
| **固定接收方 13，只改变 IME 几何的来源假设** | 本窗 13 或同包窗 15 均为 `[2100,32,2300,102]`。接收方的窗 13、S1、契约和前后检查相同 | 两个假设交给四边判读器的值相同，接收方原始实测成功。IME 来源字段缺失，两个假设的可交付来源、侧别、四边均空。 |
| **固定接收方 15，只改变 IME 几何的来源假设** | 本窗 15 或同包窗 13 均为上述四边。接收方的窗 15、S2、契约和前后检查相同 | 反方向结果相同。 |
| **固定匿名接收方 17 或 19** | 本窗与对窗假设共四项。两份正常回执都在几何到达前结束 | 正配本身也没有几何。两个方向均空，无法把这一拒绝归因于识别出错窗。 |

交叉项是对两份已冻结回执的值进行宿主核对。具体实现从本轮接收方的 `editorContract` 提取字段号；有名成功分支又要求 IME 的浮点四边与无障碍四边逐边精确相等。因此可以从两份原版成功回执核验这一部分输入在两种来源假设下等价，无须把外部窗号、另一场会话号或另一个连接塞入回调。运行中的原版始终查询各自真实的当前连接。关于“系统真的投错”的发生率或可达性，本实验没有观测值。[判定代码](https://github.com/MaginaLW/agent-for-mobile/blob/ae93377c71cdb9b3a488b6205003b31871a32099/app/gateway/src/main/java/dev/magina/gateway/tools/EditorBoundsDiagnostic.kt#L228-L269) · [连接及字段取值](https://github.com/MaginaLW/agent-for-mobile/blob/ae93377c71cdb9b3a488b6205003b31871a32099/app/gateway/src/main/java/dev/magina/gateway/ime/GatewayIme.kt#L302-L316)

宿主分别固定每个接收方的正常前台包、会话、无障碍窗、可编辑标志与前后原点，对两份实采可还原的几何逐一计数。有名两场均余两个相容来源，匿名两场没有发出四边请求。只在内存中将第二场几何的左边改动 1 像素，第一接收方就只剩第一场几何吻合；另把第二场靶内字段号加 1，“两靶字段相同”的前提立即失效。后一个控制只检验两靶材料，不把发送方的靶内字段号假定为光标回调里的字段。[宿主核对与两项变异](verify.py)

## 第二条普通权限通道

两次新开匿名 Activity，同一补充观察器经过系统绑定。从无障碍服务实际取得的活动根、服务输入焦点、根内输入焦点和节点窗口分别一致指向 22、24，均与靶内窗号相符。两场窗口都在显示屏 0，右框几何相同。控件与根的 `uniqueId`、节点资源名、窗口 anchor 均为空。输入法在前后检查同一 `InputConnection` 对象，两场的输入绑定 UID 为 10216、PID 为 4060，Binder 对象通过相等判断得到同一标签 1。原生 Autofill view ID 同为 1073741825，附带的自动填充会话号同为 0。IME 本地代次从 7 变为 11。此例可以识别无障碍窗口发生切换，仍缺少从 IME 端标识到窗 22 或 24 的独立对应关系。该补充检查仅在原生空白 EditText 上实测。[窗口及焦点检查](observer/WindowProbe.java) · [输入绑定、API 36 字段及前后复核](observer/ImeProbe.java) · [两端回执](receipts.json)

## 宿主复核

```powershell
python docs/runs/fixtures/editor-autofill/window-replay/candidate-permissions/verify.py
```

默认仅使用随附 JSON，输出四种整份回执配对和八种 IME 来源配对。退出码 0 表示宿主复核了实测及其等价关系，业务判定是 `source_window_acceptance=BLOCKED`。`--capture <专用测试台收尾目录>` 可从同格式的六份专用回执和状态重新生成脱敏 JSON，无须访问设备。实际收尾用时 269 秒，十项设置均已恢复，三个测试包已卸载，自建模拟器和 ADB 服务均已退出，四个声明端口均释放。运行期仅对空白合成靶作诊断读取；交叉配对在宿主完成。[宿主核对](verify.py) · [实采摘要](receipts.json)

## 数据来自哪一端

| 字段 | 产生位置与已知范围 |
|---|---|
| `window_id` | 候选在清除缓存后定位当前应用窗口，复核根与服务输入焦点，最后写出采样后无障碍窗口的 ID。 |
| `session_id` | 候选输入法根据包、字段、输入类型、选项和递增的本地代次产生。可以比较一次查询前后的新鲜度。 |
| 四边请求 | 输入法在锁内核对待处理请求的连接对象、当下连接和会话。交给判读器的值只有当前编辑契约的整数 `fieldId` 和由 `CursorAnchorInfo` 换算的四个屏幕坐标。 |
| 原点查询 | 对当前连接发一次屏外空区间查询，检查当前连接、会话与返回矩阵。返回局部原点和会话号。 |
| 普通权限补充观察 | 在独立的两场运行中读取 `root.getWindow()`、服务与根的输入焦点、节点的窗口/资源/unique ID、窗口 anchor；IME 同时取输入绑定的 UID、PID、按 Binder 相等性分配的本场标签和 API 36 `EditorInfo.getAutofillId()`。仅记录元数据，在稳定连接、稳定窗口前后校验后落盘。 |

`keyboard_state` 的公开参数只有两个布尔探针。调用者无法在这个入口传入一个待核验的来源窗号。返回窗号、会话号及靶内窗号分别来自不同的路径，任意两个整数偶然相等也没有接口定义的身份含义。[候选服务入口](https://github.com/MaginaLW/agent-for-mobile/blob/ae93377c71cdb9b3a488b6205003b31871a32099/app/gateway/src/main/java/dev/magina/gateway/mcp/ToolRegistry.kt#L118-L124) · [候选四边判读](https://github.com/MaginaLW/agent-for-mobile/blob/ae93377c71cdb9b3a488b6205003b31871a32099/app/gateway/src/main/java/dev/magina/gateway/tools/EditorBoundsDiagnostic.kt#L219-L268) · [输入法连接复核](https://github.com/MaginaLW/agent-for-mobile/blob/ae93377c71cdb9b3a488b6205003b31871a32099/app/gateway/src/main/java/dev/magina/gateway/ime/GatewayIme.kt#L301-L344) · [补充观察代码](observer/ImeProbe.java)

Android 将 `InputBinding.getConnectionToken()` 定义为输入连接的 IPC token。无障碍窗口公开的 `getId()` 标识无障碍窗口，`getAnchor()` 只在窗口有锚点时返回节点。`AccessibilityNodeInfo.getUniqueId()` 由提供节点的一端设置，可以为空。API 36 的 IME 可以取得当前 View 的 AutofillId；原生字段号的分配范围为单个 Activity 实例。[InputBinding](https://developer.android.com/reference/android/view/inputmethod/InputBinding#getConnectionToken()) · [AccessibilityWindowInfo](https://developer.android.com/reference/android/view/accessibility/AccessibilityWindowInfo#getAnchor()) · [AccessibilityNodeInfo](https://developer.android.com/reference/android/view/accessibility/AccessibilityNodeInfo#getUniqueId()) · [EditorInfo](https://developer.android.com/reference/android/view/inputmethod/EditorInfo#getAutofillId()) · [Android 16 Activity](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-16.0.0_r1/core/java/android/app/Activity.java)

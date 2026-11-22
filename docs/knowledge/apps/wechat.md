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

现场用户说明，输入文字后微信才显示「发送」，并在右窗留了一条未发送的草稿。第二次派单保留了展开的软键盘。网关再次在右窗顶部找到「文件传输助手」，并在同一窗口右下方精确匹配到唯一的「发送」。标签下缘距键盘上缘 52 像素。两次查找的页面修订号相同；「发送」的来源为 OCR，角色为 `text`，有元素引用。由此核实了有草稿时的标签位置。按钮的实际点击、确认卡和投递效果仍待验。

本次宿主基于 `7ebafb8`，已装网关摘要与 `a9aee63` 构建一致。一次前台查询和两次不滚动的定向查找均成功，台账为 `success`，耗时 29 秒。执行器没有点击、输入或发送。[派单台账](../../runs/ledger.csv)

### 横屏发送确认卡试验

现场用户随后授权向文件传输助手发送一条指定测试文字。点击前，执行器确认微信处于同应用双窗，右窗顶部的会话标题精确匹配；查找约定的草稿文字时，`ui_find` 返回 `E_NOT_FOUND`，派单随即结束。该回执只能说明本次查询未匹配到标记，草稿的实际内容及未匹配原因仍未知。

宿主基于 `b8c5ed7`，在机网关与 `a9aee63` 的已验 APK 摘要一致。三次执行器调用各对应同一网关进程中的一条新增审计记录。发送点击 0 次，确认卡 0 次，本轮未发送测试消息。台账保留 `fail / not-found`，用时 23 秒。[派单台账](../../runs/ledger.csv)

### 横屏自动准备草稿与发送复核

11 月 19 日，PA2553 微信右窗已有文字且键盘展开。执行器核对「文件传输助手」标题和右窗底部唯一的「发送」，用标签位置定位同一行的编辑栏。仅裁该输入栏即可目检草稿是否等于测试串，现场用户无需抄录草稿、清框或重打。

用户允许覆盖原稿后，宿主核对系统焦点和输入法目标指向同一微信会话窗口，临时选用网关输入法。执行器复核右窗标题和输入焦点，以 `type_text(mode=replace)` 覆盖一次。网关返回已写入且 OCR 验证通过，但读回字符串与测试串并非逐字相等。宿主恢复原输入法及启用清单并回读核实，随后执行器在编辑栏局部图中确认整行仅有指定测试文字。

发送试验请求点击一次。设备审计记录了现场确认卡的允许决定及随后的目标复核。网关返回 `E_STALE_REF`（确认后 UI 目标证据已变化），在执行实际点击前拦截，派单终止；没有后续工具调用或消息区投递证据。宿主基于 `a8ba1de`，收尾读回的网关 APK 摘要与 `a9aee63` 构建一致。三次派单依次记录为只读核对成功、覆盖准备成功、发送试验 `fail / stale-context`。[派单台账](../../runs/ledger.csv)

回执中的点击引用与右窗「发送」的 OCR 引用一致。按该构建源码，确认前后解析同一 OCR 引用时，标签、描述、来源和窗口归属沿用缓存，重新识别会更新文字边框。结合实际错误分支，可将差异定位到两次识别所得的边框；当时没有记录两组坐标，无法判断控件是否实际移动，也无法量化识别偏差。[OCR 引用复核](../../../app/gateway/src/main/java/dev/magina/gateway/a11y/GatewayA11yService.kt) · [确认后目标比较](../../../app/gateway/src/main/java/dev/magina/gateway/core/SafetyGate.kt)

11 月 20 日离线复查三次派单，键盘高度均为 781 像素，`ui_find` 初次定位「发送」所得的右窗边框均为 `[2674,1097][2751,1135]`。发送试验最后一次取图与拦截返回时，会话 Activity、同应用双窗状态和键盘高度也一致。两次采样之间的布局仍未知。确认前和确认后会各自重新识别文字，后一次还会以上一次识别框为中心裁图。比较两次复核要读取这两个重新识别的框。像素偏差的大小本身不足以判定原因。

### 一像素边框差异的真机回执

11 月 20 日，PA2553 覆盖安装同签名的 `aefb05a` 网关，在机 APK 的 SHA-256 与候选一致。重启后的网关只能自举微信包名，未报告 Activity。系统焦点与输入法目标指向同一个微信 `ChattingUI` 窗口，执行器另行核实了右窗标题。只读检查在键盘收起的编辑行逐字核对旧稿；临时输入法下的 OCR 同时返回两个重叠文本框，用局部图再次核对后覆盖一次。原输入法恢复后，执行器逐字确认了新测试串。两次在写入前停止的准备派单保留原判。[派单台账](../../runs/ledger.csv)

设备确认卡收到一次真人允许。`ui_find` 的初次定位框为 `[2674,1877][2750,1914]`；网关确认前重新识别为 `[2674,1877][2750,1915]`，确认后为 `[2674,1877][2751,1914]`。左边和上边一致，右边向右 1 像素，下边向上 1 像素。审计与执行回执一致，唯一的点击请求以 `E_STALE_REF` 结束，实际点击与后续工具调用均为零。

这次派单的键盘读数始终为隐藏。用 2800 × 1968 的屏幕和上述坐标代入该构建的裁图算法，两次裁图的上边分别为 1785、1786 像素，其余三边一致。两帧目标区域的原始像素没有留存，控件是否移动仍未知。

收尾时对照安装前基线，原 vivo 输入法附带的一项无障碍服务缺失，系统设置标明当前值的写入者为该输入法。按原清单恢复后，默认输入法、已启用输入法、无障碍服务清单和无障碍总开关均逐项相等。本轮启动的网关前台服务已停止，端口转发及设备锁已释放。

同日用两张合成「发送」按钮图复现了裁区效应。静止画面只改裁区上边一像素就会改变识别框，固定裁区重复三次则各自一致。候选网关保留初次快照中的裁区锚点，每次从当前帧读取实际边框。固定裁区下平移按钮，两种样式均能检出移动。[样本、边框与复现方法](../../runs/2026-11-20-OCR固定裁区离线对照.md)

### 固定裁区版本在左窗就位时停止

2026-11-20，网关 `dde8139` 已在 PA2553 上以原调试签名覆盖安装。系统回读的 APK SHA-256 为 `f9ec95e4c25abfd447d6c905ded0dc8128a70b53d8f27a82319c86f5601fe64e`，与已验签的安装包相同。派单脚本取自同一提交，与合入后的 `0531987` 源码树一致。

安装后，系统焦点与输入法目标均指向微信 `LauncherUI`。网关读到同应用双窗，左窗活动并持有焦点，右窗显示「文件传输助手」标题。全屏查找在右窗标题和左窗会话行各命中一次，置信度均为 0.57。执行器仅请求点击左窗会话行。网关以动作识别门槛 0.65 对该引用重新裁图识别，未能匹配目标，返回视觉通道的 `E_STALE_REF`。两次取图分别用于查找和动作复核，局部识别中目标本身的分数未知。[识别门槛](../../../app/gateway/src/main/java/dev/magina/gateway/a11y/VisionTrustPolicy.kt)

设备审计与执行回执核实，失败发生在导航手势执行前，之后的工具调用为零。本轮没有写入草稿、请求发送或弹出确认卡。收尾时四项输入法与无障碍设置均与安装前相同，网关前台服务和本轮端口转发均已释放。固定裁区对横屏微信发送复核的实际效果仍待右窗会话就位后检验。[派单台账](../../runs/ledger.csv)

### 右窗备稿成功，发送确认卡超时

2026-11-20，PA2553 的在机摘要仍与 `dde8139` 的同签名安装包相同。现场轻点右窗输入框后，系统焦点和输入法目标均指向同一个微信 `ChattingUI`。网关确认右窗已活动、持有焦点，顶部为「文件传输助手」。派单脚本取自 `7740e58`。

微信没有返回可寻址的原生输入框。首次准备在查找 `role=input` 时收到 `E_NOT_FOUND`，执行器随后多做了一次只读文字查找，未写入。接下来的只读派单在 180 秒后超时：设备只记到预检，宿主只记到回合开始，未发生截图。事后用同一官方订阅通道做纯文本对照，5.9 秒得到完整答复；首次超时的具体原因仍未知。

用户授权核对编辑栏局部图后，执行器在键盘隐藏时从右窗裁取 `[927,1858,2800,1923]` 核对原稿，随后成功写入一次测试串。网关报告 `committed=true`、`verified=true`；OCR 回读包含测试串和额外字符。恢复原输入法后，键盘高 781 像素，编辑行随之上移。全屏 OCR 返回两个重叠命中，其中一个精确等于测试串，单凭这两个框无法判断整行内容。按当时「发送」的实时位置裁取 `[927,1078,2800,1154]`，局部图核实输入框内只有指定测试串。这两组坐标仅适用于本次布局。

实际请求点击前，执行器再次核对整行和右窗唯一的「发送」，最新按钮框为 `[2674,1097,2751,1135]`。宿主观察到设备上的确认悬浮窗。设备审计记录了一次 `ui_action(click)`，结果为 `E_CONFIRM_TIMEOUT`，没有允许或拒绝记录，也没有确认后复核。实际发送点击和后续工具调用均为零。收尾时两次运行的四项输入法及无障碍设置均与各自基线相同，服务和转发均已回收。[派单台账](../../runs/ledger.csv)

### 保留草稿后的独立现场验收

2026-11-20，宿主派单器取自 `413b259`，PA2553 上的网关与 `dde8139` 构建摘要一致。微信右窗已聚焦，原输入法键盘展开。执行器直接复核已有草稿，未调用输入工具。测试串的唯一精确命中位于编辑栏。执行器只截取一次编辑行，逐字核实整行，截图前后查到的右窗「发送」框均为 `[2674,1097,2751,1135]`。

宿主观察到确认悬浮窗并提醒现场用户。设备审计记下一次点击请求，通道为 `overlay`，结果为 `E_CONFIRM_TIMEOUT`。网关未收到允许或拒绝，也未进入确认后复核。实际点击与终态后的工具调用均为零。四项输入法及无障碍设置、前台服务和端口转发均已回到本轮基线。[派单台账](../../runs/ledger.csv)

### 已在右窗时的就位验收

2026-11-20，宿主 `1523746` 经唯一已授权 PA2553 和在机 APK 摘要检查派单一次，网关构建为 `dde8139`。派单耗时 21 秒。两条带审计编号的回执分别来自 `foreground_app` 和定向 `ui_find`。两次读数的页面修订号一致，键盘可见。系统有两个并排的微信窗口，活动与焦点都在右窗。查询「文件传输助手」只命中右窗顶部一处，OCR 完整匹配。执行器把左窗同名行也当成就位前提，随后报告失败。启动应用、导航点击、聚焦点击、输入、图片调取和发送调用均为零，无现场导航或确认卡。

准备入口的任务卡据此调整。若右窗已经活动、持有焦点且顶部标题匹配，直接核对右窗底部输入框；需要切换会话时才检查左侧会话行。本轮在编辑栏查找前结束，未验到其输入焦点和草稿内容。[准备规程](../../runbooks/P0-safety-hard-gate-smoke.md#横屏会话导航预演)

派单结束时，四项输入法和无障碍设置以及端口转发与入场基线一致，本轮自启的网关前台服务仍在。宿主持锁核实服务创建时间落在本次派单内、只有一次启动，然后以所属应用身份停止。即时读回仍见服务，后续独立读回已恢复缺席基线。准备入口已加入所属应用身份停止和有界读回。[派单台账](../../runs/ledger.csv)

### 右窗编辑栏查找与自动收尾

2026-11-20，宿主 `b177f99` 在 PA2553 上独立派单一次，在机网关 SHA-256 与 `dde8139` 候选一致。从已聚焦的微信右窗开始，依次读取前台窗口、定向查找「文件传输助手」、读取键盘、查找 `role=input`。四条回执有不同审计编号，页面修订号相同。右窗顶部唯一 OCR 命中与标题完全相符。标题查询附带的输入焦点标识和边框均为空，键盘可见、高 781 像素。最后一次查找返回无障碍通道 `E_NOT_FOUND`，后续工具调用为零。未进入编辑栏点击或草稿读写，也未出现确认卡。

此版本按原生节点的 `isEditable` 标记生成输入角色，独立 OCR 元素的角色为 `text`。本次回执能定位右窗标题，但没有能证明编辑栏焦点的引用，草稿是否为空也未知。[网关角色与查找实现](../../../app/gateway/src/main/java/dev/magina/gateway/a11y/GatewayA11yService.kt)

派单耗时 27 秒，整个准备入口用时 32.8 秒。入口前后在同一设备锁内独立比对，网关前台服务和对应端口转发两次均不存在，默认输入法、已启用输入法、无障碍服务清单及总开关逐项一致。此次无须补做清理，业务台账保留 `fail / not-found`。[派单台账](../../runs/ledger.csv)

### 缺少原生编辑框时怎样核对焦点

PA2553 的原输入法在位时，窗口焦点与输入法目标相同能确认会话窗口。Android 16 的标准输入法诊断还可能显示当前服务的 View。该 View 的四边相对父视图，换算到屏幕还涉及祖先滚动、变换和窗口偏移。全窗口编码转储会遍历其他窗口，标准 TextView 也会编码正文。横屏准备入口继续使用定向查找。[Android 16 View 实现](https://android.googlesource.com/platform/frameworks/base/+/android-16.0.0_r1/core/java/android/view/View.java) · [TextView 实现](https://android.googlesource.com/platform/frameworks/base/+/android-16.0.0_r1/core/java/android/widget/TextView.java)

候选网关提供可选的 `keyboard_state(probe_editor_origin=true)`。Android 14 及以上、网关输入法已在位且活动连接属于前台应用时，该调用触发一次屏幕外的空区域查询。网关只接受空字符范围，从返回矩阵映射编辑器局部原点，并在回调时复核连接及会话世代。最多等待 2 秒，首次失败或超时即结束。有效结果含会话 ID 和屏幕坐标，无法复核时 `ime_editor_origin` 为空。普通 `keyboard_state` 仍只查询键盘显隐与高度。[网关几何查询](../../../app/gateway/src/main/java/dev/magina/gateway/ime/EditorOriginProbe.java)

这个点可以与独立取得的候选编辑框比对。一个点没有宽、高，同原点的两个候选也无法用它区分。自动就位仍需右窗唯一编辑框和系统窗口归属；不能以该点生成点击引用。切换或恢复输入法后要重新取证。原生回执现在同时核对页面修订号、左右窗口边界、标题、可用底部及编辑框身份。上下各五分之一和距底边最多一行是当前宿主对横屏布局的假设，仍待平板标定。[宿主核对](../../../scripts/lib/dispatch-landscape.ps1)

### PA2553 原点诊断停在旧网关预检

2026-11-20，候选源码 `f913fb4` 的网关构建已同签验核。PA2553 入场时已解锁，系统焦点与输入法目标属于同一个微信 ChattingUI。单次派单入口在核对会话标题前以退出码 4 结束，台账为 `preflight-fail`。旧网关的服务启动请求发出后，宿主在 3 秒内未核实前台状态。Codex 执行器启动次数、业务工具调用、安装、输入法切换、编辑栏点击、输入和发送均为零，未取得微信的编辑器原点。

一次性宿主为跳过已解锁设备的唤醒命令，在函数内给 `$LASTEXITCODE` 赋了 0。该局部变量遮蔽了后续原生进程的真实退出码，导致原有的 `run-as` 启动分支没有执行。那条启动命令在设备上的实际返回码未记录。独立修正版将唤醒命令和对应的错误分支一起移除，用原生假 ADB 经实际预检函数复验。普通启动返回 17 后，两例均进入 `run-as`。返回 0 时核实前台并回收服务，返回 23 时记录失败且未认领服务。

首次自动收尾核实了四项设置与端口转发，服务记录仍在。随后在设备锁内核对唯一网关记录的创建时间落在本轮窗口，以所属应用身份请求停止一次。记录器误读了返回对象的字段，停止命令的即时应答未记录。最终独立读回确认服务与转发均缺席，四项设置逐项匹配，设备仍是 `dde8139` 的已验签 APK。本轮未再派单。[派单台账](../../runs/ledger.csv)

### 候选网关返回原点不可用

2026-11-20，PA2553 从已聚焦的右窗开始。修正宿主用一次派单完成五次定向读取，耗时 82 秒。前两次核对了微信右窗与「文件传输助手」标题。保数据安装同签候选 `f913fb4`、复核 APK 摘要并临时选中网关输入法后，再次核对了同一会话窗口及标题。第五次 `keyboard_state(probe_editor_origin=true)` 的结果中没有可验证的原点对象，过滤器记录 `editor-origin-unavailable` 后结束。全程没有导航点击、输入、发送或业务确认卡。

网关的空结果可来自没有匹配的活动输入连接、编辑器回调没有提供合格几何、请求超时或连接在查询期间变化。本次回执不能区分这些情况，也无法确定输入框四边。[键盘查询](../../../app/gateway/src/main/java/dev/magina/gateway/tools/SystemTools.kt) · [编辑器回调](../../../app/gateway/src/main/java/dev/magina/gateway/ime/EditorOriginProbe.java)

宿主的首次收尾报告设置不匹配。随后在设备锁内逐项读回，确认原默认输入法、启用的输入法清单和无障碍总开关均匹配。服务和转发回到入场时的缺席状态，同签候选已保留。无障碍服务清单少了一项原已启用的非网关服务，没有新增项。移除时间及原因未知，本轮保留了这项差异。

### 恢复原有无障碍服务

2026-11-20，用户授权恢复缺失的输入法无障碍服务。入场清单含一个前导冒号，首次格式检查在设备写入前结束。按非空成员核对差异、保留原始清单格式后，宿主只写入一次启用清单。首次读回与入场清单逐字一致，其余三项设置以及网关服务、端口转发均匹配。

约 73 秒后再次只读核对，原四项设置和网关资源仍匹配。Android 当前用户下选定组件只有一条服务记录，系统客户端已收到 Binder，`hasBound=true`。本次恢复没有触发微信业务派单。该组件的系统绑定和微信编辑框的输入焦点分别验收。

### 等待候选网关就绪超时

2026-11-20，在 PA2553 已聚焦的微信右窗，用旧网关完成两次读取并核实「文件传输助手」标题，随后发起一次同签覆盖安装。派单等待候选 `e994c71` 就绪的 360 秒窗口到期，回执为 `candidate-timeout`。派单共 398 秒，输入法切换、编辑器原点查询、微信点击、输入和发送次数均为零。`candidate-timeout` 出现在安装阶段，微信编辑器是否返回几何数据仍未知。[诊断候选 PR #40](https://github.com/MaginaLW/agent-for-mobile/pull/40)

安装随后完成，宿主和独立读回都核实了候选 APK 摘要。四项系统设置、网关服务和端口转发与入场一致。另一次组件读回确认，vivo 输入法原有无障碍服务仍启用，且系统客户端持有活动 Binder。本轮没有再次写入无障碍服务清单。

### 免安装复测返回 no_verified_geometry

2026-11-20，PA2553 直接使用已验签的 `e994c71`。切换网关输入法前后各用两次读取核实同一活动右窗及「文件传输助手」标题。第五次 `keyboard_state(probe_editor_origin=true)` 查询返回空原点，原因是 `no_verified_geometry`。派单用时 26 秒，安装、微信点击、输入和发送次数均为零。

按受测源码，这次查询已选中输入连接，完成时该连接仍通过校验。此原因涵盖返回状态不成功、几何对象缺失、字符范围非空及坐标变换无法验证等情形。回执未细分这些情况，不能据此确定微信采用了哪种实现，也未取得可用于点击的编辑框四边。[受测探针](https://github.com/MaginaLW/agent-for-mobile/blob/e994c716a8fa7b6b22a1011c976b7b08bc972df6/app/gateway/src/main/java/dev/magina/gateway/ime/EditorOriginProbe.java)

宿主已恢复默认输入法和启用的输入法清单，网关前台服务及转发均已回收。独立读回发现无障碍服务清单仅缺入场时启用的 vivo 输入法服务。按授权写回该项一次后，四项设置逐字匹配入场值。随后独立读回确认系统客户端已收到该组件的 Binder，`hasBound=true`。本次记录不能确定哪一方移除了该项。

重放既有 Android 16 合成回执时只比较四边。忽略原点字段后，4/4 个矩形与靶应用实测边界一致，均与同原点但尺寸不同的对照框有别。把前一阶段的矩形代入下一阶段，0/3 匹配。把上一次聚焦同一框时的旧矩形代入再次聚焦的阶段，2/2 仍匹配。即使尺寸和位置完全相符，仍需独立证据证明回调来自这一次输入连接。这是对保存读数的重放，真机上是否会迟到仍未知。[合成场景](../../runs/fixtures/editor-origin/README.md)

### 原点为空时的四边实验

2026-11-20，在隔离的 Android 16 模拟器上，合成编辑框对原点查询显式返回不支持，保留标准四边更新。独立进程中的输入法依次观察甲、乙、甲、乙四次聚焦，覆盖空稿和有稿。原点均为空，四个矩形均与靶应用实测的当前可见四边一致，并排除了同原点、尺寸不同的对照框。

输入法在收到回调时记住当时的请求对象和输入连接，再将同一份数据延后处理。换框后三次处理前一阶段样本、两次处理再次聚焦同一框前的样本，五份均被拒绝。该检查覆盖输入法内部的延后处理。若系统在换框后才首次送达事件，公开回调只有位置对象，不能从签名中直接取得请求编号。本次没有观测到可证实来源的此类系统事件，微信的编辑框归属仍待验。[Android 输入法回调](https://developer.android.com/reference/android/inputmethodservice/InputMethodService#onUpdateCursorAnchorInfo(android.view.inputmethod.CursorAnchorInfo))

针对首次送达，Android 16 源码显示应用侧发送前会检查传入 View 是否由输入法服务，并核对编辑器和系统输入法会话是否就绪。跨进程接口随后只传递 `CursorAnchorInfo`。输入法服务收到时检查会话是否启用，再把位置对象交给公开回调。发送端的检查不能给接收方提供可与本次四边请求逐一核对的编号。这份源码也没有证明 PA2553 发生过错序。[应用侧检查](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-16.0.0_r1/core/java/android/view/inputmethod/InputMethodManager.java#L4195-L4216) · [跨进程接口](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-16.0.0_r1/core/java/com/android/internal/inputmethod/IInputMethodSession.aidl#L51) · [输入法回调](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-16.0.0_r1/core/java/android/inputmethodservice/InputMethodService.java#L1532-L1537)

首次启动因干净实例缺少历史合成包，在安装前结束。修正入口后使用同一 APK 运行四个场景，共 86 秒，含启动与收尾。原默认输入法及启用清单均恢复，私有 ADB、模拟器和端口均已释放。

### 用当前输入焦点核对四边

2026-11-20，Android 16 隔离模拟器上的输入法从独立进程返回字段 ID 和四边。测试观察器在靶应用进程中通过系统无障碍接口连续两次读取当前输入焦点，分别清除缓存。两次均须指向同一个活动、获得焦点的应用窗口及同一个可见节点。对于具名节点，再核实该资源名在窗口中只匹配此节点。靶应用另行测量真实控件和同原点对照框。

| 当前输入框 | 系统焦点和输入法样本的核对结果 |
|---|---|
| 甲，空稿 | 资源名与四边匹配。 |
| 乙，有稿，节点报告不可编辑 | 资源名与四边仍匹配；来自甲的样本因身份不同被拒绝。 |
| 甲，有稿，加宽 12 像素 | 当前样本匹配。第一次聚焦甲的样本身份相同，旧宽度被拒绝。 |
| 乙，空稿，只有运行时 ID | 焦点与输入法的四边一致。无法核实资源名，返回 `missing_id`。 |

首次启动测试在第一份输入法回执到达前结束，未进行焦点核对。调整顺序，先启动观察器，再由模拟器宿主选择并读回实验输入法，四个场景均取得预期结果。用时 94 秒，含启动与收尾，两轮均恢复了原默认输入法、启用清单并释放端口。观察器和输入法均属于同一合成包。该实验能核对当前控件的身份和几何，系统首次送达回调的请求归属、第三方应用的字段可见性及微信真机结果都仍待验证。

### 跨应用网关四边诊断

2026-11-20，在 Android 16 隔离模拟器上，网关和测试编辑器安装为两个不同 UID 的应用。候选 `50c17a2` 保留在机 #40 的原点失败原因，新增只读参数 `keyboard_state({"probe_editor_bounds":true})`。网关在输入法取样前后核对系统输入焦点，在目标包资源表中解析输入法声明的字段，然后比对屏幕四边。普通的无参数键盘查询保持原有响应。

| 测试应用提供的场景 | 网关 MCP 回执 |
|---|---|
| 正常具名编辑框 | 窗口号和四边均匹配。矩形为 [43, 120, 276, 190]，同原点的较大对照框被排除。 |
| 同一布局，节点报告不可编辑 | 四边仍匹配，`editable=false`。 |
| 字段 ID 指向另一个具名控件 | `different_id`，四边为空。 |
| 同一具名控件，无障碍右边界从 276 变为 288 | `different_bounds`，四边为空。靶应用记录一次输入法四边请求。 |
| 编辑框只有动态 ID | `missing_id`，四边为空。靶应用记录的四边请求为零。 |

首轮五次查询均符合预期，四项设置和端口已恢复。Android 报告服务已停止，宿主把停止命令的退出码视为错误，未完成独立的服务状态读回，因此首轮整体验收记为失败。

第二轮使用相同的两个 APK。在第一份无参数键盘回执中，宿主未能核实前台就是靶应用，于是停止，正式四边查询为零。收尾时记录到停止命令退出码 255 及 `Service stopped`，随后独立查询确认为空。四项设置均恢复，模拟器、私有 ADB 和端口均释放。两轮分别取得了五个场景的功能结果和独立的停止回执；完整单轮尚未通过。

第三轮在首次键盘查询前增加了网关前台核对。靶应用报告窗口 13，网关也选中窗口 13，且回报该窗口活动、已聚焦。网关仍返回 `window_id_mismatch`。该轮版本 `50c17a2` 只在已跟踪的前台身份与当前应用窗口的窗口号不同时返回这个原因。宿主未保存跟踪身份的窗口号或近期事件，无法定位具体事件。首个场景随即停止，四边查询为零。宿主核实四项设置、服务和端口均已恢复。[前台身份与应用窗口的判定](https://github.com/MaginaLW/agent-for-mobile/blob/50c17a2/app/gateway/src/main/java/dev/magina/gateway/a11y/ForegroundWindowTracker.kt#L58-L82)

### PA2553 右窗四边诊断返回 focus_unavailable

2026-11-20，PA2553 在微信「文件传输助手」右窗已就位。派单先核实前台和右窗标题，再同签保数据更新网关至 `50c17a2` 并临时选择网关输入法。切换后再次核实了同一窗口号、右窗范围及标题。第五次读取是本轮唯一一次四边查询，网关返回 `focus_unavailable` 和空四边，派单随即结束。49 秒内共发起五次读取，微信内零点击、零输入、零发送。

该版本在缓存刷新失败、活动根或窗口缺失、取不到焦点节点、节点刷新或焦点一致性检查失败时，都会返回同一原因。本轮回执无法区分具体条件，也无法判断微信编辑框是否有可用的资源名。

宿主首次回选原输入法失败。独立复核时系统仍选中网关输入法，原 vivo 输入法仍在系统可选清单中。通过系统输入法管理器回选一次并读回原值后，无障碍清单只缺原 vivo 输入法服务。补回该项一次，独立读回确认默认输入法、启用的输入法、无障碍总开关及服务清单均与入场完全一致。系统客户端已收到该服务的 Binder，`hasBound=true`。网关前台服务及端口转发均已释放，候选 APK 保留在机。

### 细分焦点诊断在派单前停止

2026-11-21，候选 `8d02ed3` 完成与在机网关的同签校验，540 个非签名条目与受测 APK 一致。PA2553 已解锁。入场检查要求系统当前焦点与输入法目标均能唯一匹配微信会话窗口，两者的窗口令牌还须相同。本轮未满足该条件，回执没有区分具体是哪一项失败。宿主在核对会话标题前即退出，业务派单、安装、输入法切换及四边查询均为零。

宿主退出时对照本轮入场值核实了四项设置和网关资源。入场检查提前终止，基线只保存在内存中。随后的独立只读核对以此前已验证的基准作比较，确认默认输入法、启用的输入法、无障碍总开关及服务清单逐项相等，网关前台服务和端口转发均已释放。原 vivo 服务已绑定系统客户端，在机 APK 仍为 `50c17a2`。

### 重新就位后输入焦点节点为空

2026-11-21，PA2553 在「文件传输助手」右窗重新就位。派单在切换输入法前后分别核实前台和会话标题，两次右窗的窗口号、范围均相同。候选 `8d02ed3` 已同签保数据安装并核实在机摘要。第五次读取是唯一一次四边查询，返回空矩形、`focus_unavailable`、`before_sample` 和 `input_focus_missing`。该次派单耗时 303 秒，微信内零点击、零输入、零发送。

该回执表明缓存刷新、活动根和应用窗口检查均已通过。随后，无障碍服务调用 `findFocus(FOCUS_INPUT)` 得到空节点，网关在发出输入法几何请求之前结束查询。本轮没有测得编辑框四边，也没有取得窗口根查询输入焦点的结果；微信编辑框是否暴露具名节点仍未知。

宿主回选了入场的 vivo 默认输入法并读回。独立核对发现仅缺入场时已启用的 vivo 输入法无障碍服务，补回一次后，默认输入法、启用的输入法、无障碍总开关和服务清单均与本轮入场值一致。系统客户端已收到该服务的 Binder，`hasBound=true`。本轮网关前台服务及端口转发均已释放，候选保留在机。

### 窗口字段与输入连接的离线核对

候选 `4862535` 在服务级输入焦点为空时，用当前输入连接的 `EditorInfo.fieldId` 在目标应用中解析资源名，再按该名称查询活动窗口。节点必须唯一、可见、已聚焦，且属于同一应用和窗口。随后核对输入法回报的字段和四边，采样前后的窗口、节点、会话及矩形均须一致。资源名和节点焦点由应用提供，真机仍须验证微信是否暴露了这些信息。

在替代 Android 和输入法接口的 JVM 用例中，Debug 和 Release 各通过 83/83。6 个成功用例覆盖原焦点路径，以及仅采样前、仅采样后或两次都由窗口字段定位的情形。77 个拒绝用例覆盖字段缺失、重名、窗口或会话变化、四边冲突、密码或敏感节点等情况。只有成功使用字段定位时，四边结果才含 `window_field_phase`。旧版 `8d02ed3` 的对照用例复现了真机的 `input_focus_missing`。[受测候选](https://github.com/MaginaLW/agent-for-mobile/commit/4862535153013d22e838acaeeb3841667019283d)

### 窗口字段诊断在安装等待时终止

2026-11-21，候选 `4862535` 已与在机版本核对签名，签名后的 540 个非签名条目与受测 APK 一致。PA2553 上的派单先用两次读取确认微信右窗和「文件传输助手」标题，再发起一次保数据覆盖安装。等待候选就绪的 360 秒窗口结束时，过滤器返回 `candidate-timeout`，PC 安装子进程仍在等待。该安装进程随后被单独终止，原宿主继续收尾。回执未记录平板是否显示安装确认，也无法确定等待原因。

独立读回的在机摘要仍匹配 `8d02ed3`。输入法切换、四边查询、微信内点击、输入和发送均为零。四项设置与入场逐项相符，原 vivo 输入法无障碍服务仍绑定系统客户端，网关前台服务和本轮转发均已释放。该轮没有产生微信编辑框字段或四边的观测值。

上述 APK 摘要采自 11 月 21 日 02:29（新加坡时间）。用户随后确认已安装，并要求暂缓执行。此后未连接平板核对新摘要，也未重跑窗口字段诊断。

### 复用候选后节点未报告聚焦

2026-11-21，只读核对 PA2553 在机网关 APK 摘要，与已签候选 `4862535` 一致。首次窗口检查显示微信平行视界已打开，但系统焦点与输入法目标仍停在左窗 `LauncherUI`；现场轻点一次右窗「文件传输助手」输入栏并弹出键盘后，两者同时指向同一右窗 `ChattingUI`。

随后复用在机 `4862535` 执行单次只读诊断（免安装，使用独立回执目录保留上轮安装等待记录）。派单在切换网关输入法前后均核实同一活动右窗（窗口号与范围不变）及「文件传输助手」标题。第五次读取即唯一一次 `keyboard_state({"probe_editor_bounds":true})` 返回空四边、`focus_unavailable`、`before_sample` 与 `node_not_focused`。派单耗时 31 秒，安装、微信内点击、输入及发送均为零。

按受测源码，取样前依次通过了缓存清除、活动根与聚焦应用窗口校验，随后由服务级焦点或活动右窗按 `EditorInfo.fieldId` 解析出唯一非敏感 `id/...` 节点并完成 `node.refresh()`，因 `node.isFocused` 为假而在发出输入法四边请求前停止。结合上轮 `8d02ed3` 同场景返回 `input_focus_missing`，本轮已越过空焦点和唯一查找环节，但尚未观测到输入法四边回调，也尚未核对 `isVisibleToUser`、窗口号与矩形一致性。[受测候选](https://github.com/MaginaLW/agent-for-mobile/commit/4862535153013d22e838acaeeb3841667019283d)

宿主在收尾阶段一次回选原 vivo 默认输入法并恢复启用输入法清单，释放网关前台服务与端口转发。独立只读收尾核实：在机 APK 仍匹配 `4862535`，四项系统设置与入场逐字相等（未出现 vivo 无障碍服务丢失，无需补写），网关服务与转发均回到缺席状态；另一次只读组件检查确认原 vivo 输入法无障碍服务在当前用户下仅有唯一记录且已绑定系统客户端（`hasBound=true`）。

### 候选 2341c7d 免安装复测仍返回 node_not_focused

2026-11-21，草稿候选 `2341c7d` 仅在服务级与窗口根输入焦点均为空时放行未聚焦的唯一窗口字段节点，完整离线检查 9/9 通过（Debug 503 项、Release 406 项单测及 Lint、构建通过）。同签后的 540 个非签名条目与受测调试 APK 一致，与在机 `4862535` 仅 `classes3.dex` 存在预期差异。[受测候选](https://github.com/MaginaLW/agent-for-mobile/commit/2341c7d588bf5bc92aa45006f1ecd4cb5ccf030b)

首轮在 PA2553 已聚焦微信右窗「文件传输助手」完成同签保数据覆盖安装并核实在机摘要（`install_attempts=1`）。新网关重启并临时切换至 `GatewayIme` 后，第 3 次 `foreground_app` 核实同一右窗（`revision=1`），第 4 次标题复核期间因重启后的 `revision` 变化触发过滤器 `page-changed` 终止；本轮耗时 80 秒、4 次读取、未执行四边查询，微信内零点击、零输入、零发送。收尾回选原 vivo 默认输入法后，独立读回检出仅缺原 vivo 输入法无障碍服务，按授权补回一次并独立核实四项设置、网关资源与系统绑定（`hasBound=true`）一致。

随后另获授权执行一次免安装复用复测（`install_attempts=0`，使用独立回执目录）。输入法切换前后均核实同一活动右窗（窗口号、范围与 `revision` 均一致）及「文件传输助手」标题。第五次读取即唯一一次 `keyboard_state({"probe_editor_bounds":true})` 仍返回空四边、`focus_unavailable`、`before_sample` 与 `node_not_focused`。该轮耗时 27 秒，安装、微信内点击、输入及发送均为零。收尾同样回选原默认输入法、按授权补回缺失的单项 vivo 无障碍服务一次，独立只读核实四项设置、网关服务、端口转发及组件系统绑定（`hasBound=true`）全部回到基线，在机 APK 保持为 `2341c7d`。

按 `2341c7d` 源码，`currentFocus` 仅在以下两处抛出 `node_not_focused`：其一是服务级 `findFocus(FOCUS_INPUT)` 返回了非空节点且刷新后 `node.isFocused` 为假；其二是服务级焦点为空、窗口字段查得唯一可见同窗同包节点后，`root.findFocus(FOCUS_INPUT)` 返回同一节点但 `node.isFocused` 为假。换言之，本次已排除“服务级与根级焦点均为空”的路径——Android 无障碍焦点查询本身已返回非空节点，但微信该节点在 `node.refresh()` 后仍报告 `isFocused=false`。回执目前无法区分这两处中的哪一处，也尚未进入输入法四边采样。

### 候选 f503328 免安装复测返回 node_not_visible

2026-11-21，草稿候选 `f503328` 移除两处 `node_not_focused` 拦截，对未聚焦节点统一要求可见、同窗、同包、非冲突根焦点及取样前 `EditorInfo.fieldId` 交叉核验，完整离线检查 9/9 通过（Debug 509 项、Release 412 项单测及 Lint、构建通过）。同签后的 540 个非签名条目与受测调试 APK 一致，与在机 `2341c7d` 仅 `classes3.dex` 存在预期差异。[受测候选](https://github.com/MaginaLW/agent-for-mobile/commit/f50332839cc88f637d6d8740bdf65a9870eaf8bf)

首轮在 PA2553 已聚焦微信右窗「文件传输助手」完成同签保数据覆盖安装并核实在机摘要（`install_attempts=1`）。新网关重启并临时切换至 `GatewayIme` 后，第 3 次 `foreground_app` 核实同一右窗（`revision=3`），第 4 次标题复核期间因重启后的 `revision` 变化触发过滤器 `page-changed` 终止；本轮耗时 33 秒、4 次读取、未执行四边查询，微信内零点击、零输入、零发送。收尾回选原 vivo 默认输入法并按授权补回缺失的单项 vivo 无障碍服务一次，独立核实四项设置、网关资源与系统绑定（`hasBound=true`）一致。

随后另获授权执行一次免安装复用复测（`install_attempts=0`，使用独立回执目录）。输入法切换前后均核实同一活动右窗（窗口号、范围与 `revision` 均一致）及「文件传输助手」标题。第五次读取即唯一一次 `keyboard_state({"probe_editor_bounds":true})` 返回空四边、`focus_unavailable`、`before_sample` 与 `node_not_visible`。该轮耗时 27 秒，安装、微信内点击、输入及发送均为零。收尾同样回选原默认输入法、按授权补回缺失的单项 vivo 无障碍服务一次，独立只读核实四项设置、网关服务、端口转发及组件系统绑定（`hasBound=true`）全部回到基线，在机 APK 保持为 `f503328`。

对比 `2341c7d` 与 `f503328` 的执行顺序：`2341c7d` 仅在 `serviceFocus != null` 时先于 `isVisibleToUser` 检查 `isFocused`，若此前走的是 `serviceFocus == null` 路径则本应在 `2341c7d` 就先报 `node_not_visible`。两次连续实测共同证实：在 PA2553 微信右窗已聚焦并弹起键盘时，`service.findFocus(FOCUS_INPUT)` 返回了非空节点，但该节点同时报告 `isFocused=false` 且 `isVisibleToUser=false`。因 `node_not_visible` 仍在 `node.windowId`、`packageName`、`rootFocus`、`EditorInfo.fieldId` 校验与输入法四边请求之前触发，目前仍无法判断该服务级焦点节点是否跨窗/错控件，也尚未观测到微信是否返回输入法四边回调。

### 候选 b37c018 取得 14 键诊断快照

2026-11-21，草稿候选 `b37c018` 新增失效服务焦点下的活动窗 `EditorInfo.fieldId` 兜底与仅在 `focus_unavailable` 时产出的 14 键脱敏诊断对象 `ime_editor_focus_diag`，完整离线检查 9/9 通过（Debug 516 项、Release 419 项单测及 Lint、构建通过）。同签后的 540 个非签名条目与受测调试 APK 一致，与在机 `f503328` 仅 `classes3.dex` 存在预期差异。[受测候选](https://github.com/MaginaLW/agent-for-mobile/commit/b37c018bee88f260a6800ce819022b09410d595c)

为避免安装重启引起中途 `page-changed`，按授权先单独对 PA2553 执行一次同签保数据覆盖安装并独立核实在机 APK 摘要与右窗 `ChattingUI` 焦点，再执行单次免安装只读诊断（`install_attempts=0`，耗时 33 秒，5 次读取，微信内零点击、零输入、零发送）。输入法切换前后均核实同一活动右窗（窗口号、范围与 `revision` 均一致）及「文件传输助手」标题。第五次 `keyboard_state({"probe_editor_bounds":true})` 返回空四边、`focus_unavailable`、`before_sample / node_not_visible` 以及完整 14 键脱敏诊断快照：

- 服务与根焦点状态：`service_focus_present=true`、`service_focus_refreshed=true`、`service_focus_same_window=true`、`service_focus_same_package=true`、`root_focus_state=matches_service`、`service_focus_focused=false`、`service_focus_visible=false`、`service_focus_matches_field=null`（按源码此时已解析出非敏感 `fieldName`，故表明该节点无 `viewIdResourceName`）。
- 活动右窗字段查找：`window_field_lookup=ambiguous`（当前输入连接的 `EditorInfo.fieldId` 成功解析出非敏感 `id/...` 资源名，但在微信右窗中命中多于一个节点，尚未筛选可见/窗内有效子集，也尚未发起输入法四边请求）。

收尾阶段宿主一次回选原 vivo 默认输入法并释放网关前台服务与端口转发；按授权补回缺失的单项 vivo 无障碍服务一次，独立只读核实四项系统设置、网关资源与组件系统绑定（`hasBound=true`）全部回到基线，在机 APK 保持为 `b37c018`。

### 候选 8f0baa0 取得 17 键计数并证实 0/2 窗内命中

2026-11-21，草稿候选 `8f0baa0` 在多命中活动窗字段兜底中新增同窗同包敏感优先 fail-closed、可见窗内子集筛选与 17 键脱敏诊断快照（在 14 键基础上新增 `window_field_total_matches`、`window_field_visible_in_window_matches`、`window_field_bounds_in_window_matches`）。同签后的 540 个非签名条目与受测调试 APK 一致，与在机 `b37c018` 仅 `classes3.dex` 存在预期差异。[受测候选](https://github.com/MaginaLW/agent-for-mobile/commit/8f0baa0c1632d765cabf045fd30ac1fd842dd86a)

按授权先对 PA2553 独立执行一次同签保数据 `adb install -r` 更新至 `8f0baa0`，并核实在机 APK 摘要及微信右窗 `ChattingUI` 焦点。随后因本机 Codex CLI 升级，前两次诊断均在零业务调用前退出且独立收尾全绿（`all_match=true`，零输入法与无障碍设置改动）：首次冻结宿主按精确白名单拒绝未知版本 `codex-cli 0.171.0`；合入 `0.171.0` 契约（[PR #62](https://github.com/MaginaLW/agent-for-mobile/pull/62)）后刷新宿主重跑，因 `toolchain/codex/` 仅放了 `codex.exe` 而缺少同目录配套的 `codex-code-mode-host.exe`（`0.171.0` 默认模型远端元数据强制进入 `ToolMode::CodeModeOnly` 且不回退 `Direct`），Codex 在第 1 次工具调用前 fail-closed 退出（耗时 14 秒）。

经授权补齐同源、OpenAI 签名有效的 `codex-code-mode-host.exe` 后，在新轮次目录执行单次免安装只读诊断（`install_attempts=0`，耗时 25 秒，5 次读取，stderr 为空，微信内零点击、零输入、零发送）。输入法切换前后均核实同一活动右窗（窗口号、范围与 `revision` 均一致）及「文件传输助手」标题。第五次 `keyboard_state({"probe_editor_bounds":true})` 返回空四边、`focus_unavailable`、`before_sample / node_not_visible` 以及完整 17 键脱敏诊断快照：

- 既有 14 键与 `b37c018` 一致：`service_focus_present=true`、`service_focus_refreshed=true`、`service_focus_same_window=true`、`service_focus_same_package=true`、`root_focus_state=matches_service`、`service_focus_focused=false`、`service_focus_visible=false`、`service_focus_matches_field=null`、`window_field_lookup=ambiguous`。
- 新增 3 项命中计数：`window_field_total_matches=2`、`window_field_bounds_in_window_matches=0`、`window_field_visible_in_window_matches=0`。按 `8f0baa0` 源码 `scanMultiMatches`，当前输入连接的 `EditorInfo.fieldId` 在微信右窗确实命中 2 个非敏感节点，但两者在进入 `isVisibleToUser` 筛选前均已被前置条件（`refresh()`、同窗同包、`viewIdResourceName == fieldName`、`!bounds.isEmpty` 或 `windowBounds.contains(bounds)`）全部淘汰，尚未发起输入法四边请求。

收尾阶段宿主一次回选原 vivo 默认输入法、恢复启用输入法清单并释放网关前台服务与端口转发；按授权补回缺失的单项 vivo 无障碍服务一次，独立只读核实四项系统设置、网关资源与组件系统绑定（`hasBound=true`）全部回到基线，在机 APK 保持为 `8f0baa0`。针对本轮发现，派单侧已通过 [PR #63](https://github.com/MaginaLW/agent-for-mobile/pull/63) 为 `0.171.0` 补齐配套 `codex-code-mode-host.exe` 存在性与 OpenAI 验签门禁；草稿 PR #47 已推进至 `0b4b4d4`，将 `ime_editor_focus_diag` 细化为 23 键（新增 6 项互斥/可见淘汰原因计数），并已完成基于 `696ca58` 宿主的离线调试包（540 个非签名条目）绑定与 23 键过滤器（27 项）、入场（11 项）、收尾（7 项）及真实 `0.171.0` 配套验签离线预演（零设备访问、零实签）。

### 候选 0b4b4d4 的两个节点均在资源名核对时被排除

2026-11-21，PA2553 从 `8f0baa0` 同签保数据更新至 `0b4b4d4`。安装前后已核实在机摘要、右窗会话焦点和设置基线。本轮从已聚焦的微信右窗开始，使用 `696ca58` 宿主免安装派单一次，用时 28 秒。切换输入法前后共四次读取均核实了同一右窗及「文件传输助手」标题。第五次读取编辑框四边返回 `before_sample / node_not_visible`。本轮没有导航、输入、截图、发送或设备端发送确认卡。

23 项脱敏诊断中，`window_field_total_matches=2`，`window_field_id_mismatch_matches=2`，刷新失败、窗包不符、空边界、越界及窗内命中的计数均为 0。服务级与窗口根的输入焦点仍指向同一个未聚焦、不可见的节点。按候选源码，两个字段候选均已刷新且匹配窗口与包，资源名精确比较失败后即跳过可见性与边界读取。回执没有区分资源名缺失与返回其他名字，两节点的实际位置和编辑框身份仍未知。[受测判断](https://github.com/MaginaLW/agent-for-mobile/blob/0b4b4d4fb3c0792445522f777397feb021ad6c5c/app/gateway/src/main/java/dev/magina/gateway/tools/EditorBoundsDiagnostic.kt#L396-L412)

第一次独立收尾读回发现原无障碍服务清单少一项，其余三项设置与网关资源均匹配。仅补回入场时已启用的 vivo 输入法无障碍服务一次，随后独立核实原清单、四项设置、网关服务、端口转发及该服务的系统绑定。

### 候选 39bfaed 的两个节点均未返回可用资源名

2026-11-21，PA2553 从 `0b4b4d4` 同签保数据更新至 `39bfaed`。在机摘要、入场设置和右窗焦点均已核对。宿主 `696ca58` 从已就位的「文件传输助手」右窗派单一次，用时 27 秒。输入法切换前后共四次读取均通过窗口和标题复核。第五次查询返回 `before_sample / node_not_visible`。全程零导航、零输入、零截图、零发送，未触发业务确认卡。

按字段查到 2 个节点，刷新后 2 个资源名未匹配。新增脱敏计数为 `ime_editor_field_missing_name_matches=2`，即 2 个名字均为 null、空串或纯空白，具名异名为 0。节点在读取边界前即被排除，实际坐标、刷新前的名字及唯一编辑框身份仍未知。该计数只保存在本机回执。草稿代码的完整离线检查 9/9 通过，含 Debug 527 项及 Release 430 项单测。[草稿 PR #47](https://github.com/MaginaLW/agent-for-mobile/pull/47)

独立核查同一签名 APK 的编译资源，网关无障碍配置为 `0x53`，含 `FLAG_REPORT_VIEW_IDS`（`0x10`）。此次派单回执没有记录实际连接的服务标志。Android 16 的参考实现按数值视图 ID 查找后创建无障碍节点，单凭查找命中还无法证明节点公开了资源名。[Android 标志定义](https://developer.android.com/reference/android/accessibilityservice/AccessibilityServiceInfo#FLAG_REPORT_VIEW_IDS) · [Android 16 查找实现](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-16.0.0_r1/core/java/android/view/AccessibilityInteractionController.java#L1810-L1815)

如需实测该标志，应从当次已绑定的网关连接读取 `getServiceInfo().flags`。Android 16 参考实现的 `dumpsys accessibility` 绑定服务摘要省略了该位。`39bfaed` 的网关和测试靶均未提供该项读数，后续连接的结果只能说明后续连接。[连接信息](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-16.0.0_r1/services/accessibility/java/com/android/server/accessibility/AbstractAccessibilityServiceConnection.java#L506-L545) · [系统摘要字段](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-16.0.0_r1/services/accessibility/java/com/android/server/accessibility/AbstractAccessibilityServiceConnection.java#L1623-L1635)

初次独立收尾发现已启用的无障碍服务少一项。按入场基线仅补回原 vivo 输入法无障碍服务一次，随后核实原清单、四项设置、网关服务及转发均一致，并独立观察到系统客户端已重新绑定该服务。

### 候选 123cf59 在资源名报告已开启时仍有两个无名节点

2026-11-21，PA2553 从 `39bfaed` 同签保数据更新至 `123cf59`。独立安装一次，读回在机摘要，四项设置、网关服务和端口转发均匹配。首次进入五步诊断时，系统焦点和输入法目标各有一条读数，两者都没有指向微信会话。宿主在启动派单前退出，业务调用、输入法切换均为零。独立收尾核实基线与原 vivo 服务绑定。

现场重新就位后，宿主 `696ca58` 沿用在机版本发起一次只读派单，用时 28 秒。前四次调用核实了切换输入法前后的同一微信右窗及「文件传输助手」标题。第五次查询得到 `before_sample / node_not_visible`。查到 2 个字段候选，刷新后资源名未匹配的有 2 个，缺名的也有 2 个，具名异名为 0。在同一份回执中，网关从当前服务连接读到 `ime_editor_report_view_ids=true`。该次连接已请求系统报告资源名，两个节点仍未提供可核验的标识。在比较边界前结束，编辑框四边、唯一身份和消息投递均未获证实。全程零输入、零发送，业务确认卡出现次数为零。[源码草稿 #47](https://github.com/MaginaLW/agent-for-mobile/pull/47)

后一次派单收尾时，原无障碍服务清单少一项。仅补回原有 vivo 输入法服务一次，独立读回核实四项设置、网关资源和系统绑定均已恢复。在机网关为 `123cf59`。其离线检查 9/9 通过，含 Debug 528 项、Release 431 项单测及两种构建的 Lint 和打包。

#### 怎样判读两个无名候选

对照该轮脱敏回执与 `123cf59` 的筛选顺序，服务焦点与窗口根焦点指向同一个节点，但该节点报告未聚焦、不可见。按输入字段查出的两个候选都通过了刷新、窗口和包名校验，随后因缺名被跳过。程序到此尚未读取这两个候选的可见性和矩形。因此，即使“窗内命中”“越界”“空边界”三项都为零，两个候选的位置仍是未知。[多候选筛选顺序](https://github.com/MaginaLW/agent-for-mobile/blob/123cf590f5ad4ee10584331d55d30a8435781652/app/gateway/src/main/java/dev/magina/gateway/tools/EditorBoundsDiagnostic.kt#L412-L439)

网关从字段信息和会话代次生成输入法会话标识，从窗口、资源名、类名、包名和矩形生成无障碍节点标识。两者没有可直接对照的键。项目编译用的 Android API 35 在无障碍节点上提供 `getUniqueId()`，输入法的 `EditorInfo` 和 `CursorAnchorInfo` 均未提供对应的节点标识。网关从当前输入契约为四边样本附上 `fieldId`，因此样本与契约中的字段值来自同一处。重开横屏就位还需要能独立核实当前输入连接对应哪一个右窗编辑框、并能比对该框四边的证据。[输入法会话标识](https://github.com/MaginaLW/agent-for-mobile/blob/123cf590f5ad4ee10584331d55d30a8435781652/app/gateway/src/main/java/dev/magina/gateway/ime/GatewayIme.kt#L21-L44) · [四边样本来源](https://github.com/MaginaLW/agent-for-mobile/blob/123cf590f5ad4ee10584331d55d30a8435781652/app/gateway/src/main/java/dev/magina/gateway/ime/GatewayIme.kt#L302-L312) · [无障碍节点标识](https://github.com/MaginaLW/agent-for-mobile/blob/123cf590f5ad4ee10584331d55d30a8435781652/app/gateway/src/main/java/dev/magina/gateway/a11y/FocusedInputIdentity.kt#L5-L17)

#### 无名编辑框保持焦点时重启输入连接

在全新 Android 16（API 36）模拟器上，基于主线 `16a0b56` 的四场景合成实验订阅 `TYPE_VIEW_FOCUSED`，按事件来源节点及窗口与系统输入焦点逐次核对。四个场景各取得一条来源相符的事件。最后的无名编辑框也收到了该事件，输入法与无障碍读到的四边一致，身份核对仍返回 `missing_id`。[基础实验与四个场景](../../runs/fixtures/editor-origin/README.md#用当前输入焦点核对身份和四边)

保持最后一个编辑框的焦点，测试应用对它调用一次 `InputMethodManager.restartInput(view)`。应用为该框创建输入连接的次数由 1 增至 2，独立输入法进程收到 `onStartInput(restarting=true)`，代次由 5 变为 6。重启前后系统焦点指向同一窗口的同一无名节点，四边相同。从调用起的 1,244 毫秒内，该应用的焦点事件数为 0。因此，最近一次焦点事件可以指示曾获得焦点的节点，单凭它无法区分该节点上先后建立的两个输入连接。PA2553 的两个无名候选仍缺少与当前输入连接的独立对应证据。

#### 横屏编辑框的四边能否单独确定输入目标

11 月 22 日记录的 PA2553 派单从操作者已聚焦的微信右窗开始。在机候选 `2289925` 在切换输入法前后均核实了同一右窗和「文件传输助手」标题，约 28 秒收到第五次读取的结果 `missing_id / before_sample / field_id_unresolved`。这次已取得输入契约，解析字段 ID 时停止，尚未向输入法请求矩形。具体字段值、候选数和编辑框位置均未知。全程零导航点击、零输入、零发送、零业务确认卡。收尾补回原有 vivo 服务一项，独立读回核实四项设置、系统绑定、网关服务和端口转发均恢复。[该轮真机记录](https://github.com/MaginaLW/agent-for-mobile/blob/ae93377c71cdb9b3a488b6205003b31871a32099/docs/knowledge/apps/wechat.md#pa2553-在采样前无法解析字段-id)

用草稿 #47 的九行固定样本检验只看四边的做法。逐行将样本的 `ime` 与 `left`、`right` 四个坐标精确比较，仅一侧吻合时选该侧，再核对同一行的 `focused` 和预期 `outcome`。[回放数据](https://github.com/MaginaLW/agent-for-mobile/blob/ae93377c71cdb9b3a488b6205003b31871a32099/app/gateway/src/test/resources/anonymous-editor-landscape.json)

| 样本 | 只按四边作出的选择 | 样本中的焦点证据 |
|---|---|---|
| 1–2 | 左、右各选中一次 | 分别与持焦侧一致 |
| 3 | 两侧都匹配，无法选择 | 两框四边重合 |
| 4 | 唯一匹配右框 | 持焦侧是左框，服务焦点与窗口根焦点矛盾 |
| 5–9 | 五例均有唯一匹配 | 服务或窗口根返回的焦点、可见性读数有冲突，五例均应停止 |

这里的 `ime` 来自固定回放输入。候选网关在焦点冲突时先停止采样；PA2553 的第五次读取也没有编辑框四边。后续判读须同时保留输入连接、两侧焦点与矩形各自的来源。[候选判定实现](https://github.com/MaginaLW/agent-for-mobile/blob/ae93377c71cdb9b3a488b6205003b31871a32099/app/gateway/src/main/java/dev/magina/gateway/tools/AnonymousEditorPair.kt)

能否沿用 vivo 输入法，从无障碍服务直接取得这份几何？核对项目编译所用 API 35 的公开方法和 Android 16 框架源码，无障碍输入法可取得当前 `EditorInfo` 并接收选区变化。它拿到的 `AccessibilityInputConnection` 缺少普通 `InputConnection` 上的 `requestTextBoundsInfo` 和 `requestCursorUpdates`。因此，只启用无障碍输入法标志，仍无法沿用网关现有的原点与四边查询。这次接口核对没有切换设备输入法。[Android 无障碍输入连接](https://developer.android.com/reference/android/accessibilityservice/InputMethod.AccessibilityInputConnection) · [Android 16 框架实现](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-16.0.0_r1/core/java/android/accessibilityservice/InputMethod.java)

API 36 隔离实验随后验证了一种独立对应方式。实验输入法读取当前连接的原生自动填充标识，自动填充服务从同一窗口的结构找到候选，靶应用另行记录哪一侧真正收到了连接请求。同一对无名原生控件左右交接均选对，四边重合与焦点冲突均停止。微信是否暴露可供这种比对的结构仍待验证。[四场实测及适用范围](../../runs/fixtures/editor-autofill/README.md#隔离模拟器实测)

隔离实验后，在 PA2553 已安装的 `2289925` 上进行了单次免安装只读复核。入场时系统焦点与输入法目标已在同一微信会话。派单耗时 26 秒，前四次读取在切换输入法前后均核实了同一右窗和「文件传输助手」标题。第五次读取返回 `missing_id / before_sample / field_id_unresolved`，未发起四边采样，也未得到与连接匹配的编辑框结构。该版本未实现合成实验的自动填充服务，此次未取微信的自动填充结构。导航点击、输入和发送均为零。收尾回选原输入法，补回一项入场时已启用的 vivo 服务，独立确认系统绑定、四项设置、网关服务与端口转发均恢复。最终系统焦点和输入法目标仍指向同一微信会话。

在合成靶上判读换框后的结构时，要同时核对连接开始、结构采集和回调送达的先后顺序。把左场回执延迟到右场处理，旧采集时间仍会被识别。若右侧没有回调，可先用系统请求历史把空响应与会话号对上，再按靶应用进程和右框字段标识核对进入事件。本次 API 36 实测见到会话已结束，且客户端明确忽略了已登记右框的进入事件。微信右窗本身仍缺少与当前连接匹配的结构。[旧样本回放](../../runs/fixtures/editor-autofill/README.md#系统自动请求) · [模拟器框架回执](../../runs/fixtures/editor-autofill/README.md#空响应后的会话与右框请求)

#### 持焦切换输入法时如何判读无回调

在 API 36 合成双框靶上，右框保持焦点时切换输入法会重建输入连接。此次方法轨迹中，靶进程没有调用 View 焦点变化或自动填充进入通知，系统请求历史也没有新增条目。同一进程内新建 Activity、让右框自然聚焦，两层通知和系统请求都出现。诊断时应分别记录连接重建、焦点进入和系统派发；仅看到会话为 `FINISHED`，不足以认定发生了「已登记字段被忽略」。微信真机仍缺切换后可用的编辑框结构。[方法轨迹与独立回执](../../runs/fixtures/editor-autofill/README.md#持焦切换时的客户端方法轨迹)

保留原自动填充会话后重复持焦切换。系统在切换前后均报告同一会话为 `ACTIVE`，两次快照都只有请求 896。右框已经接到新输入连接的探针，仍未收到新结构。随后新 Activity 自然聚焦才出现请求 898，采集发生在新连接建立后。判读时应分别核对会话状态、请求号和采集时刻；仅凭会话仍活跃或旧响应已过期，均不足以把旧结构归到新连接。[保留会话的实测](../../runs/fixtures/editor-autofill/retained-session/README.md)

#### 同包窗口出现相同的自动填充字段号

11 月 22 日在宿主回放中，两个同包、同类的 Activity 实例产生相同的右框字段号及屏幕四边。只有活动窗口的右框接到输入探针，但分别把两份结构送入现行实验观察器后，完整终结回执相同，都选中了右框。把另一窗口的字段号改成不同值后，观察器才返回 `NO_ID_MATCH`。Android 16 按 Activity 分配原生字段号。解释右框回执时应同时保留结构来源窗的独立依据，来源未知时，最终侧别和四边留空。这是宿主构造的窗口对照，微信真机的字段值仍未知。[九场回放与判定表](../../runs/fixtures/editor-autofill/window-replay/README.md) · [Android 16 字段号分配](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-16.0.0_r1/core/java/android/app/Activity.java)

#### 用系统诊断把结构请求归属到窗口

在 API 36 合成靶上，同包同类的两个 Activity 各显式发起一次结构请求。宿主先核对请求号及会话号，沿会话的 Activity 令牌找到唯一系统窗口，再用同一系统进程输出的窗口客户端标记对齐无障碍窗号。两次分别得到 11 和 14，均与对应靶独立记录的窗号一致，右框四边都是 `[2100,32,2300,102]`。保留每场的请求、时间与窗口采样，仅把期望窗换为对方，两次均得到 `WRONG_WINDOW` 并清空侧别和四边。这是宿主离线交叉回放；两次模拟器采集均来自各自的前台窗。本实验依赖 shell 读取系统诊断，并延迟空响应以采到活跃会话。微信普通网关在持焦切换后能取得哪些同等证据，仍待验证。[实验与窗口归属对照](../../runs/fixtures/editor-autofill/window-replay/system-source/README.md)

#### 候选自己的窗口号与输入样本来源

在 API 36 合成靶上，原版 `2289925` 的只读四边查询能为两个有资源名的右框返回不同窗号 13、15，虽然两个框的四边完全相同。宿主可用已知目标窗号排除拿错的整份回执。两个匿名右框都在采样前因无障碍服务焦点节点缺名而停止。另用普通输入法与无障碍服务观察两个匿名实例，节点、窗口根和服务焦点的窗号一致，两个实例的窗号不同；输入法看到的客户端 UID、PID、输入绑定标记、原生字段号和填充会话号则分别相同。输入法代次能识别本次连接，但本次读数里没有能用来核对来源窗号的共同标识。[候选正控、匿名场与错窗回放](../../runs/fixtures/editor-autofill/window-replay/candidate-permissions/README.md)

#### 三项离线补充实验实测收口与第四路线（CursorAnchorInfo + 4B 遥测）

2026-11-22，针对 PA2553 微信横屏的 3 项既有离线夹具在全新隔离 API 36 模拟器上全部补齐实测并完成设置/角色/端口清场，同时对照历史真机日志定位了未曾触发的零新增权限第四路线：

- **Track B · 逐请求矩阵与布局尺寸（`request-matrix`，`2772db0`）**：修复 `Bundle.EMPTY`、横屏底窗与多任务启动后，145 秒完成 4 项几何对照 + 3 项微信等价对抗（10/10 设置与双包读回还原）。显式正像素原生 `EditText` 上通过了活体双窗双向区分与同原点不同缩放区分，重合场（`east` vs `overlap`）诚实退回 `ambiguous`；但三项微信等价对抗全部 fail-closed——`MATCH_PARENT`/`WRAP_CONTENT` 的 `ExtraRenderingInfo.getLayoutSize()` 实测返回 `[-1,-2]`（`incomplete`），`CODE_UNSUPPORTED` 零矩阵落盘，`AccessibilityDelegate` 剥离 `visible=false, focused=false` 记为 `hidden_editors=1`（`incomplete`）。**该路线收口为窄 AOSP 边界结论，不适用真实微信。**[实测与对抗回执](../../runs/fixtures/editor-autofill/window-replay/request-matrix/README.md)
- **Track A2 路线 1 · 输入法触发手动自动填充（`ime-menu`，`a11ee7e`）**：118.38 秒完成 4 场景实测（8/8 设置读回）。证实 Android 16 上**零 UI IME**（`ui_shown=false`，零布局偏移）调用 `InputConnection.performContextMenuAction(android.R.id.autofill)` 可在不移动焦点、无目标配合、异签名条件下让已持焦的匿名标准 `EditText` 产出新鲜 `FLAG_MANUAL_REQUEST` 结构，并按原生 `AutofillId.getViewId()` 与当前连接精确匹配 `[2100,32,2300,102]`；`IMPORTANT_FOR_AUTOFILL_NO` 与吞菜单的自定义 `InputConnection` 均 fail-closed。作为真机备选仍受限于微信是否吞掉 `android.R.id.autofill`/排除自动填充、OriginOS 自动填充切换恢复及同包多窗归属。[四场景实测回执](../../runs/fixtures/editor-autofill/ime-menu/README.md)
- **Track A2 路线 2 · 系统助理结构（`assistant-structure`，`340dddc`）**：511 秒完成 7 场景实测（13/13 设置及 `android.app.role.ASSISTANT` 持有者均读回还原为原助理）。`VoiceInteractionSession`（`SHOW_WITH_ASSIST`，零 UI、零截图）零焦点/连接打断采得新鲜 `AssistStructure`，在 `obfuscated` 中穿透微信式 `AccessibilityDelegate` 剥离，并在 `multiwin`/`multiwin2` 区分双窗/双 Activity 左右窗格、`FLAG_SECURE` 下 fail-closed；但实证普通助理树 `ViewNode.getAutofillId()` 恒为 `null`（匿名框无跨通道共同 ID），且需高侵入接管系统唯一助理角色。[七场景实测回执](../../runs/fixtures/editor-autofill/assistant-structure/README.md)
- **第四路线 · 零新增权限 Pathway 4A+4B（草稿分支 `codex/swarm-p4-cursor-diag` `345f897`，基于 #47 `ae93377`）**：复盘全部 10 轮 PA2553 诊断发现，此前网关均在无障碍 `before_sample` 处提前返回，**从未在微信真机上真正调用过一次标准 `InputConnection.requestCursorUpdates()`**（API 21 商业输入法通用接口，独立于 API 34 `requestTextBoundsInfo` 与无障碍剥离）；同时 `2289925` 在进入 `currentFocus()` 前未先检查 `InputType.TYPE_NULL`（可能把兜底 `DecorView` 连接误报为 `field_id_unresolved`），且 `scanMultiMatches` 在资源名比对失败后提前 `continue`，从未读出 2 个 `fieldId` 命中节点的真实四边、可见性与 `inputType`。草稿分支在不改动 `AndroidManifest.xml`（零新增权限、零角色接管、零可见 IME UI）前提下接入 `keyboard_state({"probe_cursor_anchor": true})`（2 参过滤 + API 21 1 参降级 + 不相交双窗严格归属，重叠/跨应用/会话漂移一律 fail-closed）与 4B 全量非短路节点遥测及 `TYPE_NULL` 前置分类，Debug 547 / Release 450 单测与 Lint/构建全过，并在 API 36 隔离微信等价 6 场景实测 6/6 通过（147.23 秒，0 像素误差匹配右/左窗格，验证 1 参降级、窗口重叠 `ambiguous_window_overlap` 与 `TYPE_NULL` 失败关闭，6/6 设置与双包清理完成）。

#### PA2553 真机只读实测：Pathway 4A 打通右窗编辑框归属、4B 封口无障碍节点路线

2026-11-22，经用户明确授权，在 PA2553 上同签保数据安装 `345f897` Debug APK（在机 SHA-256 `483994bbcd3252b34611b4c5fb95e8291e7a76c2c9ce2edbb1ab5f7177b9ceda`，零新增权限、零系统角色接管）。现场就位于微信横屏右窗「文件传输助手」`ChattingUI` 并聚焦底部文本输入框（切 IME 前后 `dumpsys input_method` 均核实 `inputType=0x24001` / `147457`、`imeOptions=0x50000006` / `1342177286`、`fieldId=2131365757`、`autofillId=1073741825`），随后经 `origin/main`（`4ac8aa5`）宿主 `scripts/dispatch.ps1`（Codex `0.171.0` + 配套 `codex-code-mode-host.exe`）执行单次 4 工具只读诊断（耗时 45.61 秒，退出码 `0`，零点击、零输入、零发送、零重试，台账 `pa2553-p4-cursor-diag`）：

1. **`foreground_app({})`**（`a-000002`）：`window_topology="same_app_multi"`，`package="com.tencent.mm"`，`activity="com.tencent.mm.ui.chatting.ChattingUI"`，`selected_window_id=364`，`revision=93`；2 个互不相交的微信应用窗：右窗 `id=364`（`active=true, focused=true`，`[927, 0, 2800, 1968]`）与左窗 `id=358`（`active=false, focused=false`，`[0, 0, 923, 1968]`）。
2. **`ui_find({"text":"文件传输助手","scroll_search":false})`**（`a-000003`）：右窗顶部标题命中 `window_id=364, pane="right", bounds=[1717, 140, 1999, 184]`（OCR，左窗会话行 `[216, 281, 498, 325]`）；`focused_input_id=null`、`focused_identity_source="ime_only"`。
3. **`keyboard_state({"probe_editor_bounds":true})`**（`a-000004`，**Pathway 4B 决定性封口**）：
   - `ime_editor_contract_diag` 核实真实输入契约：`contract_present=true`、`input_type_is_null=false`、`input_type=147457`、`ime_options=1342177286`、`field_id_class="id"`、`autofill_id_present=true`、`autofill_id_virtual=false`、`supported_handwriting_gestures=true`。
   - `ime_editor_node_telemetry` 首次完整读出 `service_focus` 与全部 2 个 `fieldId` 命中节点（`total_matches=2, inspected_matches=2, unnamed_matches=2, empty_bounds_matches=2, bounds_in_window_matches=0, visible_matches=0, focused_matches=0, editable_matches=0, input_type_matches=0, same_as_service_matches=1`）：**三者均为 100% 空壳剥离桩**（`focused=false, visible=false, editable=false, view_id_state="missing", bounds_state="empty" ([0,0,0,0]), input_type=0, class_name=null`），彻底关闭微信上所有依赖无障碍节点四边或属性的识别路线。
4. **`keyboard_state({"probe_cursor_anchor":true})`**（`a-000005`，**Pathway 4A 真机打通**）：
   - 真实微信拒绝了 API 33/34 双参数 `requestCursorUpdates(mode, filter)`（`filtered_accepted=false`），网关自动降级至 API 21 单参数 `requestCursorUpdates(CURSOR_UPDATE_IMMEDIATE)`（`legacy_accepted=true`，`request_mode="legacy_1arg"`），直接取得：
     - `matrix_origin`: `(1048, 1834)`（`matrix_is_identity=false`）
     - `editor_bounds`: **`[1048, 1834, 2578, 1946]`**（`1530 × 112` px，完整覆盖右窗底部聊天输入栏）
     - `insertion_marker`: `top=(1067, 1864), baseline=(1067, 1915), bottom=(1067, 1929), flags=1, visibility="visible"`（可见闪烁光标）
     - 严格不相交双窗归属：**`window_id=364`、`pane="right"`、`window_bounds=[927, 0, 2800, 1968]`**（`same_package_window_count=2, total_app_window_count=2, geometry_source="editor_bounds+insertion_marker", session_generation=1`），`a11y_cross_check` 三项均为 `0`（与 4B 空壳桩一致）。
5. **无条件收尾与双重独立读回**：回选原 vivo 输入法并恢复逐字基线后，间隔 2 秒两次独立读回均核实全部 4 项基线设置逐字相等（含前导 `:` 与 vivo `AutoSendImageService`）、`dumpsys accessibility` 中 `GatewayA11yService` 与 vivo `AutoSendImageService` 双绑定、`GatewayService` 停止且 `adb forward --list` 为空。

#### PA2553 起点 1（已聚焦右窗）生产横屏就位实测通过

2026-11-22，生产接线与横屏宿主回执分支 2 随 [PR #47](https://github.com/MaginaLW/agent-for-mobile/pull/47) 合入 `main`（合并提交 `30dd179`，候选 `3d700cc`，完整 `scripts/check.ps1` 9/9 通过：Debug 554 / Release 457 / 派单 59 / runner 157，API 36 隔离 `schema_version=2` 六场景 6/6 通过，零新增权限）。经用户明确授权，在 PA2553 上同签保数据安装 `3d700cc` Debug APK（在机 SHA-256 `73b778b0467a5d7c1562128abd329087788ea9631ed4037af67779bef505a16a`，安装后自动回到已聚焦的右窗 `ChattingUI`，`inputType=0x24001`、`fieldId=2131365757`，`GatewayA11yService` 与 vivo `AutoSendImageService` 双绑定）。外层在 `dispatch.ps1` 入场前临时启用并切换至 `GatewayIme` 并静置等待 OriginOS 无障碍列表副作用稳定（2.5 秒后复读确认不再变动），随后在同步至 `30dd179` 的宿主上执行单次官方生产命令 `scripts/dispatch.ps1 -TaskFile scripts/tasks/wechat-landscape-prepare.md -TimeoutMin 3`：

- **派单与宿主门禁结果**：**首次派单即通过**（派单耗时 `36s`，含外层切换/收尾 `44.86s`，退出码 `0`，`verdict=success`，`note: 宿主已核实同一微信会话窗口的输入目标及收尾基线`，台账 `wechat-landscape-prepare`）；用户为导航或调试动手 0 次，启动、点击、输入、发送、确认卡与工具错误均为 0。
- **6 次只读调用与生产焦点交叉核验（全链同一 `rev=3`，`window_topology="same_app_multi"`，`a-000002..a-000007`）**：
  - `[1]`/`[4]` `foreground_app({})`：确认 2 个互不相交微信应用窗——左窗 `id=358`（`[0,0,923,1968]`，`active=false, focused=false`）、右窗 `id=364`（`[927,0,2800,1968]`，`active=true, focused=true`，`selected_window_id=364`）。
  - `[2]`/`[5]` `ui_find({"text":"文件传输助手","scroll_search":false})`：屏幕 `2800×1968`，右窗顶部标题命中 `win=364, src=ocr, [1717,140,1999,184]`（左窗列表行 `win=358, [217,282,498,325]`）；生产焦点元数据首次在真实微信上直接返回 **`focused_identity_source="ime_cursor_anchor"`、`focused_input_id=null`、`focused_input_window_id=364`、`focused_input_pane="right"`、`focused_input_bounds=[1048,1834,2578,1946]`**。
  - `[3]`/`[6]` `keyboard_state({"probe_cursor_anchor":true})`：`visible=false, height=0`，`ime_editor_contract_diag={contract_present:true, input_type_is_null:false, input_type:147457}`，`ime_cursor_anchor` 经 `legacy_1arg`（`filtered_accepted=false, legacy_accepted=true, matrix_is_identity=false`）返回 `window_id=364, pane="right", window_bounds=[927,0,2800,1968], same_package_window_count=2, total_app_window_count=2, session_generation=5, geometry_source="editor_bounds+insertion_marker"`，`editor_bounds={left:1048, top:1834, right:2578, bottom:1946}` 与可见插入光标 `top=(1067,1864), baseline=(1067,1915), bottom=(1067,1929)`，无 `ime_cursor_anchor_reason`。执行器按任务卡第 4/5 步在确认 `ime_cursor_anchor` 后直接跳过 `ui_find(role="input")`，宿主 `Test-LandscapeEditorReceipt`（分支 2）与 `Complete-LandscapePreparation`（`mCurrentFocus == imeInputTarget == ChattingUI` 且派单期间零基线漂移）同步放行。
- **无条件收尾与双重独立读回**：外层 `finally` 回选原 vivo 输入法并恢复 4 项基线设置后，+2s 与 +4s 两次独立读回均逐字匹配（`match=True`），`GatewayService` 停止、`adb forward --list` 为空、`dumpsys accessibility` 中 `GatewayA11yService` 与 vivo `AutoSendImageService` 双绑定（`Crashed:{}`）。

剩余待推进两项：(1) **起点 2 & 3（左窗与桌面自动就位）**——实测已知从左窗切入冷 `ChattingUI` 时系统先挂 `inputType=0x0` 且微信无障碍节点全为空壳桩，冷态自动聚焦底部编辑栏需要可核验的非盲点锚点或热聚焦契约；(2) **获授权的草稿备稿 + 单次设备端 ConfirmOverlay 发送与消息区投递验收**。

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

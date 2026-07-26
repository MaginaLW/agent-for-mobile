# Android 通用坑（版本级行为 + 工具链）

> 来源：M0/M0.5 实测（2026-07-16/17，Android 16 环境）。厂商特有的坑在 [vivo-originos.md](vivo-originos.md) / [other-vendors.md](other-vendors.md)。

## Android 版本级行为

- **系统状态验证不能信 settings 键**：`settings get global bluetooth_on` 返回 0 时蓝牙实际是开的（Android 16 实测）；`dumpsys bluetooth_manager` 才是真值。验证通道要用 dumpsys / 专用 API（真值源对照表见 [sys-cli.md §1](sys-cli.md)）。
- **后台剪贴板写入受限**（Android 10+，16 实测拦截）：devicekit 1.2.4 的中文输入（写剪贴板+注入粘贴键）被拦，输入框出现的是剪贴板旧内容，可复现 3 次。纯 ASCII 正常。→ **M1 自带 IME 通道（输入法级注入），不依赖剪贴板戏法**；读剪贴板靠"默认 IME 豁免"。
- Android 13+ 普通 app 无法编程开关蓝牙/WiFi（shell 位阶专属，见 [sys-cli.md](sys-cli.md)）。
- 无障碍 `takeScreenshot`（API 30+）：单发极快 **32–37ms**（vivo V2352A/Android16 实测，远优于 500ms 判据）。连发（~400ms 间隔）触发**软节流**——第二次**不报** `ERROR_TAKE_SCREENSHOT_INTERVAL_TIME_SHORT`，而是 `takeScreenshot` 延迟到 **~750ms** 后成功返回；冷却 ~2s 后回落常速（Spike S4 实测，未精确二分冷却边界）。**与常见文档所述「硬失败」不同**，OriginOS6 是拖延返回。网关 `E_RATE_LIMITED` 冷却窗口参考 ~800ms（或容忍单次 ~750ms 延迟，不必判失败）。**M1b 补充（2026-07-19）：更紧的连发（<300ms，OCR 融合 snapshot 紧跟点击校验）也会硬报 INTERVAL_TIME_SHORT**——软/硬两种形态都存在；网关内部视觉通道已吸收（等 ~900ms 重试一次），`screen_capture` 工具仍向大脑透出 E_RATE_LIMITED 语义。

## AccessibilityService 窗口身份（vivo/Android 16，2026-07-22）

- `TYPE_APPLICATION_OVERLAY` 也会产生 `TYPE_WINDOW_STATE_CHANGED`；事件携带的 package/class（实测 class 为 `FrameLayout`）只描述事件窗口，不能直接当作当前前台身份。必须用 `event.windowId` 归属到 windows 列表中的 active `TYPE_APPLICATION`，没有 active 时才保守后备到 focused `TYPE_APPLICATION`；已知 overlay、IME 或 inactive 窗口事件直接忽略。
- **防御性乱序场景（已有离线回归覆盖，尚无单独真机时序证据）**：事件若短暂早于 windows 列表更新，仅对尚未出现在列表中的 windowId 暂存候选，等 `TYPE_WINDOWS_CHANGED` 后复核归属再发布，不能把候选先写成前台。
- 前台身份必须显式区分 `Known` / `Unknown`；root 仅给出 package 的 fallback 不等于已验证窗口身份。`Unknown` 时只读 R 可用于诊断，写入 W 与危险 D 动作必须 fail-closed。

## App 屏蔽无障碍树与 IME 单命名空间降级（微信，2026-07-25）

- **微信 ≥8.0.52 对 a11y 树基本不透明**：会话页 `ui_snapshot` 的 a11y 元素恒为状态栏那 13 项，标题/气泡/输入框 100% 来自 OCR，`findFocus(FOCUS_INPUT)` 取不到焦点节点；同一时刻 IME 侧（激活、InputConnection、`focusedInputId`）三项全部正常。与网络调研"有意混淆 a11y 节点数据对抗自动化"吻合。**因此"a11y 可见的焦点可编辑节点"在此 App 上不可满足，与点击精度、OCR 质量、几何算法都无关**——不要再往这三个方向排查。
- **对策：显式的 IME 单命名空间降级链**（design：`docs/specs/2026-07-25-IME单命名空间降级门-design.md`）。要点：
  - 身份来源写进值本身（`FocusIdentity(source = A11Y | IME_ONLY)`），**降级必须显式**。直接删掉 a11y 检查会让 `blank == blank` 恒真，绑定悄悄退化成"无绑定"。
  - **能严则严**：`FocusIdentity.of()` 是唯一降级决策点，a11y 侧一旦给得出合法节点身份就必须走严格链；a11y 侧有值但格式非法（例如把 IME 会话 id 塞进 a11y 位）一律 fail-closed，既不接受也不降级。
  - **一致缺失 vs 错配**：只有 `nodePresent/focused/editable/stage`（以及 bounds、input proof nodeId）**全部缺失**才算结构性缺失；一边有一边没有是错配，两条链都不给过。
  - 两套命名空间**不合并比较**（knowledge #43 的老教训）：IME-only 是另一条独立链，不是"把 IME id 当 a11y id 用"。旧代码里 `focusedInputSnapshot` 在无节点时把 `ImeBridge.focusedInputId` 填进 a11y 的 `id` 槽，正是这种隐式混用——只是被 store 的格式断言意外挡住了，改造时先堵这个口。
- **降级后的安全强度：确实有让步，不是等价替换。** 保留：IME 会话身份、输入长度/SHA-256/预览、**OCR 读回**、OCR 会话标题、包名、12 位确认编号、真人逐项核对并点击确认（两段式硬门不受影响）。失去：a11y 焦点节点身份与 bounds，**以及由 bounds 推出的"焦点确实是底部聊天输入框"这条几何保证**。IME-only 链下 OCR 读回是仅剩的"内容确实落框"机械证据，故设为硬性条件：读回未通过就不记输入证据，Enter 必被拦。
- **无节点通道要有读回区域**：全树空时没有任何 bounds 可用，读回区域退到与盲点探针同一几何（`p0FocusProbeRegion`，锚定系统底部 inset）。此前 `typeTextNoNode` 在 `target == null` 时**完全跳过读回**，降级链会因此永远拿不到证据。

## 自有零 UI IME 与 `ime_visible` 判据的冲突（2026-07-25 真机实锤）

- **`GatewayIme.onEvaluateInputViewShown()` 返回 false**（有意设计：注入通道不需要可见键盘，也避免键盘高度扰动布局），因此它**永远不创建 `TYPE_INPUT_METHOD` 窗口**。而 `ime_visible` 的定义就是 `windows.any { type == TYPE_INPUT_METHOD }` → **只要当前输入法是「执行网关」，`ime_visible` 恒为 false**（`keyboard_state.visible` 同源，三次真机诊断全程 false）。
- 这条恒假判据当时被用在三处当"输入会话是活的"的代理，其中两处是既有代码：`withFreshPreparedTargetGuard` 的 fresh proof、其 `requireCurrent()` 终验、以及 P0 宏的降级就绪判据。后果是**已准备目标在自有 IME 下从来就记录不成功**——这是与"微信屏蔽 a11y 树"**相互独立的第二根因**，两者叠加才是 P0 长期卡死的全貌。
- **替换判据（已实现）：用 IME 会话身份自证，三条**——①活性：`ImeBridge.session()` 非空且 InputConnection 可用（`onFinishInput` 会清空会话，所以为真即代表真有活会话）；②归属：会话的 `EditorInfo.packageName` 必须等于前台包（该包名原先被哈希进 `focusedInputId` 就取不回来了，需在 `ImeBridge` 单独留存 `sessionPackage`）；③**新鲜度**：聚焦动作前后 session id 必须变化（`onStartInput` 重新触发过）——这直接证明"这一次点击真的落在输入框上"，比"键盘弹起来了"更强，因为键盘可见根本不说明焦点在哪个框。
- **教训**：给"活性/可见性"选代理指标时，先确认这个指标在**自家组件的架构下**是否可能为真。零 UI 组件天然不满足一切"窗口可见"类判据。
- **"会话必须换新"也不成立**（同日实测的第二次踩空）：微信输入框在**键盘收起后仍长期持有焦点与活的 InputConnection**，对已聚焦的输入框再点一次不会重新触发 `onStartInput`，session id 自然不变。因此"聚焦动作前后 session id 必须变化"无法区分"点在了已聚焦的输入框上"（合法）与"点空了"（非法），只会把合法情形一起否掉。留下的判据是：会话归属 + **降级链永不走"已聚焦"短路（必须亲手执行那次已校验的盲点）** + 打字后输入栏 OCR 读回。
- **`keyboard_state.visible` 在自有 IME 下不可用作诊断依据**：它与 `ime_visible` 同源，恒为 false。真机诊断里用它"佐证键盘没弹起"是空推理，别再据此下结论。

## 那个"残留焦点节点"会连累三处，别只堵一处（2026-07-26）

微信会话页 `findFocus(FOCUS_INPUT)` 返回的残留节点（不 focused、不 editable、**bounds 退化**）在一天内连着咬了三处，且每处症状完全不同：

1. **身份**：被当成 a11y 焦点身份 → 证据绑到一个打不进字的节点上（改：`focusedInputSnapshot`/`FreshPreparedInputProof` 只在 `isEditable` 时产出节点 id 与几何）。
2. **就绪判据**：`nodePresent=true` 让"a11y 一致缺失"不成立 → 降级链永远进不去（改：`a11yAbsent = !nodePresent || (!editable && !focused)`）。
3. **输入路径**：`type_text` 在无 ref 时直接用 `focusedEditable()`，于是走了普通节点通道而不是无节点通道——SET_TEXT 打不进去，且**读回拿它的退化 bounds 去裁剪，把 ML Kit 喂出 `InputImage width and height should be at least 32!`**（改：同一把尺子 `refresh() && isEditable`，不满足就走无节点通道；读回再加一道 bounds<32 退到输入栏带的兜底）。

**教训**：给"这个节点能不能用"定了新判据后，要把**所有**取用该节点的路径一起改，否则症状会在离判据最远的地方冒出来（这里是 OCR 报错）。

## 输入栏 OCR 读回的两条实测约束（2026-07-26）

- **裁剪几何必须用截图位图自身尺寸，不能用 `displayMetrics`**：裁剪发生在位图坐标系里，两者不保证相等。
- **读回带要比盲点带高得多**：盲点带（`P0_PROBE_HEIGHT_PX=90`，底边=h−inset−10）只需要一个可点中心；而输入框文字基线实测落在系统 inset **之下**，用盲点带裁会读回 null。现按 `INPUT_BAR_READBACK_HEIGHT_PX=260` 从截图底边向上取。
- **读回判据是"归一后包含"**，能证明"我们的字落进去了"，**不能证明"框里只有我们的字"**（实测读回 `")PO降级链诊断 ))PO降级链诊断 D"` 仍判通过）。Enter 门另有输入长度/SHA-256 与真人核对屏幕兜底，但这条局限要记住。
- **读回失败必须区分三态**：抛异常 / 读到几何但无文字 / 读到文字但不匹配。早期 `runCatching{}.getOrNull()` 把异常吞成 null，直接多烧一轮诊断。

## ML Kit 中文 OCR 实战（M1b 融合层，vivo V2352A/Android16，2026-07-19）

- **深色模式灰底灰字漏识 ~40%**（微信搜索框/留言框占位符实锤；同屏正常对比度文本稳定命中）：临界对比度文本不可依赖单发识别。对策：整屏 OCR 缓存加 **2s TTL 重识**给抖动翻盘机会（revision 缓存对事件静默 app 会把单次漏识钉死）；关键锚点尽量选正常对比度文本。
- **小裁剪图识别塌方**：372×147 裁剪返回 **0 行**（同区域整屏可识）；小图 conf 普遍偏低。→ 校验/读回类裁剪**最小 ~620×220** 且居中给上下文；此类小图用 **conf 阈值 0**（靠位置稳定 + 相似度把关），整屏融合维持 0.5 过滤内嵌图乱码。
- **CJK 形近字逐帧抖动**：同一控件两次识别「搜索/搜素」互跳；图标偶被识成字符（放大镜→Q）时有时无；数字 0→O（S3 已知）。→ 匹配一律「归一（全角/大小写/o→0）contains ∥ 位置稳定（漂移≤1.2 行高）+ 字符袋相似度 ≥0.4」，纯 contains 会把自己人误判 STALE。
- **两行长标签拆成两个 OCR 行**（「文件传输/助手」实锤）→ 查询用短子串（find「文件传输」而非全名）。
- **手势后必须主动失效 OCR 缓存**：事件静默 app（微信）点击/滑动后 revision 不动，不失效就读旧屏。
- bundled 中文 client 常驻进程：冷加载 ~700ms 一次性；整屏 ~300–700ms 随文本密度（列表页低、图文重页高）。
- **深色模式灰底灰字漏识的直接对症修法：灰度化+对比度拉伸后再识别一遍，取更高置信度合并**（2026-07-24，[OcrEngine.kt](../../../app/gateway/src/main/java/dev/magina/gateway/ocr/OcrEngine.kt)）。此前只在下游（宏代码里）调阈值治标；真机实锤过某些实例的置信度直接跌破 `MIN_CONF=0.5` 这个 `OcrEngine.recognize()` 内部的基础过滤——阈值再怎么调也够不着连候选池都进不去的文字，只能从识别源头治本。做法：原图识别一遍、`ColorMatrix`（`setSaturation(0)`+围绕中灰点的对比度矩阵）增强后再识别一遍，按文字+位置重叠（IoU≥0.5）判定"同一处"，取置信度更高者合并，两遍互不覆盖只取优——不是替换原图识别，避免对本来就清晰的文字造成回退。**`OcrEngine.kt` 全仓库零单测**（依赖真实 `Bitmap`/ML Kit 推理，项目未配 Robolectric，`android.graphics.*` 在纯 JVM 单测下方法体是 stub 会直接抛异常），只能靠真机 dispatch 验证效果，效果未达预期时优先调 `CONTRAST_BOOST` 常量或改用自适应阈值/局部直方图均衡（比全局线性拉伸更贴近成因但实现和验证成本都更高）。

## adb / uiautomator 工具链

- **`uiautomator dump` 在重动画商业 app 报 `could not get idle state`**（京东首页实测；设置类 app 正常）。截图+视觉定位兜底是刚需不是可选项。M1 自研 AccessibilityService 直读事件流可绕开 idle 等待——这是自研执行器的核心价值证据。
- 软键盘弹出导致坐标错位（M0 两次误触的主因之一）。→ M1 需求：键盘状态感知、点击前二次校验（网关已内建）。
- **mobile-mcp 截图是缩放图**（实测约 360×800），而 click 工具吃物理坐标（1260×2800）——直接按截图坐标点击必偏约 ×3.5（M0.5 复测实锤）。规程：先 `get_screen_size` 拿物理分辨率再换算；站规 v2 已写入。M1 网关坐标主权收归执行器侧，此坑架构性消灭。
- 手机黑屏用 `adb shell input keyevent KEYCODE_WAKEUP` 点亮；预防靠「充电时屏幕不休眠」+ 临时关锁屏。

## 监督式真机跑测控制面（2026-07-23，离线实现）

- **确认状态可观察不等于确认可写**：debug runner 只用 `run-as` 写入一次性 `test-control.json`（run/leg/nonce/目标/过期时间/stale 开关），字段集合严格校验且不含 `allowed/denied`；PC 只读 `test-confirmation-state.json`。状态中的决定来自手机按钮回调，不能增加“测试方便”的 decision 写接口。release 必须使用 no-op 控制面且没有可用 stale 注入能力。
- **`run-as` 是 debuggable 私有取证边界**：token、确认状态、app cache 截图都不经过 exported provider/网络接口。外部命令异常不得拼接 adb stdout；token 只短暂驻留内存，配置原子替换、结束恢复，截图拉取后校验 PNG 并清设备副本。
- **自有 overlay 必须从执行面排除**：确认卡若进入 `windows/snapshot/ref`，Agent 可能通过 `ui_action` 机械自确认。窗口遍历、ref 注册和动作解析都要统一拒绝 gateway 自有窗口；仅把按钮回调作为真人决定源。
- **危险 Enter 不能只绑定抽象焦点**：成功 `type_text` 后登记短 TTL 的输入证据，绑定预览、长度、SHA-256 与 focused-input 指纹（包含 view/class/bounds）。确认卡展示预览/长度/哈希/焦点位置，最终执行前再比较；audit 只记长度/哈希，不落正文。
- **准备宏还要绑定业务目标，不只绑定输入**：宏成功后短时保存进程内 `PreparedTargetEvidence(label/package/focused-input/bounds/TTL)`；只允许沿 `macro → type_text → press_key(enter)` 链存活，任何旁路 UI mutation 都先使其失效。Enter 前后必须同时复核 label、包、焦点与 bounds，避免已进入“文件传输助手”的旧证据被其他导航复用。
- **同一确认必须有机械关联键**：12 位 confirm ID 同时显示在卡片、写入只读 confirmation state，并绑定该卡截图文件；runner 校验同一 ID，不能靠“时间接近”猜测截图与 allowed 状态属于同一张卡。用户只读卡上的编号，不负责计算输入哈希。
- **OCR ref 用前必须 fresh，不只是“缓存没过期”**：准备宏每个可变阶段先强制新截图并递增视觉世代，再按 capture revision、前台 windowId、置信度和 bounds 校验；resolve 可能触发慢 OCR，返回后还要快速原子复检再 perform。旧缓存或跨截图拼出的语义不能授权点击。
- **焦点身份有两套合法命名空间，不能强行相等**：a11y 节点 producer 生成 `windowId|viewId|class|package|bounds`，IME InputConnection 生成 `ime|<24hex>` session id。预备目标证据必须同时保存两套并分别复核（节点 id 绑 UI 树/bounds，IME id 绑输入通道）；任何“统一成一个 id 再比较”的捷径会让真实合法宏必然 `E_STALE_REF`（fail-closed 误杀）。节点 id 生成要收敛到单一共享 producer（`FocusedInputIdentity`），并用真实 producer 格式写契约测试——测试桩把所有 id 手工设成同一个值会掩盖编码差异，离线全绿也发现不了（2026-07-23 规格复审实锤）。
- **runner 离线套件必须在空闲机器上单独跑**：`p0-supervised-runner-offline.ps1` 的 fixture 用例对子 runner 有 `WaitForExit(15000)` 硬超时，与 gradle 全量编译或杀软扫描并发时子进程冷启动被拖垮，会成片报“runner 离线测试超时”的假失败（同机同代码：并发 28/32 → 空闲 32/32，2026-07-23 实锤）。判定套件结果前先确认无并发重负载；假超时重跑即可，不要当回归修。
- **离线全绿的 provision 脚本首次接真机大概率还会炸；别把离线通过当真机通过**（2026-07-23 首次真机 P0 provision 实锤，连续踩 4 个坑，均只在真机才现形）：
  1. `run-as ... am start-foreground-service -n <pkg>/.Service` 不显式给 `--user 0` 时，shell 以 user -2（USER_CURRENT）身份请求，被 `SecurityException: requires INTERACT_ACROSS_USERS[_FULL]` 拒绝——必须显式 `--user 0`。
  2. PowerShell `ArgumentList` 传 `'sh','-c','rm -f a/b-*.json'` 时，通配符参数在 adb shell 侧丢了引号，变成裸 `rm` 收到多个 glob 展开参数报错；必须内嵌单引号 `"'rm -f a/b-*.json'"` 让 shell 侧重新加引号。
  3. 重装 APK 后系统重绑无障碍服务是异步的（vivo 实测数秒到近百秒），单次探测必然与之竞态；`settings put secure enabled_accessibility_services <同值>` 不触发系统重新绑定——必须先写一个不同值（去掉本服务或整体 delete）强制系统解绑，再写回目标值触发重绑，之后按上限轮询而非单次探测。
  4. vivo 的 `dumpsys accessibility` 绑定区段只打印 `Service[label=执行网关, ...]`，不含组件名，纯组件名字符串匹配在 vivo 上永远判失败；需要额外接受 `label=<manifest application label>` 匹配。
  5. `cmd appops get <pkg> AUTO_START` / `BACKGROUND_START_ACTIVITY` 不是真实存在的 Android appops 操作名，任何设备上都会报 `Unknown operation string` 而非反映真实权限状态——这类“查询厂商专有权限”的探测如果找不到真实可查的系统 API，宁可不做，不要用会永远失败的伪探测冒充硬门（真实防护已有 deviceidle 白名单 + 每腿开始前强制重核无障碍绑定/输入法 + 全链路状态变化 fail-closed 兜底，2026-07-23 移除）。
  6. 目标 Android 版本（本机 Android 16/API 36）的 `adb shell am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -p <pkg>` 隐式包名解析直接报 "unable to resolve"，加 `--include-stopped-packages` 也无效；必须先 `cmd package resolve-activity --brief -c android.intent.category.LAUNCHER <pkg>` 拿到真实组件名，再用 `-n <component>` 显式启动。
  7. PowerShell `[Parameter(Mandatory)][string[]]$X` / `[byte[]]$X` 对**零长度（非 null）数组**一样拒绝绑定（`Cannot bind argument ... because it is an empty array`），这是常见陷阱，不是 `$null` 检查能防住的；任何后续可能拿到空集合调用的 Mandatory 数组参数必须加 `[AllowEmptyCollection()]`（同文件里另几处早已这么写，本次是没写全）。本次咬人的两处：cleanup 阶段扫描空的证据文件列表、真机截图被拉空时的 PNG 校验。
  8. `test-confirmation-state.json` 由 app 侧非原子写入（`pending → evidence_ready → allowed/denied/...` 多次覆写），PC 侧轮询 `cat` 有真实概率读到写入途中的半成品/截断内容；这类瞬时不可解析必须当“还没就绪”处理（等同文件不存在，返回 null 让下一次轮询重试），而不是直接当作永久性错误硬抛——调用方已有的确认超时兜底本来就能兜住“持续损坏”的情形，不会因此被静默放行。
  9. `GatewayA11yService.snapshot()` 里 `hasBlockingOverlay(ws)`（[GatewayA11yService.kt:343](app/gateway/src/main/java/dev/magina/gateway/a11y/GatewayA11yService.kt:343)）用默认参数 `primaryId = applicationWindow()?.id`，在耗时的 OCR 融合**之后**才被求值，等于对系统窗口状态重新查询了一次，而不是复用同一次快照早前已经拿到的 `fgWinId`；若这段时间前台窗口的 active/focused 标志发生哪怕一瞬间的抖动，"排除前台窗口自身"这条判断就会失配，微信自己的主窗口被当成"遮挡自己的浮层"，`blocking_overlay` 误判为 true，导致 `p0_wechat_file_transfer_prepare` 在完全干净的聊天列表页也会 `E_BLOCKED("sensitive_entry")`（2026-07-23 真机首次执行准备宏即实锤）。诊断方法：派一个只读 `ui_snapshot()` 诊断任务比对 `foreground_window_id`/`blocking_overlay`/`fg_elements` 与真实手机画面。修法：显式传入同一次快照已经算好的 `fgWinId`，不要依赖会重新查询的默认参数——这个函数在另一处调用点（`readFreshActionState`）本来就是这么做的，唯独 `snapshot()` 里这一处没跟上。
  10. `P0FocusProbeValidator.hasSensitiveOrBlockingSurface`（[P0WeChatPrepareMacro.kt:230](app/gateway/src/debug/java/dev/magina/gateway/a11y/P0WeChatPrepareMacro.kt:230)）原先对**整页全部元素**（含 OCR 融合出来的聊天列表预览文字）做危险词/取消-确认组合扫描；`DEFAULT_DANGER_WORDS` 含「支付」「转账」这类通用财务词，而「微信支付」官方入口和转账到期通知横幅在任何有真实使用记录的账号上近乎恒在——修好 9 号坑之后这道 `sensitive_entry` 门槛在真机上依然必错，因为触发源根本不是 `blocking_overlay`，是整页扫描把无关会话预览当成了当前弹窗内容。定位手段同上（只读 `ui_snapshot()` 诊断任务，比对真实 elements 数组的 `source` 字段）。修法：扫描前按 `element.source == "a11y"` 过滤——WeChat 聊天列表行本身 a11y 稀疏（`root=null`），可读文字几乎全部来自 OCR 融合，真实弹窗/系统对话框反而多为原生 a11y 节点，因此收窄到 a11y-only 既剔除了列表噪音，又不削弱对真实弹窗的检测。这两处（9、10）都是安全相关判据，修之前先用只读诊断任务实测拿到真实证据，不要凭猜测改；9 号是纯粹的实现 bug（两次查询语义应该一致却没对齐），10 号是设计取舍，改前征得了项目所有者同意再动手。
  11. 修完 9、10 号坑后 `sensitive_entry` 在真机上还是必错——`hasBlockingOverlay` 本身有个更根本的缺陷：状态栏/导航栏是常驻的独立 `TYPE_SYSTEM` 窗口，状态栏满宽、y 落在 0..~系统栏高度，与探测用的 `titleBand`（y 4%~22%）在任意分辨率下都大概率几何相交（本设备 1260×2800 实测：状态栏 bounds=(0,0)-(1260,133)，titleBand=(315,112)-(945,616)，在 y=112~133 段确定相交）；函数只排除了 `primaryId`（前台 App 窗口）和 `TYPE_INPUT_METHOD`，没排除 `TYPE_SYSTEM`，导致这条判定在**任意前台 App、任意时刻**都恒为 true，跟 9 号的时序竞态无关，是从未在真机上跑过就没人发现的纯粹遗漏。定位手段：不需要新的诊断，早前为查 vivo 无障碍绑定标签抓的真实 `dumpsys accessibility` 全量转储（`a11yWindow[...type=TYPE_SYSTEM...bounds=Rect(0,0-1260,133)...]`）里已经有现成证据，回头翻旧诊断数据比重新跑诊断更快。修法：`hasBlockingOverlay` 的窗口排除条件里加一条 `window.type == AccessibilityWindowInfo.TYPE_SYSTEM`。9/10/11 三条都是安全相关判据但性质不同：9 是纯实现 bug（同一次快照两次查询语义没对齐），11 也是纯实现 bug（系统常驻窗口类型没排除，任何合理的人都会同意状态栏不该被当成遮挡对话框），两者改前不需要额外确认；10 是真正的设计取舍（整页扫描 vs 只扫真实弹窗的 a11y 节点），改前征得了项目所有者同意。三层坑叠在一起，任何一层不修，`sensitive_entry` 在真机上都过不去——这也是为什么“改一处、重装、重跑”的迭代法在这类多因失效上格外耗时，早知道有三层就该一次性通读整个 `hasSensitiveOrBlockingSurface`/`hasBlockingOverlay` 调用链再动手。
  12. `sensitive_entry` 修完后（9/10/11 三层）下一关是 `unrecognized_entry`：`recognizedChatList = hasTopTitle(snapshot, "微信") && findSearchEntry(snapshot) != null` 恒假，两条各自原因不同——① 聊天列表顶部「微信」标题字号小、颜色浅，真机 OCR 置信度实测 0.51~0.61，低于全代码库唯一复用的 `MIN_ACTION_OCR_CONFIDENCE=0.65`；② 微信聊天列表的搜索入口是**纯图标、无 OCR 可读文字**（真机 47 个 OCR 元素里不存在任何「搜索」候选，不是置信度不够，是压根没有文字可识别），阈值再怎么调也补不上①和②不是同一类问题：①靠"引入更低的识别专用阈值"能修，②在当前 OCR-文字匹配架构下无法通过调阈值修，只能放弃把"能找到搜索图标"当作识别聊天列表的前提条件。诊断复用已抓到的真实 elements 原始 JSON（含各元素 `confidence`），不用再跑诊断。修法：新增 `MIN_RECOGNITION_OCR_CONFIDENCE=0.45`（[VisionTrustPolicy.kt](app/gateway/src/main/java/dev/magina/gateway/a11y/VisionTrustPolicy.kt)），只用于"当前是哪个页面"这类识别判据（如 `hasTopTitle`），不碰任何会被点击的目标；`recognizedChatList` 精简为只看标题。这个改动看似放宽了门槛，实则安全性不受影响——真正会被点击的目标（`findTargetConversation`/`findSearchEntry` 找到的搜索入口）在 `clickOrFail` 阶段仍会独立走 `P0StageRefActionValidator.find` 的 `MIN_ACTION_OCR_CONFIDENCE=0.65` 复核，找不到就在那一步 fail-closed（`E_NOT_FOUND`），只是失败阶段从"识别聊天列表"挪到了"定位搜索入口"，从不点击这条核心安全属性没变。改前顺着"识别→点击"两层独立校验的关系确认了这一点，不是拍脑袋放宽；这类"识别用途 vs 点击用途该不该共用同一阈值"的判断，判据是"后续是否有独立的、未被我改动的点击时复核"——有则识别层放宽是安全的，没有就不能碰。
  13. 上述第 9~12 四条都在 `app/gateway/src/main`/`debug` 主源码里，不是 runner 脚本；改完必须重新 `assembleDebug`（+`assembleRelease`/单测按需）并让下一次 provision 重装 APK 才会生效——`adb shell dumpsys package <pkg> | grep lastUpdateTime` 可以核对新 APK 确实已经装上。PowerShell 侧的空数组/引号/竞态坑（本册前面几条）对这四条不适用，反之亦然。
  14. 12 号坑修完，`recognizedChatList` 能识别聊天列表了，但真正要点击的目标依然卡壳：聊天列表里「文件传输助手」这一行文字实测 OCR 置信度约 0.51，搜索图标无文字可识别，两条路径都到不了 `MIN_ACTION_OCR_CONFIDENCE=0.65` 这道**点击级**门槛（`findTargetConversation`/`P0StageRefActionValidator.find`），`search_entry` 阶段 `E_NOT_FOUND` fail-closed（2026-07-23 真机实锤）。这里和 9/11（纯实现 bug）、12（识别用途可独立放宽）都不同：点击目标的置信度门槛就是防止点错东西的最后一道真实防线，不能再往下让——征得项目所有者同意后选择了不动代码，改成流程约束：跑测前用户手动把微信打开到「文件传输助手」会话页（宏能靠会话标题识别 `isConversationSurface`，这条路径 OCR 置信度足够），跳过依赖脆弱识别的自动搜索导航。见 [runbook §3.0](../../runbooks/P0-safety-hard-gate-smoke.md)。判断某个 OCR 置信度问题该走"代码放宽"还是"流程规避"，看它守的是"识别当前在哪"还是"决定点哪里"——后者出问题时，流程规避永远比降门槛更安全。
  15. 14 号写下的"会话标题识别路径 OCR 置信度足够"是想当然：`hasTopTitle`（微信聊天列表标题）当时已经改用 `MIN_RECOGNITION_OCR_CONFIDENCE=0.45`，但语义完全同构、唯一调用方是 `isConversationSurface`、从不作点击 ref 的 `conversationTitle()` 却漏改，仍卡在 `trustedVisualEvidence`（即 `MIN_ACTION_OCR_CONFIDENCE=0.65`）——这才是"手动切到会话页验证过不能绕开"的真实原因：人工已经站在「文件传输助手」会话页，`isConversationSurface` 依然判 false（会话页标题实测同样只有 ~0.55），宏照样掉回搜索分支撞上 14 号那堵墙，制造了"同一处 OCR 漏识，流程规避也没用"的假象。2026-07-24 定位：这是纯粹的改动遗漏（该迁移到识别层的两处只改了一处），不是新的设计取舍，不需要重新征求同意——`conversationTitle()` 只用于"是否在会话页"这一布尔判断，从未进入任何点击链路，和 12 号 `hasTopTitle` 是同一类。修法：`conversationTitle()` 同样改用 `trustedForRecognition`；`findTargetConversation`（聊天列表行本身的点击目标）保持不动，14 号"点击级门槛不能再让"的决定继续有效，只是它保护的从来只是真正的点击目标，没打算覆盖这处纯识别函数。改前逐条比对了 `P0WeChatPrepareMacroTest.kt` 里所有涉及「文件传输助手」/TOOLBAR/置信度的用例（含最貌似相关的 `low-confidence OCR title blocks probe`），确认无一被打破——那条用例改动后仍会在 `P0FocusProbeValidator` 的门槛上以同一 `E_BLOCKED` 失败，只是失败阶段从 `unrecognized_entry` 挪到了 `focus_probe_validation`，测试只断言错误码不断言阶段。已用补装的本地 gradle 跑 `testDebugUnitTest`+`testReleaseUnitTest` 验证：Debug 170 + Release 93 = 263 tests 全绿，与改动前基线一致，`P0WeChatPrepareMacroTest` 单类 51/51；`assembleDebug` 也成功，人工推演与实测结果一致。本地构建工具链的补装过程见 [harness.md](../brain/harness.md)。
  16. 15 号修完当天（2026-07-24）真机跑了 9 轮才把"卡在哪"彻底定位清楚，过程本身比结论更值得记：
      - **`P0FocusProbeValidator` 的标题识别和 `conversationTitle` 是同一族但性质不同，不能照抄**：它同样只用于"证明在文件传输助手会话里"、从不是点击目标（真正盲点的是算好的固定底栏坐标），但它的 `titleConfidence` 会写进 `P0FocusProof`/`PreparedTargetEvidence`，是确认卡证据链的一部分——所以这处改成 `MIN_RECOGNITION_OCR_CONFIDENCE` 是征得项目所有者明确同意后才动的真设计取舍，不像 `conversationTitle` 那次是纯粹的改动遗漏。改完 `P0WeChatPrepareMacroTest.kt` 里 `low-confidence OCR title blocks probe`（原 confidence=0.64，正好是新门槛之上、旧门槛之下）语义变了——降到 0.3 保留"真正低到连识别都不该信"的原意，另加一条新用例锁定 0.64 现在会往下走到真正尝试盲点（不再在 `focus_probe_validation` 就 fail-closed）。
      - **`scripts/lib/p0-device-provision.ps1` 的 `Start-P0TargetApp` 每一腿开始前无条件 `adb shell am start` 重启微信**，不检查是否已在前台——直接违背 runbook §3.0"人工预置状态、工具不碰微信"的设计初衷。修法：先查 `dumpsys activity activities` 的 `topResumedActivity`/`mResumedActivity` 是否已是目标包，是则跳过 relaunch。
      - **人工"预聚焦输入框"这条路径撑不住 `-Provision` 的耗时**：`-Provision` 每次都是必须的（runner cleanup 会按设计把输入法恢复回用户原来的，不是遗漏),而 `-Provision`+子进程冷启动总共 20~30 秒，人工点一下输入框建立的焦点/IME 连接撑不了这么久,和点击时机无关——`findInput()` 反复实测确认空白输入框真的没有 a11y/OCR 锚点（同 D4）,不是"没找对方法"。
      - **诊断技巧**：只读 `ui_snapshot()` 只能看 OCR/a11y 元素列表,看不出"截图是不是陈旧的"；派一个只读 `screen_capture()` 诊断任务、让子代理直接用视觉描述截图内容（不调用 ui_snapshot),能独立验证截图管线本身是否正确——本次用这招排除了"截图缓存陈旧"的怀疑（子代理看到的标题/气泡/输入框和用户描述完全一致),把范围收窄到"OCR 提取本身漏识了标题"。
      - **真正根因比两处代码门槛更底层**：[`OcrEngine.kt`](../../../app/gateway/src/main/java/dev/magina/gateway/ocr/OcrEngine.kt) 的 `MIN_CONF=0.5f` 是 `OcrEngine.recognize()` 内部的基础过滤,在整屏 OCR 调用路径（`GatewayA11yService.ocrScreen()`,无 minConf 参数即用此默认值）里,任何置信度低于 0.5 的文字连候选元素都不会出现在 `ui_snapshot()` 结果里——这道地板在 `MIN_RECOGNITION_OCR_CONFIDENCE`（0.45）和 `MIN_ACTION_OCR_CONFIDENCE`（0.65）**之下**,宏代码层面的门槛调节完全够不着它。真机实测两次独立诊断都显示「文件传输助手」标题在 `ui_snapshot()` 里零候选（不是低置信度,是压根不存在),说明这次它的真实识别置信度大概率跌破了 0.5 这条地板,和本册开头记录的"深色模式灰底灰字漏识约 40%"是同一个已知、尚未解决的 P0 风险——不是本轮两处阈值改动能覆盖的层次。两处阈值改动本身仍是真实、已测试验证的修复（对 0.5~0.65 区间确有效,「微信」聊天列表标题那次即是实锤),只是没能解决今天这次卡在 0.5 以下的具体状况。
      - 顺带留意但未确认是否相关：`ocrScreen()` 有一段按 `TYPE_INPUT_METHOD` 窗口顶边裁剪 OCR 位图的逻辑（"键盘弹出时只识键盘上方"),网关自身是无可见窗口的注入型 IME,这段裁剪对它的实际影响还没有专门验证过——如果后续排除 0.5 地板问题后空白输入框仍找不到锚点,这是下一个该查的点。
  18. **微信会话页对无障碍树基本不透明——这是 P0 当前的架构级阻断，不是调参问题**（2026-07-25 真机连穿五关后确认）。当天按"失败阶段前移"逐关验证修了 5 处真缺陷（伽马校正让标题从零候选变可识别；`revision` 排除 `TYPE_SYSTEM` 事件；Android 侧标题门槛 0.65→识别级；`P0PreparedTargetRecorderValidator` 的 `==`→`contains`+门槛；盲点安全区改为锚定 inset），最终在**微信已确认停在会话页、输入栏文字模式、文本框空白**的理想状态下仍卡在 `focus_ready`。
      - **诊断关键：`waitForReadyFocus` 的超时消息会逐条列出六个条件里缺哪几个，直接读它比加日志快得多。** 实测缺失项只有 a11y 四项（焦点节点/未 focused/非 editable/stage 不对），而 IME 三项（激活、InputConnection、focusedInputId）**全部正常**——输入法框架看得见焦点，无障碍 API 看不见。
      - **佐证（回头翻当天所有快照即可，不必新跑）：每次 `ui_snapshot` 的 a11y 元素恒为状态栏那 13 项（时钟/通知/信号/电量），微信会话页的标题、气泡、输入框 100% 来自 OCR，无一 a11y 节点。** 与当天网络调研到的"微信 ≥8.0.52 有意混淆 AccessibilityService 节点数据以对抗自动化"（CSDN/博客园/知乎多源独立印证）吻合。2026-07-22 曾记录"聚焦后 `findFocus(FOCUS_INPUT)` 可取到 MMEditText"，与现状矛盾——需复核当时微信版本，可能是版本升级后新增的混淆。
      - **因此宏要求的"a11y 可见的焦点可编辑节点"在此微信版本上不可满足**，与点击精度、OCR 置信度、区域几何统统无关；继续调这些参数不会有进展。而 [SafetyGate.kt:76](../../../app/gateway/src/main/java/dev/magina/gateway/core/SafetyGate.kt:76) 按设计硬性要求 Enter 前同时具备 a11y 侧 `focusedInputId`+`bounds` 与 IME 侧 `imeSessionId`（knowledge #43 的双命名空间），a11y 侧结构性缺失 → `PreparedTargetEvidence` 无法形成 → 链路必断。**2026-07-22 那条"人工预聚焦 + 无 ref `type_text`"的老路也已被这道门有意堵死，属加固不是回退选项，不要试图绕。**
      - **社区流传的绕过手法不可采用**：把自家无障碍服务注册成系统白名单服务名（如 `com.google.android.marvin.talkback.TalkBackService`）来躲混淆检查——这是冒充系统服务，有 ToS/封号风险，且白名单随时可变，与本项目"永不逆向、只走官方通道"的铁律相悖。
      - **下一步是决策而非编码**：要么查明并合法解决 a11y 全盲，要么由项目所有者决定是否允许 Enter 门以"IME 侧身份 + 输入证据哈希 + OCR 侧会话标题"成链（这会削弱刻意设计的双命名空间复核，属真安全取舍，**不得顺手放宽**）。
      - 附带待修：`Start-P0TargetApp` 改成"已在前台就跳过 `am start`"后有副作用——网关服务重启后再没有窗口状态事件触发，`ForegroundWindowTracker` 拿不到 activity 名，`foreground_known=false` 导致 W 级工具被拒；当前靠"人工回桌面、让脚本自己拉起微信"绕过，正式修法是让 tracker 能在服务连接时自举当前前台身份。
  17. 16 号之后同一天（2026-07-24）又追了一整天，最终发现真正卡点不是置信度，是**字符串精确匹配**：
      - **对比度增强真机证实有效**：[`OcrEngine.recognize()`](../../../app/gateway/src/main/java/dev/magina/gateway/ocr/OcrEngine.kt) 改成原图+灰度对比度拉伸图各识别一遍、按区域取更高置信度合并后，真机独立诊断证实「文件传输助手」标题从两次连续拿到"零候选"（完全不存在，不是低置信度）提升到能识别（0.55~0.59）——16 号定位的"跌破 0.5 地板"这个假说被这次真机结果正面验证。同时给宏顶层加了纯感知阶段（`unrecognized_entry`/`focus_probe_validation`，还没做任何点击/盲点之前）的有限次重试（`perceptionRetryAttempts`/`perceptionRetryDelayMs`），给 OCR 抖动翻盘机会；"故意不重试"只管点击/盲点之后，这两处新重试不受影响。
      - **但真正反复卡住的不是置信度，是精确匹配**：真机诊断实锤 OCR 把标题识别成**"文件传输助手8"**——尾随多识别出一个字符，`confidence=0.51~0.53` 完全正常。`conversationTitle`/`P0FocusProbeValidator` 标题查找/`P0FixedQueryValidator` 的 `targetToolbarPresent` 守卫这三处当时都用严格 `normalized(text) == P0_FILE_TRANSFER_ASSISTANT`，"文件传输助手8" 永远不等于"文件传输助手"，置信度再怎么调、重试再多次都没用——这和 common.md 开头 CJK 匹配那条规矩（"归一+contains∥位置稳定+字符袋相似度，纯 contains 会误判 STALE 但纯 `==` 会漏判"）本就该覆盖这类场景，P0 宏这几处却一直用了更严格的 `==`。修法：三处改用 `contains`；**点击目标**（`findTargetConversation`/`isTargetLabel` 严格版、`P0StageRefActionValidator.find` 的 `TARGET_CONVERSATION` 分支）保持 `==` 不动——这几处是 14 号"点击安全防线"决定保护的对象，识别/守卫用途和点击用途在这里第二次证明必须分开处理，不能因为发现了新问题就顺手把点击目标也放宽。
      - **即便如此，当天最终还是没能跑出一次完整到确认卡的真机结果**：这 5 处修复（含 15/16 号）逐条都用真机诊断单独验证过有效，178 个单测全绿，但端到端 smoke 反复卡在 `unrecognized_entry`/`focus_probe_validation`/`search_entry` 之间跳来跳去。排查排除了两个疑虑：① 截图缓存陈旧（`screen_capture` 视觉核对过，画面真实）；② 屏幕锁屏（`adb shell settings get global stay_on_while_plugged_in` = 7，且 `dumpsys power` 显示 `mWakefulness=Awake`，充电时三种电源都保持唤醒，不是锁屏问题）。剩下能确认的是两个概率性因素在叠加：OCR 抖动本身（即使装了重试，同一屏在很短时间内多次识别结果仍可能不同）+ 微信自己会在测试间隙把内部导航状态漂回聊天列表（不是 `Start-P0TargetApp` 的 `am start` 导致——已用 `dumpsys activity activities` 确认前台 Activity 全程没变，很可能是微信自身内存/空闲状态下的 fragment 栈重置，不受这几处代码或 adb 层面控制）。**诊断经验**：比起反复整套重跑 `run-p0-safety-smoke.ps1 -Provision`（每次装 APK+建 IME，几十秒起，还要现场人重新导航），先用 `dispatch.ps1 -Task "只读诊断..." -Executor gateway`（不需要 `-Provision`，几毛钱、二三十秒）确认当前真实状态再决定要不要整套重跑，今天这轮省了不少无效尝试。

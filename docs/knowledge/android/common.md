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

## ML Kit 中文 OCR 实战（M1b 融合层，vivo V2352A/Android16，2026-07-19）

- **深色模式灰底灰字漏识 ~40%**（微信搜索框/留言框占位符实锤；同屏正常对比度文本稳定命中）：临界对比度文本不可依赖单发识别。对策：整屏 OCR 缓存加 **2s TTL 重识**给抖动翻盘机会（revision 缓存对事件静默 app 会把单次漏识钉死）；关键锚点尽量选正常对比度文本。
- **小裁剪图识别塌方**：372×147 裁剪返回 **0 行**（同区域整屏可识）；小图 conf 普遍偏低。→ 校验/读回类裁剪**最小 ~620×220** 且居中给上下文；此类小图用 **conf 阈值 0**（靠位置稳定 + 相似度把关），整屏融合维持 0.5 过滤内嵌图乱码。
- **CJK 形近字逐帧抖动**：同一控件两次识别「搜索/搜素」互跳；图标偶被识成字符（放大镜→Q）时有时无；数字 0→O（S3 已知）。→ 匹配一律「归一（全角/大小写/o→0）contains ∥ 位置稳定（漂移≤1.2 行高）+ 字符袋相似度 ≥0.4」，纯 contains 会把自己人误判 STALE。
- **两行长标签拆成两个 OCR 行**（「文件传输/助手」实锤）→ 查询用短子串（find「文件传输」而非全名）。
- **手势后必须主动失效 OCR 缓存**：事件静默 app（微信）点击/滑动后 revision 不动，不失效就读旧屏。
- bundled 中文 client 常驻进程：冷加载 ~700ms 一次性；整屏 ~300–700ms 随文本密度（列表页低、图文重页高）。

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

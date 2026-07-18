# Android 通用坑（版本级行为 + 工具链）

> 来源：M0/M0.5 实测（2026-07-16/17，Android 16 环境）。厂商特有的坑在 [vivo-originos.md](vivo-originos.md) / [other-vendors.md](other-vendors.md)。

## Android 版本级行为

- **系统状态验证不能信 settings 键**：`settings get global bluetooth_on` 返回 0 时蓝牙实际是开的（Android 16 实测）；`dumpsys bluetooth_manager` 才是真值。验证通道要用 dumpsys / 专用 API（真值源对照表见 [sys-cli.md §1](sys-cli.md)）。
- **后台剪贴板写入受限**（Android 10+，16 实测拦截）：devicekit 1.2.4 的中文输入（写剪贴板+注入粘贴键）被拦，输入框出现的是剪贴板旧内容，可复现 3 次。纯 ASCII 正常。→ **M1 自带 IME 通道（输入法级注入），不依赖剪贴板戏法**；读剪贴板靠"默认 IME 豁免"。
- Android 13+ 普通 app 无法编程开关蓝牙/WiFi（shell 位阶专属，见 [sys-cli.md](sys-cli.md)）。
- 无障碍 `takeScreenshot`（API 30+）：单发极快 **32–37ms**（vivo V2352A/Android16 实测，远优于 500ms 判据）。连发（~400ms 间隔）触发**软节流**——第二次**不报** `ERROR_TAKE_SCREENSHOT_INTERVAL_TIME_SHORT`，而是 `takeScreenshot` 延迟到 **~750ms** 后成功返回；冷却 ~2s 后回落常速（Spike S4 实测，未精确二分冷却边界）。**与常见文档所述「硬失败」不同**，OriginOS6 是拖延返回。网关 `E_RATE_LIMITED` 冷却窗口参考 ~800ms（或容忍单次 ~750ms 延迟，不必判失败）。**M1b 补充（2026-07-19）：更紧的连发（<300ms，OCR 融合 snapshot 紧跟点击校验）也会硬报 INTERVAL_TIME_SHORT**——软/硬两种形态都存在；网关内部视觉通道已吸收（等 ~900ms 重试一次），`screen_capture` 工具仍向大脑透出 E_RATE_LIMITED 语义。

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

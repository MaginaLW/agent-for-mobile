# Android 通用坑（版本级行为 + 工具链）

> 来源：M0/M0.5 实测（2026-07-16/17，Android 16 环境）。厂商特有的坑在 [vivo-originos.md](vivo-originos.md) / [other-vendors.md](other-vendors.md)。

## Android 版本级行为

- **系统状态验证不能信 settings 键**：`settings get global bluetooth_on` 返回 0 时蓝牙实际是开的（Android 16 实测）；`dumpsys bluetooth_manager` 才是真值。验证通道要用 dumpsys / 专用 API（真值源对照表见 [sys-cli.md §1](sys-cli.md)）。
- **后台剪贴板写入受限**（Android 10+，16 实测拦截）：devicekit 1.2.4 的中文输入（写剪贴板+注入粘贴键）被拦，输入框出现的是剪贴板旧内容，可复现 3 次。纯 ASCII 正常。→ **M1 自带 IME 通道（输入法级注入），不依赖剪贴板戏法**；读剪贴板靠"默认 IME 豁免"。
- Android 13+ 普通 app 无法编程开关蓝牙/WiFi（shell 位阶专属，见 [sys-cli.md](sys-cli.md)）。
- 无障碍 `takeScreenshot`（API 30+）：单发极快 **32–37ms**（vivo V2352A/Android16 实测，远优于 500ms 判据）。连发（~400ms 间隔）触发**软节流**——第二次**不报** `ERROR_TAKE_SCREENSHOT_INTERVAL_TIME_SHORT`，而是 `takeScreenshot` 延迟到 **~750ms** 后成功返回；冷却 ~2s 后回落常速（Spike S4 实测，未精确二分冷却边界）。**与常见文档所述「硬失败」不同**，OriginOS6 是拖延返回。网关 `E_RATE_LIMITED` 冷却窗口参考 ~800ms（或容忍单次 ~750ms 延迟，不必判失败）。

## adb / uiautomator 工具链

- **`uiautomator dump` 在重动画商业 app 报 `could not get idle state`**（京东首页实测；设置类 app 正常）。截图+视觉定位兜底是刚需不是可选项。M1 自研 AccessibilityService 直读事件流可绕开 idle 等待——这是自研执行器的核心价值证据。
- 软键盘弹出导致坐标错位（M0 两次误触的主因之一）。→ M1 需求：键盘状态感知、点击前二次校验（网关已内建）。
- **mobile-mcp 截图是缩放图**（实测约 360×800），而 click 工具吃物理坐标（1260×2800）——直接按截图坐标点击必偏约 ×3.5（M0.5 复测实锤）。规程：先 `get_screen_size` 拿物理分辨率再换算；站规 v2 已写入。M1 网关坐标主权收归执行器侧，此坑架构性消灭。
- 手机黑屏用 `adb shell input keyevent KEYCODE_WAKEUP` 点亮；预防靠「充电时屏幕不休眠」+ 临时关锁屏。

# 设备 / ROM / 输入通道的坑

> 整理自 M0 实测（2026-07-16，vivo V2352A · X100 系列，Android 16 / OriginOS，1260×2800）。原始记录：[docs/runs/2026-07-16-M0.md](../runs/2026-07-16-M0.md)。品牌开关完整矩阵见 [M0 runbook §1.1](../runbooks/M0-runbook.md)。

## vivo / OriginOS（主力测试机）

- **「USB 模拟点击」开关必开**，否则注入报 SecurityException；开了之后 tap/swipe 完全正常（实测确认）。
- OriginOS 5 有 ADB 白名单：一直 unauthorized 就检查「USB 调试 → 仅允许指定计算机调试」。
- **系统设置深链不可靠**：`am start -a android.settings.BLUETOOTH_SETTINGS` 不把蓝牙页带到前台（主设置 intent 正常）。执行器的 `open_link` 必须有「深链失败 → UI 导航兜底」。

## Android 16 通用

- **系统状态验证不能信 settings 键**：`settings get global bluetooth_on` 返回 0 时蓝牙实际是开的；`dumpsys bluetooth_manager` 才是真值。验证通道要用 dumpsys / 专用 API。
- **后台剪贴板写入受限**：devicekit 1.2.4 的中文输入（写剪贴板+注入粘贴键）被拦，输入框出现的是剪贴板旧内容，可复现 3 次。纯 ASCII 正常。→ **M1 必须自带 IME 通道（输入法级注入），不能依赖剪贴板戏法。**
- **预测输入法吞空格**（M0.5 复测，vivo 默认联想输入法）：mobile-mcp `type_keys` 发出的空格在合成态被当成「选词确认」而非字面空格——"harness drill 0717" 连成 "harnessdrill0717"，单发空格无效果，全选重输同样复现。含空格文本无法精确录入 → M1 IME 通道再添一条实锤；临时绕法候选：切无预测 ABC 键盘 / 剪贴板粘贴（英文场景未验证）/ 任务文本避开空格。

## adb / uiautomator 工具链

- **`uiautomator dump` 在重动画商业 app 报 `could not get idle state`**（京东首页实测；设置类 app 正常）。截图+视觉定位兜底是刚需不是可选项。M1 自研 AccessibilityService 直读事件流可绕开 idle 等待——这是自研执行器的核心价值证据。
- 软键盘弹出导致坐标错位（M0 两次误触的主因之一）；输入法预测引擎会篡改大小写。→ M1 需求：键盘状态感知、点击前二次校验。
- **mobile-mcp 截图是缩放图**（实测约 360×800），而 click 工具吃物理坐标（1260×2800）——直接按截图坐标点击必偏约 ×3.5（M0.5 复测实锤，很可能也是 M0 部分误触的共因）。规程：先 `get_screen_size` 拿物理分辨率再换算；站规 v2 已写入。
- 手机黑屏用 `adb shell input keyevent KEYCODE_WAKEUP` 点亮；预防靠「充电时屏幕不休眠」+ 临时关锁屏。

## 其他品牌速记（未实测，来自 runbook 调研）

- 小米 HyperOS：必开「USB 调试（安全设置）」（要求插 SIM + 小米账号）。
- 华为鸿蒙 NEXT：**无标准 adb**（只有 hdc），不能用。
- 三星 One UI 最省事。

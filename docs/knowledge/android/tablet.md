# Android 平板知识册

> 当前状态：🔵 只读设计与代码审计；尚无平板真机数据。首轮实测后按“设备/ROM/日期”补证据。

## 当前能力边界

- 手机与平板复用 Android 执行器和 MCP 架构，但现有 P0 几何仍以手机竖屏为基线。
- `P0FocusProbeValidator` 要求 `h>w` 且 `h/w` 在 `1.4..2.7`；4:3 竖屏与全部横屏可能正确
  fail-closed。不得删除这道门来换成功率。
- snapshot/OCR 多处仍以整屏为坐标系；在分屏、自由窗或微信双栏下，标题、IME 焦点、输入框和消息
  气泡可能分属不同 pane。未建立 window/pane 身份前，禁止危险输入与发送。
- 首轮支持边界：竖屏、全屏、单窗口、默认显示缩放、非浮动 IME；其他形态只读记录为 unsupported。

## T0 入场需要记录

- 设备：manufacturer/model/product/device、Android/API/ABI；ADB serial 与 build fingerprint 只落 hash。
- 显示：physical/override size、density、smallestWidthDp、rotation/orientation、system bars/insets。
- 窗口：application window 数量、前台 package/activity、app window bounds、windowing mode。
- 输入：默认 IME、硬键盘/浮动 IME；解析不出记 `unknown`，绝不猜。
- ROM：USB 安装确认、a11y、overlay、notification、后台/电池策略；厂商特有结论再路由到厂商册。

## 参考

- Android 官方建议按动态 App 窗口而非设备型号适配，并以 window size classes 表达可用空间：
  https://developer.android.com/develop/ui/views/layout/use-window-size-classes
- Android 16 在大屏上会忽略部分方向/宽高比/可调整大小限制，因此不能依靠锁竖屏规避适配：
  https://developer.android.com/develop/adaptive-apps/guides/app-orientation-aspect-ratio-resizability

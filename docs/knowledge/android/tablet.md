# Android 平板知识册

> 当前状态：🔵 首份 T0 真机画像已保存；兼容候选已钉
> `5ba9532aad3485b22a25e20c9eeaa89264333b87`。真机验证前不合入 main 行为。

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

T0 当前只覆盖设备/显示/姿态/窗口/IME 的固定只读 ADB 查询；不安装 APK、不启动 App、不截图、
不改设置、不接 gateway。ROM 安装、权限与后台策略属于 T0 后续分层探测，不得混入这次只读入场。
即使只读 readiness accepted，也仍须保持 `p0_capability=unsupported`，直到微信 app window/pane、
目标输入焦点与消息后验在该平板上分别验证。

## vivo PA2553 / Android 16 · 2026-08-24

- 证据：`tablet-t0-20260823T162008Z-5e4e0186`；只保存 SHA-256 设备标识，不保存 raw serial/fingerprint。
- 已知画像：vivo PA2553（product/device DPD2437）、Android 16 / API 36、arm64-v8a；physical
  1968×2800、400dpi、无 override；默认输入法为 vivo Pad IME。
- 采集时屏幕亮、已解锁、勿扰关闭、IME 未显示且非浮动；前台为 Chrome CustomTab。窗口中同时有一个
  fullscreen 2800×1968 和一个 pinned 1013×570，说明当时为横屏且非单窗口，因此正确 blocked。
- schema v1 没有持久化 raw dumps，不能事后判定 rotation/sw 是缺席还是歧义，也不能补写
  capture consistency。旧证据保持 `device_class=unknown` / `intake=inconclusive`，不得修绿。
- 新候选只用固定 `am get-config` 的唯一当前 `swNNNdp` 决策 device class；activity 全局配置若存在则必须
  与其一致。窗口尺寸回退只在唯一前台 owner、fullscreen、原点为 0,0 且边长严格匹配 effective wm size
  时用于 current orientation；冲突、重复、历史 config 或采集前后漂移均返回 unknown/blocked。
- 下一次 T0：关闭 Chrome、画中画/pinned、分屏/自由窗，断开实体键盘，平板锁竖屏；微信全屏停在
  文件传输助手会话页，输入框清空、键盘收起。即使 readiness accepted，微信内部单/双 pane 仍待只读探针。

## 参考

- Android 官方建议按动态 App 窗口而非设备型号适配，并以 window size classes 表达可用空间：
  https://developer.android.com/develop/ui/views/layout/use-window-size-classes
- Android 16 在大屏上会忽略部分方向/宽高比/可调整大小限制，因此不能依靠锁竖屏规避适配：
  https://developer.android.com/develop/adaptive-apps/guides/app-orientation-aspect-ratio-resizability

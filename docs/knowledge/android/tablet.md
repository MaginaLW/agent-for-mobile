# Android 平板知识册

> 当前状态：🔵 PA2553 日常横屏为当前平板基线。T0-L schema v5 候选
> `135010863ef395a0cb8aacfa625ae87a2453b1dd`（42/42、coverage 41/41、独审 P0/P1=0）与 T-L1 无机契约
> `f5c8e15bca5065b504dab73149c7750a1e6dda3d`（gate 11/11、契约 41/41、coverage 25/25）均未合行为。
> v4 已取得一次真实平板画像但正确 blocked；首条固定 v5 C0 在设备发现阶段看到 0 台设备，未产出画像。

## 当前能力边界

- 手机与平板复用 Android 执行器和 MCP 架构，但现有 P0 几何仍以手机竖屏为基线。
- `P0FocusProbeValidator` 要求 `h>w` 且 `h/w` 在 `1.4..2.7`；4:3 竖屏与全部横屏可能正确
  fail-closed。不得删除这道门来换成功率。
- snapshot/OCR 多处仍以整屏为坐标系；在分屏、自由窗或微信双栏下，标题、IME 焦点、输入框和消息
  气泡可能分属不同 pane。未建立 window/pane 身份前，禁止危险输入与发送。
- 首轮 T0-L readiness：横屏、微信前台、全屏单 OS app window、边界覆盖当前显示、默认显示缩放、
  采集稳定、非浮动 IME。accepted 只允许继续做只读 pane 探针；P0 仍 unsupported。
- OS 单窗口不等于微信内部单 pane。横屏微信可能同时展示左侧会话列表和右侧目标会话；未建立唯一
  target pane、title/input/message 同 pane 与 layout epoch 前，禁止危险输入和发送。

## T0-L 已实现画像

- 设备：manufacturer/model/product/device、Android/API/ABI；ADB serial 与 build fingerprint 只落 hash。
- 显示：physical/override size、density、smallestWidthDp、rotation/orientation；任一 size/density override
  都阻断默认显示基线。
- 窗口：application window 数量、前台 package/activity、app window bounds、windowing mode。
- 输入：默认 IME、IME visible/floating/session；解析不出记 `unknown`，绝不猜。

T0 当前只覆盖设备/显示/姿态/窗口/IME 的固定只读 ADB 查询；不安装 APK、不启动 App、不截图、
不改设置、不接 gateway。ROM 安装、权限与后台策略属于 T0 后续分层探测，不得混入这次只读入场。
即使只读 readiness accepted，也仍须保持 `p0_capability=unsupported`，直到微信 app window/pane、
目标输入焦点与消息后验在该平板上分别验证。

T0-L **尚未机械证明** font scale、实体键盘、system-bar/taskbar/cutout insets 或多 display；这些字段必须
由未来 T-L1 受控 producer 与真机数据补齐。ROM 的 USB 安装确认、a11y、overlay、notification、后台/
电池策略也不属于本次纯 ADB intake；以后按厂商和能力分层验证，再路由到厂商册。

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
- 下一次 T0-L（主会话明确通知连接后）：关闭 Chrome、画中画/pinned、分屏/自由窗，断开实体键盘，
  平板锁横屏；微信全屏停在文件传输助手会话页，输入框清空、键盘收起。内部单/双 pane 保持真实日常
  状态，不要求用户强行切成手机 UI；交给 T-L1 只读探针判定。

## schema v4/v5 受控结果 · 2026-08-25

- v4 只读 run `t0l-landscape-20260825T113747Z-da2fa68d` 已取得 PA2553 / Android 16 画像：physical
  1968×2800、400dpi、`smallest_width_dp=787`，但 rotation、current size 与 foreground 均不可可靠判定；
  两个窗口都投影为 `[0,0,2800,1968]`，v4 没保存也没比较 WindowState identity，无法证明是一个对象重复输出
  还是两个不同窗口。readiness 因此保持 blocked；历史 v4 JSON 不迁移、不补判。
- v5 候选 `135010863ef395a0cb8aacfa625ae87a2453b1dd` 改为 topResumed 权威、identity canonical、强可见性、
  focus/display/type 关系、default-display rotation 严格定域、状态/IME 初末双读与 run-wide 脱敏标签；离线
  fake-adb 42/42、required coverage 41/41、独审 P0/P1=0。即使 readiness accepted，P0 也恒 unsupported。
- 首条固定 v5 C0 `t0l-v5-landscape-20260825T125508Z-13501086-r1` 只执行一次入口，`adb devices`
  识别到 0 台设备后 exit 1；查询表未继续、无 profile/evidence、未重跑。这是连接/发现前置失败，既不验证
  也不否定 v5 解析。下一次必须在用户重新确认 USB 连接与调试授权后使用全新 run/worktree，不能复用本轮。

## 横屏路线与硬边界

1. **T0-L** 只证明设备/姿态/OS window 可用于继续测量；固定输出
   `wechat_layout_unverified` + `tablet_landscape_p0_unimplemented`，P0 unsupported。
2. **T-L1 无机契约** 当前只有 synthetic schema/validator：生产入口在读取 caller 文件前固定
   `runtime_producer_unavailable`，fixture 只能验证几何契约，不能产生 runtime、微信验证或执行授权。
3. **T-L1 真机 producer** 未来必须纯感知两帧并找到唯一目标 pane，证明目标标题是 pane toolbar、不是左栏同名行；
   toolbar/message/input bounds 与前台/window identity 在两帧中稳定。只保存 bounds/hash/reason。
4. **T-L2** 才实现危险链：每腿 fresh layout proof；prepare/type/确认/Enter/发送后验/teardown 传播同一
   display + app window + pane + layout epoch。首版禁用 IME-only 与整屏坐标兜底。
5. 四腿带外 OCR 必须覆盖 Allow/Stale/Deny/Reentry、保留 X/Y 并裁 target pane；unavailable、unreadable
   或 inconclusive 均不得把横屏批次判通过。
6. 手机 `P0FocusProbeValidator` 的 `h>w`、比例和手机式标题/底栏规则继续保留；横屏是独立策略，不在
   手机路径上删门放行。竖屏平板兼容在横屏闭环后另批验证。

## 参考

- Android 官方建议按动态 App 窗口而非设备型号适配，并以 window size classes 表达可用空间：
  https://developer.android.com/develop/ui/views/layout/use-window-size-classes
- Android 16 在大屏上会忽略部分方向/宽高比/可调整大小限制，因此不能依靠锁竖屏规避适配：
  https://developer.android.com/develop/adaptive-apps/guides/app-orientation-aspect-ratio-resizability

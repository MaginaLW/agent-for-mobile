# Android 平板适配设计

- 日期：2026-08-23
- 状态：方向已批准；2026-08-24 改为 PA2553 横屏优先；T0-L 离线候选已完成，尚未横屏真机验收
- 决策人：Magina（用户）

## 1. 决定与目标

自 2026-08-23 起，手机真机 C 道暂停，后续真机任务统一使用 Android 平板。手机既有 run、ledger、
证据和 `0/4` 结论原样保留，不改写为平板结果。

2026-08-24 用户进一步确认 vivo 平板日常以横屏使用，因此 **PA2553 / Android 16 / 横屏**成为当前
设计与验收基线；竖屏兼容后置。这个决定不修改手机历史策略，也不允许删除手机现有 `h>w`、比例、
顶部中心标题或底栏安全门。横屏走显式、默认关闭的 tablet-landscape 证据路径。

目标不是把 `phone` 文案替换成 `tablet`，而是让每次安全判断绑定**当前 App 窗口和目标会话 pane**。
Android 官方也把可用 App 窗口而非设备型号作为适配基准，并要求考虑运行时旋转、分屏和窗口尺寸变化：
[window size classes](https://developer.android.com/develop/ui/views/layout/use-window-size-classes)、
[large-screen orientation/resizability](https://developer.android.com/develop/adaptive-apps/guides/app-orientation-aspect-ratio-resizability)。

## 2. 首轮边界

T0-L 首轮 readiness 只接受：

- Android 平板（`smallestWidthDp >= 600`）；
- 横屏、全屏、单个 owner-matching BASE_APPLICATION 窗口，边界精确覆盖当前显示；
- 默认显示/字体缩放；
- 非浮动 IME，无并存硬键盘输入；
- 微信在前台；内部单栏/双栏不由 T0-L 猜测，交给下一阶段只读探针。

T0-L readiness accepted 只表示“可以继续做横屏只读 pane 测量”，不表示危险动作支持。微信内部 pane、
分屏/自由窗、桌面窗口、PiP、浮动 IME 与外接显示器均不能被 T0-L 放行为 P0。Android 16 大屏会忽略
部分 orientation/resizable 限制，所以不能靠 manifest 锁方向代替真实适配。

## 3. 为什么不能直接跑现有四腿

1. 盲点探针要求 `h>w`、手机宽高比，并按整屏中心/底部固定像素定位；双栏时可能落在分栏线。
2. IME-only 身份只证明焦点属于微信包，不能证明属于右侧目标会话而不是左侧搜索。
3. snapshot/a11y/OCR 仍可能遍历整屏或多个 APPLICATION 窗口；多窗内容会混入 ref 与语义面。
4. runner 的发送后验主要按 Y 轴划消息区；同 Y 不同 pane 的 marker 可能被误当消息证据。
5. 确认 overlay 全屏宽、固定物理像素 padding、无最大高度/滚动，横屏大屏尚未验。

当前失败方向大多是安全的 fail-closed。删除方向或比例判断只会把“明确拒绝”变成“可能点错”，禁止。

## 4. 分批路线

### T0-L · 横屏只读入场

受控脚本只执行 ADB 只读命令，生成脱敏 `tablet-profile.json`。记录：

- serial hash、manufacturer/model/product/device、Android/API/ABI、fingerprint hash；
- physical/override size、density、smallestWidthDp、rotation/orientation；
- wake/keyguard/zen、默认 IME；
- top package/activity、APPLICATION window 数量/bounds/windowing mode；
- 解析不出的字段为 `unknown`，不以默认值冒充通过。

T0-L 不安装、不启动 App、不注入输入、不改设置、不调用确认或发送。其产物先证明“这台平板是什么、
处于什么姿态”，再决定是否进入安装/权限/网关只读能力的下一段 C0。ADB serial/fingerprint/raw dumpsys
不得持久化。

T0-L 的 `p0_capability` 永远是 `unsupported`，固定原因至少包含 `wechat_layout_unverified` 与
`tablet_landscape_p0_unimplemented`。外部 `tablet-profile.json` 只用于验收归因，不参与 gateway 放行。

### T-L1 · 微信横屏 pane 只读探针

在 T0-L 通过后，用独立 R 级工具做两帧以上纯感知探针，不点击、不输入、不切 IME、不启动 App：

1. 区分 OS 的唯一全屏 App window 与微信内部 `single_pane` / `dual_pane` / `ambiguous` 布局。
2. 找到唯一目标会话 pane；「文件传输助手」必须是 pane toolbar/title，不能是左栏同名会话行。
3. 在同一 pane 内机械分出 toolbar、message viewport 与 bottom input bar，并绑定 window/pane identity。
4. 记录 display/app window/pane bounds、layout epoch、title/input 来源和两帧一致性；不持久化聊天明文。
5. 任一歧义、漂移、跨 pane 或 IME/editor 未绑定都 fail-closed。

T-L1 accepted 只把 `wechat_layout_verified=true`，P0 仍然 unsupported。

### T-L2 · 横屏 P0

在 T0-L 与 T-L1 通过后，依次完成：

1. 所有视觉证据绑定统一 `DisplayGeometry` 与 `layout_epoch`（display、App window、insets、pane 同代）。
2. precheck 返回唯一 app window/pane/input rect；首版横屏策略禁用 IME-only 与整屏坐标兜底。
3. 标题、输入栏、确认意图、Enter 前 fresh capture、发送后验与 teardown 全部绑定同一 pane。
4. 发送后验与四腿带外 OCR 同时校验 X/Y、window/pane，先裁目标 pane 再聚类 OCR 行；inconclusive 不得绿。
5. 确认卡整卡和两个按钮必须位于横屏 safe area；布局变化立即 `E_STALE_REF`。
6. 完整离线矩阵和独审通过后，才钉 SHA 跑 Allow→Stale→Deny→Reentry。

### T-L3 · 横屏确认 surface 与多窗

确认 overlay 改为有最大宽/高、正文可滚动、按钮固定可见，并独立验证横屏 safe area、大字体、显示缩放
与 cutout。分屏/自由窗只有在元素具备 window identity、OCR 先裁 App window、后验绑定 pane 后再开放。

### T-P · 竖屏兼容

横屏闭环后单独验证 PA2553 竖屏的单/双栏、标题、输入栏和确认 surface。平板竖屏不能借用手机比例门
冒充验收，手机 portrait 历史策略也不自动继承平板结果。

## 5. 验收顺序

1. **A 道**：T0-L 脚本与 fake-adb fixtures；设备画像 schema、路径边界、命令 allowlist、凭据扫描。
2. **C0 只读**：用户明确连接后只跑 T0-L；未知/漂移即冻结并回 A，不算手机批次 4 失败。
3. **A/C 只读**：实现并运行 T-L1；固定 SHA，持久化脱敏 pane schema，P0 仍 unsupported。
4. **A 道**：实现 T-L2 pane-aware 策略；全量 gate 与独审通过后固定精确 SHA。
5. **C2 危险腿**：唯一 build/install/runner；任何一腿失败整轮冻结。通过后才按协议合 main。

## 6. T0-L 验收矩阵

| 场景 | intake | P0 能力 |
|---|---|---|
| PA2553 横屏、全屏、单 OS 窗口、微信前台 | readiness accepted | `unsupported`：待 T-L1 + T-L2 |
| 平板竖屏 | 画像通过但 readiness blocked | `unsupported_portrait_compat_pending` |
| 横屏 4:3 / letterbox | 画像通过并明确记录 | `unsupported_geometry` |
| 分屏/自由窗/多 APPLICATION window | 画像通过并明确记录 | `unsupported_multi_window` |
| 浮动 IME/硬键盘并存 | 画像通过并明确记录 | `unsupported_input_mode` |
| 手机 | intake 拒绝 `not_tablet` | 手机历史流程已暂停 |
| 多台/unauthorized/offline | setup fail | 不产生真机能力结论 |

## 7. 不变量

- T0-L 永远零输入、零发送；命令 allowlist 由离线测试扫描。
- “画像通过”不等于“危险动作支持”；manifest 必须分开记录 intake 与 P0 capability。
- 未识别的 rotation/window mode/insets/input mode 不得猜成默认值。
- 手机和平板 run 分开编号与归因；历史手机 C 不复用。
- 手机 `h>w`、手机比例和手机式标题/底栏门永远不因横屏平板而放宽；tablet-landscape 是独立路径。
- T-L1 必须先有左栏同名标题、错 pane 同 Y marker、pane 漂移等反例，再进入横屏危险实现。

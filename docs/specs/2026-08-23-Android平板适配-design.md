# Android 平板适配设计

- 日期：2026-08-23
- 状态：方向已批准；T0 A 道已启动，尚未平板真机验收
- 决策人：Magina（用户）

## 1. 决定与目标

自 2026-08-23 起，手机真机 C 道暂停，后续真机任务统一使用 Android 平板。手机既有 run、ledger、
证据和 `0/4` 结论原样保留，不改写为平板结果。

目标不是把 `phone` 文案替换成 `tablet`，而是让每次安全判断绑定**当前 App 窗口和目标会话 pane**。
Android 官方也把可用 App 窗口而非设备型号作为适配基准，并要求考虑运行时旋转、分屏和窗口尺寸变化：
[window size classes](https://developer.android.com/develop/ui/views/layout/use-window-size-classes)、
[large-screen orientation/resizability](https://developer.android.com/develop/adaptive-apps/guides/app-orientation-aspect-ratio-resizability)。

## 2. 首轮边界

首轮只接受：

- Android 平板（`smallestWidthDp >= 600`）；
- 竖屏、全屏、单个 APPLICATION 窗口；
- 默认显示/字体缩放；
- 非浮动 IME，无并存硬键盘输入；
- 微信停在文件传输助手的单会话 surface。

这是安全的阶段性入口，不是永久锁竖屏。横屏、微信双栏、分屏/自由窗、桌面窗口、浮动 IME 与外接
显示器先标 `unsupported` 并 fail-closed。Android 16 大屏会忽略部分 orientation/resizable 限制，
所以不能靠 manifest 锁方向代替真实适配。

## 3. 为什么不能直接跑现有四腿

1. 盲点探针要求 `h>w`、手机宽高比，并按整屏中心/底部固定像素定位；双栏时可能落在分栏线。
2. IME-only 身份只证明焦点属于微信包，不能证明属于右侧目标会话而不是左侧搜索。
3. snapshot/a11y/OCR 仍可能遍历整屏或多个 APPLICATION 窗口；多窗内容会混入 ref 与语义面。
4. runner 的发送后验主要按 Y 轴划消息区；同 Y 不同 pane 的 marker 可能被误当消息证据。
5. 确认 overlay 全屏宽、固定物理像素 padding、无最大高度/滚动，横屏大屏尚未验。

当前失败方向大多是安全的 fail-closed。删除方向或比例判断只会把“明确拒绝”变成“可能点错”，禁止。

## 4. 分批路线

### T0 · 只读入场

受控脚本只执行 ADB 只读命令，生成脱敏 `tablet-profile.json`。记录：

- serial hash、manufacturer/model/product/device、Android/API/ABI、fingerprint hash；
- physical/override size、density、smallestWidthDp、rotation/orientation；
- wake/keyguard/zen、默认 IME；
- top package/activity、APPLICATION window 数量/bounds/windowing mode；
- 解析不出的字段为 `unknown`，不以默认值冒充通过。

T0 不安装、不启动 App、不注入输入、不改设置、不调用确认或发送。其产物先证明“这台平板是什么、
处于什么姿态”，再决定是否进入安装/权限/网关只读能力的下一段 C0。ADB serial/fingerprint/raw dumpsys
不得持久化。

### T1 · 竖屏全屏 P0

在 T0 画像通过后，依次完成：

1. 所有视觉证据绑定统一 `DisplayGeometry`（截图、显示、App window、insets、rotation 同代）。
2. precheck 返回 app window/pane/input rect 与 window identity。
3. IME-only 在大屏必须证明目标 input 位于目标会话 pane；否则拒绝。
4. 发送后验与带外 OCR 同时校验 X/Y、window/pane，先裁目标 pane 再拼 OCR 行。
5. 完整离线矩阵和独审通过后，才钉 SHA 跑 Allow→Stale→Deny→Reentry。

### T2 · 横屏/双栏

加入 pane-aware 标题、ref、输入与消息区；用“右侧目标会话 + 左侧搜索/其他会话”反例证明不会串 pane。
横屏/双栏最多合并两个行为改动，不与确认 surface 同批。

### T3 · 确认 surface 与多窗

确认 overlay 改为有最大宽/高、正文可滚动、按钮固定可见，并独立验横屏/4:3。分屏/自由窗只有在
元素具备 window identity、OCR 先裁 App window、后验绑定 pane 后再开放。

## 5. 验收顺序

1. **A 道**：T0 脚本与 fake-adb fixtures；设备画像 schema、路径边界、命令 allowlist、凭据扫描。
2. **C0 只读**：平板接入后只跑 T0；若设备/姿态/窗口未知，冻结并回 A，不算批次 4 失败。
3. **A 道**：用 C0 的脱敏窗口/截图/元素数据实现 T1；完整 gate 与独审。
4. **C1 危险腿**：固定精确 SHA，唯一 build/install/runner；任何一腿失败整轮冻结。
5. C1 通过后才按仓库协议合入 main。

## 6. T0 验收矩阵

| 场景 | intake | P0 能力 |
|---|---|---|
| 平板竖屏、全屏、单窗口 | 通过并完整画像 | `pending_t1`，不能直接发送 |
| 平板横屏 | 画像通过 | `unsupported_landscape` |
| 4:3 竖屏平板 | 画像通过，不因手机宽高比拒绝 | `pending_t1` |
| 分屏/自由窗/多 APPLICATION window | 画像通过并明确记录 | `unsupported_multi_window` |
| 浮动 IME/硬键盘并存 | 画像通过并明确记录 | `unsupported_input_mode` |
| 手机 | intake 拒绝 `not_tablet` | 手机历史流程已暂停 |
| 多台/unauthorized/offline | setup fail | 不产生真机能力结论 |

## 7. 不变量

- T0 永远零输入、零发送；命令 allowlist 由离线测试扫描。
- “画像通过”不等于“危险动作支持”；manifest 必须分开记录 intake 与 P0 capability。
- 未识别的 rotation/window mode/insets/input mode 不得猜成默认值。
- 手机和平板 run 分开编号与归因；历史手机 C 不复用。
- 任何放宽横屏/多栏的改动必须先有错 pane 反例，再上平板真机。

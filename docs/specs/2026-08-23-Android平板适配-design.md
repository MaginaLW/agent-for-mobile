# Android 平板适配设计

- 日期：2026-08-23
- 状态：方向已批准；PA2553 原生横屏应用多窗优先。当前进展与卡点见 [STATUS](../../STATUS.md)；C1b 现行运行见 [C1b 规程](../runbooks/T-L1-tablet-c1b.md)。
- 决策人：Magina（用户）
- 本文只写现行设计与决定；旧主机链历史见 git `7a3b069` 及 `docs/runs/` 的 C1b 记录。

## 1. 决定与目标

用户决定（按日期）：

- **2026-08-23**：手机真机 C 道暂停，后续真机任务统一使用 Android 平板。手机既有 run、ledger、证据和
  `0/4` 结论原样保留，不改写为平板结果。
- **2026-08-24**：vivo 平板日常以横屏使用，**PA2553 / Android 16 / 横屏**成为当前设计与验收基线；竖屏兼容
  后置。不修改手机历史策略，不删除手机 `h>w`、比例、顶部中心标题或底栏安全门；横屏走显式、默认关闭的
  tablet-landscape 路径。
- **2026-08-25**：**项目尽量适配设备，不通过关闭设备功能换通过**。产品设计与最终验收以 vivo“应用多窗”
  保持日常开启的横屏形态为基线；项目必须识别同一微信的双 OS window，并把目标 conversation pane、标题、
  消息区和输入区绑定到同一 window/pane identity。关闭应用多窗不是准备、部署前置或通过条件，只可在用户另行
  授权时作为 `control_only` 对照实验，结果不计入产品验收。官方说明：[应用多窗说明](https://bbs.vivo.com.cn/newbbs/thread/32933113)、
  [vivo Pad“一个 App，双窗口”](https://www.vivo.com.cn/vivo/vivopad)。
- **2026-10-09**：退役 C1b 主机证据链，C1b 改用简单只读 runner `scripts/run-tablet-c1b.ps1`，见
  [C1b 规程](../runbooks/T-L1-tablet-c1b.md)。

目标是让每次安全判断绑定**当前 App 窗口和目标会话 pane**，而非把 `phone` 换成 `tablet`。Android 官方
也以可用 App 窗口而非设备型号为适配基准：
[window size classes](https://developer.android.com/develop/ui/views/layout/use-window-size-classes)、
[large-screen orientation/resizability](https://developer.android.com/develop/adaptive-apps/guides/app-orientation-aspect-ratio-resizability)。

## 2. 首轮边界

T0-L v5 的 readiness 只接受：

- Android 平板（`smallestWidthDp >= 600`）；
- 横屏、全屏、单个 owner-matching BASE_APPLICATION 窗口，边界精确覆盖当前显示；
- 无 wm size/density override；font scale 未机械证明，不属于 T0-L accepted 结论；
- IME 状态可解析且非浮动；实体键盘、safe insets、cutout 与多 display 留给 T-L1/真机 producer；
- 微信在前台；内部单栏/双栏不由 T0-L 猜测，交给 T-L1 只读探针。

这是保守的旧单窗入口，不定义目标设备形态；readiness accepted 只表示可继续做横屏只读 pane 测量，
不表示危险动作支持，任何多窗/PiP/浮动 IME/外接显示形态都不能被 T0-L 放行为 P0。Android 16 大屏会忽略部分 orientation/resizable 限制，不能靠 manifest 锁方向代替真实适配。

日常应用多窗形态下 T0-L 的正式结论是 `intake_status=accepted`（已分类为 tablet）、
`readiness_status=blocked`、`p0_capability=unsupported`，任何状态、报告和路由不得简称“T0 通过”。
T-L1 可凭独立 `probe_only` 资格从该 blocked evidence 启动纯感知诊断，但不得回写 T0，不得产生
readiness/P0/execution grant；路由保持 `settings_mutation_allowed=false`、`device_action_allowed=false`。

## 3. 为什么不能直接跑现有四腿

1. 盲点探针要求 `h>w`、手机宽高比，按整屏固定像素定位；双栏时可能落在分栏线。
2. IME-only 身份只证明焦点属于微信包，不能证明属于右侧目标会话而不是左侧搜索。
3. snapshot/a11y/OCR 可能遍历整屏或多个窗口，多窗内容混入 ref 与语义面。
4. runner 的发送后验主要按 Y 轴划消息区；同 Y 不同 pane 的 marker 可能被误当消息证据。
5. 确认 overlay 全屏宽、固定像素 padding、无最大高度/滚动，横屏未验。

现有失败大多是安全的 fail-closed；删除方向或比例判断会把“明确拒绝”变成“可能点错”，禁止。

## 4. 分批路线

### T0-L · 横屏只读入场

受控脚本只执行 ADB 只读命令，生成脱敏 `tablet-profile.json`（画像字段见
[平板知识册](../knowledge/android/tablet.md)）；解析不出为 `unknown`，不以默认值冒充通过。T0-L 不安装、
不启动 App、不注入输入、不改设置；serial/fingerprint/raw dumpsys 不持久化。`p0_capability` 永远 `unsupported`，固定原因至少含
`wechat_layout_unverified` 与 `tablet_landscape_p0_unimplemented`。profile 只用于验收归因，不参与 gateway 放行。

### T-L1 · 微信原生横屏双 window/pane 只读探针

在 fresh T0 evidence 获得 `probe_only` 资格后做纯感知探针：不点击、不输入、不切 IME、不启动 App，也不
修改手机/P0 共用的单窗口选择器。每轮固定恰好两帧（`c1`、等待至少 900 ms、`c2`，不补拍）；增加帧数或
提升结论须另开合同。分两段：

- **C1a**（v2 合同，已冻结）：已在 PA2553 应用多窗形态建立可信只读来源，观察到两个稳定微信 application
  window，但七项真实诊断 blocker 使 T-L1 保持 blocked。
- **C1b**（[c1b-v1 合同](../contracts/tablet-layout-observation-c1b-v1.md)）：pure-a11y 拓扑诊断。

C1b 设计要求：

1. 枚举全部 interactive application windows；T0/WMS 的 `wN` 与 a11y 的 run-local `awN` 分属不同身份命名
   空间，不得凭编号或 bounds 宣称相等。
2. 第一批只要求恰好两个稳定、root owner 均为微信的 application window，验证 inventory、root→window exact
   binding 与一窗一 projection pane（只是几何投影，`semantic_role=unknown`）；另一 App、额外 display、identity
   替换、截断或 root 冲突均 blocked。
3. `window.root` 非空不等于语义树可用。零几何、`childCount=0`、无正几何可见节点的 root 记为 opaque；
   不得用 left/right、宽窄、layer、active/focused、包名、scrollable 或 editable 猜 navigation/conversation。
   window-level title 匹配与 `window_only` focus 只是诊断事实，不能选择目标会话。
4. 只有后续新合同取得独立语义证据后，才可找到唯一目标会话 pane，证明「文件传输助手」是目标
   window/pane 的 toolbar/title 而非另一窗同名会话行，再在同一 pane 内分出 toolbar、message viewport 与
   input region。若 pure-a11y 仍 opaque，下一步评审 pane/window-bound 视觉通道，不关闭应用多窗，也不回退
   整屏坐标猜测。
5. C1b 最多观察到微信 window ownership、root projection、双 application-window topology、hidden IME；
   navigation/conversation/target/region、`layout_accepted`、`wechat_layout_verified`、`editor_action_ready`、
   P0 与 execution 固定 false/unsupported。
6. 只保存 run-local label、window type code、bounds、计数、match state 与 reason；不持久化 raw identity、
   标题明文、聊天内容或稳定内容 hash，不截图/OCR。任一歧义、漂移、跨 pane、预算耗尽都 fail-closed。

### T-L2 · 横屏 P0

在 T0-L 与 T-L1 通过后，依次完成：

1. 所有视觉证据绑定统一 `DisplayGeometry` 与 `layout_epoch`（display、App window、insets、pane 同代）。
2. precheck 返回唯一 app window/pane/input rect；首版横屏策略禁用 IME-only 与整屏坐标兜底。
3. 标题、输入栏、确认意图、Enter 前 fresh capture、发送后验与 teardown 全部绑定同一 pane。
4. 发送后验与四腿带外 OCR 同时校验 X/Y、window/pane，先裁目标 pane 再聚类 OCR 行；inconclusive 不得绿。
5. 确认卡整卡和两个按钮必须位于横屏 safe area；布局变化立即 `E_STALE_REF`。
6. 完整离线矩阵和独审通过后，才钉 SHA 跑 Allow→Stale→Deny→Reentry。

### T-L3 · 横屏确认 surface 与其它多 App 窗口形态（后置）

确认 overlay 改为限宽高、正文可滚动、按钮固定可见，并验证 safe area、大字体、显示缩放与 cutout。其它
App 分屏/自由窗须元素具备 window identity、OCR 先裁 window、后验绑定 pane 后才开放。

### T-P · 竖屏兼容（后置）

横屏闭环后单独验证 PA2553 竖屏的单/双栏、标题、输入栏和确认 surface。平板竖屏不能借用手机比例门
冒充验收，手机 portrait 历史策略也不自动继承平板结果。

## 5. 验收顺序

1. **A0/C0**：T0-L v5 只读入场，已在 PA2553 正确输出 readiness blocked / P0 unsupported。
2. **A1 归档**：T-L1 v1 旧单窗合成门只作 fail-closed 归档，不用于 PA2553 日常形态验收。
3. **A2/C1a 只读诊断**：v2 合同与 C1a 已完成可信只读取证；结果固定不 accepted，T-L1/P0/execution 未通过。
4. **A3/C1b 只读契约**：v2 合同原样冻结，另建 C1b pure-a11y 合同、producer、对抗 fixture 与 validator；
   按 C1b 规程真机运行。即使 topology 成立，T-L1 语义布局与 P0 仍未通过。
5. **A4**：实现 T-L2 pane-aware 策略；全量 gate 与独审通过后固定精确 SHA。
6. **C2 危险腿**：唯一 build/install/runner；任何一腿失败整轮冻结。通过后才按协议合 main。

## 6. T0-L 验收矩阵

| 场景 | intake | P0 能力 |
|---|---|---|
| PA2553 横屏、全屏、单 OS 窗口、微信前台 | readiness accepted | `unsupported`：待 T-L1 + T-L2 |
| PA2553 日常横屏、同一微信两个 `multi_landscape` OS 窗口 | intake accepted、readiness blocked；仅可路由 `probe_only` | `unsupported`：待 T-L1 双 window/pane 证据 |
| 平板竖屏 | 画像通过但 readiness blocked | `unsupported_portrait_compat_pending` |
| 横屏 4:3 / letterbox | 画像通过并明确记录 | `unsupported_geometry` |
| 其它 App 分屏/自由窗/额外 APPLICATION window | 画像通过并明确记录 | `unsupported_multi_window` |
| 浮动 IME | 画像通过并阻断 readiness | `unsupported_input_mode` |
| font scale / 实体键盘 / safe insets / cutout / 多 display | T0-L 不冒充已证明 | 留给 T-L1/真机 producer，未知即不进危险阶段 |
| 手机 | intake 拒绝 `not_tablet` | 手机历史流程已暂停 |
| 多台/unauthorized/offline | setup fail | 不产生真机能力结论 |

## 7. 不变量

- T0-L 永远零输入、零发送；命令 allowlist 由离线测试扫描。
- “画像通过”不等于“危险动作支持”；manifest 分开记录 intake 与 P0 capability。
- 未识别的 rotation/window mode/insets/input mode 不得猜成默认值。
- 手机和平板 run 分开编号与归因；历史手机 C 不复用。
- 手机 `h>w`、手机比例和手机式标题/底栏门永远不因横屏平板而放宽；tablet-landscape 是独立路径。
- vivo 应用多窗保持日常开启；关闭功能只能是用户另行授权并标注 `control_only` 的对照实验，结果不得计入产品验收。
- T0 blocked evidence 只可产生 `probe_only` 资格，不得改写原 assessment 或授予设备动作/P0。
- 新 TabletLayoutProbe 隔离枚举多 window；禁止放宽手机共用 `applicationWindow()`/P0 validator。
- T-L1 必须先有左栏同名标题、错 pane 同 Y marker、pane 漂移等反例，再进入横屏危险实现。
- 宿主传输与采集顺序修复不得掩盖帧内漂移或任何 window/pane 诊断 blocker；设备与 ADB 坑见
  [平板知识册](../knowledge/android/tablet.md)。

## 8. 真机准入

任何平板真机运行前须同时满足：

- 对应只读入口的离线测试全绿；未知、歧义、多设备/offline、横竖屏与多窗漂移等路径均 fail-closed；
- 输出恒为 P0 unsupported、无设备动作授权；只读阶段不输入、不截图、不改设置、不启动目标 App；
- 现场就位并取得用户对本次运行的开跑令，条件以 [backlog](../backlog.md) 与 [C1b 规程](../runbooks/T-L1-tablet-c1b.md) 为准；
- 一次调用只采一次、不自动重试；失败回 A 修复后以新 run_id 重跑，不复用旧授权。危险腿（C2）任一腿失败整轮冻结。

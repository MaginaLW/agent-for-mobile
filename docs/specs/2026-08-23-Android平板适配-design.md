# Android 平板适配设计

- 日期：2026-08-23
- 状态：方向已批准；PA2553 原生横屏应用多窗优先；T0-L v5 已真机正确 fail-closed；T-L1 v2/C1a 历史与证据冻结，fixed SHA `4b96f89a6622eb8b5fe04bd249571c7d77936b25` 已完成唯一 C1a trusted origin/read-only 取证但 diagnostic blocked；A3/C1b pure-a11y 合同、producer、受控 runner 与 synthetic gates 已形成候选，真实受控构建、最终独审与平板取证尚未执行，待提交并固定新 HEAD 后取得单独授权
- 决策人：Magina（用户）

## 1. 决定与目标

自 2026-08-23 起，手机真机 C 道暂停，后续真机任务统一使用 Android 平板。手机既有 run、ledger、
证据和 `0/4` 结论原样保留，不改写为平板结果。

2026-08-24 用户进一步确认 vivo 平板日常以横屏使用，因此 **PA2553 / Android 16 / 横屏**成为当前
设计与验收基线；竖屏兼容后置。这个决定不修改手机历史策略，也不允许删除手机现有 `h>w`、比例、
顶部中心标题或底栏安全门。横屏走显式、默认关闭的 tablet-landscape 证据路径。

2026-08-25 用户进一步拍板：**项目尽量适配设备，不通过关闭设备功能换通过**。PA2553 的产品设计与
最终验收以 vivo“应用多窗”保持日常开启的横屏形态为基线；项目必须识别同一微信的双 OS window，
并把目标 conversation pane、标题、消息区和输入区绑定到同一 window/pane identity。关闭应用多窗不属于
正常准备、部署前置或通过条件；只有用户另行明确授权时，才可作为标注 `control_only` 的对照实验，
且该结果不得计入产品验收。vivo 官方对应用多窗的说明是横屏并排展示同一 App 不同层级界面：
[应用多窗说明](https://bbs.vivo.com.cn/newbbs/thread/32933113)、
[vivo Pad“一个 App，双窗口”](https://www.vivo.com.cn/vivo/vivopad)。

目标不是把 `phone` 文案替换成 `tablet`，而是让每次安全判断绑定**当前 App 窗口和目标会话 pane**。
Android 官方也把可用 App 窗口而非设备型号作为适配基准，并要求考虑运行时旋转、分屏和窗口尺寸变化：
[window size classes](https://developer.android.com/develop/ui/views/layout/use-window-size-classes)、
[large-screen orientation/resizability](https://developer.android.com/develop/adaptive-apps/guides/app-orientation-aspect-ratio-resizability)。

## 2. 首轮边界

T0-L v5 的首轮 readiness 仍只接受：

- Android 平板（`smallestWidthDp >= 600`）；
- 横屏、全屏、单个 owner-matching BASE_APPLICATION 窗口，边界精确覆盖当前显示；
- 无 wm size/density override；font scale 尚未机械证明，不属于 T0-L accepted 结论；
- IME 状态可解析且非浮动；实体键盘、safe insets、cutout 与多 display 留给 T-L1/真机 producer；
- 微信在前台；内部单栏/双栏不由 T0-L 猜测，交给下一阶段只读探针。

这是一条保守的旧单窗入口，不再定义目标设备形态。T0-L readiness accepted 只表示“可以继续做横屏只读
pane 测量”，不表示危险动作支持。微信内部 pane、
分屏/自由窗、桌面窗口、PiP、浮动 IME 与外接显示器均不能被 T0-L 放行为 P0。Android 16 大屏会忽略
部分 orientation/resizable 限制，所以不能靠 manifest 锁方向代替真实适配。

T0-L r2/r3 的 `intake_status=accepted` 仅表示设备已分类为 tablet；正式结论仍是
`readiness_status=blocked`、`p0_capability=unsupported`，任何状态、报告和路由不得简称为“T0 通过”。
T-L1 v2 可以通过独立 `probe_only` 资格从该 blocked evidence 启动纯感知诊断，但不得回写 T0，不得产生
readiness/P0/execution grant；路由必须保持 `settings_mutation_allowed=false`、`device_action_allowed=false`。

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

### T-L1 · 微信原生横屏双 window/pane 只读探针

在可信 fresh T0 evidence 获得 `probe_only` 资格后，用隔离的 R 级工具做纯感知探针，不点击、
不输入、不切 IME、不启动 App，也不修改手机/P0 共用的单窗口选择器。本轮 C1a 固定恰好两帧
（一次 `c1`、宿主等待至少 900 ms、一次 `c2`，不补拍）；未来 C1b 若要增加帧数或提升结论，必须另开合同：

1. 枚举全部 interactive application windows；T0/WMS 的 `wN` 与 a11y 的 run-local `awN` 分属不同身份
   命名空间，不得凭编号或 bounds 宣称相等。
2. C1b 第一批只要求恰好两个稳定、root owner 均为微信的 application window，并验证 window inventory、
   root→window exact binding 与一窗一 projection pane；另一 App、额外 display、identity 替换、截断或 root
   冲突均 blocked。这里的 projection pane 只表示 OS window/root 的几何投影，`semantic_role` 固定为
   `unknown`，不等于 navigation/conversation。
3. `window.root` 非空不等于页面语义树可用。若 root 为零几何、`childCount=0`、没有正几何可见节点，则
   必须记录为完整读取到的 opaque subtree；不得用 left/right、宽窄、layer、active/focused、包名、
   scrollable 或 editable 猜 navigation/conversation。window-level title exact match 与 `window_only` focus
   也只能作为诊断事实，不能选择目标会话。
4. 只有后续新合同取得独立语义证据后，才可找到唯一目标会话 pane，并证明「文件传输助手」是目标
   window/pane 的 toolbar/title、不是另一窗同名会话行；随后才能在同一 target window + pane 内机械分出
   toolbar、message viewport 与 input region。若 pure-a11y 仍 opaque，下一步应评审 pane/window-bound
   视觉通道，而不是关闭 vivo“应用多窗”或回退整屏坐标猜测。
5. C1a observation 固定 `runtime_evidence=false`。未来 C1b fresh fixed-SHA runner/sidecar 最多可把可信来源、
   微信 window ownership、root projection、双 application-window topology、hidden IME 等机械结论置真；
   navigation/conversation/target/region、`layout_accepted`、`wechat_layout_verified`、
   `editor_action_ready`、P0 与 execution 仍固定 false/unsupported。
6. 只保存 run-local label、平台 window type code、bounds、计数、固定 match state 与 reason；不持久化 raw
   window/root/node identity、window/node title 明文、聊天内容或稳定内容 hash，也不截图/OCR。任一歧义、
   漂移、跨 pane、预算耗尽或证据来源不可信都 fail-closed。

当前 v2 无机 schema/validator/gate 已以 main `589421a` 冻结，fixture 最多得到
`fixture_contract_valid=true`，而 `runtime_evidence`、`wechat_layout_verified`、P0 与 execution grant 永远
为 false。隔离只读 producer 基线 `b5769df7baba075fda47aec17f249a5caa124b92` 未接 ToolRegistry/MCP、
未合 main；C1a 已从当前 main 干净移植，机械绑定 producer/T0 六个基线 blob，并完成独立受控
runner/attest、release-absence、无机门与独审。首个 fixed SHA `2635fc9...` 的 pre-C 全门只说明当时离线候选
可进入 C，不等于真机 origin 或 T-L1 通过。

2026-08-26 的第一个明确授权轮在安装阶段超时，`run_id=none`、无 c1/c2、无 evidence；按合同没有自动
重试。用户另行明确授权后，第二轮唯一 run `tl1-c1a-20260826t114535z-63667b68ce4f` 只采 c1/c2 各一次，
间隔 1982.304 ms、无补拍。trusted-runtime validation 失败且没有 success sidecar，origin 未成立；
runtime/layout/微信布局/editor/P0/execution 均保持 false/unsupported。该失败不否定纯只读取证边界，也不授予
任何能力；它只把 transport/order 两个离线缺口和真实设备诊断 blocker 带回 A。

两个修复边界是：

1. Windows 普通 `adb shell` stdin 把 T0 的 747 个 CRLF 归一为 LF，artifact hash 因而从
   `43d9529ce10dca04c4bc60528d66376844f23edf0ebea9b63f0de04e8ff48fed` 变成 provider 所见的
   `f9d548...`。T0 write 改为 `adb exec-in content write` 的 binary stdin，并向其传 raw canonical URI；
   只读 content endpoint 继续使用 `adb shell` 与远端 POSIX 引号。
2. 静态页没有新 a11y event，两帧 raw revision 合法保持 15/15，却被跨帧 strict-increase 误判为
   `capture_order_invalid`。仅在 debug-only C1a adapter 使用可逆
   `logical revision = raw event revision + capture ordinal`；capture token 可反算 raw，帧内 event 漂移、
   raw 跨帧下降、未知 token 与溢出仍 fail closed。六个 producer/T0 baseline blob 不改。

以上修复不得删除 `focus_fallback_insufficient`、`focus_target_conflict`、`node_binding_invalid`、
`region_candidate_missing`、`target_title_not_unique`、`target_window_pane_missing`、
`window_pane_bijection_invalid` 等真实诊断 blocker。即使下一轮可信 origin 成立，这些 blocker 仍使当前布局
保持 diagnostic blocked；C1a 也始终不提升 runtime/layout/P0/execution。A 修复的标准全门已通过：C1a
15/15、coverage 46/46、self 3/3，Debug 377/377、Release 261/261、dispatch 28/28、runner 82/82、
T-L1 24/24，assembleDebug/release absence/凭据扫描全绿；独立终审 P0/P1=0。vivo“应用多窗”在失败轮
保持开启，设备设置未改。

修复后的 fixed SHA `4b96f89a6622eb8b5fe04bd249571c7d77936b25` 随后完成唯一 C1a run
`tl1-c1a-20260826t125127z-354a7b4b0ed5`，runner exit 0。success sidecar 证明 origin binding、只读入口与
schema 有效，cleanup=`not_required`；fresh APK local/pre/post base SHA-256 全部等于
`0f2e5922e5f4c12b03b74fe06b7e0e40aa870ec376eca2cf06a4984ac2e4b288`。T0 profile/upstream
同为 23,865 bytes、747 个 CRLF、无 bare LF/CR，且 SHA-256 同为
`6f5b1539d3d09bf77e26dc2ba5d700d11857c3edac84eef33fee03df4a81c316`，机械证明 `adb exec-in`
的 binary stdin 修复在真机保持了原始 bytes。

c1/c2 各一次，capture ID 为 `capture-c1`/`capture-c2`，delta 2023.223 ms；host wait 905 ms、总 span
3140 ms、recapture=0。两帧横屏 2800×1968，两个稳定 `com.tencent.mm` application window 分别覆盖
`[0,0,985,1968]` 与 `[989,0,2800,1968]`。用户现场保持 vivo“应用多窗”；机械证据是 T0
`multi_landscape` 与这两个 a11y application window，不构成系统开关值 attest。run 未修改 settings、未启动
目标 App、未截图；这证明可信只读诊断可在原生双窗形态下完成，不等于布局已经适配。

可信来源不等于布局通过。validation 保留 `window_pane_bijection_invalid`、`target_window_pane_missing`、
`node_binding_invalid`、`target_title_not_unique`、`region_candidate_missing`、
`focus_fallback_insufficient`、`focus_target_conflict` 七项真实 reason，`diagnostic_observed=false`、
`diagnostic_status=blocked`；
runtime/layout/微信/editor/execution 仍为 false，P0 unsupported。因此 C1a 只读取证成功，但 T-L1 未通过，
app 不合 main，也不能进入 T-L2。

A3/C1b 已按上述真实形态另开 `tablet-layout-observation/c1b-v1`，没有改写 v2/C1a。第一批只读 producer
闭合保存 platform window type、root handle/binding、subtree completeness、run-local projection pane、direct focus
与 IME inventory；任何 display/type/layer/touchable/active/focused 结构读取失败都不得以默认值冒充稳定窗口，
opaque subtree、截断 window inventory 或未知 window type 也不能提升 focus/hidden IME。observation gate 49/49、coverage
89/89、self 5/5、host-only 26/26 已通过；build-env 23/23、artifact 32/32、ADB provenance 6/6、private
ADB 16/16、T0 sidecar 7/7、aapt2 15/15、readonly 67/67。五场景 host E2E 最终稳定复跑通过：fake ADB
219 = 211 valid + 8 rejected；valid 为 private server start/status/kill 6/6/4 + device 195，T0 4 是 device
子集，另观测 server exit 6。runner process 7、fake Gradle 6、fake signer 10、repository inputs 41，real
ADB/JDK/Gradle 0；direct client Job active limit 1、T0 四层 Job 链 limit 4、official-style auto-start
attempts 2、escaped child/listener/side-effect 0、正常 cleanup 无残留。这些均是无机证据，
不代表已完成真实受控构建、最终独审或平板取证。

C1b 受控构建把固定 HEAD 的 implementation/build inputs 收敛为 41 个普通文件（新增 private ADB server
module），并以动态重算的
`catalog_sha256` 绑定 exact bytes；专用 probe 同轮构建 Debug 与 Release，并以 artifact proof 绑定 APK、
merged manifest、DEX、依赖闭包和受控 aapt2 解析。宿主 guard 冻结 Oracle JDK、Gradle、ProgramFiles/Git
完整安装树（9,576 paths、9,489 identities、85 个内部 hardlink groups、6 个关键 hash）与三包 isolated
Android SDK，使用 fresh user/project/Kotlin cache、strict dependency verification；构建允许联网，不能写成
offline dependency build。Git 调用只接收 exact 15-key environment + `ClearEnvironment`；Gradle、签名器、ADB、
aapt2 与 T0 子进程接收各自受控 child environment + `ClearEnvironment`。全局设备 lease 从 Windows KnownFolder
导出，不信任 `LOCALAPPDATA`。全部设备命令
使用 `49152..65535` 随机 loopback private `server nodaemon`、显式 `-H/-P` 与 `ADB_SERVER_SOCKET`，绑定 listener
owner PID、server-status executable、job membership、cleanup 与 port rebind，永不使用 default 5037。success
sidecar 只在 private server、build/artifact guards 与 device lease 全部 cleanup 成功后原子发布。这里的环境
主张只覆盖 guard 建立后的文件系统与环境
完整性，不覆盖同用户进程内存注入、预先持有的可写 handle/mapping、ACL/ownership takeover，或对刻意保留
可写的 fresh build state 的同用户并发篡改。

本轮尚未访问平板，C1a 授权已消费且不能复用。下一步是提交并固定完整新 HEAD，再针对该 HEAD 单独取得
一次 C1b build/install/只读采集授权。

### T-L2 · 横屏 P0

在 T0-L 与 T-L1 通过后，依次完成：

1. 所有视觉证据绑定统一 `DisplayGeometry` 与 `layout_epoch`（display、App window、insets、pane 同代）。
2. precheck 返回唯一 app window/pane/input rect；首版横屏策略禁用 IME-only 与整屏坐标兜底。
3. 标题、输入栏、确认意图、Enter 前 fresh capture、发送后验与 teardown 全部绑定同一 pane。
4. 发送后验与四腿带外 OCR 同时校验 X/Y、window/pane，先裁目标 pane 再聚类 OCR 行；inconclusive 不得绿。
5. 确认卡整卡和两个按钮必须位于横屏 safe area；布局变化立即 `E_STALE_REF`。
6. 完整离线矩阵和独审通过后，才钉 SHA 跑 Allow→Stale→Deny→Reentry。

### T-L3 · 横屏确认 surface 与其它多 App 窗口形态

确认 overlay 改为有最大宽/高、正文可滚动、按钮固定可见，并独立验证横屏 safe area、大字体、显示缩放
与 cutout。其它 App 分屏/自由窗只有在元素具备 window identity、OCR 先裁 App window、后验绑定 pane 后再开放；
vivo 同 App 原生应用多窗已是 T-L1/T-L2 主线，不放到本阶段后置。

### T-P · 竖屏兼容

横屏闭环后单独验证 PA2553 竖屏的单/双栏、标题、输入栏和确认 surface。平板竖屏不能借用手机比例门
冒充验收，手机 portrait 历史策略也不自动继承平板结果。

## 5. 验收顺序

1. **A0/C0**：T0-L v5 fake-adb 42/42、coverage 41/41；源 SHA `1350108...` 与 clean port
   `4ca32b1...` 均在 PA2553 上 exit 0 并正确输出 readiness blocked/P0 unsupported。
2. **A1 归档**：T-L1 v1 `f5c8e15b...` 的 gate 11/11、契约 41/41、coverage 25/25 保留为安全
   fail-closed 的旧单窗合成门；真实 producer unavailable，不能拿去做 PA2553 日常形态真机验收。
3. **A2/C1a 只读诊断**：v2 diagnostic-only observation schema、可信 T0→`probe_only` envelope 与隔离的
   多 a11y window producer 已离线冻结；首个 fixed SHA 的失败 run 原样保留。A 道修复 binary T0 transport
   与可逆 capture logical revision 后，`4b96f89...` 的唯一真机 run 已建立 origin/read-only、证明横屏双微信
   window 形态，同时如实保留七项 diagnostic blocker。A2/C1a 的来源与只读取证完成，但结果固定不 accepted，
   T-L1/P0/execution 未通过。
4. **A3/C1b 只读契约**：保持 v2 contract/schema/validator/fixture 原样冻结，另建 C1b pure-a11y
   diagnostic contract、producer、对抗 fixture、validator 与单次受控 runner。41-file closure、专用 probe 的
   Debug/Release artifact proof 和 host synthetic gates 已闭合；真实受控构建、最终独审与平板取证仍未执行。
   第一批只验 window/root projection 与拓扑，不把 opaque root 解释成 navigation/conversation；即使可信来源和
   topology 成立，T-L1 语义布局与 P0 仍未通过。固定新 HEAD 后必须另取一次 C1b build/install/只读授权。
5. **A4**：实现 T-L2 pane-aware 策略；全量 gate 与独审通过后固定精确 SHA。
6. **C2 危险腿**：唯一 build/install/runner；任何一腿失败整轮冻结。通过后才按协议合 main。

## 6. T0-L 验收矩阵

| 场景 | intake | P0 能力 |
|---|---|---|
| PA2553 横屏、全屏、单 OS 窗口、微信前台 | readiness accepted | `unsupported`：待 T-L1 + T-L2 |
| PA2553 日常横屏、同一微信两个 `multi_landscape` OS 窗口 | intake accepted、readiness blocked；仅可路由 `probe_only` | `unsupported`：待 T-L1 v2 双 window/pane 证据 |
| 平板竖屏 | 画像通过但 readiness blocked | `unsupported_portrait_compat_pending` |
| 横屏 4:3 / letterbox | 画像通过并明确记录 | `unsupported_geometry` |
| 其它 App 分屏/自由窗/额外 APPLICATION window | 画像通过并明确记录 | `unsupported_multi_window` |
| 浮动 IME | 画像通过并阻断 readiness | `unsupported_input_mode` |
| font scale / 实体键盘 / safe insets / cutout / 多 display | T0-L 不冒充已证明 | 留给 T-L1/真机 producer，未知即不进危险阶段 |
| 手机 | intake 拒绝 `not_tablet` | 手机历史流程已暂停 |
| 多台/unauthorized/offline | setup fail | 不产生真机能力结论 |

## 7. 不变量

- T0-L 永远零输入、零发送；命令 allowlist 由离线测试扫描。
- “画像通过”不等于“危险动作支持”；manifest 必须分开记录 intake 与 P0 capability。
- 未识别的 rotation/window mode/insets/input mode 不得猜成默认值。
- 手机和平板 run 分开编号与归因；历史手机 C 不复用。
- 手机 `h>w`、手机比例和手机式标题/底栏门永远不因横屏平板而放宽；tablet-landscape 是独立路径。
- vivo 应用多窗保持日常开启；关闭功能只能是用户另行授权并标注 `control_only` 的对照实验，结果不得计入产品验收。
- T0 blocked evidence 只可产生 `probe_only` 资格，不得改写原 assessment 或授予设备动作/P0。
- 新 TabletLayoutProbe 隔离枚举多 window；禁止放宽手机共用 `applicationWindow()`/P0 validator。
- T-L1 必须先有左栏同名标题、错 pane 同 Y marker、pane 漂移等反例，再进入横屏危险实现。
- Windows 向 debug-only provider 写 fresh T0 原始 bytes 必须走 `adb exec-in` binary stdin 与 raw canonical URI；
  普通 `adb shell` stdin 不可作为 byte-exact 通道。
- C1a capture logical revision 必须可由 token 还原 raw event revision；它只证明采集顺序，不能掩盖帧内
  event 漂移、raw 下降或任何 window/pane 诊断 blocker。

## 8. 无机 → C0 准入清单

只有以下条件同时满足，主会话才可通知连接平板：

- 钉精确 clean-port/content-attested SHA，worktree clean，producer/T0 六个基线 blob、`git diff --check`、AST 与凭据扫描通过；
- T0-L 无设备 gate 全绿并生成机器报告；0/offline/no-permissions/mixed device、ADB 路径/退出/超时、
  解析 unknown/ambiguous、横竖屏、多窗/PiP/letterbox、override/rotation 漂移都有必需 case ID；
- T0 schema、退出码、失败不落 artifact、命令 allowlist、路径/reparse/collision/privacy 和
  `p0_capability=unsupported` 均有正反例；
- T-L1 schema 与纯 validator 的 fixture/runtime 隔离、重复 key、时间重放、退化几何、错 pane、epoch 漂移、
  window 歧义、IME-only、路径/数值异常全部 fail-closed；真实 producer 保持 unavailable；
- 主会话独立复跑 T0-L 与 T-L1 gate，并记录 SHA、用例数及作废候选；
- C0 新开只读任务，只跑 T0-L，不安装、不截图、不连接 gateway。失败即冻结回 A。

当前 T0-L v5 clean port `4ca32b1...` 已满足 42/42、coverage 41/41 并完成只读 C0；T-L1 v1
`f5c8e15b...` 的 gate 11/11、41/41 cases、25/25 coverage 只作为旧单窗 fail-closed 归档。
首版 `c0f2e65` 因 synthetic provenance、freshness 与退化几何 C 级缺口作废，不得恢复或入队。T-L1 v2
contract/gate `589421a` 已 5/5、24/24、coverage 24/24；producer 基线 `b5769df...` 专项 33/33。
C1a clean-port 候选已完成 debug-only provider、受控 runner/attest 与 release-absence：C1a 15/15、
coverage 45/45、self 3/3，Debug 373/373、Release 261/261，标准全门通过，跨层独审 P0/P1=0。
这些是失败 fixed SHA `2635fc9...` 的 pre-C 历史计数。该 SHA 的真机 C1a 已冻结失败；A 修复的
标准全门为 C1a 15/15、coverage 46/46、self 3/3，Debug 377/377、Release 261/261、dispatch 28/28、
runner 82/82、T-L1 24/24，assembleDebug/release absence/凭据扫描全绿，独立终审 P0/P1=0。fixed SHA
`4b96f89...` 已完成唯一 origin/read-only C1a；diagnostic 仍 blocked，runtime/layout/P0/execution 不放行。
C1b observation 49/49、coverage 89/89、self 5/5、host-only 26/26；build-env 23/23、artifact 32/32、ADB
provenance 6/6、private ADB 16/16、T0 sidecar 7/7、aapt2 15/15、readonly 67/67。五场景 host E2E
稳定复跑通过，fake ADB 219（211 valid + 8 rejected；server start/status/kill/exit 6/6/4/6、device 195/T0
4）、runner process 7、fake Gradle 6、fake signer 10、repository inputs 41、real ADB/JDK/Gradle 0；Job
limits 1/4、auto-start attempts 2、escaped effects 0、cleanup 无残留。41-file
implementation/build-input catalog 与专用 Debug/Release artifact proof 已纳入候选，但真实受控构建、最终独审
和平板取证仍未执行；下一步提交并固定 C1b 新 HEAD，再单独取得该 HEAD 的 build/install/只读授权。

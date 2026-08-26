# Android 平板适配设计

- 日期：2026-08-23
- 状态：方向已批准；PA2553 原生横屏应用多窗优先；T0-L v5 已真机正确 fail-closed；T-L1 v2 离线契约已合 main、隔离只读 producer 基线已冻结；失败 SHA `2635fc9f...` 原样冻结，修复 fixed SHA `4b96f89a6622eb8b5fe04bd249571c7d77936b25` 已完成唯一 C1a trusted origin/read-only 取证；diagnostic blocked，T-L1 未通过，转 A3/C1b
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
2. 原生基线要求恰好两个稳定、root owner 均为微信的 a11y window，并建立 navigation/conversation
   pane 与 window 的一一绑定；另一 App、额外 display、identity 替换或 root 冲突均 blocked。
3. 找到唯一目标会话 pane；「文件传输助手」必须是目标 window/pane toolbar/title，不能是另一窗同名会话行。
4. 在同一 target window + pane 内机械分出 toolbar、message viewport 与 input region；两帧 identity、
   window→pane 映射、几何与 layout epoch 必须稳定。
5. 本轮 C1a 无论 observation 形态如何都固定 `runtime_evidence=false`、`layout_accepted=false`、
   `editor_action_ready=false`、`p0_capability=unsupported`、`execution_grant=false`。只有后续 A3/C1b
   新合同才可讨论 focus absent、IME hidden 是否足以形成 `layout_accepted=true` 的纯感知结论；已知 focus
   指向别窗或 visible IME 未绑定 target editor 时仍须立即 blocked。
6. 只保存 run-local label、bounds/hash/reason，不持久化 raw window ID、聊天明文或全屏截图；OCR 只在
   已绑定 window/pane crop 内使用。任一歧义、漂移、跨 pane 或证据来源不可信都 fail-closed。

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
app 不合 main，也不能进入 T-L2；下一步是 A3/C1b 根据真实 window/root/node/region 形态冻结新合同。

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
4. **A3/C1b 只读契约**：根据 C1a 真实 window/root/node/region 形态冻结 v2 contract、对抗 fixture 与
   validator，再固定新 SHA 真机验收；即使 T-L1 accepted，P0 仍 unsupported。
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
`4b96f89...` 已完成唯一 origin/read-only C1a；diagnostic 仍 blocked，runtime/layout/P0/execution 不放行，
app 未合 main，下一步进入 A3/C1b。

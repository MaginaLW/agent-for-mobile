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

### 后续视觉合同的离线准备

本段仅整理后续 window/pane-bound 视觉合同的证据需求与反例，依据现有源码作静态设计；未采集新截图、
未运行 OCR、未操作设备，不代表 producer 已存在、通道可用或真机通过。C1b 合同、schema、fixture、
探针和生产接线均保持原状；实际视觉通道仍依赖真实观察、新合同评审及现有真机队列和开跑许可。

2026-11-01 已完成[正式视觉合同设计评审](2026-11-01-平板window-pane视觉证据合同-design.md)：本段保留需求来源，后续来源绑定、阶段失效、隐私与实施准入按该设计核定；实施与设备运行仍阻塞，不是机器合同已落地。

#### 现有证据边界

- 2026-11-01 [ccc8cce 单次 C1b](../runs/2026-11-01-C1b原字节传输候选验收.md)已取得原 T0 字节绑定及合同有效的两帧：各存两微信窗口，但 inventory 不完整；微信 root 完整却 opaque。该证据支持开展正式视觉合同评审，不提供会话 pane 身份，不放行 T-L1/T-L2；未采截图或运行 OCR，现有诊断合同与安全门不变。
- [C1b 合同](../contracts/tablet-layout-observation-c1b-v1.md)及其
  [closed schema](../contracts/tablet-layout-observation-c1b-v1.schema.json)只允许 pure-a11y 诊断。
  [C1bPaneObservation](../../app/gateway/src/main/java/dev/magina/gateway/tablet/c1b/TabletC1bModel.kt)
  的 pane 是一窗一 root projection，bounds 来自 window；`semantic_role=unknown`、`semantic_evidence=[]`。
  它既不是会话 pane，也不是未来截图裁剪身份的现成证明。
- [TabletC1bProbe](../../app/gateway/src/main/java/dev/magina/gateway/tablet/c1b/TabletC1bProbe.kt)
  区分 readable handle、exact root/window binding、完整 subtree 与读取失败。完整采到单个零几何 root、
  零 child、零正几何可见节点是 opaque；`read_error`、truncated、预算耗尽则是证据缺失，不能改写成
  “完整但 opaque”，也不能据此声称目标区域为空或无变化。
- window title 的 query-bound match、`window_only` 或 `editor_known` focus、包名、左右位置、layer、
  scrollable/editable 都不证明目标会话。T0/WMS `wN` 与 a11y `awN` 不按编号或相同 bounds 跨命名空间绑定。
  C1b 的 observed 值与 runner 来源记录也不授予语义布局、`layout_accepted`、P0 或 execution；相关结论
  继续为 false/unsupported，不把 `runtime_binding_inputs_match` 当成来源证明。

#### 证据到消费者的需求表

下表“需绑定”是待评审合同的字段语义要求，不是本轮新增字段或 schema。“来源未验证，不可放行”表示
尚无已验证的平板视觉产生者；模型描述、调用者自报 identity、合成样例或仅有同名字段都不能补上该来源。
所有缺项均停止相应消费，不允许靠整屏坐标、IME-only、默认 display/insets 或手机门槛兜底。

| 证据 | 现有/候选产生者与边界 | 需绑定的字段语义 | 最小消费者 | 拒绝或证据不足时的停止行为 |
|---|---|---|---|---|
| 采集身份与时钟 | C1b 有 run/capture id、`capture.token`、`captured_at` 与帧内 revision；未来图像/OCR capture 来源未验证，不可放行 | 采集进程/会话、固定候选与 run、每阶段唯一 capture token、采集起止时间、同一单调时钟域及动作先后关系；墙钟只作审计 | 来源绑定校验与各阶段 freshness 校验 | 来源不可验证、时钟域未知/回退、token 重用、图像与树时序无证明时停止；不能由时间字符串相等自证同帧 |
| display | C1b 有 `display_id/effective_size/orientation`；完整视觉 `DisplayGeometry` 来源未验证，不可放行 | 单一真实 display identity、旋转、物理/图像尺寸、缩放、insets/cutout；绑定本次 capture 与 geometry 版本 | 几何校验、裁剪与安全区域检查 | 多 display、身份未知、旋转/尺寸矛盾或缺变换信息时停止；不默认 display 0、不建后台屏绕过 |
| App window | C1b 有 run-local `awN`、root owner/exact binding、bounds/type；截图对该 window 的独立绑定来源未验证，不可放行 | 原生 window identity 的会话内连续性、owner、display、bounds、可见/遮挡状态、capture token 与 epoch；raw identity 不落盘 | 目标 window 唯一性与连续性校验 | 同包多窗不能择一猜测；window 替换、额外 window、遮挡未知或凭 bounds crosswalk 时停止 |
| pane | C1b `apN` 仅 root projection；会话 pane 语义及其连续性来源未验证，不可放行 | window-bound pane identity、pane bounds、语义来源、唯一性、capture token、geometry/epoch | 目标 pane 选择与区域归属校验 | unknown role、多 pane 候选、左右位置猜角色、身份断链或区域跨 pane 时停止 |
| crop 与坐标映射 | 当前 C1b 不截图/OCR；pane 裁图与 OCR 映射来源未验证，不可放行 | 原图 capture、display/window/pane、裁剪 rect、坐标原点/单位、缩放/旋转/偏移变换、裁剪覆盖率与有效范围 | 先裁 pane 的 OCR、X/Y 及 region containment 校验 | 裁剪退化/越界/不足、变换缺失或不一致、只校验 Y 时停止；不把整屏 OCR 行先聚类再按 Y 挑入 |
| layout epoch | C1b 有帧内 revision 一致性，不是跨阶段视觉 epoch；统一 epoch producer 来源未验证，不可放行 | `DisplayGeometry`、window/pane identity 与 bounds、insets、IME 布局版本统一生成的 `layout_epoch`，以及失效原因 | precheck、确认与动作前 stale gate、后验与 teardown | 任一布局变动或版本无法比较即销毁旧证据并停止该链；不由消费者自行补 epoch |
| 标题与目标会话 | C1b 只提供 native window title match；pane 内 toolbar/title 的可定位语义来源未验证，不可放行 | 目标 query 的授权匹配结果、title region、同 window/pane、capture token、geometry/epoch；区分 toolbar 与会话列表行 | 目标准备与每阶段目标复核 | 另一窗同名行、多个匹配、标题被裁/遮挡或只能看到文本时停止；不持久化聊天明文或内容 hash 来替代身份 |
| 消息 viewport 与后验 | C1b 无此 region；pane 内消息语义、标记位置与执行后效果来源未验证，不可放行 | message region、marker 的 X/Y、目标 pane、capture token/时间、动作前基线与动作后新采集的先后关系 | 发送后验及带外 OCR 判据 | marker 在另一 pane、输入框回显、仅整屏变化、只有发送前画面或不可观测时记证据不足并停止；不据此重发 |
| 输入区与焦点 | C1b focus 只是 inventory；现有 `FocusIdentity` 不含 pane，不能作为已实现的平板身份功能；pane-bound 输入产生者来源未验证，不可放行 | 唯一 input region、editor 与 window/pane 的独立绑定、IME 会话、来源、bounds、capture token、geometry/epoch | precheck、输入/读回、确认意图、Enter 前复核 | 左窗搜索框、只有包名/IME 会话、editor 与 pane 不一致或缺失时停止；不启用 IME-only 退路 |
| IME 与 safe-area | C1b 的 `ime_hidden_observed` 依赖完整 inventory；显示中 IME 的可靠布局、insets/cutout、安全区与确认卡可见性来源未验证，不可放行 | 同 capture 的 IME token、模式/几何、editor 归属、insets/cutout、确认卡整卡和双按钮可见可触达区域、geometry/epoch | 输入区与确认 surface 检查、布局失效 | unknown/浮动 IME、错 token、safe-area 未知、卡/按钮被遮挡时停止；C1b hidden 不能证明未来输入态安全 |
| TTL 与失效 | `FreshVisionCache`、`SnapshotRefRegistry`、`PreparedTargetEvidenceStore` 有局部机制；统一 pane-bound 生命周期来源未验证，不可放行 | 每阶段 capture 的单调采集时间、独立 TTL、会话/ref generation、证据关联、epoch 和主动失效事件 | freshness/ref 校验、prepared/input/approval 证据清理 | 过期、跨进程/跨代 ref、失效后再用、TTL 未定义或事件覆盖不足时停止并清除关联证据；不以缓存命中延长 TTL |

#### 阶段绑定与新鲜度

目标约束是在同一未失效链内持续证明**同一个 window/pane 及有效的 `DisplayGeometry/layout_epoch`**；
相关布局变化终止旧链，后续须在新布局重新准备，旧批准不可复活。这不是整个任务永远共用一个 epoch，
也不是共用同一截图或同一 ref generation。后续合同至少分别约束：目标准备/标题、输入区与输入读回、
确认意图、设备确认后 Enter 前、发送后验、teardown。每阶段分别 fresh capture，记录各自 capture token、
采集时间和相对输入/确认/Enter 的先后关系；一个阶段内的树、图像、OCR、IME 与 region 必须有可验证的
同代绑定，不能把不同帧按相同 bounds 拼装。阶段间通过独立的 window/pane 连续性和 epoch 证明关联，
不得沿用旧 ref 去绑定新快照。发送后验必须采于发送之后；发送前画面永远不能作为发送后证据。

若旋转、window/pane 移动/替换、IME 或 insets 改变导致 geometry/epoch 失效，该链停止并清除旧准备、
输入和批准证据。即使预期会弹出 IME，也不能忽略漂移；未来合同须明确新布局下重新准备和重新确认的
入口，当前不自动续跑、不复活旧批准。OCR 必须先裁到已绑定的目标 pane，再在消息 region 内聚类，
验证 X/Y、完整区域与 window/pane/epoch；识别不确定、看不到区域和观测失败分别保留，均不得报绿。

现有机制的可复用范围仅限其源码已经实现的部分：

- [FreshVisionCache](../../app/gateway/src/main/java/dev/magina/gateway/a11y/FreshVisionCache.kt)的
  `forceFresh` 会绕过缓存执行 loader，但不保证 loader 真的采新图，也不携带 pane、geometry 或 epoch。
- [SnapshotRefRegistry](../../app/gateway/src/main/java/dev/magina/gateway/a11y/SnapshotRefRegistry.kt)
  用 session + generation 防跨进程/快照静默重绑定；它不是授权，也不证明目标 pane，不能为视觉连续性放宽旧 ref。
- [PreparedTargetEvidence](../../app/gateway/src/main/java/dev/magina/gateway/core/PreparedTargetEvidence.kt)
  已有单调时钟 TTL、package/identity/bounds 变化即清除；其
  [FocusIdentity](../../app/gateway/src/main/java/dev/magina/gateway/core/FocusIdentity.kt)只有来源、a11y input 与
  IME session，没有 pane/geometry/epoch。既有 120 秒默认 TTL 不是平板视觉 TTL 的验证依据。
- [VisionTrustPolicy](../../app/gateway/src/main/java/dev/magina/gateway/a11y/VisionTrustPolicy.kt)区分页面识别与
  动作 OCR 门槛，并约束最小裁图尺寸；手机像素带和既有置信度均不能证明平板 pane 归属或替代新鲜度。

#### 待覆盖反例与正确停止结果

以下为未来合同及离线矩阵的输入需求，本轮不创建 fixture，也不声称这些用例已经运行。

| 反例 | 相对正例的输入差异 | 应拒绝/证据不足的原因与停止结果 |
|---|---|---|
| 另一窗同名会话行 | 目标词只位于另一 window 的列表行，目标 pane toolbar 不匹配 | 文本相同不证明 toolbar/目标归属；目标准备停止 |
| 同 Y、错 pane marker | 保持 marker 的 Y，改为另一 pane 的 X/window/pane | 先裁目标 pane 后不应命中；后验失败或证据不足，禁止重发 |
| window 移动/缩放 | identity 未变，但 bounds 或 crop 偏移改变 | geometry/epoch 失效，旧 rect/ref/批准全部停止使用 |
| 旋转或 display 变化 | 保留内容，旋转尺寸/坐标轴或引入另一 display | 不再是原 display geometry；停止，不归一化后冒充同布局 |
| insets/IME 改变 | token/内容类似，但 IME 显示、模式或 safe insets 改变 | 输入区、crop 与确认卡安全区须重证；失效并停止旧链 |
| 截图与树跨代 | 图像来自 capture A，树/ref/IME 来自 capture B，bounds 恰好相等 | 缺同代来源证明；不能拼装，停止相应消费 |
| 遮挡/裁剪不足 | pane identity 看似正确，但 toolbar、消息区或输入区被 overlay 遮挡/裁掉 | 不可观测不等于不存在；证据不足并停止 |
| 多个目标 | 同一或多个 pane 都有可匹配标题/输入候选 | 唯一性未成立；不按左右、layer、active/focused 选一个，停止 |
| 过期或 ref 复用 | 内容/位置不变，但 TTL 已到、服务重启或 snapshot generation 已变 | 时间和命名空间失效；清除关联证据，停止使用旧目标 |
| opaque/read_error 混淆 | 一例完整读到零几何 root，另一例读取抛错/截断/预算耗尽 | 前者只能报告语义不可用，后者报告采集不完整；两者都不能产生目标/后验成功 |
| 整屏变化假阳性 | 目标 pane 无可证明消息变化，另一窗动画、通知或键盘产生变化 | 全屏差分不证明目标效果；后验证据不足，禁止报业务成功 |
| 输入回显冒充消息 | marker 只在 input region，message viewport 没有独立证据 | 回显只能证明输入读回；发送后验停止，不宣称对方收到 |
| 前图冒充后验 | 使用发送前 capture，或无法证明 capture 晚于 Enter | 缺动作后观察；后验证据不足，不自动重发 |
| 相同 bounds 的 window 替换 | 新 window 复用旧位置/标题或 run-local 编号 | 缺 identity 连续性；不能按坐标或标签跨 run 认同一对象，停止 |
| 时钟/token 自报一致 | caller 拼出相同时间/token，但无采集来源与单调时序 | 字段相等不自证来源；来源校验停止，模型描述不能补齐 |

#### 最小消费者、剩余缺口与停止线

后续最小消费者限于来源/时序校验、window/pane 唯一性与连续性校验、几何裁剪/OCR 区域归属校验、
stale/TTL 清理，以及准备—确认—动作前复核—后验—teardown 的既有安全链接入。当前缺口是可信图像采集
与时钟、图像到原生 window 的绑定、会话 pane 语义、统一 `DisplayGeometry/layout_epoch` 及其失效事件、
各阶段 TTL 和独立后验判据；没有其中任一项，就停止对应链路，不产生 layout/P0/execution grant。
本段不实现 producer/schema/fixture 或生产接线，也不启动新的视觉采集批次。

[Mika 查阅记录](../knowledge/brain/mika.md)仅提供读屏质量分类和效果表达的参考：可分别报告完整但 opaque、
部分可见、读取失败、目标区域不可观察，以及“动作已分派/观察到变化/内容读回一致/任务未核实”。不照抄
上游阈值、坐标归一化或业务成功结论，不把整屏变化当目标 pane 效果，也不把未观察到变化当自动重试依据。

若推进需要新截图/OCR、修改 C1b 探针、放宽单 display、启用 IME-only/整屏坐标兜底，或进入发送等危险
路径，应在此停止并报告所缺合同与真实证据；本轮不执行。设备上可见 ConfirmOverlay 的逐次确认、
固定完整 SHA 验收和现有队列约束继续适用；静态设计与合成覆盖不能冒充真机结论。

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

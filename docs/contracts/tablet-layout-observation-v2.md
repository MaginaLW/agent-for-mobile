# `tablet-layout-observation/v2` 诊断契约

这是 PA2553 日常横屏、vivo“应用多窗”保持开启时的 T-L1 第一阶段契约。机器合同描述 **2–4 帧纯感知诊断**，
其中受控 C1a producer 固定恰好两帧（c1/c2）。这两条路径都不是 layout acceptance、微信真机验证、
编辑器动作、P0 或 execution grant。机器结构见
[`tablet-layout-observation-v2.schema.json`](tablet-layout-observation-v2.schema.json)。

## 永久安全边界

本阶段无论 fixture 的窗口、pane、标题、IME 与 focus 多么完整，以下字段都固定：

- `mode=diagnostic_only`；
- `route.kind=probe_only`；
- `settings_mutation_allowed=false`、`device_action_allowed=false`；
- `layout_accepted=false`、`wechat_layout_verified=false`、`editor_action_ready=false`；
- `p0_capability=unsupported`、`execution_grant=false`；
- P0 blocker 恰含 `tablet_layout_diagnostic_only`、`upstream_t0_readiness_blocked`、
  `tablet_landscape_p0_unimplemented`、`tablet_tl2_unverified`。

`diagnostic_status=observed` 只表示 synthetic fixture 在这份诊断模型中自洽。它不能简写为“T-L1 通过”，
不能进入 T-L2，也不能喂给既有手机 gateway。公共 file consumer 的非 `-FixtureMode` 入口仍在读取 caller 路径前
固定返回 `runtime_producer_unavailable`。C1a 新增的 trusted-runtime 路径只允许经独立受控 runner 完成
clean-port/APK/设备/T0/ContentProvider 绑定后内部调用；它只在 sidecar 记录 origin/read-only proof，validation
仍固定 `runtime_evidence=false`，不得冒充 runtime accepted。

## fresh blocked T0 envelope

T-L1 v2 不把 T0-L v5 的 readiness blocked 改写为 accepted。`upstream_t0` 必须保存并复核：

- `schema_version=5`、T0 `run_id` 与 canonical UTC `captured_at`；
- artifact SHA-256、T0 producer 的完整 Git SHA、device profile canonical hash；
- `intake_status=accepted`、`readiness_status=blocked` 及原始 readiness reasons；
- `p0_capability=unsupported` 与原始 unsupported reasons，其中仍含
  `wechat_layout_unverified`、`tablet_landscape_p0_unimplemented`。

fixture validator 从受控 root 的固定 `upstream-t0-v5.json` 单独读取 artifact，重算 artifact/device hash，
核对 clean T0 producer `4ca32b131007df58f7752c5ee9b2d049cb1cd54e`，并要求 T0 早于首帧且相差不超过
10 分钟。该独立 T0 复核不能因进入函数前已存在 observation/provenance issue 而跳过；只有 T0 自身缺少
required 顶层字段、因而无法安全继续时才能提前返回。caller 在 observation 里重复自报相同字段不能构成 runtime provenance；fixture 与 runtime 的
`source_kind`/`provenance.kind` 分离，fixture 永远 `runtime_evidence=false`。

受控 C1a runner 必须把 T0 producer 留下的**原始 BOM-less bytes**交给 app producer，不能先 parse/re-serialize
再传入。app 构造边界只接受 1..65,536 bytes、strict UTF-8/RFC 8259 object，拒绝任意层重复 key、非 Int64 number，
并用与 consumer 相同的 device canonical JSON 重算 hash。该 intrinsic provenance 复核仍不构成 runner
attest 或 runtime evidence；当前 production capability 继续 unavailable。

## 2–4 帧 DTO（C1a 固定两帧）

每帧包含：

- `capture`：run-local `cN`、`revision_before`、`revision_after`、`layout_revision`、`ime_revision`；四个
  revision 必须相等，capture token 必须严格按 frame index 为 `c1`、`c2`……且全局唯一，下一帧 revision
  严格递增；Android C1a 的字段是 composite logical marker：`logical revision = 同一无障碍服务的 raw event
  revision + capture token ordinal`，可按 `raw = logical - ordinal` 还原，不冒充原始 event epoch。同一 service
  identity 下 raw revision 相等或递增时 c1/c2 严格有序，raw 下降时仍阻断；任一帧读取期间的 raw revision
  漂移仍会破坏四值相等并 fail closed；
  帧间至少 900 ms，总跨度不超过 15 秒，末帧距验证时刻不超过 2 分钟；
- `display`：display ID 的 known/unknown 状态、nullable ID/size 与 orientation；unknown、非横屏或额外
  display 都能被持久为诊断，但不能 observed；
- `a11y_windows`：全部 interactive window（含 application、IME、accessibility overlay 与 system），最多 16；
- application-only `panes`（最多 8）与 bounded `node_observations`（最多 512）；三个 inventory 分别用
  `windows_truncated`、`panes_truncated`、`nodes_truncated` 明示 producer 是否有界截断；
- `target`：expected title hash、nullable conversation window/pane、title/toolbar/message/input 候选数组、
  focus 与 IME。0 个或多个候选可以进入 schema，以便 producer 如实 fail-closed，validator 不允许 producer
  猜一个“选中项”修绿。跨帧 conversation window/pane label 必须保留 nullable 类型做 ordinal 对称比较：
  `null`/`null` 不漂移，只有一侧为 `null` 或两个非 null label 不同才是 drift。

### Intrinsic 声明与 consumer freshness

Evidence 内的 `diagnostic_status/reason_codes` 与 `consistency.*` 只声明 producer 能从同一 capture 稳定重算的
intrinsic reasons。`capture_in_future`、`capture_stale` 取决于 file consumer 实际 validation `UtcNow`，因此是
consumer-owned validation-time reasons：它们不进入 evidence 的 producer 声明，也不进入 intrinsic consistency。

除上述 consumer-owned freshness 外，producer 顶层 intrinsic reason 集必须能由**序列化后的同一 DTO**完整
重算。raw-only anomaly 必须转换为 schema 可见的 truncation/status/binding 字段（例如
`windows_truncated=true`、unknown/root status），或在构造边界拒绝该帧；不得把只存在于内存 raw state、consumer
无法观察的 reason 额外塞进顶层声明。Consumer 对 intrinsic reasons 做 exact 检查：漏声明与不可见的额外声明
都 fail closed。

Consumer 仍以实际 `UtcNow` 强制执行 future 与末帧两分钟 freshness 门，并把动态 reason 加入最终 validation
envelope，使 `diagnostic_observed=false`；这不产生额外 `declared_status_mismatch` 或
`consistency_declared_mismatch`。反过来，evidence 自行把这两个动态 reason 填入顶层或 consistency 声明属于
extra declaration，必须 fail closed。此职责分层不延长两分钟期限、不接受 future，也不把动态 blocker 从最终
结果移除。

### Window 与 pane identity

T0/WMS 的 `wN` 与 a11y 的 `awN` 是两个互不相等的命名空间。producer 只在内存中维护 raw a11y window
identity → run-local `awN` 映射；同一 raw identity 在两帧中保持同一 `awN`，raw ID 及其稳定 hash 都不落盘。
window 记录 `display_id/type/root_status/root_package/layer/bounds/touchable_bounds/active/focused`。bounds
允许 `-32768..32768` 的有界负坐标，producer 不得 clamp；validator 再判断非退化、display 与 ownership。

原生双窗基线要求恰好两个 `application` window，均为 readable 微信 root；恰好一个 navigation pane 与一个
conversation pane，并与两个 window 一一绑定。pane bounds 当前要求等于所属 native window bounds。
IME/overlay/system window 可以同帧存在但不计入“双窗”；pane 只能绑定 application window。额外 App、其它
owner、额外 display、跨帧 awN replacement、window↔pane 非双射，或任一 inventory 截断标志为 true 都明确
阻断。数组仍在 16/8/512 上限内保持 closed-schema 可序列化，producer 不能以超限为由丢失截断事实。

### Node、标题与 region

`node_observations` 只包含 frame-local `anN`、window/pane、结构角色、bounds 与布尔交互属性；禁止 text、
contentDescription、viewId、raw node/window identity，也禁止一般内容 hash。目标标题 hash 固定为：

```text
sha256(UTF-8(NFKC(text).trim()))
```

producer 在**全部 application window** 中枚举与 caller 已知 `expected_title_hash` 相等的候选，并必须输出
**所有**匹配者；其它文本及 hash 不落证据。唯一候选必须是 target conversation window/pane 内的
`pane_toolbar_title`，其 `node_label` 还必须
唯一绑定一个 `role=toolbar_title` 的结构节点，且 node/candidate 的 window、pane 与 bounds 逐字段一致；候选
自报 role 不能替代结构证明。另一窗同名、同 Y 错窗、wrong role/pane/window 或非唯一都 fail closed。

每个 raw frame 还必须只在内存中绑定采集时实际用于文本比较的 expected title hash；assembler 在生成任何
候选或 JSON 前要求所有帧的绑定均为 strict SHA-256，且与 run context `expected_title_hash` exact。只保存
`matches=true/false` 而不保存这层绑定，或把按 A 捕获的布尔命中放到 B context 下复用，均在构造边界拒绝。

toolbar/message/input 都是候选数组，且只从已唯一识别的 conversation application window/pane 产生；navigation
窗的 scrollable node 不能进入 target message candidates。observed fixture 要求各恰一项、同 target
window/pane/capture token，
source node 的结构角色、ownership 与 bounds 也必须和候选逐字段绑定；三段横向覆盖 target pane，纵向无缝
分区。跨 window region、候选 0/多项、仅靠 label 自报、绑定或几何错误都明确诊断。input fingerprint 只能是
**每次 run 随机 salt**下的结构摘要；salt 与 raw material不序列化，不能变成跨 run 稳定身份。

### Focus、IME 与 overlay

- `focus.status=absent` 且没有 focused window/input 时允许纯感知 `observed`，但 action 仍 false；
- Consumer 无论 `focus.status` 都先从 serialized DTO 重算 inventory conflict：任一 non-application focused
  window、多个 focused app window/input、window/input 有无不对称、label 不一致或不在 target，均报
  `focus_target_conflict`；
- `known` focus 必须同时唯一绑定 target window 与 target input；`unknown` 不靠 active/IME fallback 猜测，
  始终报 `focus_fallback_insufficient`，且 inventory 有冲突时同时保留 `focus_target_conflict`；unknown inventory
  无冲突时只报 fallback；
- hidden IME 必须是 `visible=false/mode=none/binding=not_active`，且 interactive window inventory 中没有
  `type=input_method` window，才允许 layout-only observed；hidden observation 却仍出现该 window 时按
  `ime_target_editor_unbound` fail closed。`windows_truncated=true` 时同样无法证明 hidden inventory 恰零，
  因此同时保留 `window_inventory_truncated` 与 `ime_target_editor_unbound`；
- 若 raw capture 自相矛盾（例如 `visible=false` 却仍有 mode/bounds/editor binding），producer 必须在构造边界
  拒绝该帧，不能先归一化成表面正常的 hidden DTO、再附加 validator 无法从证据重算的自报 blocker；
- visible IME 还要求 inventory 恰有一个 `type=input_method` window：frame、target window 与 IME window
  必须处于同一 known display，IME window bounds 非 null/非退化且与 `target.ime.bounds` exact。该阶段不以
  `touchable_bounds` 替代或放宽视觉 bounds 绑定。只有这些条件连同 docked、`target_editor`、target input
  label 与 run-salted fingerprint 全部匹配才不新增诊断；缺失/多个 IME window、错 display、bounds mismatch、
  `windows_truncated=true`（无法证明恰一 inventory）、floating、无效 bounds 或其它 editor 均报
  `ime_target_editor_unbound`；错 display 同时保留
  `multi_display_blocked`。无论绑定是否完整，
  `editor_action_ready` 仍固定 false。`bounds=null` 报 editor unbound；非 null 退化 bounds 还同时保留
  `region_geometry_invalid`；若退化的是 inventory 中 IME window bounds，还同时保留通用
  `window_geometry_invalid`；
- target 同一 **known** display 上、layer 高于 target window、且双方 rect 有效、其 **window bounds** 与已绑定
  target window/pane 的 title/region 相交的 accessibility/system/unknown 潜在 overlay 报（不以 touchable
  bounds 替代视觉遮挡几何）`overlay_target_occlusion`。target/overlay 任一 display ID 为 null（包括 null/null）
  或两个 known ID 不同，都不得自称同 display 并派生该 reason。

## 隐私与文件入口

所有 object schema 均 `additionalProperties=false`。证据不保存聊天明文、全屏截图、raw dump、whole-screen
OCR、raw identity 或一般内容稳定摘要。离线 validator 在 schema 前扫描 raw JSON key，避免未知字段先被吞掉；
此外内建一个固定、非目标、fixture-only 的 synthetic dummy canary：validator 在同一 immutable observation raw
与固定 `upstream-t0-v5.json` raw 的**所有 JSON string value** 中用 ordinal comparison 拒绝该 dummy 明文及其
无盐 SHA-256，即使它被放进 schema 合法的 safeId/hash 字段。该机制只证明这一个 synthetic canary 未泄漏，
不声称能推断或发现任意聊天内容；CLI/validator 不接受真实聊天文本作为 canary 参数。

fixture file 入口只接受固定本地卷、受控 root 内 `.json`，拒绝 drive root、UNC/device/ADS、root 外路径、
reparse/junction、hardlink、打开后 final-path 变化、非 BOM-less strict UTF-8、超过 1 MiB、重复 JSON key 与
非 Int64 整数字面量。所有异常收敛为安全 validation envelope；该 envelope 自身也始终把 runtime/layout/
action/P0/execution 固定为 false/unsupported。

## 离线 gate

一键入口：

```powershell
pwsh -NoProfile -File scripts/run-tablet-layout-observation-v2-offline-gate.ps1
```

它先运行 machine-summary 自测，再执行 exact **24/24 cases、24/24 required coverage**，原子发布固定
`.checks/tablet-tl1-v2-offline-gate.summary.json` 并按本次随机 run ID 读回重算。required coverage 正是设计
审计给出的 24 个 ID，从 `upstream_t0_block_preserved` 到 `p0_exec_false`；缺、多、重复 case/coverage、0 case、
计数伪造、安全常量自提升或旧 run ID 均非零退出。summary 仍只是 fixture contract gate，不是 runtime attest。

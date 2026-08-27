# Tablet T-L1 C1b v1：pure-a11y 拓扑诊断合同

## 1. 目的与版本边界

`tablet-layout-observation/c1b-v1` 是在 C1a 真机暴露出 opaque accessibility tree 后新增的只读诊断合同。
`tablet-layout-observation/v2`、C1a sidecar、既有 validation 与 fixtures 全部冻结；C1b 不迁移、重解释或
回填旧 evidence。

本版只回答以下问题：

1. 两个 application window 的 inventory、owner、display、bounds 是否稳定；
2. 每个 application window 是否有且只有一个 run-local root projection；
3. root handle 是否确实绑定原 a11y window，subtree 是完整但 opaque，还是读取失败/截断；
4. native window title 对 caller 已知 title hash 的匹配状态、focus inventory 与 IME hidden 状态是什么。

本版不识别 navigation/conversation，不选择 target，不划分 toolbar/message/input，不授予布局、动作、P0
或 execution 结论。

## 2. 冻结的安全常量

- `mode=c1b_pure_a11y_diagnostic`
- `route.kind=probe_only`
- settings/device action/screenshot/OCR 全部不允许；
- pane 的 `semantic_role` 恒为 `unknown`，`semantic_evidence` 恒为空；
- node 的 `semantic_role` 恒为 `unknown`；
- `layout_accepted=false`、`wechat_layout_verified=false`、`editor_action_ready=false`；
- `p0_capability=unsupported`、`execution_grant=false`。

observation validator 不能仅靠 observation 与 caller 字符串相等自证来源；它的 `runtime_origin_verified`、
`runtime_evidence` 及所有 `*_verified` 在本层恒为 false。trusted-runtime 入口最多输出
`runtime_binding_inputs_match=true` 这一非证明性的 binding fact。最终 runtime origin 只能由后续独立
sidecar/runner 对 APK、observation、validation、T0、fresh install 与只读计数完成强闭环后产生。

`upstream_t0` 保留 T0 v5 的 `readiness_reasons` 与 `p0_unsupported_reasons`，后者至少包含
`wechat_layout_unverified` 和 `tablet_landscape_p0_unimplemented`。这些字段只传递 probe-only 阻断归因，
不能被 C1b 改写为 readiness 或能力结论。

## 3. window、root 与 subtree

`root_handle_status=readable` 只表示 `AccessibilityWindowInfo.getRoot()` 返回了 handle；它不表示树可用于语义。
必须另行记录：

- `root_window_binding=exact|mismatch|unknown`；`exact` 的 producer 条件是 root/node 的 window id 与当前
  `AccessibilityWindowInfo` raw id 在内存中逐值相等，raw id 不落盘；
- `subtree_capture.status=complete|truncated|read_error|not_attempted`；
- root child、visited、正几何可见 node、focused editable node、read error 与 budget 状态。

`complete + root_child_count=0 + visited_node_count=1 + positive_visible_geometry_node_count=0` 是
“完整观察到 opaque root”，不是 unreadable，也绝不是 semantic proof。退化 root node 以
`geometry_status=degenerate` 保存；它不能成为任何候选。

`platform_type_code` 是 Android 的数值 window type，不是 identity。wire `type` 必须覆盖 application、IME、
system、accessibility overlay、split-screen divider、magnification overlay 与 Android 16 window control；
未知 code（包括 `0` 与未映射值）保留为 `unknown`，不得猜类型。`unknown` 可以诚实落盘，但表示 window-type
inventory 不完整：`window_inventory_observed`、ownership/root projection/topology observed 与
`ime_hidden_observed` 必须全部为 false，并产生 `window_type_invalid` 与 `ime_inventory_invalid`。
同样，`windows_truncated=true` 表示 window 清单不完整；即使持久 IME tuple 恰为 hidden 形态，也必须产生
`window_inventory_truncated` 与 `ime_inventory_invalid`，并令 `ime_hidden_observed=false`。后续 sidecar 的
`ime_hidden_verified` 与 observed 对称绑定，因此也不可能单独置 true。

## 4. title、focus 与 IME

`expected_window_title_match` 只保存 native window title 与已授权 hash 的查询结果：
`match|no_match|absent|over_budget|read_error|not_attempted`。不得保存 title 明文、未命中 title 的 hash，
也不得把 window-title match 塞成 toolbar/title-node candidate。即使唯一 `match`，本版 target 仍未验证。
offline fixture 可使用 synthetic strict SHA-256；trusted runtime 必须固定复用 C1a 的目标 hash
`sha256:5d3510ec998c991305fcede15b32be9ea1c4061d82ab15a3994a38faa243311c`，runner/provider 不接受 caller
传入标题或 hash。

focus 是 inventory 观测而不是 target selector：

- `absent`：零 focused application window、零 focused editable node；
- `window_only`：恰好一个 focused application window、零 focused editable node；
- `editor_known`：恰好一个 focused application window 与一个满足 exact window binding、positive bounds、
  visible、enabled、editable、focused 的 node，且二者同窗；
- `conflict|unknown`：其余歧义。

上述 `absent|window_only|editor_known|conflict` 只有在每个 application window 都满足 positive bounds、readable
root handle、微信 owner、exact root/window binding、恰好一个合法且同 bounds 的 root-subtree pane、
`subtree_capture.status=complete`、非空 `root_child_count`、`visited_node_count>=1`、wire node 数与 visited 相等、
`read_error_count=0` 且 `budget_exhausted=false` 时才允许重算。每窗还必须恰好一个 `is_root` wire node；该 root
必须绑定同一合法 pane、`window_id_binding=exact`，且 positive/degenerate/unavailable geometry 分别满足既有几何规则。
任一条件不完整，或 window/node inventory 截断、window type 为 unknown 时，focus 必须为 `unknown` 且
window/node label 均为 null；不得把读取失败降级成 `absent` 或 `window_only`。

producer 的 direct `findFocus` 只有在 refresh 成功、唯一 focused application window、node 的 focused/editable/
visible/enabled 全真、package 与 window id exact、positive bounds 全部成立时，才能记录为 `editor_known`。
这组条件由 Kotlin producer coordinator tests 作为跨层 requirement 固定；consumer 仍独立重算持久 inventory。

`editor_known` 也不能选择 conversation；navigation 搜索框是固定反例。hidden IME 必须同时满足完整且全部
已知、未截断的 window-type inventory、无 IME window、`mode=none`、无 bounds/editor binding。
每帧 `ime.capture_token` 还必须与同帧 `capture.token` exact 相等；closed schema、producer assembler 与
consumer validator 必须各自独立校验。错绑统一视为 `ime_inventory_invalid`，不能产生
`ime_hidden_observed`，后续 sidecar 也不能将其提升为 `ime_hidden_verified`。

## 5. 禁止的推断

- package 只证明 owner；不能证明 navigation/conversation/target；
- left/right、宽窄、layer、active、focused 只用于 topology 与稳定性；
- scrollable 不能证明 navigation，editable 不能证明 conversation；
- fixture 只能提供 synthetic `expected_title_hash`，不能提供 target window/pane/role；runtime provider 不接受 caller 标题参数；
- T0/WMS `wN` 与 a11y `awN` 是不同 identity namespace，禁止按编号或 bounds crosswalk。

closed schema 会拒绝未知声明字段；validator 还必须用左右镜像 fixture 证明结论不依赖位置。

## 6. 结论层

observation validator 分开输出：

- `window_inventory_observed`
- `wechat_window_ownership_observed`
- `window_root_projection_observed`
- `application_window_topology_observed`
- `ime_hidden_observed`
- `semantic_tree_usable`
- `runtime_binding_inputs_match`（仅比较固定输入，不是 attestation）

本层 `runtime_origin_verified/runtime_evidence`、ownership/root projection/topology/IME 的全部 `*_verified`
恒为 false。后续独立 sidecar validator 才可按 `runtime_origin_verified && 对应 observed` 机械形成最终 verified。

navigation/conversation/target/regions/layout/微信/editor/action/P0/execution 在本版恒为 false/unsupported。

公共 observation offline gate 固定为 49/49 cases、89/89 required coverage；machine summary 的 closed
schema 必须拒绝旧 48/86 计数、删减 case/coverage 或错绑 IME token 的摘要。

## 7. 隐私与采集纪律

只保存 run-local `awN/apN/anN`、枚举、计数、bounds、query-bound match 与已批准的 artifact hash。禁止 raw
window/root/node id、uniqueId、`toString()`、title/text/description/class/viewId、聊天明文、未加盐内容 hash、
截图与 raw dump。本版截图和 OCR 调用计数必须为 0；若以后需要 window-scoped OCR，另开合同和授权。

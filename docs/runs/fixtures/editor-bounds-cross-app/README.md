# 跨应用编辑框四边验收

此 Activity 是独立的 Android 应用。输入法和无障碍服务均来自待测网关。靶应用把获得焦点的真实控件、同原点的较大对照框、无障碍节点和输入连接的几何请求次数写入自己的私有目录。对外只核对窗口、身份是否相符、四边、可编辑标志和失败原因。

在新的私有构建目录，按[几何实验的构建步骤](../editor-origin/README.md#构建)打包本目录下的清单、资源和 `EditorActivity.java`。Java 编译只需该源文件和 Android 平台 jar。用测试密钥签名。使用[本地测试台](../../../runbooks/本地测试台.md)的独占 Android 16 模拟器，安装待测网关和该靶；先核对在机 APK 摘要和两个不同的应用 UID。记录模拟器原默认、启用的输入法和无障碍设置，再依本地测试台入口启动网关、启用其无障碍服务和输入法。

每次以新任务启动同一 Activity，依次把下表的场景名传入 `--es lab_case`。下例中 `$target` 包含已核实的私有 ADB 端口和模拟器序列号。

```powershell
& $Adb @target shell am start -W -f 0x10008000 -n dev.magina.crossappfixture/.EditorActivity --es lab_case $case
& $Adb @target shell run-as dev.magina.crossappfixture cat "files/$case.json"
```

Activity 启动后，每 250 毫秒检查一次该场景的回执，最多等 12 秒。回执须确认输入连接已建立，控件和窗口均已获焦。先用无参数的 `keyboard_state` 检查默认响应未产生编辑框四边；随后每个场景仅用一次 `keyboard_state({"probe_editor_bounds":true})`，再读靶应用回执。只要一项失败或等待超时，就保存已取得的结果并收尾。

| 场景 | 独立对照和预期回执 |
|---|---|
| `named` | 具名焦点的窗口号及四边须与靶实测一致，能排除同原点、不同尺寸的对照框。靶侧收到一次新的四边请求。 |
| `not_editable` | 同样核对具名焦点的身份和四边，`editable` 为假。 |
| `conflict` | 输入连接声明另一具名控件的字段 ID，返回空矩形和 `different_id`。 |
| `bounds_conflict` | 同一具名控件只修改无障碍描述，右边界增加 12 像素。靶记录两组矩形，网关返回空矩形和 `different_bounds`。 |
| `missing` | 控件只有动态 ID。缺少资源名时返回空矩形和 `missing_id`。 |

还原原默认输入法、启用清单及无障碍设置，逐项读回。停止本轮自建网关、转发、模拟器及私有 ADB，核实端口释放。此验收只覆盖当前输入焦点的只读元数据。

显式查询四边时，如果网关返回 `focus_unavailable`，矩形仍为空。`ime_editor_focus_phase` 表明核对发生在输入法取样前（`before_sample`）或取样后（`after_sample`）。`ime_editor_focus_check` 记录按执行顺序首个失败的检查。

| 检查位置 | 可能的回执值 |
|---|---|
| 清理无障碍缓存、取得活动根或所属窗口 | `cache_clear_failed`、`active_root_missing`、`active_window_missing` |
| 取得系统输入焦点、刷新节点、核对焦点和可见状态 | `input_focus_missing`、`node_refresh_failed`、`node_not_focused`、`node_not_visible` |
| 核对节点所在窗口、应用和活动根返回的输入焦点 | `node_window_mismatch`、`node_package_mismatch`、`root_focus_mismatch` |

这两个字段仅含固定标记。成功或其他失败原因的回执省略它们。旧候选的 `focus_unavailable` 回执无法追溯到具体检查；`node_not_focused` 枚举在 `2341c7d` 及更早候选上出现，新候选对通过下述交叉核验的未聚焦节点改为进入四边比对并在 `ime_editor_bounds` 中标出 `node_focused: false`。

### 服务级输入焦点失效兜底与未聚焦节点的交叉核验

沿用 `INPUT_NULL`。完成清理缓存与活动应用窗口核验（`TYPE_APPLICATION`、活动、获焦且包名匹配）后，读取一次服务级输入焦点 `serviceFocus`：

- **活动窗密码/敏感快速拒绝**：若 `serviceFocus != null` 且 `serviceFocus.refresh()` 成功、与活动窗口同窗同包，且 `isPassword || isAccessibilityDataSensitive`，立即返回 `sensitive_field`（绝不兜底、零输入法请求、省略 `ime_editor_focus_diag`）。
- **有效服务焦点路径**：若 `serviceFocus != null` 且 `refresh()` 成功、`isVisibleToUser == true`、同窗、同包且非敏感，严格沿用原有检查与顺序，**禁止**因 `root_focus_mismatch`、`different_id`、`ambiguous_id` 或 `invalid_bounds` 绕过兜底：`isFocused == true` 取样前不依赖 `EditorInfo`；`isFocused == false` 仍要求活动根输入焦点 `rootFocus == serviceFocus` 且取样前 `EditorInfo.fieldId` 交叉核验与节点资源名一致。若 `rootFocus != serviceFocus`，直接返回 `focus_unavailable` / `root_focus_mismatch`，且不额外调用 `EditorInfo` 或按名查表（`window_field_lookup = "not_attempted"`）。
- **服务焦点缺失或无效时的活动窗字段兜底**：仅当 `serviceFocus == null`，或 `serviceFocus` 未通过活动窗可用性检查（`!refresh()`、`!isVisibleToUser`、`windowId != window.id` 或 `packageName != pkg`）时，尝试经 `EditorInfo.fieldId` 解析非敏感的全限定 `id/...` 资源名，再在已核实的活动聚焦应用窗口内按名查找。[Android 字段 ID 约定](https://developer.android.com/reference/android/view/inputmethod/EditorInfo#fieldId) · [窗口内的资源名查找](https://developer.android.com/reference/android/view/accessibility/AccessibilityNodeInfo#findAccessibilityNodeInfosByViewId(java.lang.String))
  - 4 类密码 `EditorInfo.inputType` 立即 fail-closed 返回 `sensitive_field`（绝不静默吞掉敏感拒绝，且省略 `ime_editor_focus_diag`）。
  - **单命中（`matches.size == 1`）**：沿用单节点校验，依次完成 `candidate.refresh()`、密码/敏感快速拒绝（`sensitive_field`）、`isVisibleToUser`（`node_not_visible`）、`windowId`（`node_window_mismatch`）、`packageName`（`node_package_mismatch`）、单次活动根输入焦点校验、`viewIdResourceName == fieldName`（`missing_id` / `different_id`）、窗口内二次唯一查表（`ambiguous_id`）及非空且完整落于非空活动窗口内的四边校验（`invalid_bounds`）。
  - **多命中可见子集筛选（`matches.size >= 2`）**：对 `matches` 中每个节点各调用一次 `refresh()`：
    - **同窗同包敏感优先 fail-closed**：只要任一刷新成功的同窗同包节点满足 `isPassword || isAccessibilityDataSensitive`（不论其是否可见、四边是否为空或是否越界），立即返回 `sensitive_field`（绝不兜底、零输入法请求、省略 `ime_editor_focus_diag`）。
    - 按统一口径统计 `boundsInWindowMatches`（刷新成功、同窗、同包、非密码/非敏感、`viewIdResourceName == fieldName` 且四边非空并完整落于非空活动窗口内，不限 `isVisibleToUser`），并在其上追加 `isVisibleToUser == true` 筛出可见窗内有效子集 `usable`（计数记为 `visibleInWindowMatches`）。
    - 仅当 `usable.size == 1`（`window_field_lookup = "filtered_unique"`）时取唯一节点 `candidate`：保留本次刷新后的状态、四边、聚焦与可编辑标记（不再重复 `refresh()`），执行下述单次活动根输入焦点校验，随后再次调用 `findNodesByViewId(fieldName)` 按**同一严格过滤口径**（含同窗同包敏感 fail-closed 扫描）做二次唯一复核，要求二次筛选结果严格 `.singleOrNull() == candidate`，否则返回 `ambiguous_id`。
  - **兜底路径的根焦点放行边界（`unique` 与 `filtered_unique` 共用）**：单次读取 `rootFocus = root.findFocus(FOCUS_INPUT)`，仅在以下三者之一成立时放行，其余非空 `rootFocus`（具名、已聚焦、可见、未刷新成功、跨窗敏感或指向第三节点）一律严格返回 `root_focus_mismatch`：
    1. `rootFocus == null`；
    2. `rootFocus == candidate`；
    3. 仅豁免 PA2553 已证实的退化形态：`candidate != serviceFocus && rootFocus == serviceFocus && serviceFocus.refreshed == true && !serviceFocus.isFocused && !serviceFocus.isVisibleToUser && serviceFocus.viewId == null && !serviceFocus.sensitive`。
  - **兜底失败归因**：
    - `serviceFocus == null` 时沿用原错因（`missing_id`、`resources_unavailable`、`input_focus_missing`、多命中 `usable.size >= 2` 报 `ambiguous_id`，或 `candidate` 对应的失败）；若多命中但 `usable.size == 0`，返回 `focus_unavailable` / `node_not_visible` 并附 17 键 `ime_editor_focus_diag`（`window_field_lookup = "ambiguous"` 与三个整数计数）。
    - `serviceFocus != null` 时，若兜底未产生有效唯一节点（`no_contract` / `missing_id` / `resources_unavailable` / `zero_matches` / 多命中 `usable.size != 1` 记 `ambiguous`）或命中与 `serviceFocus` 相同的失效节点，按原顺序返回 `serviceFocus` 的原始 `focus_unavailable`（`node_refresh_failed` → `node_not_visible` → `node_window_mismatch` → `node_package_mismatch`）；若命中**不同于 `serviceFocus` 的唯一节点 `candidate`**（`unique` 或 `filtered_unique`）且 `candidate` 自身校验失败，则按 `candidate` 归因（非 `focus_unavailable` 错误省略 `ime_editor_focus_diag`）。

取样前后须取得同一节点、窗口、具名资源、可编辑状态、聚焦状态和屏幕四边（任一字段变化含采样前后焦点双向翻转均返回 `context_changed`），默认输入法须仍为网关输入法、输入会话须稳定，输入法回调中的字段名须与节点一致（`different_id`）且四边按 `Float` 逐边精确匹配（`different_bounds`，不截断小数）。对照用例覆盖正常聚焦不依赖 `EditorInfo`、失效服务焦点（刷新失败/不可见/跨窗/跨包）由活动窗唯一字段或多命中可见子集筛选成功兜底及混合阶段、PA2553 匿名不可见未聚焦根焦点豁免与具名/聚焦/可见/未刷新/敏感/第三节点边界拒绝、有效服务焦点冲突绝不被兜底绕过、未聚焦节点（`rootFocus == node` / `null`）、活动窗密码节点与多命中同窗同包敏感重复框（含二次查表）及密码 `EditorInfo` 快速拒绝（零 IME 请求）、不可见同节点复现与多命中零可见/多可见 17 键诊断、另一候选失败归因、首查/复查重名、四边像素/小数偏差、空或越界矩形、采样前后焦点双向翻转（含 `cloneNodes=false` 原地刷新翻转）、空采样、超时与中断。

### `focus_unavailable` 脱敏诊断快照（`ime_editor_focus_diag`）

仅当活动根与活动窗口均已核实、且最终落入 `focus_unavailable` 时，在顶层响应附带只读脱敏对象 `ime_editor_focus_diag`；成功、非 `focus_unavailable` 失败（含 `sensitive_field`）以及 `cache_clear_failed` / `active_root_missing` / `active_window_missing` 均省略该字段。每次阶段核对最多调用一次 `root.findFocus(FOCUS_INPUT)`；正常成功路径不额外调用 `EditorInfo` 或按名查表。

该对象严格限于下表 17 个固定键，值只允许布尔、非负整数、`null` 或固定小写枚举，不包含任何文本、草稿、包名、资源名、屏幕坐标或窗口号：

| 键名 | 类型 / 固定枚举 | 语义 |
|---|---|---|
| `service_focus_present` | `Boolean` | `serviceFocus != null` |
| `service_focus_refreshed` | `Boolean?` | `serviceFocus.refresh()` 结果；`serviceFocus == null` 时为 `null` |
| `service_focus_focused` | `Boolean?` | `serviceFocus.isFocused`；未刷新成功时为 `null` |
| `service_focus_visible` | `Boolean?` | `serviceFocus.isVisibleToUser`；未刷新成功时为 `null` |
| `service_focus_same_window` | `Boolean?` | `serviceFocus.windowId == window.id`；未刷新成功时为 `null` |
| `service_focus_same_package` | `Boolean?` | `serviceFocus.packageName == pkg`；未刷新成功时为 `null` |
| `service_focus_matches_field` | `Boolean?` | 仅当 `serviceFocus` 已刷新、非密码/非敏感、具名资源非空且兜底已解析出非敏感 `fieldName` 时为相等比较结果，否则 `null` |
| `root_focus_state` | `"missing"` \| `"matches_service"` \| `"matches_window_field"` \| `"matches_both"` \| `"other"` | 单次 `root.findFocus(FOCUS_INPUT)` 与 `serviceFocus` 及兜底唯一候选（`unique` / `filtered_unique`）的归属关系 |
| `window_field_lookup` | `"not_attempted"` \| `"no_contract"` \| `"missing_id"` \| `"resources_unavailable"` \| `"zero_matches"` \| `"ambiguous"` \| `"unique"` \| `"filtered_unique"` | 活动窗 `EditorInfo.fieldId` 兜底查找结果（8 个全可达固定枚举：有效 `serviceFocus` 遇 `root_focus_mismatch` 时为 `"not_attempted"`；多命中筛出唯一可见窗内节点为 `"filtered_unique"`；多命中筛出 `0` 或 `>= 2` 个可见窗内节点为 `"ambiguous"`；密码 `EditorInfo` 与敏感节点直接走 `sensitive_field` 且省略整个诊断对象） |
| `window_field_same_as_service` | `Boolean?` | 仅当 `window_field_lookup` 为 `"unique"` 或 `"filtered_unique"` 且 `serviceFocus != null` 时为 `candidate == serviceFocus`，否则 `null` |
| `window_field_visible` | `Boolean?` | 仅当 `window_field_lookup` 为 `"unique"` 或 `"filtered_unique"` 且 `candidate.refresh()` 成功时为 `candidate.isVisibleToUser`，否则 `null` |
| `window_field_focused` | `Boolean?` | 同上，`candidate.isFocused` |
| `window_field_same_window` | `Boolean?` | 同上，`candidate.windowId == window.id` |
| `window_field_bounds_in_window` | `Boolean?` | 同上，`!bounds.isEmpty && windowBounds.contains(bounds)` |
| `window_field_total_matches` | `Int?` | 未调用 `findNodesByViewId` 时为 `null`；调用后为原始命中总数（`>= 0`） |
| `window_field_visible_in_window_matches` | `Int?` | 未调用 `findNodesByViewId` 时为 `null`；调用后为按统一口径刷新成功、同窗同包、非敏感、资源名匹配、四边非空且落于活动窗内且 `isVisibleToUser == true` 的节点数（`0..total`） |
| `window_field_bounds_in_window_matches` | `Int?` | 未调用 `findNodesByViewId` 时为 `null`；调用后为同上条件但不限 `isVisibleToUser` 的节点数（`0..total`） |

回执保持只读诊断语义，不生成操作引用或输入身份，也不新增 `ime_editor_bounds_reason` 或 `ime_editor_focus_check` 枚举值：

- `ime_editor_bounds.window_field_phase`：仅在至少一个阶段（`serviceFocus == null` 或失效服务焦点转兜底）用过按字段查找的成功回执中出现，取值为 `before_sample`、`after_sample` 或 `both`；两阶段均由有效服务级焦点直接取得时（即使 `node_focused` 为 `false`）省略该字段。
- `ime_editor_bounds.filtered_visible_field`：仅在至少一个阶段经过多命中可见子集筛选（`filtered_unique`）取得候选节点的成功回执中出现在 `ime_editor_bounds` 内，固定为 `true`；未经多命中筛选的成功回执、全部失败回执与顶层响应均省略该字段。
- `ime_editor_bounds.node_focused`：仅在成功回执依赖未报告聚焦的节点（`node.isFocused == false`）时出现在 `ime_editor_bounds` 内，固定为 `false`（此时 `window_field_phase` 可省略，或为 `before_sample`、`after_sample`、`both`）。正常聚焦成功路径与所有失败回执均省略该字段，顶层响应也不出现该字段。

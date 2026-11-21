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

这两个字段仅含固定标记。成功或其他失败原因的回执省略它们。旧候选的 `focus_unavailable` 回执无法追溯到具体检查。

### 服务级输入焦点为空时的字段核对

沿用 `INPUT_NULL`。当服务级输入焦点非空时，原有全部检查与顺序保持不变：节点未报告聚焦仍返回 `focus_unavailable` / `node_not_focused`，活动根返回的输入焦点不等于该节点仍返回 `root_focus_mismatch`。

仅当服务级输入焦点为空时，候选从当前输入连接取得非敏感的 `EditorInfo.fieldId`，在目标应用的资源表中解析全限定 `id/...` 资源名，然后在已核实的活动聚焦应用窗口内按名唯一查找。字段 ID 缺失、非 `id/...` 或无法解析时返回 `missing_id`；窗口内无命中返回 `input_focus_missing`，多命中返回 `ambiguous_id`。[Android 字段 ID 约定](https://developer.android.com/reference/android/view/inputmethod/EditorInfo#fieldId) · [窗口内的资源名查找](https://developer.android.com/reference/android/view/accessibility/AccessibilityNodeInfo#findAccessibilityNodeInfosByViewId(java.lang.String))

命中并完成 `node.refresh()` 后，继续校验 `isVisibleToUser`、窗口号与包名，再查询活动根输入焦点 `rootFocus = root.findFocus(FOCUS_INPUT)`：

- `rootFocus != null && rootFocus != node`：返回 `focus_unavailable` / `root_focus_mismatch`（他节点持焦时绝不放行）。
- `rootFocus == node && !node.isFocused`：返回 `focus_unavailable` / `node_not_focused`（矛盾状态拒绝）。
- 仅当 `rootFocus == null && !node.isFocused` 时，允许节点以未聚焦状态继续执行非密码/非敏感检查、`viewIdResourceName == fieldName`、二次唯一查表、非空且完全落于活动窗口内的四边校验，以及输入法四边采样。

取样前后须取得同一节点、窗口、具名资源、可编辑状态、聚焦状态和屏幕四边（任一字段变化含采样前后焦点翻转均返回 `context_changed`），默认输入法须仍为网关输入法、输入会话须稳定，输入法回调中的字段名须与节点一致且四边按 `Float` 逐边精确匹配（不截断小数）。对照用例覆盖服务级焦点未聚焦、根焦点指向他节点、根焦点等于节点但自报未聚焦、不可见、跨窗/跨包、密码与敏感字段、首查/复查重名、字段名不符、四边像素/小数偏差、空或越界矩形、采样前后焦点翻转、空采样与超时。

回执保持只读诊断语义，不生成操作引用或输入身份，也不新增 `ime_editor_bounds_reason` 或 `ime_editor_focus_check` 枚举值：

- `ime_editor_bounds.window_field_phase`：仅在至少一个阶段用过按字段查找的成功回执中出现，取值为 `before_sample`、`after_sample` 或 `both`。
- `ime_editor_bounds.node_focused`：仅在成功回执依赖未报告聚焦的节点（`node.isFocused == false`）时出现在 `ime_editor_bounds` 内，固定为 `false`（此时采样前后必均走窗口字段查找，`window_field_phase` 为 `both`）。正常聚焦成功路径与所有失败回执均省略该字段，顶层响应也不出现该字段。

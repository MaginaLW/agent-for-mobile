# 微信横屏等效对抗靶标（Pathway 4A + 4B）

独立合成 Android 应用（`dev.magina.wechatparity`，编译 API 35 / 运行 API 36），用于离线隔离模拟器复现 PA2553 微信横屏平行视界全部已知对抗特性，并验收网关只读诊断通道：

- **双同包横屏窗口（含重叠负对照）**：主 Activity 窗口作为左栏（`TYPE_APPLICATION`），附着子窗（`TYPE_APPLICATION_ATTACHED_DIALOG` -> 无障碍侧映射为同包 `TYPE_APPLICATION`）作为右栏；分栏场景严格 X 轴互不重叠（留 16px 间隙），`overlap_right` 场景使双窗在目标编辑框区域真实重叠。
- **反无障碍脱敏与重复 `R.id`**：目标栏内放置 2 个共享同一 `R.id`（`wechat_chat_input` / `wechat_left_input`）的视图——一个 `[0,0,0,0]` 空占位 `View` 与一个 `MATCH_PARENT` 的 `EditText`；自定义 `AccessibilityDelegate` 强制剥离 `viewIdResourceName = null`、`isFocused = false`、`isVisibleToUser = false`（死路场景额外清零 `boundsInScreen = [0,0,0,0]`、`editable = false`、`inputType = TYPE_NULL`）。
- **API 34 `requestTextBoundsInfo` 不支持但 `requestCursorUpdates` 可用**：自定义 `InputConnectionWrapper` 对 API 34 `requestTextBoundsInfo` 固定返回 `TextBoundsInfoResult.CODE_UNSUPPORTED`（复现 `e994c71` 的 `no_verified_geometry`），同时保留标准 2 参/1 参 `requestCursorUpdates()`（及仅支持 API 21 1 参降级的变体）。
- **`TYPE_NULL` 兜底连接对照**：焦点停留在非编辑器可聚焦 `View` 上，触发系统默认 `InputType.TYPE_NULL` 连接，验证 4B 分类为 `input_type_null` 而非 `missing_id / field_id_unresolved`。

## 编译构建（Build SDK 35 + JDK 21）

在新建的私有构建目录执行下列 PowerShell 命令（不把构建产物留在仓库内）：

```powershell
$Fixture = (Resolve-Path 'docs/runs/fixtures/cursor-anchor-wechat-parity').Path
$Sdk = $env:ANDROID_HOME
$PlatformJar = "$Sdk\platforms\android-35\android.jar"
$BuildTools = "$Sdk\build-tools\35.0.0"
$JdkBin = "$env:JAVA_HOME\bin"
$env:PATH = "$BuildTools;$JdkBin;$env:PATH"

New-Item -ItemType Directory classes,dex -Force | Out-Null
aapt2 compile --dir "$Fixture\res" -o res.zip
aapt2 link -I $PlatformJar --manifest "$Fixture\AndroidManifest.xml" -o unsigned.apk res.zip
javac --release 17 -encoding UTF-8 -g:none -classpath $PlatformJar -d classes "$Fixture\WeChatParityActivity.java"
jar cf classes.jar -C classes .
d8 --min-api 34 --lib $PlatformJar --output dex classes.jar
jar uf unsigned.apk -C dex classes.dex
zipalign -f 4 unsigned.apk aligned.apk
apksigner sign --ks $FixtureKey --ks-pass pass:android --out wechat-parity.apk aligned.apk
apksigner verify wechat-parity.apk
```

## 隔离 API 36 AVD 验收矩阵

使用[本地测试台](../../../runbooks/本地测试台.md)独占单槽 API 36 AVD（`ADB_USB=0`、`ADB_MDNS=0`、`ADB_EMU=1`、私有端口 `tcp:localhost:<port>` 非 5037、启动前空 `adb devices`）。安装待测网关 APK 与本靶标 APK，核对两个不同 UID 与 APK 摘要；保存原始默认/启用 IME 与无障碍设置后启用网关无障碍与 `GatewayIme`。

对每个场景以新任务启动，等 `files/<case>.json` 落盘后再调用网关只读 MCP 工具 `keyboard_state`：

```powershell
& $Adb @target shell am start -W -f 0x10008000 -n dev.magina.wechatparity/.WeChatParityActivity --es lab_case $case
& $Adb @target shell run-as dev.magina.wechatparity cat "files/$case.json"
```

| 场景 | 靶标配置 | 预期网关回执 |
|---|---|---|
| `disjoint_right_dead_end` | 双窗互不重叠、右窗 2 个同 `R.id` 无名 `[0,0,0,0]` 节点、`requestTextBoundsInfo -> CODE_UNSUPPORTED` | 1) `probe_editor_origin=true` -> `no_verified_geometry`（靶 `text_bounds_requests=1`）；2) `probe_editor_bounds=true` -> `focus_unavailable/node_not_visible` + 4B `ime_editor_node_telemetry`（`inspected_matches=2, unnamed_matches=2, empty_bounds_matches=2`）；3) `probe_cursor_anchor=true` -> **通过**：归属 `pane="right"`、`request_mode="filtered_2arg"`、屏幕 `editor_bounds` 与靶 `target_rect` 逐边一致、`insertion_marker` 落于框内 |
| `disjoint_right_valid_node` | 同上，但右窗真实 `EditText` 保留真实 `boundsInScreen`/`editable`/`inputType`（仍剥离 `viewIdResourceName/focused/visible`） | 1) `probe_editor_bounds=true` -> 4B `ime_editor_node_telemetry` 报 `bounds_in_window_matches=1, input_type_matches=1, same_as_service_matches=1`；2) `probe_cursor_anchor=true` -> **通过**（`pane="right"`），且 `a11y_cross_check.exact_editor_bounds_matches=1, input_type_and_geometry_matches=1` |
| `disjoint_right_legacy_1arg` | 同 `disjoint_right_dead_end`，且 2 参 `requestCursorUpdates(mode, filter)` 返回 `false`，仅 1 参可用 | `probe_cursor_anchor=true` -> 自动降级 1 参（`request_mode="legacy_1arg"`, `filtered_accepted=false`, `legacy_accepted=true`）并 **通过**（`pane="right"`） |
| `disjoint_left_dead_end` | 双窗互不重叠、焦点在左窗（同受反无障碍脱敏与 `CODE_UNSUPPORTED`） | `probe_cursor_anchor=true` -> **通过**并归属 `pane="left"` |
| `overlap_right` | 同包双窗在编辑框区域真实重叠（`windows_disjoint=false`） | `probe_cursor_anchor=true` -> **fail-closed 拒绝**：`ime_cursor_anchor=null`，`ime_cursor_anchor_reason="ambiguous_window_overlap"` |
| `type_null_decor` | 焦点停留在非编辑普通 `View`（系统 `TYPE_NULL` 连接） | `probe_editor_bounds=true` 与 `probe_cursor_anchor=true` 均 **fail-closed 拒绝**：`reason="input_type_null"` + `ime_editor_contract_diag.input_type_is_null=true`，零 `requestCursorUpdates` 调用，绝不误报 `field_id_unresolved` |

收尾时逐项还原并读回原默认/启用输入法与无障碍设置，停止自建网关、转发、模拟器与私有 ADB，并确认端口释放。

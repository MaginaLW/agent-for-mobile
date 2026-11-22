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
| `disjoint_right_dead_end` | 双窗互不重叠、右窗 2 个同 `R.id` 无名 `[0,0,0,0]` 节点、`requestTextBoundsInfo -> CODE_UNSUPPORTED` | 1) `probe_editor_origin=true` -> `no_verified_geometry`（靶 `text_bounds_requests=1`）；2) `probe_editor_bounds=true` -> `same_bounds` + 4B `ime_editor_node_telemetry`（`inspected_matches=2, unnamed_matches=2, empty_bounds_matches=2`）；3) `probe_cursor_anchor=true` -> **通过**：归属 `pane="right"`、`request_mode="filtered_2arg"`、屏幕 `editor_bounds` 与靶 `target_rect` 逐边一致、`insertion_marker` 落于框内 |
| `disjoint_right_valid_node` | 同上，但右窗真实 `EditText` 保留真实 `boundsInScreen`/`editable`/`inputType`（仍剥离 `viewIdResourceName/focused/visible`） | 1) `probe_editor_bounds=true` -> `focus_conflict` + 4B `ime_editor_node_telemetry` 报 `bounds_in_window_matches=1, input_type_matches=1, same_as_service_matches=1`；2) `probe_cursor_anchor=true` -> **通过**（`pane="right"`），且 `a11y_cross_check.exact_editor_bounds_matches=1, input_type_and_geometry_matches=1` |
| `disjoint_right_legacy_1arg` | 同 `disjoint_right_dead_end`，且 2 参 `requestCursorUpdates(mode, filter != 0)` 返回 `false`，仅 1 参（Android 16 经 `cursorUpdateFilter == 0` 派发）可用 | `probe_cursor_anchor=true` -> 自动降级 1 参（`request_mode="legacy_1arg"`, `filtered_accepted=false`, `legacy_accepted=true`）并 **通过**（`pane="right"`） |
| `disjoint_left_dead_end` | 双窗互不重叠、焦点在左窗（同受反无障碍脱敏与 `CODE_UNSUPPORTED`） | `probe_cursor_anchor=true` -> **通过**并归属 `pane="left"` |
| `overlap_right` | 同包双窗在编辑框区域真实重叠（`windows_disjoint=false`） | `probe_cursor_anchor=true` -> **fail-closed 拒绝**：`ime_cursor_anchor=null`，`ime_cursor_anchor_reason="ambiguous_window_overlap"` |
| `type_null_decor` | 焦点停留在非编辑普通 `View`（系统 `TYPE_NULL` 连接） | `probe_editor_bounds=true` 与 `probe_cursor_anchor=true` 均 **fail-closed 拒绝**：`reason="input_type_null"` + `ime_editor_contract_diag.input_type_is_null=true`，零 `requestCursorUpdates` 调用，绝不误报 `field_id_unresolved` |

收尾时逐项还原并读回原默认/启用输入法、无障碍与旋转设置，卸载双包并在 `pm list packages -u` 确认清空，停止自建网关、转发、模拟器与私有 ADB，并确认端口释放与临时 AVD 删除。

## 2026-11-22 隔离 Android 16 (API 36) 实测结果（`receipts.json`，`schema_version=2`）

- **运行环境与隔离证明**：`pixel_5` 横屏（`2340x1080`），`ro.build.version.sdk=36`，`ro.kernel.qemu=1`，私有 ADB 端口 `5049`（非 `5037`），AVD 控制台/传输端口 `5596/5597`，本地网关转发端口 `18854`，`ADB_USB=0`、`ADB_MDNS=0`、`ADB_EMU=1`，启动前 `adb devices` 为空（`initial_adb_devices_empty=true`），总耗时 `151.28s`。
- **在机 APK 与独立 UID 核验**：
  - `dev.magina.gateway`（Debug APK，源码 `dfb948151b61fd93bfa8633fe8b329c64c2e1f4b`，UID `10216`）：SHA-256 `73b778b0467a5d7c1562128abd329087788ea9631ed4037af67779bef505a16a`（`gateway_hash_matched=true`）
  - `dev.magina.wechatparity`（UID `10217`）：SHA-256 `c22b07694a8a558d7b4915af9bb60cdfdc64d28497475282672975e1bb21942a`（`fixture_hash_matched=true`）
- **全部 6 场景结果**（所有场景 `foreground_app` 均核验 `window_topology="same_app_multi"` 且恰好 2 个 `dev.magina.wechatparity` `TYPE_APPLICATION` 窗口、零 Launcher；所有场景 `ui_find(role="input")` 均真实抛 `E_NOT_FOUND` 且 `ui_snapshot.input_elements_count=0`，零伪造 ref）：

| 场景 | 双窗（`left` / `right`） | 4B `probe_editor_bounds` & 4A `probe_cursor_anchor` | 生产 `ui_find` & `ui_snapshot` 透出 | 结论 |
|---|---|---|---|---|
| `disjoint_right_dead_end` | `[136,96,929,966]` / `[977,144,2340,1014]` | `same_bounds` + 4B (`inspected=2/2, empty=2`)；`probe_editor_origin -> no_verified_geometry`；`probe_cursor_anchor`: `win=15, pane="right", filtered_2arg`, `[1001,253,2316,352]` == 靶 (`ic=3/0`) | `source="ime_cursor_anchor"`, `id=null`, `bounds=[1001,253,2316,352]`, `window_id=15`, `pane="right"` | **PASS** |
| `disjoint_right_valid_node` | `[136,96,929,966]` / `[977,144,2340,1014]` | `focus_conflict` + 4B (`in_window=1, editable=1, input_type=1`)；`probe_cursor_anchor`: `win=18, pane="right"`, `a11y_cross_check=1/1/1` (`ic=1/0`，生产路径零降级) | `source="a11y"`, `id="18\|\|EditText\|...\|1001,253,2316,352"`, `bounds=[1001,253,2316,352]`, `window_id=null, pane=null` | **PASS** |
| `disjoint_right_legacy_1arg` | `[136,96,929,966]` / `[977,144,2340,1014]` | `same_bounds`；2 参拒 -> 1 参降级 (`filtered=3, legacy=3`)，`win=21, pane="right", legacy_1arg`, `[1001,253,2316,352]` == 靶 | `source="ime_cursor_anchor"`, `id=null`, `bounds=[1001,253,2316,352]`, `window_id=21`, `pane="right"` | **PASS** |
| `disjoint_left_dead_end` | `[136,96,929,966]` / `[977,144,2340,1014]` | `same_bounds`；`probe_cursor_anchor`: `win=23, pane="left", filtered_2arg`, `[160,205,905,304]` == 靶 (`ic=3/0`) | `source="ime_cursor_anchor"`, `id=null`, `bounds=[160,205,905,304]`, `window_id=23`, `pane="left"` | **PASS** |
| `overlap_right` | `[136,96,1899,966]` / `[687,144,2340,1014]`（重叠） | `same_bounds`；`probe_cursor_anchor -> ambiguous_window_overlap` (`ic=3/0`) | 严格退回 `source="ime_only"`, `id=null, bounds=null, window_id=null, pane=null` | **PASS (fail-closed)** |
| `type_null_decor` | `[136,96,929,966]` / `[977,144,2340,1014]` | `probe_editor_bounds` 与 `probe_cursor_anchor` 均 `input_type_null` (`autofill_id_present=true/virtual=false`, `ic=0/0`) | 严格退回 `source="ime_only"`, `id=null, bounds=null, window_id=null, pane=null` | **PASS (fail-closed)** |

- **收尾核验**：`6/6` 项设置逐字还原相等，双包卸载并在 `pm list packages -u` 清空，`emulator_stopped=true`、`isolated_adb_stopped=true`、`ports_released=true`、`avd_deleted=true`、`cleanup_errors=[]`。
- **离线验真**：
  - `python -B verify.py --receipts receipts.json --require-production-ui` -> `{"verified": true, "scenarios": 6}`
  - `python -B verify.py --self-test` -> `SELF-TEST PASS: 1 positive / 10 negative mutations caught`
- **已证实边界**：
  - **优势**：零新权限、零系统角色接管（不切 `ROLE_ASSISTANT` / `autofill_service`）、零可见 IME UI，直接在现有 `GatewayIme` + `GatewayA11yService` 内绕开反无障碍剥离与 `requestTextBoundsInfo -> CODE_UNSUPPORTED`，在横屏互不重叠双窗上以 0px 误差精确归属左/右窗；同时 4B 单次可读回 2 个无名节点的完整非短路遥测及 API 36 `EditorInfo.getAutofillId()` 存在性。
  - **硬限制**：`CursorAnchorInfo` 回调无 AIDL 请求编号（须依赖会话世代/窗口稳定前后核对）；双窗在目标编辑框处重叠时必然且必须 fail-closed 拒绝（`ambiguous_window_overlap`）；仍依赖真实 PA2553 微信的 `MMEditText`/`InputConnection` 正常响应该十年标准 `requestCursorUpdates()` API（待用户授权的真机只读探针最终实证）。

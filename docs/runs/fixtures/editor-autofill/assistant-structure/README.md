# 已持焦右框的系统助理结构

**2026-11-22，API 36 隔离模拟器已完成全部 7 场实测并收尾。** 系统助理（`VoiceInteractionSession` + `SHOW_WITH_ASSIST` + `setUiEnabled(false)`）在右框持续持焦、切换输入法且目标应用零配合的条件下，成功按需采得一份新的普通 `AssistStructure`，输入连接与窗口焦点全程未被打断，且绕过了 `AccessibilityDelegate` 的节点剥离；同时实证确认普通助理路径中 `ViewNode.getAutofillId()` 为 `null`，匿名编辑框缺少可与 `EditorInfo` 交叉比对的共同字段标识（`strict_selected_side = null`），且 `FLAG_SECURE` 严格按 `assist_blocked` 失败关闭。[脱敏回执原件](receipts.json) · [核对脚本](read_result.py)

## API 36 隔离实测结果

在全新 API 36 横屏模拟器（2340 × 1080，私有 ADB `ADB_USB=0` / `ADB_MDNS=0` / `ADB_EMU=1`，初始空表，`ro.kernel.qemu=1`）上安装两份独立一次性 RSA-3072 证书签名的合成 APK：

- 靶应用 `dev.magina.autofilltarget`（UID `10216`），SHA-256 `f6cd715a61d76e0cfe57f1c3e2e8c7b007e3f9bc47227d42615f2652b628e26d`
- 观察器 `dev.magina.autofillobserver`（UID `10217`），SHA-256 `971a1fc52334573b31b92c788ab93a67db13030ce02b5a2138532033b28410db`

所有阶段均关闭会话 UI（`setUiEnabled(false)`）与截图（`setDisabledShowContext(SHOW_WITH_SCREENSHOT)`），不调用任何正文读取接口，仅在合成靶包范围内遍历。

| 场景 / 阶段 | 请求标志 | 结果判定 | 关键实测观测（屏幕像素 `[左, 上, 右, 下]`） |
|---|---|---|---|
| **核心 A2 · `assist`**（持焦切 IME 后匿名右框） | `SHOW_WITH_ASSIST` | `CURRENT_ASSIST_STRUCTURE` | 切换后自动填充回调 0 次（`NO_NEW_CALLBACK`）；助理按需采得新树（`ime_start=192583 < request=217784 < acquired=217793 <= completed=217794 <= received=217809 <= close=221299`），聚焦框 `[2100, 32, 2300, 102]` 与靶回执一致；`current_on_receive=true`、`current_at_close=true`，前后探针 `-3/-4` 均命中同一连接 `wire=4`；ART 轨迹 `onProvideStructure=2`、`onProvideAutofillStructure=0`、`onCreateInputConnection=0`、`onFocusChanged=0`、`onWindowFocusChanged=0`；**`ViewNode.getAutofillId() == null`、`has_resource_id=false`、`common_native_id=false`、`strict_selected_side=null`** |
| **核心 A2 · `noflag`**（零标志负控） | `0` | `NO_STRUCTURE` | 回调 1 次但 `structure_null=true`、`target_trees_examined=0`；ART 轨迹 `onProvideStructure=0`、`onCreateInputConnection=0`、`onFocusChanged=0`；收尾探针 `-4` 仍命中同一 `wire=4` |
| **离线过期回放** | 复用 `assist` 样本 | `STALE_OR_UNORDERED_STRUCTURE` | 将 `assist` 采集时间戳回放到 `noflag` 的较晚请求窗口，被时间戳单调序检查拒绝 |
| **对抗 1 · `secure`**（`FLAG_SECURE` 退出） | `SHOW_WITH_ASSIST` | `ASSIST_BLOCKED` | 靶窗声明 `FLAG_SECURE`；根 `WindowNode` 报告 `root_assist_blocked=true`、`assist_blocked=true`、`editors=[]`、`focus_count=0`，严格 fail-closed |
| **对抗 2 · `ccoptout`**（内容捕获退出） | `SHOW_WITH_ASSIST` | `CURRENT_ASSIST_STRUCTURE` | 靶根与两框设为 `IMPORTANT_FOR_CONTENT_CAPTURE_NO_EXCLUDE_DESCENDANTS`（值 `8`）；API 36 普通助理路径不以该属性阻断结构，`assist_blocked=false`、仍采得 2 框且聚焦框匹配右框 |
| **对抗 3 · `obfuscated`**（微信式无障碍剥离） | `SHOW_WITH_ASSIST` | `CURRENT_ASSIST_STRUCTURE` | 靶 `EditText` 安装 `AccessibilityDelegate` 将 `focused=false`、`visibleToUser=false`、`viewIdResourceName=null` 全部剥离；`AssistStructure` 直接走 `View.onProvideStructure`，**绕过无障碍剥离**，仍采得真实 `focused=true` 与右框 `[2100, 32, 2300, 102]` |
| **对抗 4 · `multiwin`**（同 Activity 双 OS 窗） | `SHOW_WITH_ASSIST` | `MULTIWIN_RIGHT_DISTINGUISHED` | `SplitWindowActivity`（左侧主窗 `[176, 40, 1176, 520]` + 右侧可聚焦非模态 Dialog 窗 `[1300, 40, 2300, 520]`）；单树含 `window_count=2`，两窗几何互不相交（`window_bounds_disjoint=true`），右侧窗唯一含聚焦框 `[2060, 72, 2260, 142]`，左侧窗含未聚焦左框 `[216, 72, 416, 142]`；匿名框 `strict_shared_id=false` |
| **对抗 5 · `multiwin2`**（同包双 Activity 双 Task） | `SHOW_WITH_ASSIST` | `MULTIWIN_RIGHT_DISTINGUISHED` | `LeftPaneActivity`（Task 13 全屏左框 `[40, 32, 240, 102]`）+ 半透明 `RightPaneActivity`（Task 14 右半窗 `[1340, 40, 2340, 520]`，右框 `[2100, 72, 2300, 142]`）；`onHandleAssist` 回调 2 次（`count=2`），`index=0` 为 `.RightPaneActivity`（`state.isFocused()=true`、`focus_count=1`），`index=1` 为 `.LeftPaneActivity`（`state.isFocused()=false`、`focus_count=0`），`distinct_activity_ids=2`、`focused_activity_count=1`、`editor_bounds_disjoint=true`（因左窗全屏覆盖底层，`window_bounds_disjoint=false` 属预期）；匿名框 `strict_shared_id=false` |

### 角色恢复与收尾读回

- 入场角色持有者读回：`assistant_holder_before = com.google.android.googlequicksearchbox`
- 实验期间选择并绑定：`assistant_role_during = dev.magina.autofillobserver`，`voice_during = dev.magina.autofillobserver/.AssistService`，确认 `SyntheticAssist: service_ready`
- 退场顺序：先将 `android.app.role.ASSISTANT` 恢复回 `com.google.android.googlequicksearchbox` 并等待 `VoiceInteractionManagerService` 落定，再恢复输入法与自动填充服务并卸载两包，随后核对并恢复其余设置，最后无条件独立读回：
  - `assistant_holder_after = com.google.android.googlequicksearchbox`（`assistant_role_restored = true`）
  - 全部 13/13 项设置读回与入场基线逐字一致
  - `cleanup_errors = []`，两包卸载后 `pm list packages -u` 均为空，模拟器与私有 ADB 均停止，三个专属端口（`5071 / 5604 / 5605`）零监听，临时 AVD 已清除（总耗时 511 秒）

### 结论与边界

1. **已证实的能力**：在 API 36 上，拥有系统助理角色的应用可在不移动焦点、不打断输入连接、无需目标应用配合的前提下按需采得新鲜 `AssistStructure`；该路径绕过 `AccessibilityDelegate` 的节点剥离，遵守 `FLAG_SECURE` 失败关闭，并能凭 `AssistState.isFocused()`、`ActivityId`、`ActivityComponent` 与 `WindowNode` 几何区分同包双窗 / 双 Activity 的左右窗格。
2. **明确的硬限制**：
   - **匿名编辑框无跨通道共同标识**：API 36 实测确认普通助理树（`View.dispatchProvideStructureForAssistOrAutofill(..., forAutofill=false)`）不调用 `setAutofillId()`，故 `ViewNode.getAutofillId()` 恒为 `null`（而 `EditorInfo.getAutofillId()` 非空）。对无资源 ID 的编辑框，本路径不能提供与当前 `InputConnection` 逐字段交叉验证的共同 ID（`common_native_id=false`、`strict_selected_side=null`）；若用于定位，只能依赖 `AssistState.isFocused()` + `ViewNode.isFocused()` + 窗口/控件几何与 `inputType` 一致性。
   - **额外高侵入系统角色**：需要接管系统唯一 `android.app.role.ASSISTANT` 角色（替换系统默认语音助理），现有生产网关未启用该角色；PA2553 OriginOS 6 上是否允许第三方接管助理角色、以及微信实际页面是否声明 `FLAG_SECURE` 或覆写 `onProvideStructure` 均尚未在真机验证。

## 历史失败与修复记录

- **初版 `234ae17`（停在角色选择）**：宿主安装循环误将 `$role` 用作迭代变量覆盖了 `'android.app.role.ASSISTANT'`，导致 `select-assistant` 与 `restore-assistant-role` 均把 `'observer'` 传给 `cmd role` 而失败，终场缺少角色持有者读回。13 项设置读回、两包卸载及进程/端口收尾均正常，可用 `python -B read_result.py --setup-only <首轮原件目录>` 复核。此外初版 `prepare.py` 为 `SilentRecognition` 声明了 Android SDK 中不存在的 `BIND_SPEECH_RECOGNITION_SERVICE` 权限，且 `GeometrySession.java` 原先拒绝 `state.getCount() != 1` 与 `window_count != 1`。
- **修复版首跑（停在最后一场 `multiwin2` 启动参数）**：前 6 场（`assist`、`noflag`、`secure`、`ccoptout`、`obfuscated`、`multiwin`）全部采得并完成 13/13 设置与角色持有者恢复读回，第 7 场 `am start` 误用了不支持的 `--activity-new-task`。改为 `-f 0x18000000` 后复跑 7/7 全绿收尾（上述实测结果）。

## 离线复核与复现

```powershell
# 1. 离线核对本目录提交的脱敏回执（零设备、零模拟器）
python -B docs/runs/fixtures/editor-autofill/assistant-structure/read_result.py --receipts docs/runs/fixtures/editor-autofill/assistant-structure/receipts.json

# 2. 运行离线自测（prepare 校验、脚本角色常量不变量、多窗与 fail-closed 变异、回执核验）
python -B docs/runs/fixtures/editor-autofill/assistant-structure/test_offline.py

# 3. 独立构建双证书实验 APK（需显式指定含 platforms/android-35 与 build-tools/35.0.0 的 SDK 及 JDK 21）
python -B docs/runs/fixtures/editor-autofill/assistant-structure/build.py <新构建目录> --sdk <BuildSdk> --jdk <Jdk21>

# 4. 在全新隔离 API 36 模拟器执行完整 7 场并全量收尾（绝不触碰 5037 端口或真机）
pwsh -NoProfile -File docs/runs/fixtures/editor-autofill/assistant-structure/run_isolated.ps1 `
    -BuildDir <新构建目录> -OutputDirectory <新运行目录> `
    -TestbenchSdk <TestbenchSdk> -JavaHome <Jdk21> -AdbServerPort 5071 -ConsolePort 5604

# 5. 对原始运行目录执行完整认证（含 ART 轨迹与日志）
python -B docs/runs/fixtures/editor-autofill/assistant-structure/read_result.py <新运行目录>
```

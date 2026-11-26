# 系统内置 App（vivo PA2553 / Android 16 / OriginOS）

> **事实边界**：
> - **包名与入口实测**：2026-11-26 在 PA2553（Android 16 / OriginOS）上经 `pm list packages -s`、`dumpsys package`（`installed=true`、`hidden=false`、`enabled=0` 及 `MAIN`+`LAUNCHER`）与 `dumpsys activity provider com.bbk.launcher2`（桌面图标组件）三源交叉只读实测确认。
> - **宏真机验收转正**：阶段 6B-2 全部 7 枚系统内置 App 只读宏已于 2026-11-27 在 PA2553（`5750321` / `0.2.0-m3`）完成同签覆盖安装与 Wave 1 + Wave 1B 串行真机验收（全部实调 `skill_macro_exec` `completed`、所有 `origin=macro` 子步全 `OK`、`ConfirmOverlay == 0`），正式转正为 `"verified": "2026-11-27"`（见 [11-27 阶段 6A+6B-2 验收](../../runs/2026-11-27-PA2553-阶段6A冷启与6B-2系统内置App真机验收.md)）。

## 1. PA2553 实测系统内置 App 包名表（2026-11-26）

### 1.1 已纳入技能包（`apps.json` + `<queries>` 1:1 + 只读宏）

| 中文别名 | 精确包名 | 主 Launcher Activity | 对应只读宏（`verified: "2026-11-27"`） | 接入方式与守卫要点 |
|---|---|---|---|---|
| 设置 | `com.android.settings` | `com.android.settings/.Settings` | `settings_state_readonly_check` | **L1 API-first**：直接走 `system_get_state`，禁止进入设置 UI 触发安全中心回收无障碍 |
| 相册 | `com.vivo.gallery` | `com.vivo.gallery/com.android.gallery3d.vivo.GalleryTabActivity` | `gallery_readonly_prepare` | 查最新照片/截图元信息优先 `media_query`；UI 浏览需禁删/禁改/禁外发 |
| 闹钟时钟 | `com.android.BBKClock` | `com.android.BBKClock/.Timer` | `clock_readonly_prepare` | 只读查看列表；严禁新增、修改、开关或删除闹钟，禁启停计时器 |
| 日历 | `com.bbk.calendar` | `com.bbk.calendar/.FakeMainActivity` | `calendar_readonly_prepare` | 只读查看日期/视图；严禁新建、编辑、删除日程或订阅日历 |
| 原子笔记 | `com.android.notes` | `com.android.notes/.Notes` | `notes_readonly_prepare` | 仅核对结构元数据，严禁摘录私人笔记正文，严禁新建/编辑/删除/分享 |
| 文件管理 | `com.android.filemanager` | `com.android.filemanager/.FileManagerActivity` | `filemanager_readonly_prepare` | 只读浏览目录结构；严禁删除、移动、重命名、安装 APK 或一键清理 |
| 计算器 | `com.android.bbkcalculator` | `com.android.bbkcalculator/.Calculator` | `calculator_readonly_prepare` | 只读核对面板状态；未获明确计算指示时不主动按键或清空历史 |

### 1.2 同轮实测确认但暂未注册的内置 App（按需再接入）

以下内置 App 同于 2026-11-26 在 PA2553 经三源交叉实测确认具备 `MAIN+LAUNCHER` 与桌面入口，当前保持按需接入原则，未写入 `apps.json` 与 `<queries>`：

| 常见名称 | PA2553 实测包名 | 主 Launcher Activity |
|---|---|---|
| 天气 | `com.vivo.weather` | `com.vivo.weather/.WeatherMain` |
| 录音机 | `com.android.bbksoundrecorder` | `com.android.bbksoundrecorder/com.android.activity.ReclistActivity` |
| 浏览器 | `com.vivo.browser` | `com.vivo.browser/.BrowserActivity` |
| 相机 | `com.android.camera` | `com.android.camera/.CameraActivity` |
| 音乐 | `com.android.bbkmusic` | `com.android.bbkmusic/.WidgetToTrackActivity` |
| 电子邮件 | `com.vivo.email` | `com.vivo.email/.activity.Welcome` |
| 联系人 | `com.android.contacts` | `com.android.contacts/.DialtactsContactsEntryActivity` |
| 应用商店 | `com.bbk.appstore` | `com.bbk.appstore/.ui.AppStore` |

## 2. OriginOS / PA2553 注意事项

1. **shell 侧查询过滤限制**：PA2553（Android 16 / OriginOS）在 `adb shell`（uid 2000）下执行 `cmd package resolve-activity` / `query-activities -a MAIN -c LAUNCHER` 仅返回 `com.android.settings/.Settings` 与 `com.android.BBKClock/.Timer`（连同已验证可启动的 `tv.danmaku.bili`、`com.xingin.xhs`、`com.tencent.mm` 亦返回 `No activity found`，属 ROM 对 shell 命令的过滤限制）。网关应用内 `app_launch` 调用 `PackageManager.getLaunchIntentForPackage(pkg)`，依赖 `AndroidManifest.xml` `<queries><package>` 的精确 1:1 声明（严禁 `QUERY_ALL_PACKAGES`）。
2. **避开系统设置 UI 触发安全中心撤销无障碍**：`com.vivo.safecenter` 会在 `com.android.settings` 位于前台时监控并移除第三方无障碍（见 [vivo-originos.md](../android/vivo-originos.md)）。查询蓝牙、Wi-Fi、飞行模式、电量、网络、屏幕、音量、亮度时，一律优先使用 `settings_state_readonly_check` 或 `system_get_state`（L1 API-first）；且 `android.settings.BLUETOOTH_SETTINGS` 在 OriginOS 上不可靠（见 [deeplinks.md](deeplinks.md)）。
3. **相册 L1 媒体库捷径**：仅获取最新图片或截图的文件名、时间、相册名与 `content://` URI 时，优先 `media_query`（需 `READ_MEDIA_IMAGES` 运行时权限，重装后需留意权限是否被重置）；仅当任务需要查看相册 UI 时才调用 `gallery_readonly_prepare`。
4. **系统拦截弹窗**：跨应用启动系统内置 App 仍可能命中 `com.vivo.appfilter`，前置宏检测到后会返回 `handoff_required(blocker_detected=true)`，必须停下交由现场用户处理。
5. **留置前台导致 `window_id_mismatch` 拦截**：2026-11-27 PA2553 实测中，前序任务将 `com.android.filemanager` 留置前台时，下一轮直接执行 `notes_readonly_prepare` 观测到 `foreground_known=false`（`foreground_reason=window_id_mismatch`），触发 `SafetyGate` fail-closed 拒绝 W 级 `skill_macro_exec`（`E_BLOCKED`）；先经 `bootstrap-gateway.ps1 -ReturnHome` 冷启/返回桌面清离 `filemanager` 前台后再测独立 App 即一次性通过（21s `success`，5/5 子步 `OK`）。串行切换独立内置 App 验收或前序停留在文件管理时，务必前置返回桌面或冷启切离后再派单。

## 3. 只读与隐私约束

- **绝对只读**：不得在设置、闹钟时钟、日历、原子笔记、文件管理、相册或计算器中执行任何写入、删除、开关切换、文件移动/重命名/清理/安装或分享动作。
- **隐私最小披露**：原子笔记、日历日程与文件管理中的私人正文、个人备忘与私密媒体内容不得写入报告或日志；仅核对前置拉起与结构元数据时仅报告包名、拓扑、遮挡与元素数量。
- **宏转正纪律**：上述 7 枚系统内置 App 只读宏已于 2026-11-27 通过 PA2553 同签重装与 Wave 1 + Wave 1B 真机验收，正式转正为 `"verified": "2026-11-27"`；后续若新增内置 App 宏，在通过真机验收前仍须保持 `"verified": ""` 与 `"status": "candidate_unverified"`。

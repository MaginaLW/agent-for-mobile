# T-L1 C1b：平板 pure-a11y 只读采集

## 目的与只读边界

在 PA2553 日常横屏“应用多窗”现场，按 [C1b observation 合同](../contracts/tablet-layout-observation-c1b-v1.md)采两帧 accessibility 拓扑。
只验 window/root/subtree/focus/IME；navigation、conversation、target、layout、P0、execution 恒为 false/unsupported。

runner 不执行 input/tap/`am start`/`settings put`/uninstall，不截图、不 OCR，不启动目标 App，不关闭应用多窗。
C1b 不含危险动作；手机侧发送/支付/删除的两段式确认不受影响。

## 前置

- 设备：PA2553 横屏，微信应用多窗双窗口在前台，键盘隐藏；USB 只连这一台。
- 探针无障碍服务已开启（runner 以探针自报的 `a11y_service_ready` 为准；vivo 的 `dumpsys accessibility` 绑定列表可能不列出它）。首次安装后先点开桌面图标「平板 C1b 只读探针」，再到 设置 → 快捷与辅助 → 无障碍 开启，i管家弹窗选“允许”。若权限随后被 vivo 安全中心撤销，目前没有已知解法，见[运行记录](../runs/2026-10-09-C1b-真机-vivo安全中心撤销无障碍.md)；先解阻，不反复开启或重跑。runner 只检查，不改设置；未就绪时 exit 2。
- 工作树 clean；固定完整 HEAD 记为本次 `commit_sha`。APK 内嵌构建 SHA 记为 `producer_commit_sha`：须是 HEAD 的祖先且两者之间 `app/` 无改动；只改脚本或文档不必重装。`run.json` 同时记录这两个 SHA。
- PC Suite 手机助手若占用 TCP 5037 且其 adb 版本不同，可能与 `-AdbPath` 冲突。需要时由用户结束该会话；runner 不终止外部进程。
- 真机运行前，按 [backlog §7.3](../backlog.md) 先报就位、再等用户开跑令。

## 命令

```powershell
pwsh -NoProfile -File scripts/run-tablet-c1b.ps1 -AdbPath <adb.exe 绝对路径> `
  [-Serial <serial>] [-ApkPath <已构建 APK>] [-SkipBuild] [-RequireInstalledApkMatch] [-RunId <id>]
```

流程：检查工作树 → 取与派单共用的全局设备锁 → 确认恰好一台设备 → Gradle 构建 `:tablet-c1b-probe:assembleDebug`
→ `adb install -r -t`（不卸载；设备上已是同一 APK 时跳过，因为重装会让系统解绑无障碍服务，需在设置里关闭再打开「平板 C1b 只读探针」）→ 检查无障碍服务 → `run-tablet-intake` 生成 T0-L v5
→ 经 ContentProvider 写 T0、读 `c1`、宿主等待至少 900 ms、读 `c2`、读 result。

T0 通过 `adb shell -T content write --uri '<URI>'` 接收原始 stdin，禁用 PTY 并在 EOF 后读取远端输出与退出状态；需要 shell protocol 支持，不支持即失败，不回退 `exec-in`。`exec-in` 会再次转义已加引号的 URI，且不提供同等远端结果核验。T0 写入须 exit 0、stdout/stderr 均为空（含空白也拒绝），随后仍以绑定的 `status=ready_c1` 验证会话；错误只记输出字节数，不保存可能回显的会话标识。只证明离线传输契约，不替代真机验收。

- 从 `c1` 起整段采集不超过 15 秒；`c1`、`c2` 各读一次，不补拍。
- 一次调用只采一次，不自动重试。每个新运行使用新 run_id，并重新满足就位与开跑条件；已有证据目录不得覆盖。
- 探针模块的 Gradle 构建检查保证 APK 只含只读代码；`-SkipBuild`/`-ApkPath` 只用于满足上述构建身份约束的 APK。
- 保留当前已就绪的探针时，另传 `-RequireInstalledApkMatch`：只有已安装 APK 的 SHA-256 与本地 APK 相同才跳过安装并继续；缺包、路径或哈希读取失败、不匹配均在安装前失败并保留本轮 `run.json`，不覆盖安装。未传此参数时沿用原有安装行为。

## 产物

`docs/runs/evidence/<run_id>/tablet-layout-c1b/`：

- `upstream-t0-v5.json`：本次 T0 原始字节。
- `tablet-layout-observation-c1b-v1.json`：经现有 c1b-v1 validator 校验。
- `run.json`：HEAD、设备、APK、时序与结果摘要。`result_diagnostic` 初始为 null；只在结果字节数、UTF-8 及 serial/nonce 隐私检查通过后，记录结果原始字节数、SHA-256 和首个失败锚点的固定字段名（JSON/结构无效分别为 `json`/`structure`）。未通过锚点检查的 observation 不落盘，也不保留失配值；返回 control 时记 `schema` 失败。摘要不证明来源有效、采集通过或 provider 会话已清理。

## 结果解读

| 退出码 | 含义 | 处理 |
|---|---|---|
| 0 | 采集完成，observation 通过校验 | 按合同 §6 读结论层；写运行记录 |
| 1 | 失败（构建、安装、设备数、协议、时序、校验、设备锁清理或记录写入） | 冻结本轮、保留已有证据与输出，回交 A 定位修复；`run.json` 写入失败时以退出码和错误输出为准 |
| 2 | 需要用户（如无障碍服务未开启） | 保留本轮结果，等用户处理现场阻塞 |

- 设备数不是 1：检查 USB 与 5037 上的其他 adb server。
- 安装或构建失败：先离线复现，不在现场调参。
- 失败与通过都写 `docs/runs/YYYY-MM-DD-T-L1-C1b-<主题>.md`，附 run_id 与退出码。
- 再次运行须解决原阻塞、用新 run_id，并按 [backlog §7.3](../backlog.md)重新报就位、取得开跑令；不复用失败轮或已消费的会话。

启动拒绝诊断只保留最近一次、精确 run_id/nonce 的 `absent` 原因，供 status/capture/result/abort 读取；同 key 的实际会话或终态优先，下一次 start、输入拒绝处理或 shutdown 会清除旧槽，成功响应不缓存。有效 T0 通过校验后，`coordinator.begin` 抛出的 `Exception` 收口为 `failed/start_failed`；输入读取或 T0 校验失败仍为 `t0_invalid`。这只修复已复现的信息丢失，不证明真机失败根因、清理完成或允许重跑。

结果读法：`complete + childCount=0 + visited=1 + positive-visible=0` 是完整观察到 opaque root，不是树可用；
`window_only` 只是 window focus；window title 命中不是目标会话证明。
pure-a11y 仍 opaque 时，下一步另审 window/pane 视觉合同，不关闭应用多窗，不回退整屏坐标。

## 与 C1a、T-L2 的关系

C1a（[v2 规程](T-L1-tablet-layout-observation-v2.md)）已成立 origin/read-only，但 diagnostic blocked。
v2 规程按冻结合同保留历史快照，其中“app 未合 main”是当时状态；当前源码整合状态见 [STATUS](../../STATUS.md)。
C1b 只补拓扑诊断，通过也不等于 T-L1 布局通过；进入 T-L2 横屏 P0 的条件见 [backlog §4](../backlog.md)。

## 旧主机链已退役

固定候选 once、UAC 提权、raw 封存、私有 ADB server、隔离构建、A1–A5 与 Ready/R3 链于 2026-10-09 退役。
退役前最后提交为 `7a3b069`，用 git 查看旧规程与脚本；各轮记录见 `docs/runs/` 下 C1b 相关文件，
例如 [C1b goal 与正式证据闭合](../runs/2026-09-30-C1b-goal与正式证据闭合.md)。

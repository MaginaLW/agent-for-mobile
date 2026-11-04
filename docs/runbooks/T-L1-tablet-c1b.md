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
- 真机运行前，按 [backlog §7.3](../backlog.md) 先报就位、再取得具体开跑令。对同一固定完整 SHA、同一制品和设备，可一次列明并授权身份核验→只读后验→就绪核验→一轮有限采集；报告和许可须列各阶段、累计次数/预算及停止条件，已覆盖阶段满足前置后连续执行，不逐阶段重复询问。任一阶段失败即冻结，不包含重试或另一次采集；候选、制品、设备、来源、预算或目的地变化，以及新增图像、安装、设置写入或危险动作，不继承该只读许可。

## 固定同签名诊断的部署与采集衔接

当前开发分支的未分类窗口保留使用 `tablet-layout-observation/c1b-v2` 配 `tablet-c1b-inventory-result/v3`，见[设计与边界](../specs/2026-11-05-未分类窗口完整保留-design.md)。type 成功值保留全部 signed Int32，未知仍阻断能力；不新增图像或动作路径。新版本须固定代码/制品、完整离线门与对应就位/开跑许可，不能把现装 `156dbde` 的旧 inner/v2 封套当作新版本。

历史 `597ca8b` signed release 配 inventory-result/v1 runner，其[部署交接](../runs/2026-11-02-诊断候选部署交接准备.md)及 [11-04 真机结果](../runs/2026-11-04-诊断后验与窗口采集.md)按原版本保存。新旧 producer/runner 必须成套，原签名和运行许可不复用；准备不是就位或运行许可，历史包哈希也不是当前状态。

1. 安装前只核目标平板可用、USB 唯一及本轮独占；受控读取重新确认设备身份、user0、唯一 base APK 路径和预期旧包哈希。安装阶段不要求微信双窗或 IME 形态，不读取设置或 provider。
2. 报告本轮就位后取得固定范围的部署开跑令，再由 C 对固定完整 SHA 和 signed APK 至多覆盖一次。安装开始前用 ask 明确提醒现场用户留意安装/安全提示，已覆盖授权不另索审批。`-r` 只请求保留数据；默认任意安装 stderr、非标准响应、超时或后验失败均冻结，不补装、不回滚、不扩读来改判旧卡。新卡若经审查和具体授权，可仅对安装接受精确绑定 APK 完整路径/字节数/格式的单行 push 统计；其余读取仍要求 stderr 空，旧卡不追溯放宽。`156dbde` 的新卡及边界见 [11-05 记录](../runs/2026-11-05-窗口类型诊断真机采集.md)；该次安装超时，未进入分类，不能当作例外已经真机通过。
3. 成功部署也不证明无障碍授权或持续绑定。后续另核新 producer/challenge 和采样点就绪；再满足横屏多窗、IME 等采集前置及本轮采集许可，使用 `-SkipBuild -RequireInstalledApkMatch`，防止 runner 以默认 debug 构建覆盖已签名 release。仅有部署许可时不包含 T0/c1/c2；后续只读阶段若已在同一就位报告后的明确许可中逐项覆盖，可满足前置后连续执行，不重复申请。安装仍需自己的具体范围，不能从只读阶段链推导。

启动 TEMP/TMP 使用已存在且独立的区内 bootstrap，不能预设到 freshness 门要求不存在的生产 `tmp`；后者只由 wrapper 在消费 claim 后创建。HostSmoke 要从实际 launcher 冷启动验证这一点。若在 claim 前因宿主目录副作用失败，也按本轮范围冻结，不能删除目录续跑；实例与证据见[安装前核验冻结](../runs/2026-11-02-诊断候选安装前核验冻结.md)。

安装超时意味着效果未知，不等于未安装。保留原冻结收据，先收现场事实；需要核实当前包时另按有效范围执行独立只读后验，不重跑安装或用后验成功改判原轮。后验 builder 交叉核真实 proof/签名收据中的 candidate、challenge 与包哈希；仅让 fake 回述配置可能漏掉旧 challenge。预算前拒绝不计原生派发，只有明确 dispatch mark 后才计调用/安装尝试，未知状态保留 null。依据为上述本轮准备反例与真机结果。

## 命令

```powershell
pwsh -NoProfile -File scripts/run-tablet-c1b.ps1 -AdbPath <adb.exe 绝对路径> `
  [-Serial <serial>] [-ApkPath <已构建 APK>] [-SkipBuild] [-RequireInstalledApkMatch] [-RunId <id>]
```

流程：检查工作树 → 取与派单共用的全局设备锁 → 确认恰好一台设备 → Gradle 构建 `:tablet-c1b-probe:assembleDebug`
→ `adb install -r -t`（不卸载；设备上已是同一 APK 时跳过，因为重装会让系统解绑无障碍服务，需在设置里关闭再打开「平板 C1b 只读探针」）→ 检查无障碍服务 → `run-tablet-intake` 生成 T0-L v5
→ 经 ContentProvider 写 T0、读 `c1`、宿主等待至少 900 ms、读 `c2`、读 result。

原 T0 的保存字节和 SHA-256 不变；stdin 只传标准 Base64 编码后的单行 ASCII，无 BOM、无换行，避免 Windows CRT text stdin 将 CRLF 改成 LF。远端固定为 `adb shell -T "set -o pipefail && toybox base64 -d | content write --uri '<URI>'"`：禁用 PTY，由标准解码器还原原始 T0 字节，并在 EOF 后读取远端输出与退出状态。需要 shell protocol、远端 shell 的 `pipefail` 和 `toybox base64 -d`；任一能力不支持或解码/写入任一侧失败即停止，不回退原始 stdin、`exec-in` 或 PTY。T0 写入须 exit 0、stdout/stderr 均为空（含空白也拒绝），随后仍以绑定的 `status=ready_c1` 验证会话；错误只记输出字节数，不保存可能回显的会话标识。解码器可能先输出有效前缀再失败，不能据失败假定没有创建会话，原必要 abort 保留。固定 ccc8cce 的[单次真机验收](../runs/2026-11-01-C1b原字节传输候选验收.md)已验证本轮链路及原字节绑定，不证明其他环境或旧轮唯一失败根因；未来运行仍须自己的固定候选与开跑条件。

- 从 `c1` 起整段采集不超过 15 秒；`c1`、`c2` 各读一次，不补拍。
- 一次调用只采一次，不自动重试。每个新采集运行使用新 run_id，并重新满足就位与开跑条件；同一明确许可内尚未消费的只读前置阶段按阶段链连续执行，不视为新采集。已有证据目录不得覆盖。
- 探针模块的 Gradle 构建检查保证 APK 只含只读代码；`-SkipBuild`/`-ApkPath` 只用于满足上述构建身份约束的 APK。
- 保留当前已就绪的探针时，另传 `-RequireInstalledApkMatch`：只有已安装 APK 的 SHA-256 与本地 APK 相同才跳过安装并继续；缺包、路径或哈希读取失败、不匹配均在安装前失败并保留本轮 `run.json`，不覆盖安装。未传此参数时沿用原有安装行为。

## 产物

当前未分类窗口保留使用 `tablet-c1b-inventory-result/v3` 封套，内层为 `tablet-layout-observation/c1b-v2`。窗口 platform_type_code 保留 signed Int32；1–7 以外仍 unknown，windows_truncated=false 只表示没有漏存，不表示类型清单、焦点或 IME 已确定。外层 type invalid 首停必须为 0、rejected_type_code_counts 必须为空，observation 的同名诊断 reason 仍可存在。收据保持 tablet-c1b-run/v2，result_schema 指 v3；真实完整清单仍待验收，见[离线阶段](../runs/2026-11-05-未分类窗口离线实现.md)。

历史 `156dbde` 的 inventory-result/v2 配 c1b-v1，仅聚合被范围门拒绝的原整数。[11-05 单次真机采集](../runs/2026-11-05-窗口类型诊断真机采集.md)两帧各拒绝 -1 一次；完整拓扑/语义及 T-L1 未通过，不证明窗口身份或内部转换路径。旧 schema、文件名及证据不升级、不回填。

历史 `597ca8b` 的 inventory-result/v1 合同已通过真机，但拓扑/语义未通过；更早 ccc8cce 的裸 observation 与收据仍按各自固定版本解释，不迁移或补字段。新 runner 只接受 inventory-result/v3 与 inner c1b-v2，拒绝旧封套、旧 inner 和裸 observation；不能混用 APK/runner。

`docs/runs/evidence/<run_id>/tablet-layout-c1b/`：

- `upstream-t0-v5.json`：本次 T0 原始字节。
- `tablet-c1b-inventory-result-v3.json`：新封套原始字节，包含 observation 原文、两帧首次停止和空拒绝表；仅在闭合数值形状/隐私及内层 run/构建/T0 绑定通过后保存。良构但违反零/空约束的已绑定内容留证后计数拒绝；文本/未知键条目在保存前拒绝。历史 v1/v2 文件保留原名，不重命名或覆盖。
- `tablet-layout-observation-c1b-v2.json`：封套中 observation 原文的严格 UTF-8 字节，经新 c1b-v2 validator 校验；不重排 JSON。旧 v1 文件/schema 按各自版本保留。
- `run.json`：HEAD、设备、APK、时序与结果摘要。新收据的 `result_schema`、`result_envelope_sha256` 指外层；`observation_sha256` 与 `result_diagnostic` 仍指内层原文及原绑定失败字段，不能互换。`inventory_validation` 记录未运行/失败/通过及闭合原因。未通过绑定的 payload 不落盘、不保留失配值；绑定后计数失败保留已有证据且本轮失败，不重采。摘要不证明 provider 已清理或 T-L1 通过。

归档时同时保存上列四份文件（失败轮只收集实际生成者），在 manifest 中分别记录封套和 observation 原字节哈希，并核对解封后的内层字节与 observation 文件完全一致。不得只归档诊断摘要或把封套哈希写入 observation_sha256；旧 run/v1 归档不要求不存在的新文件。

## 结果解读

| 退出码 | 含义 | 处理 |
|---|---|---|
| 0 | 采集完成，observation 通过校验 | 按合同 §6 读结论层；写运行记录 |
| 1 | 失败（构建、安装、设备数、协议、时序、校验、设备锁清理或记录写入） | 冻结本轮、保留已有证据与输出，回交 A 定位修复；`run.json` 写入失败时以退出码和错误输出为准 |
| 2 | 需要用户（如无障碍服务未开启） | 保留本轮结果，等用户处理现场阻塞 |

- 设备数不是 1：检查 USB 与 5037 上的其他 adb server。
- 安装或构建失败：先离线复现，不在现场调参。
- 失败与通过都写 `docs/runs/YYYY-MM-DD-T-L1-C1b-<主题>.md`，附 run_id 与退出码。
- 失败后的再次运行须有新证据说明原阻塞已解决、使用新 run_id，并按 [backlog §7.3](../backlog.md)重新报就位、取得列明预算与停止条件的开跑令；不复用失败轮或已消费的会话。此规则不要求同一有效阶段链的成功前置步骤逐项重新审批。既有更严格单次授权不追溯扩大，危险动作的设备端现场确认保持不变。

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

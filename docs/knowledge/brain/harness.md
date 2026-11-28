# 大脑侧链路知识（headless / 按需挂载 / 两段式）

> 大脑侧链路与执行/验证 harness 的可复用经验：遇到对应情况时查。执行 harness 设计见
> [执行harness spec](../../specs/2026-07-17-执行harness-design.md)，入口 `scripts/dispatch.ps1`。
> 过程叙述与证据细节在 `docs/runs/` 对应记录与 git 历史里，本册只留结论与做法。

## 默认大脑迁移须核对 trace 消费者（2026-11-12）

- 排查旧台账中的 `mcp-transport-failure` 时，用 `Read-DispatchTraceTranscript` 核对失败调用的结果和错误类型。自 2026-11-18 起，派单入口将有效网关响应中的 `ok=false` 或 `isError=true` 记作 `gateway-tool-failure`，发送请求出错且没有返回结果时记作 `mcp-transport-failure`。离线派单回归覆盖两类错误的退出码和台账标签。
- **传输失败现场只读健康快照（2026-11-23 离线落地；2026-11-27 PA2553 首次采集；2026-11-28 归因修复）**：自 2026-11-23 起，`scripts/dispatch.ps1` 在收尾拆除端口转发与网关服务之前，若识别到 `mcp-transport-failure`，自动调用 `scripts/lib/dispatch-forensics.ps1` 将无凭据只读健康快照（`adb forward --list`、无鉴权 `/health`、`GatewayService` 状态、`enabled_accessibility_services` 及 `dumpsys accessibility` 绑定摘要，不含 Bearer token 与 UI 文本）写入本地 `docs/runs/traces/<base>.transport-health.json`，保持原 `.jsonl` 与台账 `note: mcp-transport-failure` 契约兼容。2026-11-27 `stage6b1-lockscreen-notify-deny-r4` 在 PA2553 首次触发并落盘 `.transport-health.json`（实证 8 分钟墙钟超时强杀现场 `adb_forward`、`/health` 200、`GatewayService` `foreground`、无障碍 `gateway_enabled=true` & `gateway_bound=true` 全部健康，从而定位为墙钟超时截断在途工具调用而非真实传输中断）；据此 2026-11-28 `dispatch.ps1` 已区分墙钟超时截断在途调用（`-not $finished` 且仅有 `Outcome='started'` 时记 `in-flight-tool-interrupted`，不误标 `mcp-transport-failure`、不写 `.transport-health.json`）与真实 `mcp-transport-failure`（`$finished -eq $true` 的 `exit-partial` 原契约不变）。

- 适用条件：派单默认大脑或 JSONL schema 变化。只改默认参数和 DryRun 不能证明下游消费者仍可使用。
- 有效做法：P0 复用 `Read-DispatchTraceTranscript` 解析 Codex 事件，再沿用已有调用顺序、结果数和完成时序判据；fake runner 必须产生真实大脑 schema。下方 Claude CLI 经验保留为已退役路线的历史资料，不作为当前调用指南。
- 验证依据：本轮 13 个现有定向用例通过，包含 Codex `item.*` 到 manifest 的 Allow/Stale 闭环与 ledger、顺序、JSON/audit 等反例；源码与过滤用例在 `scripts/tests/dispatch-offline.ps1`、`scripts/tests/p0-supervised-runner-offline.ps1`。证据限离线 fake，不代表设备或真实模型验收。

## 官方CLI更新与精确版本准入（2026-11-14 / 2026-11-21）

- 适用条件：桌面官方CLI升级或清理旧版桌面二进制后，真实dispatch在版本解析处拒绝，而DryRun仍能组装任务。2026-11-14 实例为 `0.167.0-alpha.4.1`；2026-11-21 实例为官方稳定版 `0.171.0`（上游 tag `rust-v0.171.0`，commit `ccf9be8cc458bd6b8336fe84d68d8893f2691a5e`）。未放入受控 `toolchain/codex` 或官方桌面 `bin` 目录的二进制不会被 resolver 自动采用，不通过放宽信任根或绕过签名来解阻。
- 有效做法：核本机官方 OpenAI OpCo 签名、隔离 `--version`/帮助/feature 列表、无凭据 `--strict-config` 解析及固定版本源码（`config.schema.json`、`features/src/lib.rs`、`tools/spec_plan.rs`、`exec_events.rs`、`event_processor_with_jsonl_output.rs`），再只加入被核过的精确契约；保留文件 guard/hash、受控 root（`toolchain/codex` 优先、官方桌面 `bin` 回退）、环境隔离和已有禁用。`0.167` 分支额外禁用 `sleep_tool`；`0.171` 分支沿用 `sleep_tool` 禁用并额外禁用恢复为默认开启的 `daemon_auto_start`，`exec_events.rs` 与 `0.167` 完全一致。此外 `0.171.0` 默认模型元数据可强制进入 `ToolMode::CodeModeOnly`（覆盖 `--disable code_mode`/`code_mode_only` 且不回退 `Direct`），必须与同目录配套的 `codex-code-mode-host.exe` 成对放置；派单链路在解析与 wrapper 启动前对 `0.171` 同目录 `codex-code-mode-host.exe` 强制核验存在性、非 reparse/link、OpenAI OpCo 签名及 deny-write 句柄下的 SHA-256。不以帮助存在或关闭几个 feature 声称原生 utilities/扩展贡献已被穷尽枚举。
- 验证依据：2026-11-14 轮见[小红书准备记录](../../runs/2026-11-14-小红书单窗口只读准备.md#官方cli精确版本兼容候选)。2026-11-21 轮在 `0.171.0` 冻结副本上实测 `Resolve-DispatchTrustedCodexExecutable` 验签/guard/hash/探针选出 `contract=0.171`，无凭据 `--strict-config` 全参数解析直达必填 gateway MCP 握手，离线回归覆盖 `0.171.0` 优先级、邻居拒绝、配套 `codex-code-mode-host.exe` 缺失/目录/junction/未签名/SHA-256 篡改拒绝与隔离 argv/环境；真机侧 `0.171.0` 仅放 `codex.exe` 时复现 `codex-code-mode-host.exe` 缺失 fail-closed，补齐同源 OpenAI 签名配套二进制后 5 次只读 MCP 调用零 stderr 跑通。

## 动态网关配置须验证真实消费路径（2026-11-14）

- 适用条件：网关配置由token同步helper动态生成，再交给Codex派单。模板可用、health和MCP ping通过，仍不能证明动态配置满足派单消费者。
- 有效做法：复用现有模板的数值timeout=420000，让真实Set-P0GatewayConfigToken产物直接进入New-DispatchCodexLaunchSpec验证；保留消费者的正数/类型校验及token只进敏感环境。服务stop即使含“Service stopped”，非零返回且缺后验仍保留UNKNOWN，不补成全收尾。
- 验证依据：A16/P02在模型启动前因动态配置缺timeout冻结，无搜索/OCR；真实producer→consumer回归先复现同错，最小修复后Codex定向12/12通过，后续固定b77e210完整离线门19/19、1057.875秒exit0覆盖该修复。原轮不恢复，仍无新设备或真实模型实证，见[后续核定](../../runs/2026-11-14-小红书单窗口只读准备.md#后续离线收尾核定与候选检查)。

## 服务停止回执与派单后代须分别取证（2026-11-14）

- 适用条件：Android16的stop-service打印“Service stopped”但exit255，或派单在模型启动前拒绝配置后只留下根进程退出结果。
- 有效做法：先核固定命令实现。AOSP android-16.0.0_r1的runStopService收到停止接口结果1后打印该文字，仍return -1；不能套用普通exit0判据解释其语义，也不能只接受255，因为未运行/错误分支同样返回-1。现有通用SDK严格门保持，停止回执和服务不存在的独立后验分别记录；vivo当前实现及状态不能从AOSP推定。
- 主机边界：New-DispatchCodexLaunchSpec先运行官方CLI版本探针，再校验timeout。模型0不等于没有主机子进程；旧轮缺逐探针/根Job绑定时保留UNKNOWN。新候选可复用既有Job与启动gate，在入口放行前绑定并记录ActiveProcesses归零；非零根退出与任务成功分开报告。
- 验证依据：[本轮核定](../../runs/2026-11-14-小红书单窗口只读准备.md#后续离线收尾核定与候选检查)包含固定官方源码、原双流范围及一次无害fixture：根exit7后实际残余子进程被本轮Job收口到0。只证明该离线路径，不补旧P02收尾，也不授予新设备或业务许可。

## 执行器工具面：`--allowedTools` 不是限制，`--disallowedTools` 是手写枚举（2026-07-26 / 07-31）

- **`--allowedTools` 只是免确认名单，不阻止任何工具。** 07-26 Allow 腿实锤执行器在本机跑了
  `Bash`；仓库里放着 gateway token（`configs/gateway-mcp.json`），等于开了后门。真正限制的是
  `dispatch.ps1` 的 `--disallowedTools`。
- **枚举拒绝天生会漏**：07-26 `ToolSearch` 被越权审计误杀；07-31 执行器调 `ReportFindings`，
  在真人已点「允许本次」、危险动作已执行之后才被判死，一轮真机白烧；同轮发现 `PowerShell`
  从未被禁（只禁了 `Bash`，本机是 Windows）。
- **做法**：名单按**类**补（shell / 文件 / 网络 / 派生执行体 / 汇报交互），关键项上离线断言
  （两个 shell 必须成对出现）。
- **`ToolSearch` 必须留在白名单**：gateway MCP 工具延迟注册，执行器要先用它加载 schema；
  trace 审计对它走显式白名单，不计入调用序列、不当证据解析。
- **只在成功路径上跑的审计等于没有审计。** 越权这类与语义无关的策略检查要抽成独立函数，
  失败路径也跑并写进 manifest（`tool_policy_violations`）。

## 已验证：headless 派单链路（M0 发现 #11）

```powershell
claude -p "<任务提示词>" --output-format json --mcp-config configs/mobile-mcp.json --allowedTools "mcp__mobile"
```

- JSON 输出自带精确 token/成本/轮次（M0 的成本数据即由此量出）。
- ⚠️ headless 在不信任的工作区会**忽略 settings.json 的 permissions.allow**，必须用 `--allowedTools`
  旁路（或先交互跑一次接受信任对话框）。

## mobile server 按需挂载

2026-07-16 起 mobile server 不常驻项目 `.mcp.json`（开发会话碰不到手机）。要跑真机：

```powershell
claude --mcp-config configs/mobile-mcp.json        # 交互式单跑
```

配置在 [configs/mobile-mcp.json](../../../configs/mobile-mcp.json)，版本锁定 `@mobilenext/mobile-mcp@0.0.62`
（保证数据可比；升级需有意为之并记录）。中文输入依赖的 devicekit 机制已死，见 [../android/common.md](../android/common.md)。

## 已定原则（供执行 harness 设计继承）

1. **危险操作必须由人确认**（用户 2026-07-16 批准，07-19 细化）：mobile 执行器在临界动作前停下，人工键盘确认后才走
   第二腿；gateway 在首次危险工具调用中等待现场人操作手机确认卡。只有危险工具尚未调用时遇到纯人工前置条件，才允许暂停后恢复。
2. 全量 trace 落盘 `docs/runs/`，只让摘要进派单方上下文。
3. 每次派单记录 token/成本（JSON 计量），持续校准 [cost.md](cost.md)。

## 执行 harness（2026-07-17 已落地）

入口 `scripts/dispatch.ps1`，站规 `scripts/prompts/executor-preamble.md`，任务卡 `scripts/tasks/`，台账 `docs/runs/ledger.csv`。
实施期实测（claude 2.1.206）：

- **`--max-turns` 已从 CLI 移除**，机械上限用 `--max-budget-usd`（wrapper 默认 $2）；轮数只能做站规软预算。
- **会话内派单要清 `CLAUDE*` 环境变量**（wrapper 已做），否则子会话带宿主会话标记；`ANTHROPIC_BASE_URL` 有意保留
  （回落通道开关），派单认证异常先查它。
- 预检不做 npm registry 探测（国内网络假阴性多）。
- 确认门 `Read-Host` 在非交互 shell 直接抛错——代理经 shell 无法代答 CONFIRM，两段式硬门机械成立。
- **派单锁判活的真值是"锁文件能否被独占打开"**（`scripts/lib/dispatch-lock.ps1`）：崩溃后 OS 回收句柄、文件残留，
  这种残锁自动清理一次再取。别用超时或 pid 存活猜（pid 会被复用）。

## Claude Code 会话本地构建工具链（2026-07-24 补装）

- 仓库原先没有 gradle wrapper、本机没装 Android Studio，早期构建结论都出自 Codex CLI 沙箱。2026-07-24 经用户同意装了官方
  Gradle 8.9 发行包（本机 JDK 21），在 `app/` 下生成 wrapper，已入库。
- 现在可在 `app/` 直接 `./gradlew testDebugUnitTest testReleaseUnitTest`、`./gradlew assembleDebug` 自验。
- 测试条数看 `build/reports/tests/<variant>/index.html` 的 `class="counter"`（控制台只报 BUILD SUCCESSFUL）；
  单类结果在 `build/reports/tests/<variant>/classes/<全限定类名>.html`。

## 真机调试：单次只读诊断优于反复整套重跑（2026-07-24）

- **验证某个真机猜测，先派几毛钱的只读诊断**（`dispatch.ps1 -Task "..." -Executor gateway`），别直接重跑整套
  `run-p0-safety-smoke.ps1`（每轮带 `-Provision` 重装、还要用户配合）。前提是设备此前被 `-Provision` 过、gateway/无障碍仍在。
- **只读诊断提示词要显式禁止写入/危险工具**（列出 `macro_run`/`type_text`/`press_key`/`ui_action` 等），并写明"输出完就结束"。
- **`ui_snapshot()` 看不出截图是否陈旧**：怀疑视觉管线时，另派只调 `screen_capture()`、由子代理自己描述画面的任务；两者一致说明
  缺的是 OCR 提取，不一致才查截图管线。
- **可能含敏感信息的元素要求在派单提示词里脱敏**（如 `[REDACTED-LEN=n]`）——结果会原样进上下文与 trace，事后补救无效。

## 派单前先自查设备状态（2026-07-26，实测省了多轮）

- **开发会话可以 `adb exec-out screencap -p` 只读截图自查**（输入框是否空、停在哪页、残留是否清掉），挡掉"前置条件不满足→必失败"的空跑。
- **跑测前先跑零 token 的 `scripts/lib/p0-gateway-health-probe.ps1`**：服务被杀/端口转发失效 1 秒内报。
- **"前置条件不满足→必然失败"的正解是网关出 R 级只读判据、PC 侧零 token 预检**，不是放宽安全判据、也不是靠人记得做
  （例：`p0_probe_region_state` 与 `P0FocusProbeValidator.build` 共用实现）。**预检不可用时只警告不阻断**——它是省钱优化。
- **错误信息把多个并列条件合并成一句话，是真机排查里最贵的反模式。** "A 或 B 或 C 已变化"式的 fail-closed 要逐条点名并附
  "旧值 → 新值"；诊断分支只在失败路径上跑，不削弱安全性。

## 危险动作统一硬门（2026-07-19 离线测试）

- **风险等级只作元数据会产生旁路**：统一安全门必须位于所有 handler 之前，静态等级和动态目标风险都在这里判定。
- **逐工具确认必然漏接**（新工具、IME 回车等通道会绕过）；确认策略集中，工具只执行已放行的本次动作。
- **自由文本 `confirm(action_desc)` 不是授权**：会形成"确认 A、执行 B"。确认卡由网关按实际工具、冻结参数与当前
  App/Activity/目标控件生成，最终执行前复核。
- **安全失败不计 retry**：拒绝、超时、上下文/目标失效是安全结果，累计为执行失败会诱导大脑换路或重试危险动作。
- **成功记账失败不能反向诱发重试**：动作已成功后 retry guard 记账 best-effort，异常只进审计。

## 双 executor 派单接线（2026-07-19 离线测试）

- `dispatch.ps1 -Executor mobile|gateway` 共用锁、trace、ledger 和结果解析；默认 `mobile`。gateway 本地配置只放 gitignored 的
  `configs/gateway-mcp.json`，仓库只存 example。
- **DryRun 的位置是安全契约**：必须在任何 adb 调用、私密配置读取、锁创建与 trace/暂停件/ledger 落盘之前返回。
- **暂停件持久化 executor**：确认腿继承原 profile，跨 profile fail-fast；无 executor 的旧暂停件只按 `mobile` 兼容。
- **凭据不进观测面**：token 与 Authorization 不得进 trace、ledger、错误消息、fixture 或快照；离线夹具只用合成值。
- **发送无白名单**：自收消息（文件传输助手）也走同一安全门。
- **safety terminal 没有第二腿**：拒绝、确认超时、`E_STALE_REF`、blocked、缺权限/通道一律常规失败，不得写成
  `[AWAIT_CONFIRM]`、不得用 `-Confirm` 重试。
- **同一错误码可以来自毫不相干的原因，"预期错误码"最会骗人**（2026-08-01 Deny 腿实锤）：debug 测试控制白名单漏了 `deny`，
  `press_key` 回 `E_BLOCKED(channel=test-control)`，确认卡根本没弹，执行器却报"符合预期"。推论：①判据要看 channel
  （真人拒绝是 `overlay`，台账已按 channel 区分）；②被测组件自报的结论要有一条独立判据兜底（这次靠 runner 独立读
  app 私有文件里的 `confirmation`）；③新腿接进 runner 时顺着调用链放开每一处按腿枚举的白名单。
- **用例会保护 bug**：上述漏洞被一条"不支持的腿 = `deny`"反向用例钉住而套件全绿。反向用例要写死一个永远不会被支持
  的值（如 `purchase`），别用"暂时还没做"的真实名字。

## C 道真机验收踩出的三条（2026-08-01）

- **新 worktree 首跑先构建。** `run-p0-safety-smoke.ps1` 只装不构建；`app/local.properties`（gitignored，只含 `sdk.dir=`）
  不随 checkout 进 worktree。开跑前固定动作：补 `local.properties` → `assembleDebug` → 再派单。
- **"场景没构造成功"必须是独立的一态。** tracker 冷启动自举验收时，`-Provision` 后的 `am start` 等动作都产生窗口事件，
  自举分支从未被执行到，而"未触达"与"通过"在旧判据下长得一样。修法是给它一个名字：四态
  `passed`/`not_reproduced`/`unavailable`/`failed`，退出码即结论。
- **定位真机故障先找只差一个变量的对照腿**，比加日志快一轮。可观测性解决"看不见"，对照实验解决"看得见但归因不了"。

## 离线套件提速：先量，再动手（2026-08-01，567s → 213s）

- **"慢在哪"必须是读出来的**：先加逐用例计时与分段归因（实测 98% 在 runner 子进程、假 adb 每次调用，不在造 fixture）。
- **热路径上的假设备脚本，每多一个进程都乘以几千次**：假 adb 分发改用 `if "%n"==`、`if exist` 等零进程内建，
  场景名在 fixture 构造时烤进脚本。
- **并行选分片、不选进程内并行**（语义与顺序跑相同、可单片重跑）；**并行度必须打印出来**，否则分不清假失败是代码还是并发压出来的。
- `P0_KEEP_FIXTURE=1` 保留临时仓库副本——用例失败时 fixture 会被当场删除。

### cmd 批处理的三个坑（改假设备脚本前先读）

1. **块内的 `rem` 仍会被解析**：括号会提前闭合 `if (...)` 块、重定向号会真的重定向，报错与真因无关。说明写在生成它的 PowerShell 注释里。
2. **重定向号前紧挨数字会变成句柄号**：`echo %*>>"adb.log"` 在命令以数字结尾时变成 `4>>`，那一行不进日志——日志说了谎。
   一律写成 `>"file" echo 2` / `>>"adb.log" echo %*`。
3. **.cmd 按 OEM 代码页读**：中文 UTF-8 按 GBK 配对会吃掉行尾 CRLF、把下一行并进来。注释只写 ASCII。

## 量函数长度：别用 grep/awk 量 Kotlin（2026-08-01 起四次量错，09-07 换工具）

- 「全仓最长函数」先后四次量错：把"到下一个 `fun` 的距离"当长度；表达式体函数（`fun f() = expr`）没有 `{`，
  括号匹配会窜到别的块；Kotlin 花括号还出现在字符串、lambda、模板 `${}` 里，行式脚本天然量不准。
- **做法**：用 `scripts/measure-kotlin.ps1`（锁定 SHA256 的 detekt 独立 JAR、真实 Kotlin PSI）。**不要引用旧的具体行数**，
  要排名就重新运行；输出含文件清单与哈希，分析前后漂移会拒绝报告。指标定义见
  [指标说明](../../../scripts/lib/kotlin-metrics/README.md)。

## 反复调参数之前先搜文档（2026-08-02，批次 2 烧掉三轮真机才醒）

**触发条件**：同一现象连撞两轮还没定位。第三轮之前**先查官方文档/搜网**，不要接着调参数
（已进 [离线开发与验证 · 排障](../../runbooks/离线开发与验证.md)）。批次 2「锁屏免解锁批准」三轮都在调通知属性，
一次搜索就判死方向：通话级待遇授予的是 `CallStyle` 而非 `CATEGORY_CALL`（详见 [android/common.md](../android/common.md)）。

- **厂商 ROM 文档常抓不到正文**（如 vivo 开放平台 JS 渲染）。抓不到就明确记"指望不上文档"，转单变量实验。
- **搜到的东西分级记**：官方文档与媒体报道分开标注，后者按未证实处理、转成可实验的假设。

## 判据看不见的东西就会烂掉（2026-08-02，四个实例）

一条东西**只要没有判据能看见它**，出错时就不会报错，只会安静地与现实脱节。修法一样：**挪到判据看得见的地方。**

| 看不见的东西 | 后果 | 修法 |
|---|---|---|
| fallback 字符串内联在 lambda 里，无用例覆盖 | 写着"输出 `[AWAIT_CONFIRM]`"，代码反过来教大脑违反站规 | 挪进可被用例引用的常量并断言 |
| `.ps1` 缺 BOM，却用 pwsh 7 AST 验 | 真实运行环境 5.1 按 ANSI 读、中文变解析错误，"可解析"是假绿 | 字节级断言 BOM + 真拿 5.1 解析 |
| 核查"用户是否拍板"的脚本丢弃所有 `tool_result` | AskUserQuestion 答案恰以 `tool_result` 回来，于是把"没查到"报成"某会话编造授权" | 换过滤条件；结论指向"某方造假"时先找第二来源 |
| `Assert-NotMatches $source 'setDeleteIntent'` | 被注释匹配到；反过来注释里出现名字就能让断言永远绿 | 只匹配调用形态 `^\s*\.setDeleteIntent\(` |

### 可操作的四条

1. **约束大脑行为的文本（提示词、fallback、错误措辞）不要内联**，放进能被用例引用的常量。
2. **用目标运行时去验**：给 5.1 跑的脚本用 5.1 验，`.cmd` 按 OEM 代码页想。
3. **源码文本断言分不清代码与注释**：匹配调用/声明形态，别匹配裸名字；必要时先剥注释。
4. **判据写完先做一次正对照**：临时塞一处违规，确认它真的变红。

同族还有「用例把错误行为钉成预期」（本册已记三次）及其变体「过时预期靠巧合存活」；以及**过时的明确指路**：
doc 注释写着"那条在调用方"，而调用方行为刚被改反。改动一处行为时，顺手搜一遍还有谁在指着它。

### 搜的是行为的形态，不是这次改动的标签（2026-08-02）

按改动标签（"决定四"）搜只找到挂同一标签的注释；按行为形态（「谁的 `fallback` 在指示 `[AWAIT_CONFIRM]`」）
搜，`ConfirmOverlay` 又冒出四处更老的。**标签只覆盖这次碰过的地方，形态覆盖所有同类。**
判断"某条指令是否自相矛盾"时，去看它指向的路在系统里通不通（这里 `dispatch.ps1 -Confirm` 对
`E_CONFIRM_TIMEOUT` 等终态本就拒绝恢复），比逐字对照规矩可靠。已加离线断言：主源码任何 `fallback = "…"`
不得含 `[AWAIT_CONFIRM]`（先剥注释，做过正对照）。

## 判据把实现细节当成了语义（2026-08-02，五个实例）

判据盯住"这次恰好长什么样"而不是"要证明的事"，会**误杀正确行为**，现场是一条言之凿凿的失败。

| 判据写的 | 实际要证明的 | 修法 |
|---|---|---|
| `ui_find` 命中数 `== 1` | 消息区只有期望 marker | OCR 对同一气泡回两个重叠框 → 改为「归一后全部命中同一 marker」 |
| marker 用十六进制 | marker 能被 OCR 稳定读回 | `0/O`、`B/8` 等易混 → 换字符集（改锚点不改判据） |
| 审计增量 = 当天文件新增行 | 本腿期间的审计行 | 跨零点读成 0 → 腿末复核日期、跨天接上新文件 |
| 「dispatch 没记台账」默认成立 | 这轮有没有留痕 | 重复两行 → 先查再补 |
| 日志里出现某行 = 当前状态 | **这一轮**的状态 | 已连出三次 → 带本轮标识再比 |

**改哪一侧**：误杀时默认**换掉被判的东西**，不放宽判据（放宽 fail-closed 是拿安全换通过率）。
只有判据本身描述错了语义（如第一行）才动判据。

## 锁屏时危险动作走不到确认那一步（2026-08-02 离线判定，🔵 未上真机）

「先锁屏、后 post 通知」的路不通，且比预想更早：`SafetyGate.execute` 先读上下文并 `requireKnownForeground`，
**早于 `policy.assess`**；锁屏后 keyguard 不是 `TYPE_APPLICATION` 窗口 → `applicationWindow()` 为 null →
`E_BLOCKED`「前台 APPLICATION 身份未知」，确认卡与审批通知都不会出现（冷启动自举也要求活动应用窗口）。
`SafetyGateTest` 的 `unknown foreground blocks Level W before confirmation and execution`（`confirmerCalls == 0`）已钉住。
这是 D1「身份必须归属活动 APPLICATION 窗口」按设计工作，所以是**安全姿态问题，不是实验设计问题**：

| 方向 | 代价 |
|---|---|
| 放宽 `requireKnownForeground` | 直接拆掉 D1，反对 |
| keyguard 视作"前台被遮住"而非"未知" | 需新概念，且放宽批准时/执行时前台的硬相等 |
| 审批对象上移到语义意图，批准后重走严格链 | 已有[语义意图设计](../../specs/2026-08-02-语义意图审批-design.md)；阶段 6B-1 语义意图生产接线已落地（2026-11-26）并通过 PA2553 真机验收（2026-11-27，PR #93） |
| 目标缩到"屏幕亮着但没盯着" | 零安全代价，但偏离原诉求 |

第二道障碍：确认卡是 `TYPE_APPLICATION_OVERLAY`，**不显示在 keyguard 之上**。当时考虑过通知审批；2026-08-28 已撤销通知批准，现行批准只来自可见 `ConfirmOverlay`，不恢复锁屏通知批准。
另：`category=call` 换不到通话级待遇（那属于 `CallStyle`，其按钮强制为接听/拒接，套不进允许/拒绝），已去掉；
紧急度由通道 `IMPORTANCE_HIGH` 提供。

## PowerShell 坑（2026-08-30 起，固定 7.6.x 实测）

- **JSON lexical type**：默认 `ConvertFrom-Json` 会把合法的 quoted ISO 字符串自动转成 `DateTime`。strict reader 用
  `ConvertFrom-Json -DateKind String`（7.4 不支持，需 ≥7.5 或 feature-detect），回归同时含 string 正对照与默认解析被拒的防退化。
- **Mandatory 集合参数拒绝空集合**：`[Parameter(Mandatory)]` 收到刚建的空 `List` 会在函数体前抛
  `ParameterArgumentValidationErrorEmptyCollectionNotAllowed`。accumulator 参数加 `[AllowEmptyCollection()]` 并有空输入正对照。
- **跨行 cast 不是 cast**：`$x = [long]` 换行再写调用，Parser 0 但实际是两条语句（把类型对象赋值 + 独立调用）。
  cast 写成单一表达式 `[long]([Native]::Call(...))`，静态门断言 RHS AST 含预期调用。
- **`[string]` 参数传 `$null` 会绑定成 `''`**：`$null -ne $p` 恒真。用 `-not [string]::IsNullOrEmpty(...)` 判断是否提供；
  别靠改成 `[object]` 或放宽 regex。
- **函数会枚举返回的数组**：`return $bytes` 在调用方变成 `Object[]`（1 元素时变标量），`Buffer.BlockCopy` 报错。
  保留数组身份用 `return ,$bytes`（AST 是单元素 `ArrayLiteralAst`，不是 `UnaryExpressionAst`）；别用 cast 或 `@()` 代替。
- **未接收的 `$task.GetAwaiter().GetResult()` 会向 stdout 写 `VoidTaskResult`**；协议 stdout 须为空时用 `$null = ...`。
- **字符串字面 `\n` 不是 LF**：拼到 JSON 后就不是 strict JSON；写出后要严格 round-trip parse。
- **`if`/`else` 之间误插语句，Parser 仍可能零错误**（`else` 被当普通命令）。Parser0 不等于控制结构正确，门脚本要实际跑到汇总。
- **`-EncodedCommand` 下 `Write-Progress` 会产生 CLIXML stderr**（2026-09-07，曾撑爆 1 MiB 捕获上限）。最早设
  `$ProgressPreference='SilentlyContinue'`，保留空 stderr 与 overflow 门；不能凭 CLIXML 头或 exit 0 放行。stderr 超限时要留
  有界原文预览，只存 hash/计数会失去归因能力。
- **Volume-GUID 路径 `-File` 先过 AuthorizationManager**：默认策略下在脚本正文前报
  `SecurityError: AuthorizationManager check failed.`；`-ExecutionPolicy Bypass` 作固定参数可过，但它只作用于该进程会话、
  不是内容/身份 authority；引擎按路径重新打开脚本，不消费父进程持有的句柄。
- **`Get-AuthenticodeSignature -Content` 不能验 PE**：blob 分支固定走 PowerShell 脚本 SIP，对签名 exe 返回 `NotSigned`；
  PE 用 `-LiteralPath`。不得把 expected 改成 `NotSigned` 让门变绿。
- **share mode 跟随 FileObject 的原始 access**：从 writer 句柄 duplicate 出的"只读 guard"仍保留写共享记账，会让按路径只读重开报
  sharing violation（`0x80070020`）。需要命名路径验签时：关闭全部 writer 句柄 → 新开 read-origin guard 并重验身份/SHA →
  再调用；如实记录中间存在重绑 gap。

## 漂移门报警后，先分「新增」还是「修改」——两者恢复路径不同（2026-09-02）

旧 C1b 的 Git 信任根门只报 file count +1 与 catalog 变化，据此立了五道重装阶梯、消费两次一次性授权后，才用一次只读全树复算
发现只是**多了一个文件**——新增文件不在安装器卸载日志里，重装根本闭合不了。**恢复手段本身也需要对照**：先回答
"这个手段作用在哪个对象上、能否让判据回到冻结值"。

| 形态 | 判别 | 恢复 |
|---|---|---|
| 新增文件 | 排除候选项后 catalog 回到冻结值 | 移出该文件，重装无效 |
| 修改文件 | 文件数不变、catalog 变 | 重装或从可信源覆盖 |
| 缺失文件 | 文件数减少 | 重装或补齐 |

- 复算脚本自己也要先对照：独立重现门记录的漂移值，证明规则复刻正确，才能用它下结论。
- **"某字符串不在日志里"必须先证明该日志能检出已知在场的字符串**（例如 UTF-16 编码假阴性）。
- **`NotSigned` 在 MSYS2 载荷目录里是常态**，只有少数入口 exe 是 `Valid`，不要当异常信号。

## `check.ps1` 跑不起来会伪装成"门失败"（2026-09-02）

`scripts/check.ps1` 声明 `#Requires -Version 7.5`，本机默认 `pwsh` 是 7.4.x：PowerShell 在第一行之前拒绝，外部 exit `1`、
一个检查都没跑，外部信号与"某道门失败"完全一样。**`exit 1` 至少分「跑了并失败」和「根本没跑」**，门汇总表是否出现是最便宜的
区分证据。仓库脚本用项目钉定的 PowerShell 跑（现为 7.6.5，路径与命令见 [离线开发与验证](../../runbooks/离线开发与验证.md)）。

### 受限宿主与区内构建缓存（2026-11-01，离线验证）

- **适用条件**：PowerShell 宿主以 `ConstrainedLanguage` 运行，或构建依赖环境未注入；项目脚本需要 .NET 类型、进程和文件 API。仅换成项目钉定的 `pwsh.exe` 不保证获得 `FullLanguage`，先核对实际语言模式，按宿主权限流程运行已授权的本地检查。
- **有效做法**：本轮将已有 Gradle 缓存的 `caches/modules-2` 与 `wrapper/dists` 复制到区内 `.checks/gradle-home`，只对检查子进程设置 `GRADLE_USER_HOME`、`TEMP/TMP`（`.checks/t`）及 JDK/SDK 路径；保留项目原有 `--offline`、`--no-daemon`、进程内 Kotlin 编译和严格依赖校验。缓存副本可复用，不复制全局 Gradle 配置或凭据。
- **验证依据**：固定候选 `dc13f1c233c8a1ef0feb40aa9b04c6c2f1bf55ae` 的完整门实际退出 0、14/14 通过，Android 219 个任务成功。此结论只证明本轮已有依赖足够，不保证任意缓存或缺失依赖也可离线构建。命令、日志和收据见[补验记录](https://github.com/MaginaLW/agent-for-mobile/blob/e1bae376217fc75b13094b2b04858ab93e692a29/docs/runs/2026-11-01-安全验收候选离线补验.md)。

### 同名应用命令可能返回多个程序（2026-11-01，纯宿主验证）

- **适用条件**：PowerShell 用 `Get-Command <name> -CommandType Application` 的 `.Source` 作为单个原生程序路径。本机 Git 和 Node 各返回两个结果；不能假定查询只返回一个。
- **有效做法**：保留 PATH 优先顺序，显式 `Select-Object -First 1 -ExpandProperty Source`，再传给进程启动器。一次性设备任务前，用相同函数做不接触设备的最小宿主检查；语法检查、解析器样例和静态审查不覆盖进程启动。
- **验证依据**：[恢复观察续记](https://github.com/MaginaLW/agent-for-mobile/blob/e1bae376217fc75b13094b2b04858ab93e692a29/docs/runs/2026-11-01-C1b底层源码与安全中心静态归因.md#7-恢复观察准备与宿主失败同日续记)的原轮在设备命令 0 条时失败；隔离原函数复现数组被合为无效程序路径。仅改单一路径选择后，固定 HEAD/clean 和 Node v24.20.0 查询成功，修订源码的纯宿主检查再次通过。没有执行修订观察入口或 ADB，不证明设备观察通过。

### Git Schannel 的凭据环境差异（2026-11-01，只读查询验证）

- **适用条件**：受限执行环境中 Git HTTPS 查询报 `AcquireCredentialsHandle failed: SEC_E_NO_CREDENTIALS (0x8009030e)`，而目标远端已核实。这个信号不能直接判为远端凭据过期。
- **有效做法**：保留错误、核对不含嵌入凭据的目标，按宿主权限流程在获准上下文执行同一个只读 `git ls-remote --heads origin refs/heads/main`，以区分权限上下文与实际远端故障；不关闭 SSL 校验、不改全局配置、不输出凭据。该方法不是脚本自动提权或所有认证错误的通用重试。
- **验证依据**：本轮受限上下文查询退出 128、报上述 Schannel 错误；获准宿主上下文的同一查询退出 0，返回与本地远端跟踪指针一致的 SHA。只证明这次查询的凭据环境差异，后续推送须独立核验结果，见[执行记录](https://github.com/MaginaLW/agent-for-mobile/blob/e1bae376217fc75b13094b2b04858ab93e692a29/docs/runs/2026-11-01-Mika借鉴解阻离线执行.md)。

### R1 受控验收的宿主与证据边界（2026-11-01）

- **适用条件**：验证 PC mobile Confirm 在执行器前阻断，需要来源、终止位置和无副作用证据，而不是复测手机确认卡。
- **有效做法**：工具的获准宿主上下文不自动等于 Windows 管理员。本轮非管理员事件订阅取消，用户授权 RunAs 后同冻结脚本的宿主正控成功；这只证明本次环境差异，不认定取消的唯一原因。使用已知离线子进程正控，先确认观测可用，不把“没事件”直接当“没执行”。
- **核验方法**：保留原始收据，按固定来源哈希、错误原件位置、终止点前后的实际控制流、暂停件及文件状态共同判读。中文抓取乱码会使精确文案匹配假阴性；对 PID/PPID/TIME_CREATED 复核能识别 PID 复用污染。不能把 conhost 等同执行器，也不能把临时准备单的额外“零后代”要求替换原验收契约。
- **验证依据与限制**：[R1 本轮记录](https://github.com/MaginaLW/agent-for-mobile/blob/e1bae376217fc75b13094b2b04858ab93e692a29/docs/runs/2026-11-01-R1原入口阻断验收.md)中原件 exit 1、定位第 111 行，三份 pause 和副作用状态一致，独立审查判原契约通过；观察器未全绿、无完整无丢事件保证。未重跑、未修原始收据；后续采集应先验证中文编码链并按进程实例/时间关联，不能宣称本轮已实现这些修复。

## 待办条目写的"必须解决"，先确认它描述的东西存在（2026-09-02）

backlog 记着「语义意图开关打开后，危险 `ui_action` 一律 `E_STALE_REF`，必须解决」。几条 grep 核实：整套机制在 `app/` 里零实现
（只存在于 spec 与那条 backlog），所以不是待修 bug 而是"别让实现继承的设计洞"；且"一律"过宽，只覆盖命中 `send_words` 的
II 级点击。**接手他人写的待办，第一步是让它落到具体文件与行号上**，落不下去说明描述本身要先修。

**同族错误——聚合/转述的信号被当成具体结论**：`exit 1` 要分跑了失败/根本没跑；catalog 漂移要分新增/修改/缺失；
待办要分已实现有缺陷/只存在于设计里。代价都是按错误形态去修。

## 信任根不能放在别人会自更新的目录里（2026-09-05）

钉定的 PowerShell 原先放在 Codex 运行时缓存里，2026-09-05 被 Codex 自行重装换代（7.6.4→7.6.5、SHA 与文件树全变，旧版不留）。
**判据写得再严，只要它指向第三方能随时替换的位置，就不是信任根，只是快照**——与"重装治不了新增文件"同族：手段作用不到成因上。

- 处置：把运行时**复制**到项目自控位置（`<repos-root>/_toolchain/powershell-7.6.5`）并冻结；迁移前原位复核 Authenticode，
  复制后逐文件重算 SHA 比对（不信任 `Copy-Item`），再编目。详见
  [钉定 PowerShell 迁出自更新缓存](https://github.com/MaginaLW/agent-for-mobile/blob/e1bae376217fc75b13094b2b04858ab93e692a29/docs/runs/2026-09-05-钉定PowerShell迁出自更新缓存.md)。
- **选钉定位置的判据**：这个路径由谁写？只要不是"只有本项目"，它就会漂。`~/.cache/**`、包管理器目录、IDE 自带运行时、
  `%TEMP%` 都不合格。

## 离线门也要验证自己消费的结果（2026-09-07）

09-05 的红门摘要写"因为 skipped 不等于 0"，读代码才发现旧 gate 允许两项 skip，真正拒绝的是硬编码 `pwsh_version=7.6.4`
——**环境缺口（缺符号链接特权）和报告消费缺陷是两件事**。现已把生产报告校验提到 `scripts/lib/check-summary.ps1`
（子进程版本须等于父进程版本；严格校验单行 JSON、重复键、类型与计数等式；真实 skip 单独拒绝并提示所需能力；
拒绝缺失/重复分片、零用例），`scripts/tests/check-summary-offline.ps1` 直接调用生产函数，不在 fixture 里另写一份 consumer。
generic reader 与 helper 专属 strict reader 的数值规则不同（如合法的 `5.0` 阈值），按各自字段合同验证。

## `.checks/` 会无界增长，按轮清理（2026-11-15）

- **现象**：每轮运行把原件、AVD 副本、候选 worktree 都留在 `.checks/<轮次>/`，到 11-15 累计约 77 GB，其中单轮最多 23 GB。
- **做法**：运行结论写进文档后，删除对应轮次目录；保留 `gradle-home`、`android-user-home`、`t` 以及仍在使用的驱动脚本目录。
- **坑**：Codex 沙箱账户创建的 `tmp/hsperfdata_*` 目录对当前用户只读，普通删除报 Access denied；不改 ACL 或提权，留给用户以管理员身份处理。

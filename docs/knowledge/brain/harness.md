# 大脑侧链路知识（headless / 按需挂载 / 两段式）

> 大脑侧链路与执行/验证 harness 的可复用经验：遇到对应情况时查。执行 harness 设计见
> [执行harness spec](../../specs/2026-07-17-执行harness-design.md)，入口 `scripts/dispatch.ps1`。
> 过程叙述与证据细节在 `docs/runs/` 对应记录与 git 历史里，本册只留结论与做法。

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

## 工序协调：A 直接问答，C 隔离验收（2026-09-08）

现行协议见 [backlog §1–7](../../backlog.md)；旧 A/B/C 三会话协议见 [历史归档](../../backlog-archive.md)
（历史 B 道记录能证明用户作过决定，不要求另开 B 会话）。

- **A 负责协调、离线开发与直接问答**；不可替代的用户选择由 A 收敛并取得真实答复，保留来源；子任务不能替用户授权。
  C 只验固定候选，不改代码。
- **协调来源随派工明确**：队列单写者；派工给出协调工作区/分支或 ref、摘要与回报对象；不假定 `main` 最新、
  不读过时 worktree 副本；会话 ID 每次传入，工具按运行时可用能力选。
- **复核验证收据，不只听自报。** 同一 SHA、受验内容、工具链、参数与环境未变时可复用完整验证结果，收据须能定位命令、
  日志、范围和结论。**复用结果不等于复用授权**：已消费或冻结的 one-shot 不得自动重跑，旧 PASS 不能覆盖冻结结果。
- **批次按触达的真机表面划分**；合并对象是已验的固定 SHA，不是前进中的分支 tip；离线通过不代替真机结论。
- **离线门也会竞争宿主资源**（2026-09-08：全局 mutex 被另一任务占用致子套件失败）。看见进程不等于证明句柄归属；
  保留环境失败、不干预他人任务，资源释放后只补验受影响的门，**分次补验不能改写成一次整合门全绿**。

### Codex C 证据必须在临时 worktree 回收前持久化（2026-08-12）

批次 4 的 Codex C 结束后 worktree 被清理，manifest/trace/截图路径失效，ledger 也没进 main，只能从 archived session 恢复。
**消息里出现过路径不等于证据已归档。** C 释放 worktree 前必须：

1. 把 ledger 原始行交给 main 单写者，按 run ID 验证 main 中**恰好一行**；dispatch 成功而 runner 后验失败时保留原始状态，不为迎合结论改写。
2. 把已脱敏的 manifest、trace、截图、cleanup 证据复制到主工作区 `docs/runs/evidence/<run-id>/`（gitignored，本机持久），
   逐文件记 SHA-256；token、私密配置、未脱敏输出不得复制。
3. 回报完整 SHA、task、run、逐腿结论、cleanup、ledger 去重结果与证据路径；完成前不得宣告完成。

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
| 审批对象上移到语义意图，批准后重走严格链 | 不放宽证据，backlog 记的正解；需另起 spec 与实现 |
| 目标缩到"屏幕亮着但没盯着" | 零安全代价，但偏离原诉求 |

第二道障碍：确认卡是 `TYPE_APPLICATION_OVERLAY`，**不显示在 keyguard 之上**，锁屏审批只能靠通知。
另：`category=call` 换不到通话级待遇（那属于 `CallStyle`，其按钮强制为接听/拒接，套不进允许/拒绝），已去掉；
紧急度由通道 `IMPORTANCE_HIGH` 提供。

## C1b：环境、全局 lease 与发布顺序都属于证据（2026-08-28）

> 旧 C1b 主机证据链已于 2026-10-09 退役，现行入口 `scripts/run-tablet-c1b.ps1`，规程见
> [C1b 规程](../../runbooks/T-L1-tablet-c1b.md)。旧主机链细节见 git 提交 7a3b069 前的历史。下面只留对新流程仍有用的通用教训。

- **success 最后发布**：先暂存并完成全部验证，再关闭 server/guard、释放 device lease；任何 cleanup 失败都不得留下 success。
  这样"成功"同时证明没有残留。
- **产物存在不等于证明已被接受**（2026-08-29）：Gradle 出了 APK 而 proof reader fail-closed，就必须冻结，不能拿临时产物继续。
- **fail-closed 不等于 failure observable**：早期失败（标识分配之前）也要有独立、已脱敏的失败记录，保留 phase 与 primary；
  记录写失败只能是 secondary，不得遮蔽 primary；cleanup 后出错也不能因"结果已发布"而吞掉失败记录。
- **失败消费顺序 primary-first**：子进程已发布结构化 failed summary 时，先读它的 primary/原因，再把 exit/stderr 作并列证据；
  validation 与 cleanup 时刻的快照分开，cleanup 成功不能覆盖失败瞬间；区分 absent / not_checked / rejected。
- **执行期的前置门，preflight 必须同等覆盖**：执行期"已存在即拒绝"的输出目录、"default ADB 进程/5037 listener 必须为零"、
  完整宿主树 pin，都要在授权前以同一规则只读检查，否则一次性授权会耗在环境门上。被动检查不运行 adb、不自动 kill 未知进程；
  snapshot 不可用与非零同样 fail closed。
- **一次性授权失败后冻结，不自动重试**；环境后来恢复也不复活旧授权，须重新形成候选与 preflight。
- **ADB 私有 server listen 必须写 `-L tcp:localhost:<port>`**（2026-08-29 源码复核：`tcp_host_is_local()` 只认空 host 或字面
  `localhost`，写 `127.0.0.1` 会 `LOG(FATAL)`、WER 表现为 `0xc0000409`）；client `-H/-P` 与 `ADB_SERVER_SOCKET` 仍可用 numeric
  `127.0.0.1`。与 USB 无关，不要加 `ADB_USB_LEGACY=1`。

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
  [钉定 PowerShell 迁出自更新缓存](../../runs/2026-09-05-钉定PowerShell迁出自更新缓存.md)。
- **选钉定位置的判据**：这个路径由谁写？只要不是"只有本项目"，它就会漂。`~/.cache/**`、包管理器目录、IDE 自带运行时、
  `%TEMP%` 都不合格。

## 离线门也要验证自己消费的结果（2026-09-07）

09-05 的红门摘要写"因为 skipped 不等于 0"，读代码才发现旧 gate 允许两项 skip，真正拒绝的是硬编码 `pwsh_version=7.6.4`
——**环境缺口（缺符号链接特权）和报告消费缺陷是两件事**。现已把生产报告校验提到 `scripts/lib/check-summary.ps1`
（子进程版本须等于父进程版本；严格校验单行 JSON、重复键、类型与计数等式；真实 skip 单独拒绝并提示所需能力；
拒绝缺失/重复分片、零用例），`scripts/tests/check-summary-offline.ps1` 直接调用生产函数，不在 fixture 里另写一份 consumer。
generic reader 与 helper 专属 strict reader 的数值规则不同（如合法的 `5.0` 阈值），按各自字段合同验证。

# STATUS 归档（只写不读）

STATUS.md 规定 ≤20 行，而它一度长到 27 行长段——原因是它逐渐变成了教训档案。
本文件收走**已闭环批次的详细复盘**，STATUS 只留一句指针。

**读法**：不要整读。需要某条教训时按标题跳；教训本身的正式落点是
[docs/knowledge/](knowledge/README.md) 与 [docs/backlog.md](backlog.md) 的复核清单，
本文件只保证原文不丢。

---

## 批次 1 时期（2026-07-26 ~ 08-01）

- **批次 1 二次验收通过，三腿一次连跑完成**（V2352A/Android16，commit `337113c`）。`20260801T143739-ff105d203a35` 一个 run 跑完 Allow→Stale→Deny，`status=passed`、退出码 0、`cleanup.ok=true`；三腿 `teardown.verdict` **均为 `clean`**，人只点了 3 次确认卡、中途一次框都没清。`confirmation` 依次 allowed/allowed/**denied**，`safety_code` 依次 OK/`E_STALE_REF`/`E_BLOCKED`，`dangerous_calls` 各 1、`input_evidence_matched` 各 true、`card_visible` 各 true。冷启动自举另由零 token 脚本 `p0-foreground-bootstrap-check.ps1` 单独验过：**重绑前 `event` → 重绑后 `bootstrap`，package 级无 activity，退出码 0**。
- **首次验收失败的教训（08-01 10:17，同一批次前一个 commit `899c095`）：判据必须能把"场景没构造成功"和"通过"分开。** 那轮 tracker 自举三次 `-Provision` 全程 `foreground_identity_source=event`、`bootstrap` 零次出现——**自举分支压根没被执行到，而失败形态与通过长得一模一样**（没有 `identity_unset` 卡死是事实，但不能记在自举头上）。修法不是调参数，是给"未触达"一个自己的名字：新脚本四态 `passed`/`not_reproduced`/`unavailable`/`failed`，退出码即结论。这是"用例把错误行为钉成预期"的同族风险第三次出现。
- **Deny 腿第一次上真机就抓到一个"最像成功"的假通过**：网关 debug 测试控制白名单只有 allow/stale、漏了 deny，`press_key` 直接回 `E_BLOCKED("debug 测试腿不在白名单", channel=test-control)`——**确认卡根本没弹**，31 秒结束。而 `E_BLOCKED` 恰是该腿的预期错误码，执行器照常报告"符合预期"。**拦住它的是 runner 独立读 app 私有文件里的 `confirmation`**（无真人决定即判失败）。这把「Deny 四条判据全部来自被测组件自报」从理论顾虑变成实锤。白名单已放开并补正反用例——**此前的用例把 `leg="deny"` 当"不支持的腿"，正在保护这个 bug**（同一类错误第二次：用例把错误行为钉成预期）。
- **Deny 腿带外验证手工做过一次**：经 runner 自己的 adb 通道截屏，marker `P0DENY-…` **原封不动留在输入框里**——微信发送后会清空输入栏，文字还在即发送没发生。注脚：那张截图消息列表往上滚了，"消息区无该 marker"**未被视觉证实**，扛结论的是输入框这条正证据。（后由批次 3 的 `deny_out_of_band` 自动化取代。）
- **Allow 腿卡五轮的真因：`press_key` 用未过滤的焦点节点走 a11y 通道，把 IME 通道短路了。** `viaNode` 直接对 `findFocus(FOCUS_INPUT)` 调 `ACTION_IME_ENTER`；微信会话页那个残留节点既不 focused 也不 editable，却**接受该动作并返回 true**（假成功），`viaNode || ImeBridge.enter()` 当场短路。**铁证**：同一调用序列里 `type_text` 报 `ime_commit_ocr`（无节点通道）而 `press_key` 报 `a11y_ime_enter`——两个工具对"有没有可用节点"的判断互相矛盾。这是《残留焦点节点连累三处》的**第四处**，而那条教训原文就是"要把所有取用该节点的路径一起改"。已统一到 `FocusedInputSnapshot.nodeUsableForAction`（只认 `IdentitySource.A11Y`）。修好后通道变为 `editor_action:send`——真正让它生效的是第 2 轮那条被挡住没执行到的修复：`ImeBridge.enter()` 原按「是不是多行」二选一且接反，安卓的约定是看 `NO_ENTER_ACTION`+actionCode，不看 multiLine（`EnterStrategyTest` 6 条用例钉住微信实测契约）。
- **方法论（最值钱的一条，已进 knowledge）：修不动的时候先加可观测性，别加假设。** 第 2 轮改完 EnterStrategy、结果照旧，而返回里没有通道信息，**连"修的地方有没有被执行到"都验证不了**；第 3 轮不再加假设，只给危险动作加了 `enter_channel`（走哪条路 + 输入框契约，成功失败都带），当轮定位真因。「回车开关」那条假设也在第 1 轮被证伪。

## harness 与仓库整改时期（2026-07-26 ~ 27）

- **harness 三处摩擦已修**：①派单锁按"能否独占打开"判活，崩溃残锁自动清；②`--allowedTools` 只是免确认名单——执行器真在本机跑起了 `Bash`，已补 `--disallowedTools`，越权扫描改为**失败路径上也跑**并写进 manifest；③开跑前零 token 预检（R 级 `p0_probe_region_state`，判据与宏共用同一实现），残留文字与"没停在会话页"都在派单之前拦下。
- **harness 判据五处修复（都由真机逼出来）**：①执行器调 `ReportFindings` 被越权扫描判死，**且发生在真人已允许、危险动作已执行之后**；②marker 归一化未做 O→0，把一次真正成功的发送判成"证据不匹配"；③"marker 在消息区"判据依赖 a11y 焦点几何，**在微信上结构性不可满足**，改为焦点几何结构性缺失时用设备自报的输入栏候选区划线；④零 token 预检在 `-Provision` 后必失效，加就绪重试；⑤终态报告不认 markdown 粗体——**而 dispatch 同一处会把 `**结果：失败**` 落进兜底分支记成 success**，台账层面最危险的错分，模式已收进 `dispatch-ledger.ps1` 由两处共用。
- **执行器工具面两次咬人，已按类补严**：`--allowedTools` 只是免确认名单，真正限制的是 `--disallowedTools`，而它是手写枚举。2026-07-26 `ToolSearch` 被越权审计误杀；07-31 执行器调 `ReportFindings` 把整腿判死。同轮发现 **`PowerShell` 一直没禁**（只禁了 `Bash`，而本机是 Windows，仓库里放着 gateway token）。现按类分组并加离线断言（两个 shell 必须成对）。详见 [brain/harness.md](knowledge/brain/harness.md)。
- **仓库整改（8 次提交）**：A 仓库卫生 + **危险动作提示词从 1204 行 PowerShell 收进 `scripts/tasks/*.tmpl.md`**（黄金回归逐字钉住）· B 一键校验 `scripts/check.ps1` · C 发送后验三态 · **跑测环境真因**（假 adb 里 `find` 被 Git Bash 的 Unix find 顶替、递归扫 C 盘到 30s 超时；此前误诊成机器负载与 stdin 各一轮）· D 凭据与审计加固 · E Deny 腿接进 runner · F 台账 `fail_reason` 列。
- **子代理复查（2026-07-27）修掉 9 处，其中两处是当轮核心改动自身的缺口**：①`fromOcrReadback` 把"OCR 一个字没读到"判成已发送——**换了触发条件的谎报成功**，且被我自己的用例固化成预期行为；②Allow 腿"必须 `sent_verified=true`"的断言写反；③Deny 提示词与严格签名自相矛盾；④后验预算 2s→6s；⑤a11y 腿补身份校验；⑥`preferredBounds` 补 ≥32 守卫；⑦TokenStore 落盘失败不再静默缓存；⑧`Stop-DevEnvGradleDaemon` 全机杀改显式 opt-in；⑨多处夸大的注释/manifest 字段改成如实措辞。
- **OCR 融合判定抽成纯函数 [OcrFusionPolicy.kt](../app/gateway/src/main/java/dev/magina/gateway/a11y/OcrFusionPolicy.kt)（15 条离线用例）**：规则原先埋在 `snapshot()` 的 55 行循环里，改一处要烧一轮真机。**两次更正（同一度量错误犯了两遍）**："`snapshot()` 317 行"与"`gatedOnly` 232 行"都是错的——两次都把"到下一个 `fun` 的距离"当函数长度。用括号匹配重测：全仓最长是 `ToolRegistry.callInternal`（179），其次 `snapshot`（130），**没有任何 200 行以上的函数**。

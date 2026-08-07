# 项目状态

> 每次会话收尾更新。保持 ≤ 20 行。**这里只放"影响下一步怎么做"的事**；
> 已闭环批次的详细复盘移出到 [docs/status-archive.md](docs/status-archive.md)（只写不读），
> 教训的正式落点是 [knowledge/](docs/knowledge/README.md) 与 [backlog 复核清单](docs/backlog.md)。

- **已通过并合入 main 的：批次 1**（干掉每跑一腿的人工前后置，`337113c`）· **批次 2**（通知栏审批）· **批次 3**（Deny 带外验证），后两批 `f08cda2`。批次 1 三腿一次连跑、`teardown.verdict` 全 `clean`、人只点 3 次卡。详细复盘见归档。
- **批次 2 判据 1 收窄为「屏幕亮着但人没盯着」**：锁屏审批与 D1 结构性冲突（`requireKnownForeground` 跑在 `policy.assess` 之前，锁屏时**卡与通知都不会出现**），用户 08-02 拍板"先收窄、再做语义意图"。**锁屏两条如实归档为从未验过、不当成通过。**
- **工序按"是否消耗人的精力"分三道并行**（[backlog](docs/backlog.md)）：A 独立闭环 / B 你一个决定 / C 你在真机旁。改动堆成**验收批次**、钉 commit SHA，把人的参与从"每个改动一次跑测"降到"一批一次"。队列写权在主会话，工序会话经 `git show main:` 读，干完主动 `send_message` 叫醒主会话。
- **语义意图审批 + 批准后重建证据：离线全部做完，在分支 `claude/serene-faraday-42d1fb` 上，main 行为一个字没变。** 生产装配已完成（钉 `67ab582`），开关随之打开；`§9.6` 会话标题读取器**已下沉到 `src/main`**，宏改调同一份，`ConversationSurfacePolicyTest` 在 `testReleaseUnitTest` 里跑得通即是"release 里也在"的机械证据。JVM 405 测试。
- **意图有效期用户 08-03 拍板 5 分钟**（语义："批准后最多隔多久回到微信"）：`foregroundWaitBudget`→300s、`intentTtl`→360s、`decisionTimeout` 保持 90s，关系写成构造断言（`intentTtl ≥ foregroundWaitBudget`；等前台超过证据 TTL 则**必须装配重建通道**——断言挂在能看见通道装没装的地方，不挂可写错的布尔）。**放宽有效期不放宽内容完整性**：执行前重读并与卡上摘要比对。
- **两处证据都要重建，两次都是离线挖出来的"上真机必然白跑"**：①输入证据按焦点身份取，而 IME 会话 id 每次 `onStartInput` 自增哈希必变；②`PreparedTargetEvidence` 同为 120s 硬要求。**两次的失败形态都与今天一模一样。** 三态 `Rebuilt`/`Mismatch`/`Unverified`，基线一律是卡上那份，**先验会话再验内容**。
- **比对方式两档**：a11y 严格 sha256；**OCR 归一包含**（`sha256` 逐位相等在 OCR-only 链上物理不可满足，且失败方向是**诬告用户改过内容**）。`contains` 弱在"发得比批准的多"→ 加长度守卫（容差 4）；**漏识导致的不匹配判 `Unverified` 而不是 `Mismatch`**——两者在 OCR-only 链上物理不可分，"读不准不敢放行" ≠ "确认你改过"。
- **下一步：批次 4 = 开关打开 + 四腿真机。卡口是第四条腿的 runner 支持**（`-Legs` 仍只接受 `Allow|Stale|Deny`）。只跑三腿只能证明"既有判据没退化"，**证不了新腿那份收益，而新腿是这批唯一的新增收益**。要求：**新腿必须真的在外面待够 60–90 秒**，否则碰不到那 5 分钟预算；配套断言 `awaitForeground` 的 `reads>1`、`waited_ms` 在区间内。
- **批次 4 现场三条防误判**（验收单已写）：**Stale 腿几十秒终态是对的**，且**挡住它的理由是"等前台恢复超时"而不是"包变了"**；**OCR 抖动导致的 `Unverified` 是正确的 fail-closed，不是功能不稳定**；`-Provision` 装的是 **debug APK**，所以**通过不能区分"功能成立"与"功能只在 debug 里成立"**。
- **跑前物理前置（都付过学费）**：微信停在「文件传输助手」· 输入框空 · 「回车发送」开着 · `zen_mode=0` · **输入栏上方无系统浮层**（联通流量提示那次把 teardown 判成 dirty）· **切 App 要真的切过去、界面显示出来再点通知**（上轮首跑没真切走，网关仍读到微信而以 `E_CHANNEL_DOWN` 终止）· **跑真机时别同时跑离线闸门**（310MB 可用内存下套件退化成顺序单分片，成片超时与代码无关却最像"新判据不稳"）。
- **判据纪律（本轮反复付学费，已进 [backlog 复核清单](docs/backlog.md)）**：断言源码文本 = 未覆盖 · 断言"个数>0"会替坏掉的注入打掩护 · **对照实验本身也需要一次对照**（短路没写进去 → 全绿 → 会读成"判据不灵"，方向正好反）· **判据与物理通道相不相称，要等真的去接才暴露** · 判据要挂在能被机械验证的东西上，不挂需要有人记得填对的字段。
- **遗留/障碍**：**开关打开后非宏路径的危险 `ui_action` 一律 `E_STALE_REF`**（只有 P0 准备宏记录目标会话证据；fail-closed 且今天无人走该路径，但**这处收窄在本批验收里看不出来**，接任务 4/2 端到端前必须解决，已进 [backlog §6](docs/backlog.md)）；C 道新 worktree 首跑要 `local.properties`（gitignored）+ 先构建 APK，**已由预热踩掉**；跑 runner 前不要手动切 IME（会把"原输入法"记成网关）；审计目录迁 filesDir 未做；S5 RemoteInput、S2 Shizuku 重启存活、`share_file` activity 级 verify 待补；`ToolRegistry.callInternal` 179 行仍是全仓最长。

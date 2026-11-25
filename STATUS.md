# 项目状态

> 更新 2026-11-25。本页只写：现在能做什么、卡在哪、下一步。待办与有效决定见 [backlog](docs/backlog.md)。
> 2026-11-15 之前的过程记录、平板双窗研究和历史状态已移出主树，需要时用 `git show e1bae37:<路径>` 查看（如 `git show e1bae37:STATUS.md`）。

## 现在能做什么

| 能力 | 状态 | 依据 |
|---|---|---|
| 网关 App（无障碍 + MCP HTTP + 工具 + 安全门） | 历史手机上跑通；PA2553 上确认卡 overlay、开机恢复、中文 `ime_commit` 已真机验证；2026-11-16 对齐普通具名点击、常规回车、黑名单出站与同应用平行视界规则，并于 2026-11-22 在 PA2553 横屏微信验证 `SAME_APP_MULTI`、`ocr_reverify=exact_nav`、`IME_CURSOR_ANCHOR`、`ime_commit_ocr` 与 `ConfirmOverlay` 发送投递闭环（跨应用分屏与未知多窗仍严格 fail-closed）；2026-11-24 完成 Ktor CIO 传输保活/异常兜底加固、`ToolRegistry`/`GatewayA11yService` 模块拆分及 M3 宏引擎落地（commit `57c4532`），并在 PA2553 实机验通新版 `skillpack_lookup`、`ocr` 上报与 `xhs_search_prepare` 6/6 宏引擎 + `origin=macro` 审计全链；2026-11-25 完成并行合流、M3 多宏转正与 Wave 2 真机验收：新增 `WindowTopologyPolicy` 瞬态空包名短重读、`SubtreeLabelPolicy` 严格子树标签聚合、`ToolCatalog` 信封文档、`jd_readonly_prepare` 京东只读前置宏（未登录态 `[AWAIT_CONFIRM]` 保持 `verified: ""`，因京东不可登录暂搁），以及替代接入哔哩哔哩 `bili_readonly_prepare`（35s 汇总 5 条公开视频，`0` ConfirmOverlay）；目前 `taobao_readonly_prepare`（20s）、`wechat_readonly_prepare`（24s）、`xhs_search_prepare`（34s / 119k in_tok 纯列表摘要）与 `bili_readonly_prepare`（35s / 152k in_tok）**4 枚前置宏**均已转正 `verified: "2026-11-25"` | [overlay 记录](docs/runs/2026-11-10-无障碍overlay确认卡真机验证.md)、[开机恢复](docs/runs/2026-11-12-网关开机恢复离线.md)、[设定对齐 spec](docs/specs/2026-11-16-网关与派单设定对齐-design.md)、[M3 宏 spec](docs/specs/2026-11-24-M3-宏系统与技能包-design.md)、[11-24 PA2553 验收](docs/runs/2026-11-24-PA2553阶段3与M3宏样板真机验收.md)、[11-25 并行验收](docs/runs/2026-11-25-PA2553并行双线真机验收.md)、[11-25 双宏转正与 Wave 2 验收](docs/runs/2026-11-25-PA2553-M3双宏转正与Wave2验收.md)、[11-25 B 站只读宏验收](docs/runs/2026-11-25-PA2553-B站只读宏验收.md)、[PR #47](https://github.com/MaginaLW/agent-for-mobile/pull/47)、[PR #79](https://github.com/MaginaLW/agent-for-mobile/pull/79)–[#83](https://github.com/MaginaLW/agent-for-mobile/pull/83)、[PR #86](https://github.com/MaginaLW/agent-for-mobile/pull/86)–[#90](https://github.com/MaginaLW/agent-for-mobile/pull/90) |
| 派单（Codex CLI + gateway） | 可用；入口 `scripts/dispatch.ps1`（固定 `codex + gateway`），内建预检与自启恢复；2026-11-24 在 PA2553 实机验通冷态起服后的非设置前台有界无障碍重绑恢复、前导 `:` 与 `AutoSendImageService` 精确还原，以及 `report-ledger.ps1` 统计脚本（2026-11-25 扩展 `m3-*` 归类至 `macro` 类别，并收敛 `gateway-executor-preamble.md` / 任务卡为 `data.status` / `data.final_snapshot` 与小红书纯列表摘要） | [执行 harness spec](docs/specs/2026-07-17-执行harness-design.md)、[设定对齐 spec](docs/specs/2026-11-16-网关与派单设定对齐-design.md)、[11-24 PA2553 验收](docs/runs/2026-11-24-PA2553阶段3与M3宏样板真机验收.md)、[11-25 双宏转正与 Wave 2 验收](docs/runs/2026-11-25-PA2553-M3双宏转正与Wave2验收.md)、[PR #86](https://github.com/MaginaLW/agent-for-mobile/pull/86) |
| 危险动作两段式硬门 | PA2553 本地测试按钮的真人 Allow、Stale、Deny 均通过；2026-11-22 横屏微信已真机全链验通「获授权草稿备稿 → 设备端 ConfirmOverlay 真人批准 → 固定裁区复核（`context=rechecked`）→ 实际点击「发送」→ 右窗消息区投递」 | [本地按钮实测](docs/runs/2026-11-19-PA2553本地确认卡验收.md) · [微信横屏发送与投递实测](docs/knowledge/apps/wechat.md#pa2553-起点-3-桌面就位确认卡发送投递与起点-2-根因定位) |
| 占位工具 | `notifications_list`、`notification_reply`、`ui_diff`、`app_stop` 已从 `tools/list` 下架，按需实施时再挂回 | [能力现状](docs/knowledge/android/m1b-capabilities.md)、[设定对齐 spec](docs/specs/2026-11-16-网关与派单设定对齐-design.md) |

## 11 月 18 日修复与离线验证

派单预检现在只回收本轮创建的服务和端口转发，前台应用未知时停止重绑。同包切窗只有在新旧窗格都可见时才沿用身份。派单台账区分网关工具失败和传输失败，凭据扫描也能识别紧邻中文或重音字母的 token。[台账判读方法](docs/knowledge/brain/harness.md)

这批修复的最后一个代码提交为 `9c69577`。完整离线检查 9/9 通过，含派单回归 56 项、监督式 runner 89 项。Android Debug 476 项、Release 379 项单测均通过，两个版本的 Lint 和构建也已通过。本轮未做真机验收。

## PA2553 小红书实测（2026-11-18 至 19）

提交 `a9aee63` 修复了搜索框将字段标签并入无障碍读回时的误判。修复版真机已通过中文输入、精确读回和点击「搜索」提交。该提交的完整离线检查 9/9 通过，Android Debug 477 项、Release 380 项单测通过。两次临时切换输入法后均已恢复原设置并逐项读回。[真机验收记录](docs/runs/2026-11-18-PA2553小红书只读验收.md)

执行器在小红书内提交「东京三日游」后，结果页一度空白。用户切换页面、看到内容后，执行器沿用该查询，98 秒内按顺序核对五条笔记并汇总，三条来自详情、两条来自列表。M0-3 的搜索和阅读均有真机证据，中间有现场协助。八次派单中两次成功、六次失败均已入账。[五条笔记与各轮结果](docs/runs/2026-11-18-PA2553小红书只读验收.md#修复版提交查询后的五条笔记)

11 月 19 日，PA2553 从本地测试 App 通过深链提交「东京三日游」，一次派单 73 秒读完五条不同笔记，其中两条取自详情，三条取自列表摘要，全程无现场协助。[五条笔记及验收依据](docs/runs/2026-11-18-PA2553小红书只读验收.md#11-月-19-日单次无人协助搜索)

## 卡在哪

PA2553 微信横屏的 `IME_CURSOR_ANCHOR` 生产接线与横屏就位宿主回执已随 [PR #47](https://github.com/MaginaLW/agent-for-mobile/pull/47)（`30dd179` / `3d700cc`）及后续左窗与冷启聚焦五笔修复（[PR #79](https://github.com/MaginaLW/agent-for-mobile/pull/79) `96c6d85`、[PR #80](https://github.com/MaginaLW/agent-for-mobile/pull/80) `3c58d7d`、[PR #81](https://github.com/MaginaLW/agent-for-mobile/pull/81) `39e2203`、[PR #82](https://github.com/MaginaLW/agent-for-mobile/pull/82) `a90d86e`、[PR #83](https://github.com/MaginaLW/agent-for-mobile/pull/83) `a3d272c`）全部合入 `main`。PA2553 已依次真机验通：**起点 1（已聚焦右窗，`36s`）**、**起点 3（桌面启动，`48s`）**、**获授权备稿 + 单次设备端 ConfirmOverlay 发送与右窗消息区投递全链**（`a-000039` `confirmation=allowed;decided_via=overlay;context=rechecked`）、**起点 2 左窗点击切入冷 `ChattingUI`**（`a90d86e` / `83cf0654...788b`，`a-000004` `ocr_reverify=exact_nav` 切开右窗 `win=418`），以及 **冷 `ChattingUI` 经底栏唯一「可按住转文字」自动聚焦并通过 `Test-LandscapeEditorReceipt`**（`47s`，退出码 `0`，`a-000017` `ocr_reverify=exact_nav` → `inputType=0x24001` → `IME_CURSOR_ANCHOR` `[1048,1834,2578,1946]`）。横屏就位两段核心能力均已实机闭环，无阻断性缺口；单笔派单连跑「左窗 → 冷 `ChattingUI` → 聚焦就位」属可选补验，标准竖屏 P0（`Allow`/`Stale`/`Deny`）继续独立暂缓。[左窗导航与冷启聚焦实测闭环](docs/knowledge/apps/wechat.md#pa2553-起点-2-左窗导航与冷-chattingui-自动聚焦实测闭环) · [PR #82](https://github.com/MaginaLW/agent-for-mobile/pull/82) · [PR #83](https://github.com/MaginaLW/agent-for-mobile/pull/83)

11 月 17 日派单的前三次网关调用成功；随后的 `ui_action` 和 `app_launch` 均报告 HTTP 请求发送失败，两次都没有收到网关结果。同期 stderr 的六条超时来自模型管理器。既有记录尚无法区分端口转发、网关服务或连接本身在哪一段中断；现已在派单收尾接入无凭据只读健康快照（[PR #86](https://github.com/MaginaLW/agent-for-mobile/pull/86)，离线验通），以便后续复现直接定位。[派单错误的判读方法](docs/knowledge/brain/harness.md)

11 月 18 日的八次小红书派单均通过预检，当天结果页空白的原因仍未知。此前的无障碍解绑和桌面深链被系统弹窗阻挡各有独立记录，长期绑定稳定性仍待观察。[无障碍记录](docs/knowledge/android/vivo-originos.md) · [小红书实测](docs/knowledge/apps/xiaohongshu.md)

## PA2553 非微信主验收（2026-11-18）

三项均取得业务结果。蓝牙在 66 秒内关闭、复核并恢复开启，派单前后的独立系统读数一致。京东启动先遇系统提示，再次接读时停在登录页；用户指定换用淘宝后，执行器在 90 秒内核对到最近一笔有物流的订单已签收。小红书读到五条，中间有现场协助。按首次派单、全程无人协助计，本机为 1/3，历史 M0 为 3/3。[三项任务与历史 M0 的对照](docs/runs/2026-11-18-PA2553非微信主验收.md)

网关、窗口识别与派单修复已合入 `main`，合并提交为 `70d50a5`。候选 `ad0cf1e` 的完整离线检查 9/9 通过，含 Android Debug 477 项、Release 380 项单测及两个版本的 Lint 和构建。合并提交与受测候选的文件树一致。[PR #18](https://github.com/MaginaLW/agent-for-mobile/pull/18)

## PA2553 本地测试 App 确认卡验收（2026-11-19）

本地确认卡验收已收尾，记录经 PR #21 合入 `main`（`246ad90`）。现场允许后，测试按钮的回调从 0 增至 1。允许后页面切换、现场拒绝两种情况下，回调均保持 0，拦截后的工具调用也均为 0。平板已保留新版测试 App，匹配的测试签名库已受限保管。[验收记录](docs/runs/2026-11-19-PA2553本地确认卡验收.md) · [PR #21](https://github.com/MaginaLW/agent-for-mobile/pull/21)

## 微信横屏就位与发送闭环（2026-11-20 至 11-22）

- **关键突破点**：
  1. **固定 OCR 裁区**：消除确认前后 1px 裁区偏移引发的 `E_STALE_REF` 误拦截（[离线对照](docs/runs/2026-11-20-OCR固定裁区离线对照.md#同一-ocr-引用的固定裁区对照) · [真机回执](docs/knowledge/apps/wechat.md#一像素边框差异的真机回执)）。
  2. **Pathway 4B 封口无障碍输入节点路线**：实测证实微信 `service_focus` 与两个 `EditorInfo.fieldId` 命中节点均为 100% 空壳剥离桩（`bounds=[0,0,0,0]`、`input_type=0`、`focused=false`、`visible=false`、`view_id_state="missing"`），彻底关闭依赖无障碍节点识别编辑框的路线（[4A/4B 实测](docs/knowledge/apps/wechat.md#pa2553-真机只读实测pathway-4a-打通右窗编辑框归属4b-封口无障碍节点路线)）。
  3. **Pathway 4A `IME_CURSOR_ANCHOR` 生产打通**：经 API 21 单参数 `requestCursorUpdates(CURSOR_UPDATE_IMMEDIATE)`（`legacy_1arg`）在零新增权限下取得右窗输入栏精确屏幕四边 `[1048,1834,2578,1946]` 与可见插入光标，并在不相交双窗门控下严格唯一归属至右窗 `ChattingUI`（[PR #47](https://github.com/MaginaLW/agent-for-mobile/pull/47)）。
  4. **左窗导航与冷启自动聚焦闭环**：合入 `<60px` 2x `resolveOcr` 兜底（[PR #79](https://github.com/MaginaLW/agent-for-mobile/pull/79)）、分窗 1:1 切片 `OcrTilePlanner`（[PR #80](https://github.com/MaginaLW/agent-for-mobile/pull/80)）、普通 4+ 字导航 `ocr_reverify=exact_nav`（[PR #81](https://github.com/MaginaLW/agent-for-mobile/pull/81)）、2,334 对繁转简折叠与繁体危险词防护（[PR #82](https://github.com/MaginaLW/agent-for-mobile/pull/82)），以及冷 `ChattingUI` 底栏唯一「可按住转文字」白名单单次点击与重读校验（[PR #83](https://github.com/MaginaLW/agent-for-mobile/pull/83)）。
- **最终实机结论**：PA2553 上**起点 1（已聚焦右窗，`36s`）**、**起点 3（桌面启动，`48s`）**、**获授权备稿（`ime_commit_ocr`）+ 设备端 `ConfirmOverlay` 发送与右窗消息区两行投递全链**、**起点 2 左窗导航切入冷 `ChattingUI`** 及 **冷启自动聚焦就位（`47s`，exit `0`）** 均已真机验通，全轮 4 项基线设置与双无障碍绑定双读回复原；第二轮隔离 API 36 实验（[PR #75](https://github.com/MaginaLW/agent-for-mobile/pull/75)）已全部结案（`request-matrix` 收口为窄 AOSP 边界不进真机，`ime-menu` / `assistant-structure` 作为离线已验备选保留）。
- **明细链接**：[三项补充实验与 4A/4B 收口](docs/knowledge/apps/wechat.md#三项离线补充实验实测收口与第四路线cursoranchorinfo--4b-遥测) · [4A/4B 真机实测](docs/knowledge/apps/wechat.md#pa2553-真机只读实测pathway-4a-打通右窗编辑框归属4b-封口无障碍节点路线) · [起点 1 实测](docs/knowledge/apps/wechat.md#pa2553-起点-1已聚焦右窗生产横屏就位实测通过) · [起点 3 与确认卡投递](docs/knowledge/apps/wechat.md#pa2553-起点-3-桌面就位确认卡发送投递与起点-2-根因定位) · [起点 2 与冷启聚焦闭环](docs/knowledge/apps/wechat.md#pa2553-起点-2-左窗导航与冷-chattingui-自动聚焦实测闭环) · [OCR 固定裁区对照](docs/runs/2026-11-20-OCR固定裁区离线对照.md#同一-ocr-引用的固定裁区对照)

## 阶段 3 稳定性与只读可用性离线加固（2026-11-23）

- **R3.1 无障碍基线还原**：定位切换输入法时原 vivo 输入法异步移除 `.AutoSendImageService` 及脚本前导 `:` 丢失、300ms RMW 竞态，已在派单与 P0 准备脚本补齐精确基线还原与抗抖动重读（[vivo 记录](docs/knowledge/android/vivo-originos.md)）。
- **R3.2 `mcp-transport-failure` 只读取证**：派单收尾识别传输失败时自动将无凭据只读健康快照（`adb forward --list`、`/health`、`GatewayService` 与 `a11y` 绑定摘要）写入本地 `docs/runs/traces/`（[harness 记录](docs/knowledge/brain/harness.md)）。
- **R3.3 非微信日常只读任务包与守卫对齐**：同步小红书/淘宝/京东/系统设置深链与 `assets/skillpack/`，修复设置回退并暴露 `actual_package` 及只读工具 `skillpack_lookup`（[实测深链库](docs/knowledge/apps/deeplinks.md)）。
- **离线验证与边界**：代码最终提交 `30fe7cd` 完整离线检查 `./scripts/check.ps1` **10/10 通过**（492 项 Release JVM 单测、Debug/Release Lint 与构建、63 项派单回归、159 项 runner 回归、4 项 `skillpack-sync` 校验、凭据扫描全绿）。离线通过不代替真机验证，本轮尚未在 PA2553 执行真机派单或重装网关 APK。

## 阶段 4：工程加固、模块解耦、M3 宏系统与 PA2553 双线验收（2026-11-24 至 11-25）

- **Phase 1 工程加固与质量门补全（`fd87443`）**：清理 `.checks/` 历史轮次目录释放 ~84.8 GB；对齐 [m1b-capabilities.md](docs/knowledge/android/m1b-capabilities.md) 工具下架与 `"ocr"` 能力位；为 `McpServer` 配置 CIO 180s 空闲超时、端口复用及脱敏 JSON-RPC `-32603` 兜底；新增 `scripts/report-ledger.ps1`、可选 `.githooks/pre-commit`（`scripts/install-git-hooks.ps1`），并将 5 套 `local-testbench-*-offline.ps1` 与台账统计离线测试纳入 `scripts/check.ps1`（12/12 通过）。
- **Phase 2 核心模块解耦（`94b8dcd`）**：将 `ToolRegistry.kt` 拆分为 `ToolCatalog.kt`、`ToolExecutionPipeline.kt`（引入 `CallOrigin.MACRO` 零旁路审计标记）与薄外观 `ToolRegistry.kt`；将 `GatewayA11yService.kt` 抽离 `A11yDiagnosticsFormatter.kt`、`A11yGestureController.kt`、`A11yOcrCoordinator.kt`。
- **Phase 4 M3 宏系统与真机首跑（`57c4532` 实装 PA2553）**：
  - 落成 [M3 设计说明](docs/specs/2026-11-24-M3-宏系统与技能包-design.md) 与 `dev.magina.gateway.macro`（`MacroSpec`、`MacroCatalog`、`MacroEngine`），注册 `skill_macro_list`（R）与 `skill_macro_exec`（W，强制经 `ToolRegistry.callFromMacro` 走完整黑名单/`SafetyGate`/`ConfirmOverlay` 管线），并新增只读样板 `xhs_search_prepare`。
  - **PA2553 阶段 3 + M3 实机核验、双宏转正、Wave 2 结案与 B 站替代验收（11-24 至 11-25）**（[11-24 验收](docs/runs/2026-11-24-PA2553阶段3与M3宏样板真机验收.md) · [11-25 对照归因](docs/runs/2026-11-25-PA2553-M3宏收敛对照与阻断归因.md) · [11-25 并行验收](docs/runs/2026-11-25-PA2553并行双线真机验收.md) · [11-25 双宏转正与 Wave 2 验收](docs/runs/2026-11-25-PA2553-M3双宏转正与Wave2验收.md) · [11-25 B 站只读宏验收](docs/runs/2026-11-25-PA2553-B站只读宏验收.md)）：① 冷态无进程且 `GatewayA11yService` `Crashed` 时先 `am start MainActivity` 再 `run-as ... am start-foreground-service` 起服，验通 PR #86 有界重绑与前导 `:`; ② 并行分支（[PR #88](https://github.com/MaginaLW/agent-for-mobile/pull/88) `2fc5f53`）落地 `WindowTopologyPolicy` 瞬态空包名短重读、`SubtreeLabelPolicy` 严格子树标签聚合（不改 `SafetyGate`）与 `taobao_readonly_prepare`（20s 转正 `verified: "2026-11-25"`）；③ Wave 1 提示词与任务卡收敛（明确 `data.status`/`data.final_snapshot` 信封读取、收敛小红书为纯列表摘要并禁点无标签卡片按钮、新增 `wechat-readonly-prepare.md`、扩展 `report-ledger.ps1` `m3-*` 归类）零重装验通：`wechat_readonly_prepare` **1 轮 24s `success`**、`xhs_search_prepare` **34s / 119,068 in_tok `success`**（0 ConfirmOverlay，全面优于 `73s / 322,497` 基线），双双转正 `verified: "2026-11-25"`；④ Wave 2A 淘宝「查看物流」单变量诊断配合用户归因结案（11-24 实为闪购/外卖订单无快递页，`交易关闭` 订单 `更多` 仅含 `删除订单`，网关代码零改动）；⑤ Wave 2B 新增 `jd_readonly_prepare`（[PR #89](https://github.com/MaginaLW/agent-for-mobile/pull/89)），因京东无法登录暂搁（`verified: ""`），按用户指示替代接入哔哩哔哩（`tv.danmaku.bili`，[PR #90](https://github.com/MaginaLW/agent-for-mobile/pull/90)）`bili_readonly_prepare`：首轮命中 `com.vivo.appfilter` 干净 `[AWAIT_CONFIRM]` 暂停（27s），放行后 **35s / 151,966 in_tok `success`**（5/5 宏子步 `OK`，具名点击「暂不开启」关推送提示并汇总 5 条公开视频，0 ConfirmOverlay），转正 `verified: "2026-11-25"`。

## 下一步

- **M3 已验样板与扩展**：`taobao_readonly_prepare`、`wechat_readonly_prepare`、`xhs_search_prepare`、`bili_readonly_prepare` 均已转正 `verified: "2026-11-25"`；京东因不可登录暂搁，后续按需为其他高频无登录只读场景扩展确定性前置宏。
- **日常只读链路待观察项**：`mcp-transport-failure` 现场快照待后续真机传输失败复现时自然取证；淘宝查物流任务按更新后的知识与任务卡跳过闪购/外卖与关闭订单并优先核对 `待收货` 或快递实物订单。
- **M1-T 尾项**：横屏微信就位、备稿与确认卡发送已闭环；「左窗 → 冷 `ChattingUI` → 聚焦右窗」单笔合流派单为可选补验，标准竖屏 P0（`Allow`/`Stale`/`Deny`）继续独立暂缓。详见 [下一轮任务安排](docs/backlog.md#1-下一轮任务安排)。

## 2026-11-15 精简

按用户要求处理过度建设（[PR #17](https://github.com/MaginaLW/agent-for-mobile/pull/17)）：删除平板双窗研究栈、M1 spike 探针和派单中已退役的 Claude 分支；STATUS/backlog/README/AGENTS 压缩，历史过程记录移出主树。跟踪文件 484 → 240，完整离线门 19 项约 15 分钟 → 9 项约 3.5 分钟，9/9 通过；未做真机验证。

## 已放弃或暂停

- **平板双窗（微信同 App 双 OS window）适配**：拿不到可验证的同代窗口来源，微信无障碍树也读不到内容，结论 NO-GO。研究代码已于 2026-11-15 删除，结论保留在 [平板知识](docs/knowledge/android/tablet.md)。生产网关改用「单窗口与同应用平行视界支持、跨应用分屏/小窗 fail-closed」三层窗口策略，详见 [设定对齐 spec](docs/specs/2026-11-16-网关与派单设定对齐-design.md)。
- 手机批次 4（语义意图四腿）、语义意图生产接线：暂停。
- M2（Claude/Termux 上机）：取消。

## 里程碑

| 里程碑 | 状态 |
|---|---|
| M0 mobile-mcp 真机验收 | 完成（2026-07-16，4.5/5，[记录](docs/runs/2026-07-16-M0.md)） |
| M1 自研网关 | PA2553 非微信三项主验收已执行（首次无干预完成率 1/3，历史 M0 为 3/3）；2026-11-24/25 在 PA2553 上真机验通 PR #86 无障碍重绑与基线精确还原、新版 `skillpack_lookup` 与 `ocr` 上报，淘宝「查看物流」回弹已归因闪购/外卖订单并收口（`交易关闭` 仅含 `删除订单`），`mcp-transport-failure` 快照待传输失败复现采集 |
| M1-T 平板 | T0-L 入场完成；微信双窗研究路线放弃，生产网关支持单窗口与同应用平行视界（跨应用/未知多窗 fail-closed）；2026-11-22 PA2553 横屏微信三起点（已聚焦右窗 / 桌面启动 / 左窗导航+冷启聚焦）与 `ConfirmOverlay` 发送投递全链真机闭环（PR #47、#79–#83）；标准竖屏 P0 独立暂缓 |
| M2 大脑上机 | 取消 |
| M3 宏、入口、技能包 | 引擎及 5 个前置宏已就绪并实机验证：`taobao_readonly_prepare`（20s）、`wechat_readonly_prepare`（24s）、`xhs_search_prepare`（34s / 119k in_tok 纯列表摘要）与 `bili_readonly_prepare`（35s / 152k in_tok 公开推荐流）均已转正 `verified: "2026-11-25"`；`jd_readonly_prepare` 5/5 宏子步真机验通（因京东不可登录暂搁，保持 `verified: ""`）；`SubtreeLabelPolicy`、瞬态空包名多窗重读及 `report-ledger.ps1` `m3-*` 归类均已落地 |

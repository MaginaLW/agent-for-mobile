# 项目状态

> 更新 2026-11-27。本页只写：现在能做什么、卡在哪、下一步。待办与有效决定见 [backlog](docs/backlog.md)。
> 2026-11-15 之前的过程记录、平板双窗研究和历史状态已移出主树，需要时用 `git show e1bae37:<路径>` 查看（如 `git show e1bae37:STATUS.md`）。

## 现在能做什么

| 能力 | 状态 | 依据 |
|---|---|---|
| 网关 App（无障碍 + MCP HTTP + 工具 + 安全门） | 历史手机上跑通；PA2553 上确认卡 overlay、开机恢复、中文 `ime_commit` 已真机验证；2026-11-16 对齐普通具名点击、常规回车、黑名单出站与同应用平行视界规则，并于 2026-11-22 在 PA2553 横屏微信验证 `SAME_APP_MULTI`、`ocr_reverify=exact_nav`、`IME_CURSOR_ANCHOR`、`ime_commit_ocr` 与 `ConfirmOverlay` 发送投递闭环（跨应用分屏与未知多窗仍严格 fail-closed）；2026-11-24 完成 Ktor CIO 传输保活/异常兜底加固、`ToolRegistry`/`GatewayA11yService` 模块拆分及 M3 宏引擎落地（commit `57c4532`），并在 PA2553 实机验通新版 `skillpack_lookup`、`ocr` 上报与 `xhs_search_prepare` 6/6 宏引擎 + `origin=macro` 审计全链；2026-11-25 完成并行合流、M3 多宏转正与 Wave 2 真机验收，2026-11-26 完成阶段 5A `skip_if_ref_missing` 与双深化宏实测转正，2026-11-27 在 PA2553（`5750321` / `0.2.0-m3`）完成阶段 6A 冷启/4-Tab 控制台只读与现场目视验收、以及阶段 6B-2 全部 7 枚系统内置 App 宏真机验收转正：目前 `taobao_readonly_prepare`（20s）、`wechat_readonly_prepare`（24s）、`xhs_search_prepare`（34s / 119k in_tok 纯列表摘要）、`bili_readonly_prepare`（35s / 152k in_tok）、`bili_readonly_feed_prepare`（27s / 32s）、`taobao_orders_prepare`（25s / 53k in_tok 直达「全部订单」）及 7 枚系统内置 App 宏（`settings_state_readonly_check` 22s、`calculator_readonly_prepare` 20s、`clock_readonly_prepare` 17s、`calendar_readonly_prepare` 18s、`filemanager_readonly_prepare` 18s、`notes_readonly_prepare` 21s、`gallery_readonly_prepare` 21s）总计 **13 枚前置只读宏**均已转正（仅 `jd_readonly_prepare` 保持 `""`） | [overlay 记录](docs/runs/2026-11-10-无障碍overlay确认卡真机验证.md)、[开机恢复](docs/runs/2026-11-12-网关开机恢复离线.md)、[设定对齐 spec](docs/specs/2026-11-16-网关与派单设定对齐-design.md)、[M3 宏 spec](docs/specs/2026-11-24-M3-宏系统与技能包-design.md)、[11-24 PA2553 验收](docs/runs/2026-11-24-PA2553阶段3与M3宏样板真机验收.md)、[11-25 并行验收](docs/runs/2026-11-25-PA2553并行双线真机验收.md)、[11-25 双宏转正与 Wave 2 验收](docs/runs/2026-11-25-PA2553-M3双宏转正与Wave2验收.md)、[11-25 B 站只读宏验收](docs/runs/2026-11-25-PA2553-B站只读宏验收.md)、[11-26 阶段 5A 验收](docs/runs/2026-11-26-PA2553-阶段5A深化宏与冷态起服验收.md)、[11-27 阶段 6A+6B-2 验收](docs/runs/2026-11-27-PA2553-阶段6A冷启与6B-2系统内置App真机验收.md)、[PR #47](https://github.com/MaginaLW/agent-for-mobile/pull/47)、[PR #79](https://github.com/MaginaLW/agent-for-mobile/pull/79)–[#83](https://github.com/MaginaLW/agent-for-mobile/pull/83)、[PR #86](https://github.com/MaginaLW/agent-for-mobile/pull/86)–[#91](https://github.com/MaginaLW/agent-for-mobile/pull/91) |
| 派单（Codex CLI + gateway） | 可用；入口 `scripts/dispatch.ps1`（固定 `codex + gateway`），内建预检与自启恢复；2026-11-24 在 PA2553 实机验通冷态起服后的非设置前台有界无障碍重绑恢复、前导 `:` 与 `AutoSendImageService` 精确还原，以及 `report-ledger.ps1` 统计脚本（2026-11-25 扩展 `m3-*` 归类至 `macro` 类别，并收敛 `gateway-executor-preamble.md` / 任务卡为 `data.status` / `data.final_snapshot` 与小红书纯列表摘要）；2026-11-26 新增显式冷态起服脚本 `scripts/bootstrap-gateway.ps1`（维持 `dispatch.ps1` 默认不抢前景焦点）并扩展 `report-ledger.ps1` 支持 `paused` 列、`bili` 类别与 `-ByMacro` 细分统计 | [执行 harness spec](docs/specs/2026-07-17-执行harness-design.md)、[设定对齐 spec](docs/specs/2026-11-16-网关与派单设定对齐-design.md)、[11-24 PA2553 验收](docs/runs/2026-11-24-PA2553阶段3与M3宏样板真机验收.md)、[11-25 双宏转正与 Wave 2 验收](docs/runs/2026-11-25-PA2553-M3双宏转正与Wave2验收.md)、[11-26 阶段 5A 验收](docs/runs/2026-11-26-PA2553-阶段5A深化宏与冷态起服验收.md)、[PR #86](https://github.com/MaginaLW/agent-for-mobile/pull/86)、[PR #91](https://github.com/MaginaLW/agent-for-mobile/pull/91) |
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
- **阶段 5A M3 宏深化与派单运维离线落地与 PA2553 真机验收（2026-11-25 至 11-26，已随 [PR #91](https://github.com/MaginaLW/agent-for-mobile/pull/91) 合并至 `main`，合并提交 `1a377cc`）**：
  - 宏引擎新增受限条件跳过原语 `skip_if_ref_missing`（[MacroSpec](app/gateway/src/main/java/dev/magina/gateway/macro/MacroSpec.kt) / [MacroEngine](app/gateway/src/main/java/dev/magina/gateway/macro/MacroEngine.kt)）：静态校验仅允许引用前序 `save_ref` 槽位的步骤启用，运行期缺失 `ref` 时跳过并记入 `skipped_steps`，但真实执行期触发的 `E_STALE_REF` / `E_BLOCKED` / `E_CONFIRM_*` 仍严格按安全终态中止（零安全旁路）；
  - 新增显式冷态起服脚本 [bootstrap-gateway.ps1](scripts/bootstrap-gateway.ps1)（保持 `dispatch.ps1` 默认不抢前景焦点）与离线测试，并在 [report-ledger.ps1](scripts/report-ledger.ps1) 补齐 `paused` 列、`bili` 类别与 `-ByMacro` 细分统计；
  - **PA2553 真机验收（`9937a7d` 首轮 + `c4ae700` 选择器收窄复测，[11-26 验收](docs/runs/2026-11-26-PA2553-阶段5A深化宏与冷态起服验收.md)）**：① `bootstrap-gateway.ps1 -ReturnHome -Json` 冷态起服（`cold_started` / `ReturnedHome=true` / `foreground`）与二次调用幂等（`already_running`）全部验通；② 首轮 `m3-bili-feed-promote-20261125` `27s / 50,739 in_tok` `success`，同时定位 `taobao_orders_prepare` 首页底栏 `role=button(desc="我的淘宝")` 与子节点 `role=text(text="我的淘宝")` 双命中导致 `save_ref` 未绑定；③ 提交 `c4ae700` 将两枚深化宏的 `ui_find` 均收窄为 `role="button"` + 精确 `desc`/`text`（`scroll_search=false`）并重装复测：`m3-taobao-orders-promote-r2-20261126` **1 轮 25s / 52,530 in_tok `success`**（11/11 宏子步全 `OK`，直达淘宝「全部订单」页，0 ConfirmOverlay），`m3-bili-feed-promote-r2-20261126` **1 轮 32s / 113,317 in_tok `success`**（0 ConfirmOverlay，汇总 5 条公开视频）；双宏同步转正 `verified: "2026-11-26"`（已转正前置宏增至 **6 枚**，`jd_readonly_prepare` 仍保持 `""`；`bili_readonly_feed_prepare` 推送弹窗实际弹出分支待后续自然复现时补充观测）；最终收尾提交 `89d92d5` 补强 5 项安全终态与台账单测，并通过完整离线门 `scripts/check.ps1` 13/13。
- **阶段 6A 设备端执行网关 App 本体升级（PA2553 真机冷启、4-Tab 控制台派单只读与现场 2 项人工目视均已验收通过，已随 [PR #93](https://github.com/MaginaLW/agent-for-mobile/pull/93) 合并至 `main`，合并提交 `f008aa6`）**：
  - 统一版本真源：`app/gateway` 升级为 `versionCode = 2` / `versionName = "0.2.0-m3"`，[SystemTools](app/gateway/src/main/java/dev/magina/gateway/tools/SystemTools.kt) 与 [McpServer](app/gateway/src/main/java/dev/magina/gateway/mcp/McpServer.kt) 统一读取 `BuildConfig.VERSION_NAME`；
  - 新增纯 Kotlin 只读审计日志读取器 [AuditLogReader](app/gateway/src/main/java/dev/magina/gateway/core/AuditLogReader.kt)（[Audit](app/gateway/src/main/java/dev/magina/gateway/core/Audit.kt) 只读目录暴露、有界尾部切片、损坏行容错、4 类筛选与二次参数脱敏兜底）及面板模型 [GatewayDashboardModel](app/gateway/src/main/java/dev/magina/gateway/ui/GatewayDashboardModel.kt)（默认遮罩 token、7 项权限与电池优化自检、宏目录与技能包概览格式化）；
  - 重构 [MainActivity](app/gateway/src/main/java/dev/magina/gateway/MainActivity.kt) 为 4 标签原生只读/自检控制台（状态 / 宏目录 / 技能包 / 审计，默认遮罩 token 并在 `onPause` 自动恢复遮罩，异步读取审计日志，保持 `.MainActivity` 与轻量启动契约不变）。
  - **2026-11-27 PA2553 实测状态（[11-27 验收](docs/runs/2026-11-27-PA2553-阶段6A冷启与6B-2系统内置App真机验收.md)）**：PA2553 真机冷启/幂等/零崩溃（`bootstrap-gateway.ps1` `cold_started` / `already_running`、`logcat` 零崩溃）、`stage6a-console-readonly-20261127` 4-Tab 控制台安全只读派单（63s `success`、25 条审计全 `OK`、`ConfirmOverlay = 0`、宏目录 6/8 与技能包 14 项及审计 73 条 4 类筛选 `31/1/1/73` 与 7 项自检 5/2、基线精确还原与无障碍重绑复原），以及现场 2 项人工目视检查（点击「显示 token」明文显示/`onPause` 自动恢复遮罩、点击「⑤ 电池优化 / 后台保活设置」跳转系统设置无崩溃）均已验收通过。

- **阶段 6B-1 语义意图审批生产接线与 PA2553 真机验收（2026-11-27 验收通过，已随 [PR #93](https://github.com/MaginaLW/agent-for-mobile/pull/93) 合并至 `main`，合并提交 `f008aa6`，[11-27 语义意图验收](docs/runs/2026-11-27-PA2553-阶段6B-1语义意图审批真机验收.md)）**：
  - 依据 [语义意图审批 spec](docs/specs/2026-08-02-语义意图审批-design.md) 完成真实 [SafetyGate](app/gateway/src/main/java/dev/magina/gateway/core/SafetyGate.kt) 与 [ToolExecutionPipeline](app/gateway/src/main/java/dev/magina/gateway/mcp/ToolExecutionPipeline.kt) 生产接线：补齐 `InputCommitEvidence` OCR 基线与同源 `monotonicClock` 重建安装、`ConversationTitlePolicy`（生产与 P0 同源标题提取）、严格只读 `AndroidIntentEvidenceReader`、`UiMutationCoordinator` 对 II 级发送点击窄保留，以及仅接受可见 `ConfirmOverlay` 批准、I 级零等待 / II 级 300s 有界前台等待 + 360s 意图有效期 + 原子消费与只读重建链（含 `7570f3d` 上下文读取与稳态等待修复、`cc86ce4` `test-target` 顶部标题带隔离、`eb5abad` `ConfirmOverlay` 底部防遮挡布局与 `ConfirmOverlayVisibilityController` 锁屏自动隐藏/解锁恢复修复）；同步更新 [硬门 spec §2](docs/specs/2026-07-19-危险动作统一硬门-design.md#2-安全不变量) 与 `RiskTier` 注释，补齐 `:gateway` 675 Debug / 578 Release 离线单测。
  - **2026-11-27 PA2553 真机验收闭环（`eb5abad` / `0.2.0-m3`）**：启用受控 `GatewayIme` 后实测通过 Leg 1B（桌面批准 → 3s 后切回 `testtarget`，审计集齐 `decided_via=overlay`、`intent_wait=recovered`、`intent_evidence=rebuilt`、`intent_match=matched`，回调 `0 -> 1`）与 300s 前台等待超时保护（`E_STALE_REF`）；验通外部 `am broadcast --ez allowed true` 拦截、锁屏自动隐藏/解锁恢复与通知 `VISIBILITY_PRIVATE` 脱敏（现场目视确认锁屏无卡/无明文/无允许）、通知「拒绝」→ `E_BLOCKED`（`decided_via=notification`）及 90s `E_CONFIRM_TIMEOUT`（回调均保持 `0`、零重试），收尾双读还原全部 5 项设备基线。

- **阶段 6B-2 系统内置 App 技能包、只读宏与真机验收转正（2026-11-27 PA2553 验收通过，已随 [PR #93](https://github.com/MaginaLW/agent-for-mobile/pull/93) 合并至 `main`，合并提交 `f008aa6`）**：
  - 基于 2026-11-26 PA2553 严格只读三源交叉实测包名表，在 [apps.json](app/gateway/src/main/assets/skillpack/apps.json) 与 [AndroidManifest.xml](app/gateway/src/main/AndroidManifest.xml) `<queries>` 1:1 新增注册 5 个高频内置 App（`闹钟时钟` `com.android.BBKClock`、`日历` `com.bbk.calendar`、`原子笔记` `com.android.notes`、`文件管理` `com.android.filemanager`、`计算器` `com.android.bbkcalculator`，合计 14 项 1:1 映射、零 `QUERY_ALL_PACKAGES`），并补齐 `com.vivo.gallery` 及新增 5 项的 `app_guides`；
  - **2026-11-27 PA2553 真机验收与转正（`5750321` / `0.2.0-m3`，[11-27 验收](docs/runs/2026-11-27-PA2553-阶段6A冷启与6B-2系统内置App真机验收.md)）**：同签覆盖安装（`queriesPackages` 14 项及 4 项安装/运行时权限完整保留，安装前 `accessibility_enabled=0` → 安装后 `1`）后串行跑通 Wave 1（7 轮）+ Wave 1B（2 轮），全部 7 枚系统内置 App 只读宏（`settings_state_readonly_check` 22s、`calculator_readonly_prepare` 20s、`clock_readonly_prepare` 17s、`calendar_readonly_prepare` 18s、`filemanager_readonly_prepare` 18s、`notes_readonly_prepare` 21s、`gallery_readonly_prepare` 21s）均达成 `dispatch success` + 实调 `skill_macro_exec` `completed` + 全步 `origin=macro` `OK` + `ConfirmOverlay == 0`，正式转正 `"verified": "2026-11-27"`（仓库总计 **13 枚**前置只读宏已转正，仅 `jd_readonly_prepare` 保持 `""`）；同步沉淀 `com.android.filemanager` 留置前台导致 `foreground_reason=window_id_mismatch` 触发 `SafetyGate` fail-closed（`E_BLOCKED`）及「前置返回桌面/冷启切离后再测独立 App」经验（[系统内置App.md](docs/knowledge/apps/系统内置App.md)）。

## 下一步

- **已全部收口的阶段（PA2553 实机闭环）**：
  - 阶段 6A（冷启、4-Tab 控制台安全只读派单与现场 2 项人工目视）、阶段 6B-1（语义意图审批生产接线、`ConfirmOverlay` 底部防遮挡与锁屏自动隐藏修复，以及离场重建/伪造拦截/锁屏通知拒绝/90s 超时真机全量验证）与阶段 6B-2（7 枚系统内置 App 只读宏）均已在 PA2553 验收闭环，并随 [PR #93](https://github.com/MaginaLW/agent-for-mobile/pull/93) 合并至 `main`（合并提交 `f008aa6`）。
- **阶段 6B-3（按需排期）**：M1b 通知只读通道或其余实测系统内置 App（天气/录音机等）按需扩展。

- **M3 已验样板与扩展**：`taobao_readonly_prepare`、`wechat_readonly_prepare`、`xhs_search_prepare`、`bili_readonly_prepare`（`verified: "2026-11-25"`）、`bili_readonly_feed_prepare`、`taobao_orders_prepare`（`verified: "2026-11-26"`）与 7 枚系统内置 App 只读宏（`settings_state_readonly_check`、`calculator_readonly_prepare`、`clock_readonly_prepare`、`calendar_readonly_prepare`、`filemanager_readonly_prepare`、`notes_readonly_prepare`、`gallery_readonly_prepare`，`verified: "2026-11-27"`）总计 **13 枚**前置只读宏已转正（仅 `jd_readonly_prepare` 因不可登录保持 `""`；`bili_readonly_feed_prepare` 推送弹窗实际弹出分支待后续自然复现时补充观测）；阶段 5A（[PR #91](https://github.com/MaginaLW/agent-for-mobile/pull/91)）已完成收尾并合入 `main`。
- **日常只读链路与冷态运维**：`mcp-transport-failure` 现场快照待后续真机传输失败复现时自然取证；PA2553 冷态无进程时可先显式运行 `scripts/bootstrap-gateway.ps1`；淘宝查物流任务按更新后的知识与任务卡跳过闪购/外卖与关闭订单并优先核对 `待收货` 或快递实物订单。
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
| M3 宏、入口、技能包 | 引擎及 14 个前置宏已就绪并上机验证：**13 枚前置只读宏已转正**（`taobao_readonly_prepare` 20s、`wechat_readonly_prepare` 24s、`xhs_search_prepare` 34s、`bili_readonly_prepare` 35s 为 `2026-11-25`；`bili_readonly_feed_prepare` 27s/32s、`taobao_orders_prepare` 25s 为 `2026-11-26`；系统内置 App 7 枚 `settings_state_readonly_check` 22s、`calculator_readonly_prepare` 20s、`clock_readonly_prepare` 17s、`calendar_readonly_prepare` 18s、`filemanager_readonly_prepare` 18s、`notes_readonly_prepare` 21s、`gallery_readonly_prepare` 21s 为 `2026-11-27`），仅 `jd_readonly_prepare`（5/5 子步验通、因京东不可登录暂搁）保持 `verified: ""`；`skip_if_ref_missing`、`SubtreeLabelPolicy`、瞬态空包名多窗重读及 `report-ledger.ps1` `m3-*` / `-ByMacro` 均已落地 |

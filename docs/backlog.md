# 待办与有效决定

> 当前状态见 [STATUS](../STATUS.md)。本文只放待办和仍有效的决定；过程记录不进本文。
> 2026-11-15 精简前的全文用 `git show e1bae37:docs/backlog.md` 查看。

## 1. 下一轮任务安排

### 已闭环基线与可选尾项

- **M1-T 微信横屏全链闭环**：PA2553 横屏三起点（已聚焦右窗 `36s`、桌面启动 `48s`、左窗导航切入冷 `ChattingUI` + 底栏「可按住转文字」自动聚焦 `47s`）与获授权备稿 + 设备端 `ConfirmOverlay` 发送投递全链已随 [PR #47](https://github.com/MaginaLW/agent-for-mobile/pull/47)、[PR #79](https://github.com/MaginaLW/agent-for-mobile/pull/79)–[#83](https://github.com/MaginaLW/agent-for-mobile/pull/83) 全部真机验通；第二轮隔离 API 36 补充实验（[PR #75](https://github.com/MaginaLW/agent-for-mobile/pull/75)）已结案（`request-matrix` 收口为窄 AOSP 边界不进真机，`ime-menu` / `assistant-structure` 作为离线已验备选保留）。明细见 [起点 3 与确认卡投递](knowledge/apps/wechat.md#pa2553-起点-3-桌面就位确认卡发送投递与起点-2-根因定位) · [起点 2 与冷启聚焦闭环](knowledge/apps/wechat.md#pa2553-起点-2-左窗导航与冷-chattingui-自动聚焦实测闭环) · [补充实验收口](knowledge/apps/wechat.md#三项离线补充实验实测收口与第四路线cursoranchorinfo--4b-遥测)。
- **可选补验与暂缓项**：两段左窗/冷启能力已分别闭环，单笔派单连跑「左窗 → 冷 `ChattingUI` → 聚焦右窗」为可选补验；标准竖屏 P0（`Allow`/`Stale`/`Deny`）独立暂缓，恢复时按原规程核对竖屏空草稿、回车发送设置与当轮真人确认（[标准入口](runbooks/P0-safety-hard-gate-smoke.md#2-标准入口)）。

### 阶段 3：M1 稳定性与日常只读任务可用性加固（已完成离线实施，随 [PR #86](https://github.com/MaginaLW/agent-for-mobile/pull/86) 合入 `main`）

1. **无障碍基线精确还原（已离线加固）**：定位原 vivo 输入法切回时异步移除 `.AutoSendImageService` 并叠加前导 `:` 丢失与 300ms RMW 竞态（[vivo 知识](knowledge/android/vivo-originos.md)），已在 `scripts/dispatch.ps1` / `scripts/lib/dispatch-profile.ps1` / `scripts/lib/dispatch-landscape.ps1` / `scripts/lib/p0-device-provision.ps1` 补齐精确还原与抗抖动重读并过离线回归。
2. **`mcp-transport-failure` 失败现场只读取证（已离线加固）**：新增 `scripts/lib/dispatch-forensics.ps1`，在 `scripts/dispatch.ps1` 拆除转发与服务前将无凭据只读健康快照写入本地 `docs/runs/traces/<base>.transport-health.json`，保持原有 `.jsonl` 与台账 `note: mcp-transport-failure` 契约并过离线回归（[harness 知识](knowledge/brain/harness.md)）。
3. **非微信日常只读任务包与守卫对齐（已离线加固）**：同步 [实测深链库](knowledge/apps/deeplinks.md)、[jd.md](knowledge/apps/jd.md)、[taobao.md](knowledge/apps/taobao.md) 与 `app/gateway/src/main/assets/skillpack/`（未实测候选维持 `verified: ""`，保持 `safety.json` 红线不变），升级 `SkillPack.kt` / `IntentTools.kt` / `SystemTools.kt` 并新增只读 `skillpack_lookup`，补齐 JVM 单测与 `scripts/tests/skillpack-sync-offline.ps1`。
- **2026-11-24 PA2553 真机阶段 3 回归结果**（[验收记录](runs/2026-11-24-PA2553阶段3与M3宏样板真机验收.md)）：
  - **已真机验证**：冷态起服后，PR #86 预检自动将 `GatewayA11yService` 从 `Crashed` 重绑恢复并完整保留前导 `:` 与 `AutoSendImageService`（`r3-script-bt-readonly-20261124-r2` `20s`）；同签升级 `57c4532` 后验通 `skillpack_lookup`、设置 `BLUETOOTH_SETTINGS` 兜底提示、`ocr` 能力上报与 `skill_macro_list`（`r3-gateway-tools-readonly-20261124` `20s`）。同时记录 PA2553 冷态无进程时须先 `am start MainActivity` 再 `run-as ... am start-foreground-service`（[vivo 知识](knowledge/android/vivo-originos.md)）。
  - **仍留待后续排查**：`r3-taobao-readonly-20261124`（104s）进入全部订单后两次点击「查看物流」均回到订单列表（`reported-fail`）；`mcp-transport-failure` 只读现场快照待后续真机传输失败复现时自然取证。

### 阶段 4 主线（M3 声明式宏系统与 App 技能包，已完成核心真机跑通，待降本转正）

- **已离线落地（2026-11-24）**：按 [M3 设计说明](specs/2026-11-24-M3-宏系统与技能包-design.md) 实现 `dev.magina.gateway.macro`（`MacroSpec`/`MacroCatalog`/`MacroEngine`），注册 `skill_macro_list`（R）与 `skill_macro_exec`（W，强制经 `ToolRegistry.callFromMacro` 走完整 `SafetyGate`/`ConfirmOverlay` 管线，保持 `DebugMacroRunner` / `P0WeChatPrepareMacro` 与 Release 隔离不变），并新增首个只读样板宏 `app/gateway/src/main/assets/skillpack/macros/xhs_search_prepare.json`（`verified: ""`）及 `scripts/report-ledger.ps1` 台账统计脚本。
- **2026-11-24 至 11-25 PA2553 实测与收敛结论**：
  - 11-24 `skill-macro-xhs-tokyo-20261124` 实机验证 `xhs_search_prepare` 6/6 子步 `status="completed"`、71 元素 `final_snapshot` 及审计 `a-000038` + `origin=macro`（`a-000039`–`a-000044`）全通；但宏后大脑另做 5 次探测/重复快照并误点 `flags=""` 的 `FrameLayout` 触发 `E_VERIFY_FAIL`，整单 82s / 477,106 in_tok（[11-19 纯大脑基线](runs/ledger.csv) 为 73s / 322,497 in_tok）。
  - **11-25 提示词收敛已实证生效**（[对照归因](runs/2026-11-25-PA2553-M3宏收敛对照与阻断归因.md)）：精简 `scripts/prompts/gateway-executor-preamble.md` 与 `scripts/tasks/m0-3-xhs-summary.md` 后，`skill-macro-xhs-tokyo-20261125` 实现首步直调 `skill_macro_exec`（前置 6→1 次）、零重复 `ui_snapshot`、零 `flags=""` 误点 `E_VERIFY_FAIL`（总调用 27→20 次、in_tok 477k→429.8k）。但因小红书卡片/展开栏无标签触发 5 次 `ConfirmOverlay`（`100s`），且视频详情点击底部无标签控件后瞬态窗口触发 `E_BLOCKED`，台账记为 `fail (safety-denied)`，故 `xhs_search_prepare.json` 诚实保持 `verified: ""`。
  - **11-25 并行双线改造与合流真机验收**（[并行验收](runs/2026-11-25-PA2553并行双线真机验收.md)）：方向 1 新增 `WindowTopologyPolicy` 瞬态空包名短重读（仅同包+空包触发，跨双包零等待且重读仍未知/跨包仍 `E_BLOCKED`）与 `SubtreeLabelPolicy` 严格非交互子树标签聚合（不改 `SafetyGate.kt`）；方向 2 新增 `taobao_readonly_prepare.json` 与 `wechat_readonly_prepare.json`。PA2553 实测：`taobao_readonly_prepare` **1 步 20s `success`**（转正 `verified: "2026-11-25"`）；`wechat_readonly_prepare` 网关返回 `completed/28` 元素但因模型未解包 `data` 记 `reported-fail`（保留 `""`）；小红书卡片外层容器实锤嵌套互动图标与作者按钮，`SubtreeLabelPolicy` 按安全红线拒绝聚合并触发 `ConfirmOverlay`（`confirm-timeout`，`xhs_search_prepare` 保留 `""`）。
  - **下一步待办**：① 补跑一次带 `data.final_snapshot` 读取指引的 `wechat_readonly_prepare` 单轮验证转正，并视需扩展京东/设置低盲点前置宏与微调小红书无详情模式（严格优先列表摘要）；② 另择期排查淘宝「查看物流」点击回弹原因。

## 2. 按需再做（有具体任务需要时才排）

- M1b 占位工具：通知读取/回复、`ui_diff`、Shizuku 强停当前已从 `tools/list` 下架；按需实施与必验失败路径见 [能力现状](knowledge/android/m1b-capabilities.md)。
- 语义意图生产接线：基础模块已在代码中，接线范围见 [语义意图 spec §5](specs/2026-08-02-语义意图审批-design.md)。
- 分享落地 activity 白名单：必须来自真机观测，没有观测就保持空。
- 微信相关任务（M0-2/M0-4 发消息、发图）：PA2553 横屏 M0-2 文本备稿与 `ConfirmOverlay` 发送投递已实机验通（[实测闭环](knowledge/apps/wechat.md#pa2553-起点-3-桌面就位确认卡发送投递与起点-2-根因定位)）；M0-4 跨应用发图与标准竖屏 P0 仍按需后置（[标准入口](runbooks/P0-safety-hard-gate-smoke.md#2-标准入口) · [平板知识](knowledge/android/tablet.md) · [微信知识](knowledge/apps/wechat.md)），不恢复已删除的研究栈。
- 语音/分享入口按需再做；M3 核心规划（宏系统「教一遍」与 App 技能包）已列入 [阶段 4 倾向方向 A](#1-下一轮任务安排)。

## 3. 有效决定

| 决定 | 内容 |
|---|---|
| 设备基线与三层窗口 | vivo PA2553 / Android 16。项目适配设备，不禁用 `com.vivo.safecenter` 或关闭系统多窗；支持单窗口与同应用平行视界（分屏/跨应用/未知多窗严格 fail-closed）。手机真机验收暂停。 |
| 大脑与派单 | 只用 Codex CLI 官方登录（固定 `codex + gateway`）；优先使用受控 `toolchain/codex` 冻结副本，回退官方桌面目录；预检内建网关自启、token 同步（仅 debug 可读写）与非设置页单次无障碍重绑。 |
| 点击与常规回车规则 | 普通具名点击（有可读 text/desc 且未命中危险/动作确认/发送/敏感词表）直接放行+审计；纯图标无标签或命中词表弹确认卡；`sensitive_targets` 与黑名单目标出站直接 `E_BLOCKED`。常规 `press_key(enter)` 只要 `focusIdentity + inputCommitEvidence` 齐全即可进确认卡（无会话标题时卡面明示；同应用多窗且 `IME_ONLY` 拦截）。 |
| 危险动作 | 发送/支付/删除类两段式：网关在执行前弹出设备端确认卡（ConfirmOverlay，默认超时 90s），由现场真人批准；一次批准只放行当次调用。通知只能拒绝或查看，不能批准。 |
| 风险分级 | 两档都逐次确认，没有免确认路径。见 [风险分级](specs/2026-08-01-危险动作风险分级-design.md)。 |
| 安全失败即终态 | 拒绝、超时、上下文失效后不重弹、不换路重试。 |
| PC 输入不是批准 | 终端输入（`Read-Host`、`RESUME` 等）不能当危险动作的真人批准；`-Confirm` 只恢复未调用危险工具的前置步骤。见 [执行 harness spec §5](specs/2026-07-17-执行harness-design.md)。 |
| `intent_send` 落地 | 指定目标时落地失败返回 `E_VERIFY_FAIL`；未指定目标如实报告“已分派、未验证”。 |
| 语义意图时钟 | `ConfirmOverlay` 默认超时已生效为 `90s`；语义意图 `intentTtl 360s` / II 级 `foregroundWaitBudget 300s`（I 级 0）/ 证据 TTL `120s` 尚未完成生产接线，见 [语义意图 spec](specs/2026-08-02-语义意图审批-design.md)。 |
| 会话标题读取 | 标题识别放在生产代码，宏复用同一份；不另造弱读取器。 |
| 宿主进程 | 脚本不终止外部进程；PC Suite 等占用 ADB 5037 造成冲突时由用户处理。 |
| 安装等待 | 安装命令不设自动超时（现场确认可能慢），开始前提醒用户。 |

## 4. 怎么做

- 改代码后按 [离线开发与验证](runbooks/离线开发与验证.md) 跑 `scripts/check.ps1`；只改文档或脚本时用 `-SkipGradle`。
- 真机运行记下构建的 commit SHA、设备和结果；失败保留证据，查清原因再跑，不盲目重试。
- 一次运行写一行台账（`dispatch.ps1` 自动写 `docs/runs/ledger.csv`）；只有出现新结论或新坑时才写 `docs/runs/` 记录，可复用的经验写进 `docs/knowledge/`。

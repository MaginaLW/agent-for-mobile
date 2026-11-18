# 待办与有效决定

> 当前状态见 [STATUS](../STATUS.md)。本文只放待办和仍有效的决定；过程记录不进本文。
> 2026-11-15 精简前的全文用 `git show e1bae37:docs/backlog.md` 查看。

## 1. 待办（按顺序）

| # | 待办 | 完成标准 |
|---|---|---|
| 1 | 小红书公开笔记完整验收 | 已分别实测应用内搜索提交、就绪列表读取五条。待空白页恢复后，经 `dispatch.ps1` 搜索并总结该次查询的五条笔记，核对结果和台账。[实测记录](runs/2026-11-18-PA2553小红书只读验收.md) |
| 2 | 在后续实际任务中核对 PA2553 无障碍绑定 | 11 月 18 日七次派单均通过预检。若 vivo 再次解绑，记录当时的前台、服务状态和单次重绑结果。[vivo 记录](knowledge/android/vivo-originos.md) |
| 3 | 自研网关完成 PA2553 M1 主验收 | 非微信日常任务（M0-3 小红书、M0-5 京东/淘宝查物流 + 确认卡演练/系统任务；M0-1 若触发 safecenter 则记 ROM 边界或待 Shizuku）同口径对比 M0；微信两项保留后置不阻塞 M1 |
| 4 | 处理设定对齐与修复的[草稿 PR #18](https://github.com/MaginaLW/agent-for-mobile/pull/18) | 合入前对候选版本运行 `scripts/check.ps1`，检查通过且获用户批准后合入 main |
| 5 | P0 真人确认 | 真机上由真人完成 Allow / Deny / Stale 各一次，见 [P0 规程](runbooks/P0-safety-hard-gate-smoke.md) |

## 2. 按需再做（有具体任务需要时才排）

- M1b 占位工具：通知读取/回复、`ui_diff`、Shizuku 强停当前已从 `tools/list` 下架；按需实施与必验失败路径见 [能力现状](knowledge/android/m1b-capabilities.md)。
- 语义意图生产接线：基础模块已在代码中，接线范围见 [语义意图 spec §5](specs/2026-08-02-语义意图审批-design.md)。
- 分享落地 activity 白名单：必须来自真机观测，没有观测就保持空。
- 微信相关任务（M0-2/M0-4 发消息、发图）：已后置；重启后以「三层窗口 + 点右窗发送按钮确认卡」单独实测，仍参考 [平板知识](knowledge/android/tablet.md) 与 [微信知识](knowledge/apps/wechat.md)，不恢复已删除的研究栈。
- M3：宏系统「教一遍」、语音/分享入口、App 技能包。
- 剩余可选精简：`-Brain claude` 现只报 PowerShell 英文参数错误，如需中文提示可加 ValidateSet 错误信息。

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

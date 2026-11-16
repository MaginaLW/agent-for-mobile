# 待办与有效决定

> 当前状态见 [STATUS](../STATUS.md)。本文只放待办和仍有效的决定；过程记录不进本文。
> 2026-11-15 精简前的全文用 `git show e1bae37:docs/backlog.md` 查看。

## 1. 待办（按顺序）

| # | 待办 | 完成标准 |
|---|---|---|
| 1 | 让网关无障碍服务在 PA2553 上稳定绑定 | 派单前置检查不再报 `gateway_a11y_not_ready`；若 vivo 反复解绑，把规律和解法写进 [vivo 记录](knowledge/android/vivo-originos.md) |
| 2 | 小红书只读任务跑通 | 经 `dispatch.ps1` 搜索并总结 5 条公开笔记，结果和台账行落盘 |
| 3 | 自研网关跑完 M0 五任务 | 每个任务记录成败/步数/耗时/token；成功率 ≥ M0（4.5/5）即 M1 验收 |
| 4 | 处理草稿 PR #13、#17、#12 | 决定合入或关闭；#17 叠在 #13 之上，先处理 #13；合入前跑一次 `scripts/check.ps1` |
| 5 | P0 真人确认 | 真机上由真人完成 Allow / Deny / Stale 各一次，见 [P0 规程](runbooks/P0-safety-hard-gate-smoke.md) |

## 2. 按需再做（有具体任务需要时才排）

- M1b 占位工具：通知读取/回复、`ui_diff`、Shizuku 强停，实施与必验失败路径见 [能力现状](knowledge/android/m1b-capabilities.md)。
- 语义意图生产接线：基础模块已在代码中，接线范围见 [语义意图 spec §5](specs/2026-08-02-语义意图审批-design.md)。
- 分享落地 activity 白名单：必须来自真机观测，没有观测就保持空。
- 微信相关任务（发消息、发图）与平板双窗适配：已后置；若重启，先读 [平板知识](knowledge/android/tablet.md) 与 [微信知识](knowledge/apps/wechat.md)，从需要的最小能力做起，不恢复已删除的研究栈。
- M3：宏系统「教一遍」、语音/分享入口、App 技能包。
- 剩余可选精简：dispatch.ps1 的 mobile executor 现在只剩 DryRun 配置预览，可连同 configs/mobile-mcp.json 一起删；-Brain claude 现只报 PowerShell 英文参数错误，如需中文提示可加 ValidateSet 错误信息。

## 3. 有效决定

| 决定 | 内容 |
|---|---|
| 设备基线 | vivo PA2553 / Android 16。项目适配设备，不靠关闭系统功能换通过；没验证过的形态 fail-closed。手机真机验收暂停。 |
| 大脑 | 只用 Codex CLI 官方登录（`-Brain codex -Executor gateway`）。Claude 执行路线已退役，旧 Claude 暂停件不恢复。 |
| 危险动作 | 发送/支付/删除类两段式：网关在执行前弹出设备端确认卡（ConfirmOverlay），由现场真人批准；一次批准只放行当次调用。通知只能拒绝或查看，不能批准。 |
| 风险分级 | 两档都逐次确认，没有免确认路径。见 [风险分级](specs/2026-08-01-危险动作风险分级-design.md)。 |
| 安全失败即终态 | 拒绝、超时、上下文失效后不重弹、不换路重试。 |
| PC 输入不是批准 | 终端输入（`Read-Host`、`RESUME` 等）不能当危险动作的真人批准；`-Confirm` 只恢复未调用危险工具的前置步骤。见 [执行 harness spec §5](specs/2026-07-17-执行harness-design.md)。 |
| `intent_send` 落地 | 指定目标时落地失败返回 `E_VERIFY_FAIL`；未指定目标如实报告“已分派、未验证”。 |
| 语义意图时钟 | decisionTimeout 90s、intentTtl 360s、II 级 foregroundWaitBudget 300s、I 级 0；证据 TTL 120s。见 [语义意图 spec](specs/2026-08-02-语义意图审批-design.md)。 |
| 会话标题读取 | 标题识别放在生产代码，宏复用同一份；不另造弱读取器。 |
| 宿主进程 | 脚本不终止外部进程；PC Suite 等占用 ADB 5037 造成冲突时由用户处理。 |
| 安装等待 | 安装命令不设自动超时（现场确认可能慢），开始前提醒用户。 |

## 4. 怎么做

- 改代码后按 [离线开发与验证](runbooks/离线开发与验证.md) 跑 `scripts/check.ps1`；只改文档或脚本时用 `-SkipGradle`。
- 真机运行记下构建的 commit SHA、设备和结果；失败保留证据，查清原因再跑，不盲目重试。
- 一次运行写一行台账（`dispatch.ps1` 自动写 `docs/runs/ledger.csv`）；只有出现新结论或新坑时才写 `docs/runs/` 记录，可复用的经验写进 `docs/knowledge/`。

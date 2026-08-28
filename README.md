# 手机 Agent（代号待定）

把已付费的 AI 订阅（Claude Pro / ChatGPT Plus）变成一个能替你操作手机各应用的托管助手。

- **架构一句话**：手机 = 无障碍执行器 + MCP server；大脑 = Claude Code / Codex CLI（官方订阅通道，零 API key 成本起步）。
- **设备范围**：Android 手机与平板复用同一执行器和 MCP 架构。手机保留为历史开发基线；自 2026-08-24 起，后续真机任务以 vivo PA2553 / Android 16 / 日常横屏为当前验收基线。vivo“应用多窗”保持日常开启，同一微信双 OS window 是主线适配对象，不是待关闭的异常形态；先做 T0-L 画像与 T-L1 只读 window/root/pane 证据，再做 pane-aware P0。其它 App 分屏/自由窗、浮动键盘与平板竖屏兼容后置，未验形态一律 fail-closed。
- **设计说明**：[docs/specs/2026-07-16-方向一-手机执行器与订阅大脑-design.md](docs/specs/2026-07-16-方向一-手机执行器与订阅大脑-design.md)
- **当前状态**：见 [STATUS.md](STATUS.md)（每次工作会话收尾更新）
- **文档结构**：`docs/specs`（设计）· `docs/runbooks`（规程）· `docs/knowledge`（实测经验，按需读）· `docs/runs`（跑测归档）；开发指南见 [CLAUDE.md](CLAUDE.md)

## 里程碑

| | 内容 | 状态 |
|---|---|---|
| M0 | mobile-mcp 真机跑通 5 个验收任务，拿到成功率/token 数据 | ✅ 完成（2026-07-16，4.5/5，[记录](docs/runs/2026-07-16-M0.md)·[runbook](docs/runbooks/M0-runbook.md)） |
| M1 | 自研 Android 执行器 App（Kotlin，无障碍 + MCP HTTP server + 确认层） | 🟡 进行中——网关已在真机跑通（a11y + IME + OCR 融合 + 内嵌 MCP server），P0 安全硬门见下 |
| M1-T | Android 平板横屏基线（T0-L 画像 + T-L1 pane 探针 + T-L2 P0） | 🟡 进行中——[适配设计](docs/specs/2026-08-23-Android平板适配-design.md)；T0-L v5 已完成，C1a 已在日常双窗形态建立可信来源/只读取证但未通过 T-L1。fixed SHA `87ac7b45e79bf658ca6e56b697a24f52fdf7381b` 的唯一 C1b 授权已[冻结失败](docs/runs/2026-08-28-T-L1-C1b私有ADB启动失败.md)：private ADB 未 ready，控制流停止于设备发现之前，未 install/T0/c1/c2，清理无残留且没有重试。2026-08-29 的 42-input 离线修复已将 server listen 固定为 `-L tcp:localhost:<port>`，client/environment/listener proof 保持 numeric `127.0.0.1`，并为 run_id 前失败加入 post-cleanup 原子发布的 bounded structured attempt evidence；stream 内容只持久化 hash/分类/计数，另保存闭合 substage/exit/cleanup，不保存 raw stdout/stderr。最终离线结果为 host/full gate 29/29、observation 49/49（coverage 89/89）、七场景 E2E、fake ADB 222=214 valid+8 rejected（start/status/kill 8/7/4、device 195、exit 7）、runner 9、fake Gradle 8、fake signer 12、private ADB 22/22、readonly 74/74、attempt schema/cross-binding 51/51；当前独审 P0/P1/P2=0，本提交固定新的 clean SHA（见 HEAD）。旧 41-input real smoke 与旧独审只属历史基线；当前 42-input real isolated host build smoke 尚未执行。后续若再真机，须先完成该 smoke，再针对新 SHA 另取授权；旧 C1a 与已消费的 C1b 授权均不可复用。导航/会话/目标区、布局、P0 与执行仍未放行 |
| M2 | 大脑迁上手机（Termux/AVF 跑 Claude Code） | ⬜ |
| M3 | 宏系统「教一遍」、语音/分享入口、App 技能包 | ⬜ |

### P0 · 危险动作安全硬门（M1 内的验收门）

发送/支付/删除类动作必须**两段式**：网关停下弹确认卡，真人在手机上决定，确认前后各复核一次上下文。
监督式真机跑测由 [scripts/run-p0-safety-smoke.ps1](scripts/run-p0-safety-smoke.ps1) 驱动（[runbook](docs/runbooks/P0-safety-hard-gate-smoke.md)）。

| 腿 | 验证什么 | 状态 |
|---|---|---|
| Allow | 真人允许后动作执行且只执行一次 | 🟡 链路已通（2026-07-26 真机：确认卡→允许→放行→只读复核全绿），发送本身待验 |
| Stale | 确认后上下文变了就必须拒绝执行 | 🟡 待在新链路下复跑 |
| Deny | 真人拒绝后绝不执行 | 🟡 runner 与判定已接通（离线 4 条用例），待真机跑 |

进度与卡点以 [STATUS.md](STATUS.md) 为准。

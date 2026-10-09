# 项目状态

> 更新 2026-10-09。本页只写现在在哪、卡在哪、下一步；待办、需要用户的事项和有效决定见 [backlog](docs/backlog.md)，过程证据见 `docs/runs/`。精简前全文用 `git show aa126dd:STATUS.md` 查看，更早历史见[状态归档](docs/status-archive.md)。

## 一句话现状

平板线卡在 T-L1/C1b：旧主机证据链已于 10-09 退役（用户确认），改用简单 runner，见 [C1b 规程](docs/runbooks/T-L1-tablet-c1b.md)。新 runner 已在真机走通到就绪前，但探针无障碍服务每次开启后数秒内被 vivo 安全中心撤销，采集未执行（[记录](docs/runs/2026-10-09-C1b-真机-vivo安全中心撤销无障碍.md)）；下一步待用户选择解阻方式。手机验收（C 道）暂停，批次 4 停在 0/4。

## 需要用户做的

如 PC Suite 手机助手占用 TCP 5037 并与 runner 冲突，结束该会话；开启探针无障碍服务；平板现场就位后对本次运行给开跑令。条件以 [backlog §6](docs/backlog.md) 为准。

## 下一步

- C1b：按 [backlog §4](docs/backlog.md)——阻塞于 vivo 安全中心撤销探针无障碍服务；可选方向见 backlog §4 C1b 待办 d。
- R1（PC CONFIRM 真人确认边界）和 R5（intent_send 落地验证）离线已完成，只剩真机验收；协调分支已同时含两者，是否搭车由 A 选候选时决定。

## 里程碑

| 里程碑 | 状态 |
|---|---|
| M0 mobile-mcp 真机验收 | 完成（2026-07-16，4.5/5） |
| M1 自研网关 | 已在历史手机上跑通。P0 两段式硬门未闭合：批次 1–3 已验收；现行链路下 Allow、Stale 尚未独立真机验收（见 [P0 规程](docs/runbooks/P0-safety-hard-gate-smoke.md)）；语义意图四腿（批次 4）暂停 0/4 |
| M1-T 平板适配 | T0-L 完成；C1a origin/read-only 成立，但 T-L1 未通过；C1b 真机受 vivo 安全中心阻塞；T-L2 未入队 |
| M2 大脑迁到手机 | 未开始 |
| M3 宏、入口与技能包 | 未开始 |

## C1b 卡点详情

- 退役理由：按运行记录近似统计，自 08-28 起约 20 余个固定候选都没有闭合 Ready 和设备验收，09-13 后都停在主机阶段。最后候选 r13 `8d808b1` 因宿主 ADB 边界非空失败，未到构建。
- 最近一次设备轮是 09-13（`a878d12` 识别到 0 台设备，`c43652a` 报 display unsupported，根因未知）；新 runner 的首次真机运行一并验证。过程见 [C1b goal 运行记录](docs/runs/2026-09-30-C1b-goal与正式证据闭合.md)。
- 新流程保留只读边界、HEAD 固定、全局设备锁与开跑令；不再有 once、冻结候选、UAC 与按 SHA 书面授权。

## 暂停与后置

手机批次 4、语义意图生产接线、T-L2/T-L3/T-P、M1b 占位工具实现均暂停或后置，条件见 [backlog §4–§5](docs/backlog.md)。

## 代码分布

协调分支 `codex/agent-workflow`（协调文档与 R1/R4/R5 等离线修复）和 C1b 实现线 `codex/c1b-host-evidence-20260930`（tip `cad7411`）未整体合并，但实现线的 C1b 探针修复已取入协调分支（`cc74daf`），实现线不再有独有 app 改动。两条线的功能改动都没有合入 main；这期间 `origin/main`（`8bc0c87`）只收了 R6 文档闭包（PR #2–#4）。本地 `main` 与 `origin/main` 已分叉（本地多 1 个提交、少 3 个）。

# 项目状态

> 更新 2026-10-09。本页只写现在在哪、卡在哪、下一步；待办、需要用户的事项和有效决定见 [backlog](docs/backlog.md)，过程证据见 `docs/runs/`。精简前全文用 `git show aa126dd:STATUS.md` 查看，更早历史见[状态归档](docs/status-archive.md)。

## 一句话现状

平板线卡在 T-L1/C1b 的主机阶段：最后候选 r13 `8d808b1` 的唯一一次 Drive 因宿主 ADB 边界非空而失败，同 SHA 不能重跑；10-01 起按用户要求暂停。解卡要先由用户结束 PC Suite 手机助手/同步会话、释放 `adb.exe` 与 TCP 5037，再从 `cad7411` 建新候选、重走 Probe 前的准备链（术语见 [backlog §4](docs/backlog.md)）。手机验收（C 道）暂停，批次 4 停在 0/4。

## 需要用户做的

结束 PC Suite 会话；新候选的 UAC 与单次 BuildOnly 授权；Ready 后重新确认平板现场并授权一次真机 build/install/只读采集。顺序与条件以 [backlog §6](docs/backlog.md) 为准。

## 下一步

- C1b：按 [backlog §4](docs/backlog.md) 的四步恢复——宿主 ADB 清零 → 新候选准备链（到 Preflight 冻结及 A5 源码发布）→ Probe、BuildOnly、读回与主机合同 → Ready 后现场确认与只读采集。
- R1（PC CONFIRM 真人确认边界）和 R5（intent_send 落地验证）离线已完成，只剩真机验收。它们和 C1b 修复不在同一分支，选它们的验收候选前要先定合并方式；这不影响 C1b 的恢复顺序。

## 里程碑

| 里程碑 | 状态 |
|---|---|
| M0 mobile-mcp 真机验收 | 完成（2026-07-16，4.5/5） |
| M1 自研网关 | 已在历史手机上跑通。P0 两段式硬门未闭合：批次 1–3 已验收；现行链路下 Allow、Stale 尚未独立真机验收（见 [P0 规程](docs/runbooks/P0-safety-hard-gate-smoke.md)）；语义意图四腿（批次 4）暂停 0/4 |
| M1-T 平板适配 | T0-L 完成；C1a origin/read-only 成立，但 T-L1 未通过；C1b 未通过；T-L2 未入队 |
| M2 大脑迁到手机 | 未开始 |
| M3 宏、入口与技能包 | 未开始 |

## C1b 卡点详情

- r13 的全量门 14 项全过，A1–A3、A5 源码阶段与 Probe 均通过。唯一一次 Drive 因宿主 ADB 边界非空（`adb.exe` 或 TCP 5037 listener 不为零）失败，没走到 Drive 的 UAC 和构建。失败当时的占用进程未知；失败后的快照显示 PC Suite 手机助手的 ADB 正在监听 5037。
- once 已消费；Readback、HostContract、Ready 与设备采集均未执行。恢复源 `cad7411` 只比 r13 多了宿主 ADB 边界复核规程，还没有跑新的全量门。
- 按运行记录近似统计，自 08-28 起约 20 余个固定候选都没有闭合 Ready 和设备验收。最近一次设备轮是 09-13（`a878d12` 识别到 0 台设备，`c43652a` 报 display unsupported，根因未知），之后都停在主机阶段。过程见 [C1b goal 运行记录](docs/runs/2026-09-30-C1b-goal与正式证据闭合.md) 开头的收尾段。

## 暂停与后置

手机批次 4、语义意图生产接线、T-L2/T-L3/T-P、M1b 占位工具实现均暂停或后置，条件见 [backlog §4–§5](docs/backlog.md)。

## 代码分布

协调分支 `codex/agent-workflow`（协调文档与 R1/R4/R5 等离线修复）和 C1b 实现线 `codex/c1b-host-evidence-20260930`（tip `cad7411`）尚未合并。两条线的功能改动都没有合入 main；这期间 `origin/main`（`8bc0c87`）只收了 R6 文档闭包（PR #2–#4）。本地 `main` 与 `origin/main` 已分叉（本地多 1 个提交、少 3 个）。

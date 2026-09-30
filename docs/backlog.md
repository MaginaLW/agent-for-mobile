# 工序分流与验收批次

> 2026-09-08：A 负责协调、开发和 ask；C 按需执行固定候选真机验收，不设常驻 B。
> 本文只保留现行规则、当前待办和有效决定。旧过程与被替代决定见 [历史归档](backlog-archive.md)，按具体证据指针读取，不能作为当前授权。
> 当前候选摘要见 [STATUS](../STATUS.md)；协调来源按 §2 指定，不能无条件读取 main 上的旧副本。

## 1. 判据

| 角色 | 负责什么 | 需要用户时 |
|---|---|---|
| **A · 主协调与开发** | 需求、设计、离线实现、直接 ask、委派与集成；维护当前队列和状态 | 收敛出具体问题、推荐方案和影响后，在当前任务直接询问 |
| **按需子代理** | 可独立推进的研究、模块实现、验证或独立审查，按文件划定写入归属 | 回报 A，由 A 汇总；不为转交一道选择题创建常驻 B |
| **C · 真机验收** | 独占设备，只验固定 SHA 的构建并保存证据；发现问题回交 A | 按本批就位与授权规程协调现场操作；手机危险动作仍逐次两段式 |

普通实现选择优先根据目标、代码和文档判断；已授权的常规、可恢复工作持续推进。
只有缺少不可替代的产品选择、验收范围或安全姿态决定，或现有证据无法裁决的关键分歧时才 ask。
等待答复只暂停依赖该决定的步骤，其他授权范围内的独立工作继续；沉默不等于回答或批准。
真实答复及其适用范围落入对应 spec；范围未变时沿用，不因换任务、换模型或主代理没看见而重问。

复杂取舍可委派独立审查来质疑前提、补充选项，由 A 负责最终提问与整合。
同一目标的补充和修复留在当前任务；只有用户明确要求新建独立任务时才创建用户任务。

## 2. 协调来源与资源边界

- **当前主协调者就是 A，不等同于持有 main 的某个历史会话。** A 开场先核实实际 checkout/HEAD 和本工作区改动，
  结合用户本轮上下文与最新 STATUS 指定本次权威队列来源。分支名、历史 STATUS 或旧任务 ID 不能替代实测。
- **派工必须携带当前摘要与可追溯来源**：协调文档路径及其提交/ref、基于该版本尚未提交的队列增量、
  本子任务输入/写入归属/验收标准，以及当前可用的回报通道。任务和设备状态以新的实际证据更新。
  跨 worktree 子任务读取 A 指定的版本和增量，不把自身旧副本或 main 自动当最新；来源缺失时向 A 补取，
  同时继续不依赖队列的工作。运行时任务 ID 随派工传入，不写死在仓库中。
- **队列与共享状态只由 A 整合**；子代理和 C 回报增量，避免分别改写隔离副本。A 应及时保存队列，
  不把有效决定的文档同步绑在尚未通过的代码合并上。协调文档版本与 C 的被测代码 SHA 分别记录。
- **单设备独占、每批固定完整 SHA 与对应构建。** A 可在其他提交上开发，C 不跟随分支 tip，不在被测 checkout 改代码。
  当前请求的普通子代理可共享 checkout，但写入文件必须分工；C 的隔离构建与设备 lease 按专用规程执行。
- C 没有可执行验收项时回报待命或结束，不转做 A 开发。验收发现问题只记录现象、候选、manifest/台账和证据；
  A 修复后形成新候选，原失败运行保持冻结。

## 3. 排序原则

A 优先完成能减少真机人工操作、缩短验收时间的工作。离线通过不能替代 ROM、确认卡、App 落地或布局的真机证据。

**C 队列有未清批次时，A 不新增待真机验收批次**，继续已授权的纯离线工作。
本次合并 A/B 不改变这条配额，也不放行尚未接线的生产路径。没有具体目标的“提速/重构”不作为无限续做理由。

每批至多包含 2–3 个改变真机行为的改动；碰相同确认或布局表面的改动须可独立归因。
只读验证不改被测路径，可在授权范围内搭便车；单次合跑多批时分别固定候选、判据与结论。

## 4. 当前工作与验收批次

### 09-27 审查待办

依据 [项目审查记录](runs/2026-09-27-项目审查与待办.md)纳入当前队列；下表维护后续进度，审查页保留当时证据。
09-30 持续 goal 已按本轮直接授权推进；协调源码 `e0fcbb2` 的 P3、主机传输与 R3 离线增量已闭合，新模块、可变实现整合及新 clean 候选按下方实际证据续办，离线通过不替代设备验收。

| 优先级 / 来源 | 待办 | 状态与依赖 | 完成标准 |
|---|---|---|---|
| **P1 · R1** | 修正 PC CONFIRM 的真人确认边界 | 离线修复 `da37f3d`，53/53 用例通过；mobile `-Confirm` 在副作用前阻断，gateway `RESUME` 只恢复纯前置流程，不新增设备批次；真人确认边界仍待本轮真机验证 | 可编程终端输入不再被当作危险动作真人批准；mobile 危险恢复须有独立人控确认，否则阻断；gateway 手机确认卡保留，不能只靠拒绝重定向 stdin |
| **P1 · R2** | 统一语义意图设计的批准来源 | 文档已提交 `3efe57d`；可见 `ConfirmOverlay` 是唯一允许来源，旧锁屏通知方案标为历史，生产接线仍后置 | 流程、实现说明与验收统一采用可见 ConfirmOverlay；旧锁屏通知批准标为历史，不重新询问同一决定 |
| **P2 · R4** | 补齐暂存区检查并避免凭据回显 | 已提交 `8e8f0fa`；10 个合成 Git 反例通过，staged 与工作树分别检查，只报告疑似路径；此项闭合 Git 离线门，不替代任何设备验收 | 工作树与 index 均检查；staged-only/部分暂存反例通过；疑似凭据只报告路径和规则 |
| **P2 · R5** | 为 intent_send 增加落地验证 | 离线实现 `7814fac` 已提交；Debug/Release 各 7 个 JVM 用例均通过，涵盖启动无异常但前台未命中；尚未真机验收，不把选择性候选整合计为 main 功能发布 | 已知目标落地失败返回 E_VERIFY_FAIL；未知目标如实报告未验证；固定候选真机覆盖启动无异常但目标未到前台的反例后，才按受测功能版本发布 |
| **P2 · R6（文档闭合）** | 校准协调、实现和 main 的文档来源 | [来源与工作树盘点](runs/2026-09-27-协调来源与工作树盘点.md)、goal 记录及 README 入口三文件增量由 [PR #2](https://github.com/MaginaLW/agent-for-mobile/pull/2) 合入 main `20398130c27bb7038f0d7ffc37851d7e2b82a6cf`；后续复验失败与 4a 准备的单份运行记录续记由 [PR #3](https://github.com/MaginaLW/agent-for-mobile/pull/3) 合入 main `030db3238cd08eadd3f9e652c5dd57ab4e233088`，Git/GitHub 的 PR、父提交、完整 tree/blob 读回一致。上述文档范围已闭合；通过完整门的 [4a 功能源码](https://github.com/MaginaLW/agent-for-mobile/tree/4a65150db9826d668341ad6d9b11cb9883f5c524) 已一次 create-only 发布至特性分支且远端 Git 读回 SHA 一致，未合入 main。新 2a4 的完整门及独立 Read 也已通过，特性源码已一次 create-only 发布并远端读回精确 SHA，main 保持 030、未合并。固定 base030、共享来源 `006cf5a9` 与已发布 exact 2a4 源码索引的 62 份 Markdown 闭包，已由 [PR #4](https://github.com/MaginaLW/agent-for-mobile/pull/4) squash 合入 main `8bc0c870702f20c2200fbd123ff654ab7e7b094a`（UTC 2026-09-30 14:21:03）；中央 fresh Git/GitHub 的 PR、ref、唯一 parent、完整 tree、62 个选定 blob、ancestry 与 clean 读回一致。实际 22 修改/40 新增、77 份可达文档、378 条相对边缺失 `0`，文档闭包已发布并读回；不纳入继任 e898 功能源码或新的主机验收。历史 3 处台账增量逐字节重合且各仅 1 次，原工作树保留 | 62 份文档来源闭包已按实际 main 和远端读回闭合；功能源码合入 main、继任主机链及设备验收仍独立待办；workflow `0`、checks 为空，不计作 CI 通过 |
| **P2 · 规则精简** | 合并重复协作规则，移出 C1b 规程中的历史过程 | 已提交 `3efe57d`；AGENTS/CLAUDE、现行 C1b 规程和历史归档分工已整理 | AGENTS 保留运行时差异、CLAUDE 保留原则，backlog 留队列与有效决定；规程保留现行步骤，历史移入既有归档并保留链接，安全约束不删 |
| **P3 · 候选生成链** | 减少新候选对库外历史工件的依赖 | 维护源迁移 `68776e4`、LF 绑定 `da56671` 与路径修复 `64c6e81` 保留；本轮补回七份库的最终 raw hash map 和 FailureDiagnostics 透传/同源转换，源码专项 `16 passed, 0 skipped`，LF/CRLF 与真实原字节复核通过，见[goal 增量](runs/2026-09-30-C1b-goal与正式证据闭合.md)。既有离线源码证据保留；4a PrepareSources 实际 Run/Read 及 5 份 exact 4a expected/renderer 的 source-only 独审已通过，但实际 Pair 因混合 slash 的 renderer 路径被 canonical guard 拒绝而失败。四文件修复已提交为 2a4，钉定 7.6.5 的实际源码专项 16 passed / 0 skipped、native `0`，cold CLI 合成首次 `0`/拒重建反例 `1`，原 bytes/只读属性不变，独审无确定 P0/P1；新 2a4 完整门会话 51145 已实际 native `0`、14 PASS / 0 FAIL / 0 SKIP，Run/独立 Read 均 `0`，受测源码已 create-only 特性发布并远端读回、未合入 main；2a4 A1 与 5 份生成源码独审已闭合；Pair 首次因 StagingRoot 不存在而失败，补普通空目录后的新 r2 实际 Run/Read `0`，R14 实际 Run/Read `0`。随后 Preflight 因 cmd/git.exe 与 transformer 假定的 mingw64/bin 布局不匹配、扫描遇 reparse 而失败，2a4 frozen_failed 保留、不重跑，BuildOnly 未启动/once 未消费。生成前 canonical 布局 guard、既有回归及 runbook 修复已提交为 e898，实际源码专项 16 PASS / 0 SKIP、独审无确定 P0/P1；新 r9 完整门 46616 已自然 outer exit `0`、14 PASS / 0 FAIL / 0 SKIP，Run/独立 Read 均 `0`，最终独审已闭合，无确定 P0/P1；e898 已一次特性发布并精确读回、未合入 main，quarantine 保全成功，A1 Run 30047 已自然 native `0`，A1 独审已闭合，无确定 P0/P1，五份生成源码独审通过后设为只读，Pair/R14 的实际主调用、Run/独立 Read 均 `0`，唯一 Preflight 主会话 1927 已自然 exit `0`，Run/独立 Read 均 `0`；A5 Prepare 会话 14744 主调用 native `0`，已生成 20 份 preview 与 manifest，三项机械 Reviews 主会话 57861 已自然 exit `0`，A5 source-only 9-key review 独审已完成，无确定 P0/P1；BuildOnly 准备主会话 13435 exit `1`，严格 HA consumer 拒绝 Preflight 的 `maximum_observer_tail_seconds=5.0`。UAC/Build/once 均 `0`，e898 不继续 formal20 发布/HA/Ready；继任整数序列化修复已提交为 0d6a，实际钉定 7.6.5 源码专项 16 PASS / 0 SKIP、outer `0`，最终源码独审无确定 P0/P1；新 r10 clean clone、两枚 baseline 与 129 项输入已准备，环境核对实际 `0`/match true，启动窄审已完成、无确定 P0/P1；新 FullCheck 主调用会话 17799 已自然 exit `0`，14 PASS / 0 FAIL / 0 SKIP；FullGraph 最终独审已闭合、无确定 P0/P1；0d6a 特性源码已一次 create-only 发布且精确读回、未合入 main，输出保全实际 `0`；A1 主会话 16432 已自然 `0`，PrepareSources Run/Read/主调用均 `0`、五份生成源独审已完成（范围仅五源，不覆盖 A5 P1）；A5 Prepare 与三项机械 Reviews 实际 `0`；独立语义确认接口 P1：生成 binding 缺顶层 `runner_sha256`，26+20 当前不准入 reviewed。0d6a 不再推进 Pair/R14/Preflight/BuildOnly/正式20发布/HostContract/Ready/设备，这些阶段均未执行、Build once `0`；继任修复已提交为 06b9439，r11 输入与启动窄审已核；FullCheck 67682/866929 实际 `0`、14 PASS / 0 FAIL / 0 SKIP，Read/独审与输出保全已完成；特性源码已一次 create-only 发布且 fresh Git/GitHub 精确读回、未合入 main；A1/五源/A5 source-only 独审已闭合，closed9 source-review 已产生；Pair/R14/唯一 Preflight Run/Read 均 `0`、候选已冻结；BuildOnly 准备实际 `0`；PublicationSupport r1 实际 `1` 保留，补普通空目录后的 r2 主会话 47770 自然 `0`，正式20文件与两阶段收据已产生，实际图独审进行中；Probe/Drive/UAC/Build/HostContract/Ready/设备未执行，0d6a 不恢复，详见当前继任段，设备未运行；4a Pair 不重跑；已消费 `4b37f34` 保持旧固定入口、不重跑 | 版本控制维护源与受控依赖生成新候选；实际固定候选完成生成、独审、pair/r14 与 preflight，旧冻结工件只读保留 |
| **P3 · M1b 能力** | 标清占位工具并收敛实现范围 | 静态核对已提交 `d21c3f2`，见 [能力现状](knowledge/android/m1b-capabilities.md)；实现和真机验收仍按具体需求排期 | notifications_list、notification_reply、ui_diff、app_stop 等标清实际可用性；需要实现的能力分别安排通道与失败路径验收 |

R1/R2/R4、规则精简与 R3 可按文件归属并行；候选固定、冻结、BuildOnly、Ready 与设备流程按下方既有顺序串行。
C1b 继续条件为现行规程及 R3 消费链闭合；其他审查项不新增开跑门，改变本轮候选输入时才纳入该候选验证。
T-L2、语义意图生产接线、分享落地及其他真机项继续使用本节后续条目和 §5；手机批次 4 保持暂停，避免重复建项。

### A · 旧候选单次 BuildOnly 已封存，新候选与正式 Ready 继续串行闭合

**09-30 goal 续办：** 用户已明确授权持续推进待办实现、具体候选准备、受控主机执行、证据与必要源码发布；启动前记录本轮完整 SHA、运行时、launcher raw hash、一次启动及自动重试 `0`，不重复询问已有授权。手机临界操作的可见两段式确认保留。用户现场答复为“已连接并保持该现场”（USB、横屏微信“应用多窗”、键盘隐藏），不能据此判定唯一设备发现或 Ready。见[goal 与正式证据记录](runs/2026-09-30-C1b-goal与正式证据闭合.md)。

协调源码 `e0fcbb2` 已补齐 P3 维护源回退、显式 child environment/双流传输及 R3 真实终态身份派生与一次 Freeze 的离线实现。源码专项 `16 passed, 0 skipped`，capture `13/13`、104 项断言，阶段 Run/Read `10/10`、81 项断言，R3 `14/14`、70 项断言及补充反例通过；失败原日志保留，未观察的历史 EOF 不补造。

新增主机维护源的离线实现保留；058 完整门 11 PASS / 3 FAIL、812 完整门 13 PASS / 1 FAIL、16d 首次 8 PASS / 6 FAIL 均不覆盖。同 16d 完整复验会话 20007 已自然退出 `1`，9 PASS / 5 FAIL，双流 EOF 和 Job 清理完成，未进入独立 Read。capture/C1a/Android 通过；raw archive/intake/C1b host/派单/runner 未全过，派单 54/55、runner 85/87，5 组新失败已只读核对，未知子进程事实与原因保持 unknown。本轮 95 个 KEEP 根已保存普通文件原字节；开跑日志记录清扫 91 个旧目录，首次 4 个失败 fixture 路径现已缺失，日志和此前元信息保留。保留模式跳过开跑清扫修复已提交，作者实际 AST mock 4/4、独审 16/16；4a 候选 `4a65150db9826d668341ad6d9b11cb9883f5c524` 当时普通 clone clean、无 alternates、baseline object 可读，source-only 材料及发布定义已完成独审。4a 完整门及独立 Read 已通过，A1 已实际 native `0`，PrepareSources 的实际 Run/独立 Read 已通过，原时限与 87 个用例不变；5 份生成源码 source-only 独审已通过，但实际 Pair 自然失败，canonical guard 拒绝混合 slash 的 renderer 路径；4a Pair 不重跑，r14/Preflight 及后续主机链未运行。路径修复与实际 cold CLI 回归已完成，形成新 2a4；新完整门会话 51145 已实际 native `0`、14 PASS / 0 FAIL / 0 SKIP，Run/独立 Read 均 `0`；2a4 特性源码已一次发布并远端读回、未合入 main，2a4 A1 与生成源码独审已闭合；Pair 首次缺 StagingRoot 的失败保留，补普通空目录后的新 r2 Run/Read `0`，R14 Run/Read `0`。随后 Preflight 因 Git 布局假定错误触发 reparse guard 而失败，2a4 frozen_failed 保存、不重跑；BuildOnly 未启动、once 未消费，继任 e898 修复及新 r9 准备已完成，完整门 46616 已自然 outer exit `0`、14 PASS / 0 FAIL / 0 SKIP，Run/独立 Read 均 `0`、最终独审已闭合，无确定 P0/P1；e898 已一次特性发布并精确读回、未合入 main，新 quarantine 保全成功，A1 Run 30047 已自然 native `0`，A1 独审已闭合，无确定 P0/P1，五份生成源码独审通过后设为只读，Pair/R14 的实际主调用、Run/独立 Read 均 `0`，唯一 Preflight 主会话 1927 已自然 exit `0`，Run/独立 Read 均 `0`；A5 Prepare 会话 14744 主调用 native `0`，已生成 20 份 preview 与 manifest，三项机械 Reviews 主会话 57861 已自然 exit `0`，A5 source-only 9-key review 独审已完成，无确定 P0/P1；BuildOnly 准备主会话 13435 exit `1`，严格 HA consumer 拒绝 Preflight 的 `maximum_observer_tail_seconds=5.0`。UAC/Build/once 均 `0`，e898 不继续 formal20 发布/HA/Ready；继任整数序列化修复已提交为 0d6a，实际钉定 7.6.5 源码专项 16 PASS / 0 SKIP、outer `0`，最终源码独审无确定 P0/P1；新 r10 clean clone、两枚 baseline 与 129 项输入已准备，环境核对实际 `0`/match true，启动窄审已完成、无确定 P0/P1；新 FullCheck 主调用会话 17799 已自然 exit `0`，14 PASS / 0 FAIL / 0 SKIP；FullGraph 最终独审已闭合、无确定 P0/P1；0d6a 特性源码已一次 create-only 发布且精确读回、未合入 main，输出保全实际 `0`；A1 主会话 16432 已自然 `0`，PrepareSources Run/Read/主调用均 `0`、五份生成源独审已完成（范围仅五源，不覆盖 A5 P1）；A5 Prepare 与三项机械 Reviews 实际 `0`；独立语义确认接口 P1：生成 binding 缺顶层 `runner_sha256`，26+20 当前不准入 reviewed。0d6a 不再推进 Pair/R14/Preflight/BuildOnly/正式20发布/HostContract/Ready/设备，这些阶段均未执行、Build once `0`；继任修复已提交为 06b9439，r11 输入与启动窄审已核；FullCheck 67682/866929 实际 `0`、14 PASS / 0 FAIL / 0 SKIP，Read/独审与输出保全已完成；特性源码已一次 create-only 发布且 fresh Git/GitHub 精确读回、未合入 main；A1/五源/A5 source-only 独审已闭合，closed9 source-review 已产生；Pair/R14/唯一 Preflight Run/Read 均 `0`、候选已冻结；BuildOnly 准备实际 `0`；PublicationSupport r1 实际 `1` 保留，补普通空目录后的 r2 主会话 47770 自然 `0`，正式20文件与两阶段收据已产生，实际图独审进行中；Probe/Drive/UAC/Build/HostContract/Ready/设备未执行，0d6a 不恢复，详见当前继任段，设备未运行，详见[本轮记录](runs/2026-09-30-C1b-goal与正式证据闭合.md)。旧冻结 `4b37f34` 保持只读、不重跑，其他计算保留，资源数值不作失败因果证明。

4a FullCheck 的 129 项输入准备和启动前窄审无漂移；核定 7.6.5 实际环境摘要匹配。Goal 恢复 active 后，新四点资源可用 10.7–11.1 GiB、commit 47.95%–48.46%，先前两个 PID 未观察到、原因未知，未调整用户计算。实际完整门会话 39744 已自然 exit `0`，14 PASS / 0 FAIL / 0 SKIP；runner 87 PASS / 0 FAIL，Android 219 个任务全部 executed，保留单 Gradle worker、fixture 和完整 Gradle 检查。root producer PID 25900、独立 reader PID 28212 均 native `0`、双流 EOF、cleanup failure `0`、Job active `0`、自动重试 `0`；独立 Read 核对 13 个输入 pin，实际 FullCheck 阶段 native `0`。钉定 main030 的功能 publisher 会话 82517 已自然 exit `0`，一次 create-only 发布特性分支并远端读回 4a；main 更新、强推、自动重试均为 `0`，尚未合入 main。尚无新 BuildOnly、Ready 或设备执行；A1/PrepareSources 成功与 Pair 失败见下文。最小启动诊断的孩子实际 native `0`、elapsed 840 ms、双 EOF/Job 清理完成；诊断 reader 仅接受 `[int]` 而误拒真实 JSON `Int64` PID，driver/group 实际 exit `1`，Prewarm 未到达。该工具缺陷另在新定义离线修正，原失败收据和 source 保留、不重跑；不能把一个最小孩子的成功视为原 intake、完整门或 Ready 通过。private ADB server 单 case 定义仍未实际执行，旧 final_substage 为 unknown。

4a A1 已实际 native `0`，closed 输入和 authority 核对 460 个 tracked、42 个 implementation 输入与 4 次真实 Git 查询；auditor、producer、orchestrator、inner root 四层实际捕获均 native `0`、双流 EOF、cleanup failure `0`、Job active `0`。首次 A1 输入 writer 在 A1 或其他 child 启动前因 function table 类型失败，仅留下空 r1 目录；修正 Hashtable 后，新 r2 输入由 native writer 创建成功并只读保存，不把前置失败记为一次 A1 执行。本次 3 个 synthetic 标记日志与 1359 份 probe build 文件已移至 FullCheck 的 owned-output-quarantine 保全、全部 hash 读回，无删除，原 build 路径不存在且 marker 为 `0`。PrepareSources 已实际 Run/独立 Read native `0`，生成 5 份 exact 4a expected/renderer 源码，source-only 独审通过。实际 Pair 因 canonical guard 拒绝混合 slash 的 renderer 路径而自然失败：stage child PID 29320、producer PID 33756 均 native `1`、双流 EOF、cleanup failure `0`、Job active `0`、自动重试 `0`。Pair 独立 Read 未运行、helper/launcher 未发布，BuildOnly 未消费；r14/Preflight/Ready/设备未运行。4a Pair 原件保留、不重跑，既有 source-only 审查保持原范围；维护源码 renderer 路径修复及实际 cold CLI 回归已提交并通过独审，形成新 2a4，完整门进度见下文；不以 4a 成功记录代替新候选验收，详细原始证据见[本轮记录](runs/2026-09-30-C1b-goal与正式证据闭合.md)。

**旧 2a4 结论：** 实现为 `2a4ccdb82783046c987689bb28d5d89000f4284d`，根源码整合 `57845053840609a1a5fc4609fd2025271d0728cf`。四文件修复已提交，作者钉定 7.6.5 的实际源码专项为 16 passed / 0 skipped、native `0`、stderr `0`；cold CLI 合成夹具首次 native `0`，no-replace 反例 native `1` 且原 bytes/只读属性不变，独审无确定 P0/P1。新 r8 普通 clone 实际 HEAD/clean、普通 `.git`、无 alternates、两枚受信 baseline 均已核；129 项输入的实际 7.6.5 preparer 与 fresh environment probe 均 exit `0`，版本/路径/runtime pin/新摘要匹配，启动窄审双次读取 129 项、零漂移、无确定 P0/P1。新完整门会话 51145 已实际结束、native `0`，14 PASS / 0 FAIL / 0 SKIP，runner 87/87、dispatch 55/55、C1b 32/32、Android 219 个任务；Run/独立 Read 均实际 `0`。保留 `-Shards 1`、Gradle、单 worker、`P0_KEEP_FIXTURE=1`、自动重试 `0`。[2a4 功能源码](https://github.com/MaginaLW/agent-for-mobile/tree/2a4ccdb82783046c987689bb28d5d89000f4284d) 已一次 create-only 发布至特性分支、远端读回精确 SHA，main 保持 `030db3238cd08eadd3f9e652c5dd57ab4e233088`，没有合并。2a4 A1 实际会话 26871 native `0`，独审核对 240 份 raw 和 8 份实际 capture，无确定 P0/P1。PrepareSources 实际 Run/独立 Read 及主调用均 native `0`，5 份生成源码 source-only 独审闭合，Parser `0`、18 项新路径正例及混合 slash 反例通过。1359 份文件、695 个目录和 3 份日志已移出保全，hash 全部一致、A1 marker `0`、删除 `0`，不计作正式 HA archive。Pair 首次主调用因 StagingRoot 尚不存在而 native `1`，补普通空目录后的新 Pair-attempt-r2 实际 Run/独立 Read/主调用均 `0`；首次工件生成失败保留，与 BuildOnly once 分开。R14 实际 Run/独立 Read/主调用均 `0`。随后 Preflight 主调用 native `1`：PrepareSources 传入 cmd/git.exe，而 transformer 的三次 GetDir 假定 mingw64/bin/git.exe，扫描 ProgramFiles 时遇 reparse；5 项 failure、cleanup `0`、quiescence `true`，实际 child PID 50008 自然 exit `1`、双流 EOF。失败收据已发布且 pass 为 false，2a4 frozen_failed 保存，不再 Git/check、覆写或重跑；BuildOnly 未启动、无 once 消费，Ready/设备未执行。此后生成前 canonical mingw64/bin 布局 guard、既有回归及 runbook 修复已提交为继任 e898，新完整门进度见下文；4a Pair 不重跑，原始材料见[本轮记录](runs/2026-09-30-C1b-goal与正式证据闭合.md)。

**旧 e898 结论：** 完整实现为 `e8988aa49ec3a04e171bbb879729be7f32f3e606`，根源码整合 `268aee60e83a476e97685bf748ba718d65fca5a3`。四文件 75 行新增/5 行删除仅涉及 CLI、纯模块 helper、现有 16-case 与 runbook；CLI 和 Add/New 生成 API 共用 canonical mingw64/bin 布局早拒检查，template/native/tree guards 不变。作者实际钉定 7.6.5 源码专项 16 PASS / 0 SKIP、native `0`、stderr `0`，独审无确定 P0/P1。r9 clone 已成功；第一次准备核对因缺 b576 baseline object 而 outer `1`，不记作完整门失败，从本地受信对象补取实际 `0` 后，actual e898/clean、普通 `.git`、无 alternates 与两枚 baseline 读回成功。129 项新 bootstrap 与 bindings 已准备，actual preparer `0`、fresh 7.6.5 纯环境匹配 `0`，启动独审 129 项双读无漂移。新完整门会话 46616 已自然 outer exit `0`，14 PASS / 0 FAIL / 0 SKIP，实际 Run/独立 Read 均 `0`；runner 87/87、dispatch 55/55、C1b 32/32，Android 为 219 个任务，126 份 JUnit XML 共 1170 tests、failures/errors/skips 均 `0`。check/producer/reader 三份 capture 的 EOF/drains 闭合，cleanup/active 均 `0`；reader 自报核对 13 pins、`root_exit_observed=false`，最外 native `0` 由主工具实际读到；最终独审核对 18 份 strict JSON、157 份 raw 双读零漂移，无确定 P0/P1；`-Shards 1`、Gradle、单 worker、`P0_KEEP_FIXTURE=1`、自动重试 `0` 不变。[e898 功能源码](https://github.com/MaginaLW/agent-for-mobile/tree/e8988aa49ec3a04e171bbb879729be7f32f3e606) 已在实际会话 50848 native `0` 后一次 create-only 发布至 `codex/c1b-host-evidence-e8988aa`，fresh Git 读回精确 SHA，当次 Git/GitHub main8bc 未变化，强推/自动重试 `0`，发布源码独审无确定 P0/P1，未合入 main。首次 quarantine 会话 45359 在 260 长路径的 Native.Open 失败，native `1`、目标不存在/移动 `0`，原 source 和失败保留；新 longpath r2 仅为 output Open 使用 extended DOS prefix，原 Native flags/identity 不变，actual native `0`。1359 份文件、695 个目录及 3 份日志已移出保全，hash 全部相同、模块原路径不存在/marker `0`/删除 `0`，属于 managed preservation，不当作正式 HA archive。A1 actual prepare `0`，两份 closed14 map 与新 129 输入已重建、绑定本轮 Full/quarantine raw pins；实际 Run 会话 30047 已自然 native `0`，A1 独审核对 233 份 raw 双读零漂移、8 份 capture/16 条 streams，无确定 P0/P1。PrepareSources Run/独立 Read/主调用已实际 `0`，五份生成源码独审通过后设为只读；Pair 实际主调用、Run/独立 Read 均 `0`，final helper/launcher hash 与 expected 一致且只读；R14 实际主调用、Run/独立 Read 均 `0`。唯一 Preflight 主会话 1927 已自然 exit `0`，Run/独立 Read 均 `0`，`all_checks_passed=true`、failure `0`、四项只读 Git 均 `0`；该预检未启动 launcher/helper、Build 或 ADB。receipt 不单独授权后续执行，其 `RO=false` 原样保留；冻结前 HEAD clean、final 三份工件只读且 hash 匹配。A5 Prepare 会话 14744 主调用 native `0`，已生成 20 份 preview 与 manifest，三项机械 Reviews 主会话 57861 已自然 exit `0`，A5 source-only 9-key review 独审已完成，无确定 P0/P1。BuildOnly 准备主会话 13435 exit `1`，prepare child PID 12568 自然 exit `1`、双 EOF，cleanup failure/active 均 `0`，stdout 为 `0` bytes、stderr 为 230 bytes；outer operationRoot 未创建，UAC/Build/once 均 `0`。唯一确定原因是实际 Preflight 的 `verifier_static_evidence.maximum_observer_tail_seconds` 序列化为 token `5.0`，被正式严格整数 HA consumer 拒绝。Full/A1/Pair/R14/唯一 Preflight 的原 actual pass 保持；冻结 e898 不补写 receipt、不运行 Git/check/Gradle、不重跑 Preflight，不继续 formal20 发布/HA/Ready。继任整数序列化修复已提交为 0d6a，源码专项及最终独审已通过，新 r10 准备完成、启动窄审已完成、无确定 P0/P1；新 FullCheck 主调用会话 17799 已自然 exit `0`，14 PASS / 0 FAIL / 0 SKIP；FullGraph 最终独审已闭合、无确定 P0/P1；0d6a 特性源码已一次 create-only 发布且精确读回、未合入 main，输出保全实际 `0`；A1 主会话 16432 已自然 `0`，PrepareSources Run/Read/主调用均 `0`、五份生成源独审已完成（范围仅五源，不覆盖 A5 P1）；A5 Prepare 与三项机械 Reviews 实际 `0`；独立语义确认接口 P1：生成 binding 缺顶层 `runner_sha256`，26+20 当前不准入 reviewed。0d6a 不再推进 Pair/R14/Preflight/BuildOnly/正式20发布/HostContract/Ready/设备，这些阶段均未执行、Build once `0`；继任修复已提交为 06b9439，r11 输入与启动窄审已核；FullCheck 67682/866929 实际 `0`、14 PASS / 0 FAIL / 0 SKIP，Read/独审与输出保全已完成；特性源码已一次 create-only 发布且 fresh Git/GitHub 精确读回、未合入 main；A1/五源/A5 source-only 独审已闭合，closed9 source-review 已产生；Pair/R14/唯一 Preflight Run/Read 均 `0`、候选已冻结；BuildOnly 准备实际 `0`；PublicationSupport r1 实际 `1` 保留，补普通空目录后的 r2 主会话 47770 自然 `0`，正式20文件与两阶段收据已产生，实际图独审进行中；Probe/Drive/UAC/Build/HostContract/Ready/设备未执行，0d6a 不恢复，详见当前继任段；设备未运行；2a4 frozen_failed 与旧成功、失败原件保持，原始证据见[本轮记录](runs/2026-09-30-C1b-goal与正式证据闭合.md)。

**旧 r10/0d6a 结论：** 固定候选为 `0d6a0789c9cf1cf2e29c1a37b34ff8b50fa81f7b`，根源码四文件整合 `f704275d7a5ccad0d47d4d3b0353bd6df5d343f9`。四文件 95 行新增/2 行删除仅将静态 `maximum_observer_tail_seconds` 明确序列化为 `[long]5`、同步 template hash、既有用例与 SOURCE 文档；HA 严格门以及 runtime double `5.0` 的观察边界不变。作者在钉定 7.6.5 的实际源码专项会话 37106 outer `0`，16 PASS / 0 SKIP、stderr `0`，最终源码独审无确定 P0/P1。新 r10 ordinary clone 初次 native `0`，实际 HEAD/clean、无 alternates 均已核；两枚受信 baseline 在 checkout 前 fetch 并读回实际 `0`。新 129 项 bootstrap 与 bindings 已生成，fresh 7.6.5 environment 实际 `0`、match 为 true。启动窄审已完成、无确定 P0/P1。新 FullCheck 主调用会话 17799 已自然 exit `0`，14 PASS / 0 FAIL / 0 SKIP；独立 reader native `0`、status 为 passed、核对 13 pins，`root_native_exit_observed=false` 原样保留，最外自然 exit `0` 来自主工具实际观测。runner 87/87、dispatch 55/55、C1b 32/32；Android BUILD SUCCESSFUL，用时 4m3s，219 个任务全部实际执行。FullGraph 最终独审已封存，无确定 P0/P1，129/152 raw 双读零漂移，三份 capture native `0`、EOF/cleanup 闭合；publisher 实际发布图独审无 P0。实际 sourcepublisher 会话 1090 exit `0`，0d6a 特性源码一次 create-only 发布，fresh Git/GitHub 读回 feature 精确 0d6a、main 保持 8bc；main/tag/force/ADB/retry 均 `0`，源码未合入 main。输出保全实际 exit `0`，1359 份文件、695 个目录与 3 份日志 raw 一致，marker/删除均 `0`；属于 managed preservation，不计正式 HA archive。A1 两份 closed14 输入准备实际 `0`，主会话 16432 已自然 `0`，460 个 tracked、42 个 implementation 与四次真实 Git 核对完成；只读 authority 属于 preparation，不计主机验收。A1 最终独审报告已封存，无 P0，215 份 raw 闭合。PrepareSources 实际 Run/独立 Read/主调用均 `0`，五份生成源已产生、独审已完成（范围仅五源，不覆盖 A5 P1）。A5 Prepare 会话 43349 实际 `0`，26 份维护源与 20 份 previews 已生成；Reviews 会话 22993 已自然 `0`，三项机械 Reviews 的阶段收据均已产生。独立语义确认接口 P1：`New-C1bDeviceEntryBinding` 生成的 binding 没有顶层 `runner_sha256`，R3 terminal 必须消费裸 64hex；真实 `manifest.context.implementation_hashes.runner_sha256` 已存在且带 `sha256:` 前缀，26 份维护源与 20 份 previews 当前不准入 reviewed。机械 `0` 保留原检查范围；该接口已在继任 06b9439 修复并完成范围回归，原 0d6a 工件不恢复；r11 当前状态见下文；publisher 定义独审与后阶段计划保持 source-only；0d6a 不再推进 Pair/R14/Preflight/BuildOnly/正式20发布/HostContract/Ready/设备，这些阶段均尚未执行、Build once `0`；已成功的 Full/A1/PrepareSources/三项机械 Reviews 与特性发布保留原结论，为继任修复保全本轮证据，旧 e898 原通过与 BuildOnly 准备失败均不改判，原始证据见[本轮记录](runs/2026-09-30-C1b-goal与正式证据闭合.md)。

**当前继任 06b9439：** 当前继任为 `06b94393eca1e0c180a82cc1179e255e2d27d799`，根源码整合 `da6812c1a076fd7839d0fd0a82afdf5d2e770cd5`，三文件 61 行新增/2 行删除。实际钉定 7.6.5 的 suite-r2 会话 12485 自然 `0`，32 PASS / 0 FAIL、32 个 actual cases；真实 producer→R3 guard 与四项 Ready 用例已执行，hoststub、未执行完整 R3 flow、设备 `0` 的边界保持。首次 94276 的 27 PASS / 1 FAIL、28 cases 保留：array 已被原 manifest guard 拒绝，原测试匹配不足，新测试只修正 array 的精确期望。最终两份源码独审在三文件 delta/cross-R3-guard 范围无确定 P0/P1；后 14 个接口及 BO→HA 预审为 source-only、无新增确定 P1，实际后阶段仍待证据。新 r11 clone/fetch/checkout 均实际 `0`；首次 post-clone Get-Item 缺 Force 的核对 native `1` 原件保留，后续只读回 `0`、未重做 clone/fetch/checkout，实际 HEAD/clean、普通 gitdir、无 alternates 与 baseline 已核。129 项 bootstrap/bindings 准备及 fresh 7.6.5 environment 均实际 `0`、match 为 true；启动窄审已封存，129 项双读零漂移、无确定 P0/P1。FullCheck 主调用 67682/866929 实际 `0`，14 PASS / 0 FAIL / 0 SKIP；三份 capture 均自然 `0`，Read 核对 13 pins，153 份 raw 的独立审查无确定 P0/P1。输出保全实际 `0`，1359 份文件、695 个目录与 3 份日志已保全、删除 `0`，不计 HA RawArchive。特性源码发布主会话 40197 实际 native `0`，create-only 一次、自动重试 `0`、main 更新 `0`；fresh 根 Git/GitHub 读回 feature 精确对应本段完整候选 SHA、main 为 8bc0c87，代码未合入 main；publisher 实际图独审已封存，38 份 raw 双读零漂移。A1 主会话 84099 实际 native `0`；本轮收据为 `passed_preparation_only`，实际 460 tracked、42 implementation、四次 Git，仅属准备、Ready/设备授权为 false。A1 最终独审已封存、无确定 P0/P1。PrepareSources 实际 Run/Read/主调用均 `0`，五份生成源独审已闭合（范围仅五源）；A5 Prepare 主会话 31559 和三项机械 Reviews 主会话 22629 实际 `0`，26 份维护源与 20 份 previews 的独立语义审查已闭合，新 closed9 source-review 为 reviewed、无确定 P0/P1，机械 `0` 仅保留原检查范围。Pair、R14 与唯一 Preflight 实际 Run/独立 Read/主调用均 `0`；冻结前 HEAD 精确对应本段候选、status 输出为空，冻结后不再运行普通 Git/check/Gradle。Preflight 的观察尾界为真实 JSON Int64 `5`，四次只读 Git 的 drain/cleanup 均闭合、failure `0`；仅属主机准备，receipt 不单独授权，其 `RO=false` 保持。三阶段独审已封存、无确定 P0/P1；整数计数勘误为 61 份 JSON/903 个整数，原报告未改。BuildOnly 准备实际 `0`，六份工件及只读实际 copy 的准备图/源码独审已闭合；Probe/Drive outer 输入已准备、独审进行中，尚无提升或构建结果。PublicationSupport 首次 r1 因精确 EntryRoot 不存在而实际 `1`，发生在 20 份写入、Support 与 once 之前，原失败保留；补普通空目录后的 r2 主会话 47770 已自然 `0`，正式 20 份文件与 SourcePublicationOuter/Support 两阶段收据已产生，20 roles 和实际 capture 图独审正在进行。本候选 Probe/Drive/UAC/BuildOnly/HostContract/Ready/设备均未执行、once `0`；旧 0d6a 不恢复，原始证据见[本轮记录](runs/2026-09-30-C1b-goal与正式证据闭合.md)。

**09-28 进度：** R3 设备发现证据 consumer/reader/freezer 已在实现分支提交
`7c5511621f9972f2bf2877591e6d19e3b69e7593`，无设备离线测试 9/9、26 项断言通过，真实 ADB/设备调用 0。
新独占普通 clone 固定该 SHA，42 项原始输入与 HEAD Git blob 逐项一致、工作区 clean、对象库无 alternates。
首次全量门在 C1b host fake-ADB E2E 发现克隆缺少两枚受信 baseline commit object，故该次 A2 失败；
补取两个精确对象后，同一 SHA 的第二次全量门实际退出 0、13/13 项通过，host 项 32/32 coverage，
R3 消费链另有 9/9、26 项断言通过，真实 ADB/设备调用 0。首轮失败日志保留，不追溯改判。
随后 exact pair/r14 工件发布与唯一只读 preflight 完成，外层 exit `0`、`prepared_not_authorized=true`。
用户授权的唯一 BuildOnly 调用因调用方漏传 launcher mandatory `-ExpectedLauncherSha256`，在参数绑定阶段 exit `1`；
helper、Gradle、ADB/设备调用均未进入，该轮已封存、不补参重跑。详见[本轮失败记录](runs/2026-09-28-C1b-7c55116-BuildOnly参数绑定失败.md)。
09-28 该轮结束时没有成功 BuildOnly、Ready 或设备放行；随后新候选结果见下文，不复用该轮授权。

**09-29 `14edb4a` 结论：** 42/42 输入绑定、全量门 13/13、R3 专项 9/9、exact pair/r14
及唯一只读 preflight 均已完成；唯一 BuildOnly 因 launcher 继承未提升令牌，在 `elevation_check`
exit `1`，helper/构建/ADB 均未进入。该 SHA 已封存，不因提权重跑。PC Suite 的退出行为设置须在
主机阶段结束后恢复。见[A1—A3](runs/2026-09-29-C1b-14edb4a-A1-A3主机准备.md)与
[失败记录](runs/2026-09-29-C1b-14edb4a-BuildOnly权限失败.md)。

**09-29 准备快照：** 用户同意 UAC 后，独立探针在钉定 PowerShell 7.6.5 内确认
`elevated_token=true`，未执行 Git、构建或 ADB；原始记录在协调工作区
`.checks/c1b-elevation-probe/result.json`，SHA-256 为
`88914fddc91f2cf01f3dac0e1c780897042f7f87f7f28cd192e47eaea5c4fb03`。
实现分支 `4b37f344d5af988ce9b2f7610df98387a49cd2d0` 写明正式启动令牌门；新普通 clone
A1 42/42、A2 全量门 exit `0`/13/13、R3 专项 9/9、A3 exact pair/r14 均通过。唯一只读
preflight 外层 exit `0`、`prepared_not_authorized=true`；提升启动脚本已静态核验但未执行。
当时本 SHA 的单次 BuildOnly 仍须另行授权，见[主机准备](runs/2026-09-29-C1b-4b37f34-A1-A3主机准备.md)；09-30 已执行并消费，见下方续办。

**09-30 续办：** 启动前 42/42 输入及启动材料被动读回一致。用户已针对完整
`4b37f344d5af988ce9b2f7610df98387a49cd2d0` 和 launcher hash
`a073552a67efcf5d6c1ba030a05fbb0686b9059ec09580df15ee7adf7b1554a4`
授权一次 UAC BuildOnly，现已实际退出 `0`；管理员令牌成立，launcher/helper 各启动一次、自动重试为 0。
独立读回 `accepted_no_device`，57 个 present 输入 pins 核对一致，69 个 raw 成员只读副本封存与独审通过，
ADB/安装/T0/采集均为 0。见[BuildOnly 与续办](runs/2026-09-30-C1b-4b37f34-BuildOnly与续办.md)。
授权已消费且不含设备操作，同 SHA 不重跑；PC Suite 临时关闭设置已精确恢复并读回，UI 行为未动态验证。

A5 三组审查草稿已完成：20 份 review-only 源静态审计、R3 终态 Read/一次 Freeze 桥接的 10 个合成场景、
host evidence r2 实物消费。正式 host contract/Ready 仍有 7 类缺口：BuildOnly/reader 的分流 EOF、
current final binding、A2/A3 capture 拓扑、legacy formal terminal-freeze 与当前 A5 source 独审。
raw 保全已完成，不能冒充正式终态封存门；R3 仍须可信 `discovery_identity` 生产接线。
主机双流模块 `e014bab` 已接入常驻离线门并通过实际 C1b 检查组，见[采集修复](runs/2026-09-30-C1b-主机双流采集离线修复.md)；
尚未接入正式候选/UAC 链，未改变 frozen `4b37f34`，没有 Ready 或设备 r2。

**09-13 收尾状态：** 根目录继续负责协调，设备发现证据修复已提交，临时副本清理已完成、归档保留；清理不再是待办。
提交、验证数值及完整交接见[收尾与待完成项](runs/2026-09-13-C1b-收尾与待完成项.md)，实现与原始证据见
[离线修复记录](runs/2026-09-13-C1b-设备发现证据离线修复.md)。

后续以 06b9439/r11 串行推进；当前 FullCheck 67682/866929 实际 `0`、14 PASS / 0 FAIL / 0 SKIP，Read/独审已闭合、输出保全已完成；特性源码、A1 与 PrepareSources 已实际 `0`，A1/五源/A5 source-only 独审和 closed9 source-review 已闭合；Pair/R14/唯一 Preflight Run/Read 均 `0`、候选已冻结，BuildOnly 准备实际 `0`；PublicationSupport r1 原失败保留，r2 主会话 47770 自然 `0`，正式20及 Support 实际图独审进行中。旧 r10 完整门、A1、PrepareSources、机械 Reviews 与特性发布成功及 A5 接口 P1 均保留，0d6a 不恢复；既有历史和原始证据见上文及[本轮记录](runs/2026-09-30-C1b-goal与正式证据闭合.md)：

1. r11 129 项输入、新环境与启动窄审已核，FullCheck 67682/866929 已实际 `0`、14 PASS / 0 FAIL / 0 SKIP，Read/独立审查已闭合、无确定 P0/P1。32/32 回归属于三文件 source/cross-R3-guard 范围，回归使用 hoststub，完整 R3 flow 尚未执行。
2. r11 输出保全已实际 `0`，不计 HA RawArchive；特性源码已一次 create-only 发布并 fresh Git/GitHub 精确读回、未合入 main。A1、五源及 A5 source-only 独审已闭合，closed9 source-review 已产生；机械 `0` 仅保留原检查范围。Pair/R14/唯一 Preflight 的实际 Run/独立 Read/主调用均 `0`，三阶段独审已封存；候选冻结后不再运行普通 Git/check/Gradle，旧候选成功记录不替代本候选验收。
3. BuildOnly 准备已实际 `0`，六份工件及只读实际 copy 的准备图/源码独审已闭合；Probe/Drive outer 输入已准备、独审进行中。后续在现有授权下完成 UAC Probe、一次 Drive、独立 reader/raw 封存及正式主机合同。当前 Probe/Drive/UAC/BuildOnly/HostContract 未执行、once `0`、自动重试 `0`；失败或已消费不在同 SHA 重跑。
4. 本候选 A5 的 26+20 source-only 语义独审和 closed9 source-review 已闭合；PublicationSupport r1 因精确 EntryRoot 不存在而实际 `1`，在 20 份写入/Support/once 之前失败，原件保留。补普通空目录后的 r2 主会话 47770 自然 `0`，正式20文件和两阶段收据已产生，20 roles/实际 capture 图独审进行中，后 14 个接口及 BO→HA 预审仅为 source-only。正式主机合同/Ready/设备尚未执行，旧 Ready 与确认不复用；主机条件闭合后才接续单次设备流程、真实终态读回及封存，手机危险动作仍在临界点真人确认。

当前没有新 Ready 或设备 r2；旧 Ready、已消费 attempt 和旧设备确认不复用。剩余显示回退、原零设备根因及设备操作次数保持未知，直到真实证据闭合。

旧候选 `a878d12/r1` 因“当前识别到 0 台”失败，`c43652a/r1` 因 `capture_c1_display_unsupported` 失败，均已封存、不重跑。
各阶段授权、主机验证与设备结果分别见 [a878d12 候选准备](runs/2026-09-13-C1b-a878d12-候选准备.md)、
[a878d12 设备执行](runs/2026-09-13-C1b-a878d12-设备执行.md)、[c43652a 主机记录](runs/2026-09-13-C1b-c43652a-BuildOnly.md)
及 [c43652a 设备执行](runs/2026-09-13-C1b-c43652a-设备执行.md)。旧候选的通过记录和设备授权不能用于新轮，不将尚未验收的实现合入 main。

| 工作 | 当前证据 | 下一步与边界 |
|---|---|---|
| **C1b display context 回退及设备发现证据（含 P1 · R3）** | 旧 `7c55116`、`14edb4a` 失败已封存；`4b37f34` 唯一 BuildOnly/独立读回/raw 封存通过且已消费。R3 离线 `14/14`、70 项断言及补充反例通过；runner 早期失败引用和受控 fake-ADB 32/32 已接线；原生助手延迟编译与确认轮询竞态已修复 | 16d 完整复验实际 exit `1`、9 PASS / 5 FAIL，原失败均保留。旧 `4a65150` 该轮的修复、clean 普通 clone、源码独审和 129 项输入准备已完成；本轮完整门会话 39744 自然 exit `0`、14 PASS / 0 FAIL / 0 SKIP，独立 Read 已通过；受测源码已特性发布并远端读回、未合入 main。A1 已实际 native `0`，PrepareSources 实际 Run/独立 Read 及 5 份生成源码 source-only 独审已通过；实际 Pair 因 renderer 混合 slash 路径被 canonical guard 拒绝而自然失败，stage/producer native `1`、双 EOF/cleanup failure `0`/Job active `0`/重试 `0`。Pair 独立 Read 未跑、helper/launcher 未发布、BuildOnly 未消费；修复及实际 cold CLI 回归已提交为新 2a4，新完整门会话 51145 已实际 native `0`、14 PASS / 0 FAIL / 0 SKIP、Run/独立 Read 均 `0`，特性源码发布并远端读回完成、未合入 main；2a4 A1 与 5 份生成源码独审闭合，Pair 首次缺 StagingRoot 的失败保留，补普通空目录后的新 r2 Run/Read `0`，R14 Run/Read `0`。随后 Preflight 因 Git 布局假定错误触发 reparse guard 而失败，2a4 frozen_failed 保存、不重跑，BuildOnly 未启动/once 未消费；继任 e898 的布局 guard、回归及 runbook 已提交并独审，新 r9 完整门 46616 已自然 outer exit `0`、14 PASS / 0 FAIL / 0 SKIP，Run/独立 Read 均 `0`、最终独审已闭合，无确定 P0/P1；e898 已一次特性发布并精确读回、未合入 main，quarantine 保全成功、A1 Run 30047 已自然 native `0`，A1 独审已闭合，无确定 P0/P1，五份生成源码独审通过后设为只读，Pair/R14 的实际主调用、Run/独立 Read 均 `0`，唯一 Preflight 主会话 1927 已自然 exit `0`，Run/独立 Read 均 `0`；A5 Prepare 会话 14744 主调用 native `0`，已生成 20 份 preview 与 manifest，三项机械 Reviews 主会话 57861 已自然 exit `0`，A5 source-only 9-key review 独审已完成，无确定 P0/P1；BuildOnly 准备主会话 13435 exit `1`，严格 HA consumer 拒绝 Preflight 的 `maximum_observer_tail_seconds=5.0`。UAC/Build/once 均 `0`，e898 不继续 formal20 发布/HA/Ready；继任整数序列化修复已提交为 0d6a，实际钉定 7.6.5 源码专项 16 PASS / 0 SKIP、outer `0`，最终源码独审无确定 P0/P1；新 r10 clean clone、两枚 baseline 与 129 项输入已准备，环境核对实际 `0`/match true，启动窄审已完成、无确定 P0/P1；新 FullCheck 主调用会话 17799 已自然 exit `0`，14 PASS / 0 FAIL / 0 SKIP；FullGraph 最终独审已闭合、无确定 P0/P1；0d6a 特性源码已一次 create-only 发布且精确读回、未合入 main，输出保全实际 `0`；A1 主会话 16432 已自然 `0`，PrepareSources Run/Read/主调用均 `0`、五份生成源独审已完成（范围仅五源，不覆盖 A5 P1）；A5 Prepare 与三项机械 Reviews 实际 `0`；独立语义确认接口 P1：生成 binding 缺顶层 `runner_sha256`，26+20 当前不准入 reviewed。0d6a 不再推进 Pair/R14/Preflight/BuildOnly/正式20发布/HostContract/Ready/设备，这些阶段均未执行、Build once `0`；继任修复已提交为 06b9439，r11 输入与启动窄审已核；FullCheck 67682/866929 实际 `0`、14 PASS / 0 FAIL / 0 SKIP，Read/独审与输出保全已完成；特性源码已一次 create-only 发布且 fresh Git/GitHub 精确读回、未合入 main；A1/五源/A5 source-only 独审已闭合，closed9 source-review 已产生；Pair/R14/唯一 Preflight Run/Read 均 `0`、候选已冻结；BuildOnly 准备实际 `0`；PublicationSupport r1 实际 `1` 保留，补普通空目录后的 r2 主会话 47770 自然 `0`，正式20文件与两阶段收据已产生，实际图独审进行中；Probe/Drive/UAC/Build/HostContract/Ready/设备未执行，0d6a 不恢复，详见当前继任段，设备未运行；4a Pair 不重跑。正式合同和 Ready 尚未完成。没有新 Ready/r2，原零设备根因未知，显示回退未获真机验收。见[goal 与证据](runs/2026-09-30-C1b-goal与正式证据闭合.md)及[旧候选主机结果](runs/2026-09-30-C1b-4b37f34-BuildOnly与续办.md) |
| **语义意图生产接线** | 48f8dd8 已补基础模块及 57 JVM 用例：一次性 store、三时钟、reader 装配、a11y/OCR 三态与绑定内容 | SafetyGate、Android 证据安装、严格执行链及 handler 次数证明未完成；C 队列未清时保持未接线，见 [spec §5](specs/2026-08-02-语义意图审批-design.md) |

**R3 离线闭合范围：** 既有 collector/reader/freezer 的 checkpoint、无 run ID 失败与 raw pins 验证保留；新 terminal discovery 从真实 terminal、observer、binding、一次预约及 stdout 内容引用派生身份，公开 Freeze 再消费原始材料，缺引用或 run 提升未知时保持 unavailable，不按文件名/mtime 猜 ID、不自动重试。协调专项 `14/14`、70 项断言及补充合成/独审反例通过；可变 runner 已补“成功落盘并读回才发布”的 early failure 指针及独立守卫。以上是离线实现证据，实际设备发现、Ready 和显示回退仍待同一新固定候选的真实证据。

C1b 历史候选 6fbb157 已通过全量 13/13、exact pair、r14 发布及唯一只读 preflight；
随后唯一 build-only 因 helper stderr 非空且捕获溢出，launcher/caller exit 1 而失败冻结。
helper exit 0、构建/签名/aapt2 完成不能替代整轮通过；该轮 ADB/设备 0、清理完成。
见 [冻结记录](runs/2026-09-07-C1b-6fbb157-构建输出流失败.md)。旧轮不重跑；
新候选 preflight 冻结后不得再运行会生成构建产物的 Gradle/check。

Git 信任根、JDK、Gradle 和 Android package 树此前已只读复核，旧 A→E 重装阶梯已作废。
这些是历史候选的证据，新候选按规程核对实际输入，不把“曾通过”解释为环境永久不漂移。

### 批次 1 / 2 / 3 · 已验收的手机历史

手机批次 1 前后置自动化、批次 2 通知栏审批、批次 3 连跑与 Deny 带外验证已验收；
早期失败不再列作当前待办。批次 2 当时按“亮屏离屏审批”收窄验收，锁屏审批已移出。
**2026-08-28 已进一步撤销通知批准：通知只保留拒绝和查看证据，批准仅能来自完成绘制与取证门的
可见 ConfirmOverlay；allowed=true 广播 fail-closed。** 历史 Allow 验收不证明现在可以从通知批准。
不声明 full-screen intent 权限，危险安全失败仍为终态，不重弹或转第二腿。

审批通道必须让大脑碰不到：用户回执直接进入网关，审批凭据与 gateway token 分离，
TestControl 不携带也不能设置真人决定。通知与确认路径改动须独立验收。
有效设计与适用范围见 [通知栏审批 spec](specs/2026-08-01-通知栏审批布局-design.md)，旧过程见 [归档 §4/§5](backlog-archive.md)。

### 平板路线与后置工作

当前基线：**PA2553 / Android 16 / 日常横屏应用多窗**。项目适配系统原生能力，
不靠关闭功能换通过；关闭功能最多是明确标注的对照实验，不能成为产品前置或验收条件。

路线为 T0-L 入场 → T-L1/C1a origin/read-only → C1b pure-a11y 拓扑 → T-L2 横屏 P0。
T-L2 依赖 pane-aware 证据、横屏确认卡 safe-area 证明和离线门；真机按 Allow → Stale → Deny → Reentry
逐腿保留独立带外证据。标题、OCR、后验先裁 pane，带外核对 X/Y，不用 IME-only 或整屏坐标兜底。
T-L3 的其他多 App 分屏/自由窗及响应式确认 surface、T-P 竖屏兼容均后置，见 [平板设计](specs/2026-08-23-Android平板适配-design.md)。

### 其他待真机项与已完成离线项

- 分享落地 activity 全类名及冷启动反例：白名单保持空，不能凭类名印象填充。
- 审计迁移 filesDir 后的 run-as 只读复验；可在适当真机批次中搭便车。
- S5 RemoteInput、S2 Shizuku 重启存活；按 [M1 真机日清单](runbooks/M1-真机日清单.md)安排，不能用历史单项观测替代。
- dispatch -Confirm 暂停件修复、真实 Kotlin PSI 指标和 C1b r14 源码生成已完成。
  函数指标以 [真实语法树工具](../scripts/lib/kotlin-metrics/README.md)为准；套件已有分片与负载自适应，
  后续提速先用当前日志定位具体成本，不恢复旧“callInternal 180 行待拆”等任务。

## 5. 待验收队列（C）

| 项 | 固定候选或既有证据 | 当前结论 / 下一步 |
|---|---|---|
| **手机批次 4** | 67ef56cc8289b34d09843701d7b83986a206ad0e，来源 codex/batch4-precheck-unify | **暂停，仍 0/4，未判定、未合 main**；八条手机历史保留，不自行重跑或计入平板失败 |
| **T0-L 入场** | 4ca32b131007df58f7752c5ee9b2d049cb1cd54e，已合 main a7940d5 | 入场取证已完成；正确 fail-closed 不等于设备 ready，不放行 T-L1/P0 |
| **T-L1 / C1a** | 4b96f89a6622eb8b5fe04bd249571c7d77936b25 | origin/read-only 成立，diagnostic blocked、七项 blocker 保留；T-L1 未通过、app 未合 main，转 C1b |
| **T-L1 / C1b** | 旧设备失败、旧 `4b37f34` 唯一 BuildOnly 消费及 058/812/16d 完整门失败均保留；确认轮询竞态和保留模式开跑清扫已修复，旧 `2a4ccdb82783046c987689bb28d5d89000f4284d` Preflight 失败保存为 frozen_failed，继任 e898 完整门 46616 已自然 outer exit `0`、14 PASS / 0 FAIL / 0 SKIP，Run/独立 Read 均 `0`、最终独审闭合；e898 特性源码已发布并精确读回，A1 Run 30047 已自然 native `0`，A1 独审已闭合，无确定 P0/P1，五份生成源码独审通过后设为只读，Pair/R14 的实际主调用、Run/独立 Read 均 `0`，唯一 Preflight 主会话 1927 已自然 exit `0`，Run/独立 Read 均 `0`；A5 Prepare 会话 14744 主调用 native `0`，已生成 20 份 preview 与 manifest，三项机械 Reviews 主会话 57861 已自然 exit `0`，A5 source-only 9-key review 独审已完成，无确定 P0/P1；BuildOnly 准备主会话 13435 exit `1`，严格 HA consumer 拒绝 Preflight 的 `maximum_observer_tail_seconds=5.0`。UAC/Build/once 均 `0`，e898 不继续 formal20 发布/HA/Ready；继任整数序列化修复已提交为 0d6a，实际钉定 7.6.5 源码专项 16 PASS / 0 SKIP、outer `0`，最终源码独审无确定 P0/P1；新 r10 clean clone、两枚 baseline 与 129 项输入已准备，环境核对实际 `0`/match true，启动窄审已完成、无确定 P0/P1；新 FullCheck 主调用会话 17799 已自然 exit `0`，14 PASS / 0 FAIL / 0 SKIP；FullGraph 最终独审已闭合、无确定 P0/P1；0d6a 特性源码已一次 create-only 发布且精确读回、未合入 main，输出保全实际 `0`；A1 主会话 16432 已自然 `0`，PrepareSources Run/Read/主调用均 `0`、五份生成源独审已完成（范围仅五源，不覆盖 A5 P1）；A5 Prepare 与三项机械 Reviews 实际 `0`；独立语义确认接口 P1：生成 binding 缺顶层 `runner_sha256`，26+20 当前不准入 reviewed。0d6a 不再推进 Pair/R14/Preflight/BuildOnly/正式20发布/HostContract/Ready/设备，这些阶段均未执行、Build once `0`；继任修复已提交为 06b9439，r11 输入与启动窄审已核；FullCheck 67682/866929 实际 `0`、14 PASS / 0 FAIL / 0 SKIP，Read/独审与输出保全已完成；特性源码已一次 create-only 发布且 fresh Git/GitHub 精确读回、未合入 main；A1/五源/A5 source-only 独审已闭合，closed9 source-review 已产生；Pair/R14/唯一 Preflight Run/Read 均 `0`、候选已冻结；BuildOnly 准备实际 `0`；PublicationSupport r1 实际 `1` 保留，补普通空目录后的 r2 主会话 47770 自然 `0`，正式20文件与两阶段收据已产生，实际图独审进行中；Probe/Drive/UAC/Build/HostContract/Ready/设备未执行，0d6a 不恢复，详见当前继任段，设备未运行 | 16d 复验实际 9 PASS / 5 FAIL、exit `1`；旧 4a 实际完整门会话 39744 已自然 exit `0`、14 PASS / 0 FAIL / 0 SKIP，独立 Read 已通过。本轮 fixture 普通文件已封存；首次缺失原件不补造。A1 已实际 native `0`，PrepareSources Run/独立 Read 和 5 份生成源码 source-only 独审已通过；实际 Pair 因混合 slash 的 renderer 路径被 canonical guard 拒绝而自然失败，Pair 独立 Read 未跑、helper/launcher 未发布，BuildOnly 未消费，r14/Preflight 未运行。4a Pair 不重跑；路径修复及实际 cold CLI 回归已提交并独审通过，新 2a4 完整门会话 51145 已实际 native `0`、14 PASS / 0 FAIL / 0 SKIP，Run/独立 Read 均 `0`；特性源码已一次 create-only 发布并远端读回精确 SHA，main 未改、未合并；2a4 A1 与生成源码独审闭合，Pair 首次缺 StagingRoot 的失败保留、新 r2 Run/Read `0`，R14 Run/Read `0`。随后 Preflight 因 Git 布局假定错误而失败，2a4 frozen_failed 保存，不再 Git/check、覆写或重跑；BuildOnly 未启动/once 未消费，Ready/设备未执行。继任 e898 布局 guard 修复及新 r9 准备已完成，完整门 46616 已自然 outer exit `0`、14 PASS / 0 FAIL / 0 SKIP，Run/独立 Read 均 `0`、最终独审已闭合，无确定 P0/P1；e898 特性源码已一次发布并精确读回、未合入 main；quarantine 的首次长路径失败保留，新 r2 保全成功且不计 HA archive；A1 prepare `0`、Run 30047 已自然 native `0`，A1 独审核对 233 份 raw 双读零漂移、8 份 capture/16 条 streams，无确定 P0/P1。PrepareSources Run/独立 Read/主调用已实际 `0`，五份生成源码独审通过后设为只读；Pair 实际主调用、Run/独立 Read 均 `0`，final helper/launcher hash 与 expected 一致且只读；R14 实际主调用、Run/独立 Read 均 `0`。唯一 Preflight 主会话 1927 已自然 exit `0`，Run/独立 Read 均 `0`，`all_checks_passed=true`、failure `0`、四项只读 Git 均 `0`；该预检未启动 launcher/helper、Build 或 ADB。receipt 不单独授权后续执行，其 `RO=false` 原样保留；冻结前 HEAD clean、final 三份工件只读且 hash 匹配。A5 Prepare 会话 14744 主调用 native `0`，已生成 20 份 preview 与 manifest，三项机械 Reviews 主会话 57861 已自然 exit `0`，A5 source-only 9-key review 独审已完成，无确定 P0/P1。BuildOnly 准备主会话 13435 exit `1`，prepare child PID 12568 自然 exit `1`、双 EOF，cleanup failure/active 均 `0`，stdout 为 `0` bytes、stderr 为 230 bytes；outer operationRoot 未创建，UAC/Build/once 均 `0`。唯一确定原因是实际 Preflight 的 `verifier_static_evidence.maximum_observer_tail_seconds` 序列化为 token `5.0`，被正式严格整数 HA consumer 拒绝。Full/A1/Pair/R14/唯一 Preflight 的原 actual pass 保持；冻结 e898 不补写 receipt、不运行 Git/check/Gradle、不重跑 Preflight，不继续 formal20 发布/HA/Ready。继任整数序列化修复已提交为 0d6a，源码专项及最终独审已通过，新 r10 准备完成、启动窄审已完成、无确定 P0/P1；新 FullCheck 主调用会话 17799 已自然 exit `0`，14 PASS / 0 FAIL / 0 SKIP；FullGraph 最终独审已闭合、无确定 P0/P1；0d6a 特性源码已一次 create-only 发布且精确读回、未合入 main，输出保全实际 `0`；A1 主会话 16432 已自然 `0`，PrepareSources Run/Read/主调用均 `0`、五份生成源独审已完成（范围仅五源，不覆盖 A5 P1）；A5 Prepare 与三项机械 Reviews 实际 `0`；独立语义确认接口 P1：生成 binding 缺顶层 `runner_sha256`，26+20 当前不准入 reviewed。0d6a 不再推进 Pair/R14/Preflight/BuildOnly/正式20发布/HostContract/Ready/设备，这些阶段均未执行、Build once `0`；继任修复已提交为 06b9439，r11 输入与启动窄审已核；FullCheck 67682/866929 实际 `0`、14 PASS / 0 FAIL / 0 SKIP，Read/独审与输出保全已完成；特性源码已一次 create-only 发布且 fresh Git/GitHub 精确读回、未合入 main；A1/五源/A5 source-only 独审已闭合，closed9 source-review 已产生；Pair/R14/唯一 Preflight Run/Read 均 `0`、候选已冻结；BuildOnly 准备实际 `0`；PublicationSupport r1 实际 `1` 保留，补普通空目录后的 r2 主会话 47770 自然 `0`，正式20文件与两阶段收据已产生，实际图独审进行中；Probe/Drive/UAC/Build/HostContract/Ready/设备未执行，0d6a 不恢复，详见当前继任段；设备未运行。正式合同、设备入口、Ready/r2 均未建立；原零设备根因未知，显示回退和采集未验收，旧消费候选不重跑 |
| **T-L2 横屏 P0 四腿** | 未固定 | 未入队，依赖 T-L1 和 §4 前置，手机安全门不放宽 |

C1a 证据见 [只读取证成功记录](runs/2026-08-26-T-L1-C1a只读取证成功.md)；
C1b 前置与解释见 [受控 runner 规程](runbooks/T-L1-tablet-layout-c1b-v1.md)。
当前 install/设备/采集/navigation/conversation/target/regions/layout/微信/editor/action/P0/execution 未放行。
本文件的进度记录不构成运行许可；不得把只读 preflight、build-only 或 C1a 许可扩大为 C1b 采集。

## 6. 待决策项与有效决定（A 直接 ask）

**当前无待回答的设计问题。** 新问题只在确有用户不可替代决定时加入：
问题与影响、已核证据、推荐及备选、依赖项、真实答复/适用范围、对应 spec。
回答后从待答项移除，把有效结论写入 spec；已替代决定保留历史标记与替代指针，不重新送审。

| 有效决定 | 适用范围与来源 |
|---|---|
| 平板及默认姿态 | PA2553、Android 16、日常横屏原生多窗；手机 C 暂停；不关闭原生功能换绿。见 [平板设计](specs/2026-08-23-Android平板适配-design.md) |
| 通知证据与权限 | 展开态三项锚点：档位、目标会话、明文预览；不声明 FSI。**08-28 已撤销通知批准**，通知仅拒绝/查看证据，可见 ConfirmOverlay 才能批准。锁屏免解锁是历史选择，不授权恢复通知批准。见 [通知设计页首现行边界](specs/2026-08-01-通知栏审批布局-design.md) |
| 危险动作失败 | 安全失败终态、不开重试口子。旧“最多两次重弹”已作废，不能恢复；纵深 guard 不是重试资格。见同篇 §5.3 |
| 风险分级 | 两档均逐次确认，无免确认路径。风险姿态变化由 A 提供证据并取得用户新决定，不再转常驻 B。见 [风险分级](specs/2026-08-01-危险动作风险分级-design.md) |
| 语义意图时钟 | decisionTimeout 90s、intentTtl 360s、II foregroundWaitBudget 300s、I wait 0；证据 TTL 120s。批准时间不可刷新，失败不复活。见 [语义意图 spec](specs/2026-08-02-语义意图审批-design.md) |

### 6.N 非宏危险动作的目标证据

**已由用户 2026-09-02 拍板“按档位收窄”，不再提问。**
preparedTargetEvidence 用于“送进会话”：press_key(enter)、type_text 与命中 send_words 的 II 级 ui_action；
II 级 ui_action 仍须补与 P0 宏同源同规则的非宏证据产出点。
I 级 ui_action 不进延后执行，保留 ref/text/description/bounds/source 逐字段相等与每次确认。
范围见 [spec §2.5](specs/2026-08-02-语义意图审批-design.md)。基础模块已实现不等于生产接线完成。

## 7. 流转、验证与收尾

### 7.1 派工与回报

A 完成最小摸底后按独立工作流委派，数量依任务、容量和文件冲突风险确定；主代理继续其他独立工作。
使用当前运行时提供的子代理消息/等待机制，DONE、BLOCKED、NEEDS-USER 三种结果都向 A 回报；
不假定某个工具名存在，不向仓库里写死的历史 ID 发送消息。
回报至少包含：结论、完整代码 SHA/未提交改动范围、验证命令/配置/环境与日志、下一步、是否需要用户。
C 另报 run/task、逐腿结论、manifest、台账、cleanup 和持久证据位置。会话或工具异常以实际状态核实，
不能靠旧日志或一次未返回就认定死亡；工具不可用时在当前任务报告缺口。

### 7.2 验证、合并与证据

- A 按影响范围运行必要检查，完整发布/验收候选执行项目必需门。主协调者独立审查变更与可追溯验证证据，
  核对同一 SHA、输入、配置和环境；不是收到报告就再跑一次全部检查。
  没有可验证证据、出现新改动/失败/覆盖缺口时补验，不以自报数字代替验证；用例与套件数取实际汇总，不写死“五项”。
- **冻结规程优先。** 全量门在冻结前完成；C1b preflight 冻结后不再跑 Gradle/check 或任何违反冻结规程的命令。
  需要修复就形成新候选并重新满足该轮条件，不能复用旧轮 one-shot。
  检查入口与验证尺度见 [离线开发与验证](runbooks/离线开发与验证.md)。
- 改变真机行为的提交：A 提交并报告完整 SHA → C 验固定构建 → 通过后 A 合并**验过的 SHA**，
  不合带有后续未验改动的分支 tip。失败则保留改动和运行证据，A 修复成新候选。
- 纯文档或不改变真机运行内容的独立改动，完成相应验证即可按授权整合；
  若所在分支祖先夹带未验代码，只合已复核的独立文档提交，不能借文档同步合入整条分支。
- C 不在旧候选上改写 STATUS/knowledge/backlog，只回报结果增量，由 A 在当前权威基线上整合。
  台账无论通过失败都须归集并去重到 main；失败记录也要保留，不能等代码通过才收台账。
  临时 worktree 回收前将必要脱敏证据保存到持久、非临时位置，核对 manifest 与 hashes；
  evidence/trace/本机状态按忽略规则保存，不把临时路径或任务消息当持久证据。

### 7.3 触发表与开跑条件

| 触发 | 动作 |
|---|---|
| A 遇到关键用户决定 | 在当前任务 ask，记录待答项并继续独立工作；真实答复落 spec 后接续实现 |
| A 完成待验批次 | 报告完整 SHA、验证证据和判据，更新 §5；C 在对应规程允许的范围内准备就位 |
| C 就位 | 回报固定 SHA、唯一设备、当前设备/姿态/窗口与 IME 证据、构建身份及前置检查；未知字段不能猜成通过 |
| C 失败 | 冻结本轮、保留现象/台账/证据；回交 A，不在 C 修代码或盲重跑 |
| C 通过 | 报告可追溯结果和持久证据，A 核验并按 §7.2 整合 |
| C 无可执行任务 | 回报待命或结束，不转做开发 |

开跑令不得先于就位报告，报告所用设备与构建必须符合本次候选和授权范围；
不能把“你自己把住”当提前放行。手机危险动作的确认卡始终由现场用户操作，
开发 ask、用户的产品决定或 PC 侧恢复许可都不替代该动作的确认。

## 8. 会话标题读取的既定方向

保留“标题识别下沉至生产、宏复用同一份”的方向，不另造一套弱读取器、不放弃会话标题校验。
基础模块与实际 Android 生产接线的完成度以 [语义意图 spec §5](specs/2026-08-02-语义意图审批-design.md)为准。
若必须退为 debug-only，须有明确决定和 release 恒 Unverified 的用例；
debug APK 真机通过不能证明 release 功能成立。推导过程见 [历史归档 §8](backlog-archive.md)。

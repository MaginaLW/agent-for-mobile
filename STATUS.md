# 项目状态

> 2026-09-30：已按用户“设立goal，授权充分的权限和批准，完成这些待办任务，多调用sub-agent”建立持续 goal，推进待办实现、新候选准备、受控主机执行、证据与必要源码发布。每次真实启动仍绑定完整候选 SHA、运行时和 launcher raw hash，一次启动、自动重试 `0`；发送、支付、删除等临界操作保留手机可见两段式确认。见[本轮 goal 与证据记录](docs/runs/2026-09-30-C1b-goal与正式证据闭合.md)。
>
> 协调源码 `e0fcbb2` 已闭合 P3 候选维护源回退、主机双流与显式子进程环境、R3 真实终态身份派生及一次封存的离线实现；源码专项 `16 passed, 0 skipped`，capture `13/13`、104 项断言，阶段 Run/Read `10/10`、81 项断言，R3 `14/14`、70 项断言及补充反例通过。新增 A1、提升启动、独立 BuildOnly reader、raw 封存和设备入口维护源已有实现与离线证据；正式主机合同仍待完成；本轮源码整合完整门及独立 Read 的实际结论见下文，专项不替代设备验收。
>
> 原候选 058 完整门 11 PASS / 3 FAIL、812 完整门 13 PASS / 1 FAIL 均保留。派单 native 延迟初始化及确认轮询竞态已分别修复，专项验证通过；`16d66c9f64ae593d6c87c46a800c6bfd66f62bf8` 首次完整门实际 exit `1`，8 PASS / 6 FAIL。Android 1170 项 JVM、全部 lint/build 组通过；派单 52/55、监督 runner 83/87，capture 反例缺双 EOF，intake 超时、C1a 失败，C1b verifier 明确报 Win32“系统资源不足”。首次日志与现场读取元信息保留；私有排空诊断 9/9、exit `0` 不替代完整门，各失败根因尚未全部核定。以下复验结果和新候选为当前续办来源，均未建立新冻结主机链、BuildOnly 或 Ready。
>
> 同 16d 完整复验会话 20007 已自然退出 `1`，9 PASS / 5 FAIL；capture 13/13、C1a 15/15、Android 构建通过，raw archive、intake、C1b host、派单及 runner 未全过。派单 54/55、runner 85/87；双流 EOF、Job active `0`、cleanup failure `0`，未执行独立 Read。5 组失败已由 sub-agent 只读审查，未证明新的生产漏杀或隔离失效，具体子进程终态和原因仍有 unknown。启动前资源 829 MB、后续低至 165 MB，不据资源读数推定因果，其他计算保留。
>
> 复验开跑日志确认自动清扫了 91 个旧目录，首次 4 个失败 fixture 路径已不存在；此前只保留日志与现场读取元信息，未复制 fixture 原字节，缺失原件不补造。本轮实际 KEEP 的 95 根已保存 3579 份普通文件只读副本并逐项读回，1 个 reparse 节点仅保存元信息、不跟随目标。保留模式跳过开跑清扫的修复提交协调 `c78862b`、实现 `4a65150db9826d668341ad6d9b11cb9883f5c524`，实际 AST mock 作者 4/4、独审 16/16，87 个用例与时限不变。新普通 clone clean、无 alternates、两枚受信 baseline object 可读；源码角色与发布定义已按新 SHA 完成 source-only 独审，无确定 P0/P1。准备结果不代表候选通过，实际完整门进度见下。
>
> Goal 已恢复 active。新四点资源窗口可用 10.7–11.1 GiB、commit 为上限的 47.95%–48.46%；两个旧 PID 未观察到，原因未知，未调整用户计算。此前 4a 的 clean、受信对象、输入 pins 与核定 7.6.5 环境摘要重新核对通过；实际会话 39744 的完整 `-Shards 1` 检查已自然 exit `0`，14 PASS / 0 FAIL / 0 SKIP，runner 87 PASS / 0 FAIL，Android 219 个任务全部 executed，Gradle 与 fixture 保留。root producer PID 25900、独立 reader PID 28212 均 native `0`，双流 EOF、cleanup failure `0`、Job active `0`、自动重试 `0`；Read 核对 13 个输入 pin，实际 FullCheck 阶段 native `0`。129 项准备及旧失败均保留，见[本轮记录](docs/runs/2026-09-30-C1b-goal与正式证据闭合.md)。
>
> 4a 的 A1 已实际 native `0`：460 个 tracked、42 个 implementation 输入及 4 次真实 Git 查询核对完成，四层实际捕获均 native `0`、双流 EOF、cleanup failure `0`、Job active `0`。本次 3 个 synthetic 标记日志及 1359 份 probe build 文件已移至 FullCheck 的 owned-output-quarantine 保全并逐项 hash 读回，无删除、原 build 路径不存在且 marker 为 `0`。PrepareSources 已实际 Run 和独立 Read native `0`，生成 5 份绑定 exact 4a 的 expected/renderer 源码，source-only 独审通过。实际 Pair 因 canonical guard 拒绝混合 slash 的 renderer 路径而自然失败，stage child PID 29320 与 producer PID 33756 均 native `1`、双流 EOF、cleanup failure `0`、Job active `0`、自动重试 `0`；Pair 独立 Read 未运行，helper/launcher 未发布，BuildOnly 未消费，r14/Preflight/Ready/设备均未运行。4a Pair 原件保留、不重跑；renderer 路径修复及实际 cold CLI 回归现已完成，形成新 2a4，当前完整门进度见下文；4a 成功与失败记录不替代新候选验收。既有 source-only 审查只保留原范围，不改判。
>
> 当前实现为 `2a4ccdb82783046c987689bb28d5d89000f4284d`，根源码整合 `57845053840609a1a5fc4609fd2025271d0728cf`。四文件路径修复已提交，作者在钉定 7.6.5 的实际源码专项为 16 passed / 0 skipped、native `0`、stderr `0`；cold CLI 合成夹具首次 native `0`，拒绝替换已有输出的反例 native `1`，原 bytes/只读属性不变，独审无确定 P0/P1。新 r8 普通 clone 实际 HEAD/clean、普通 `.git`、无 alternates 及两枚受信 baseline 已核；129 项新输入准备进程和 fresh environment probe 均实际 `0`，版本/路径/runtime pin/新环境摘要匹配，启动窄审 129 项双次原字节读回零漂移。实际完整门会话 51145 已结束、native `0`，14 PASS / 0 FAIL / 0 SKIP，runner 87/87、dispatch 55/55、C1b 32/32、Android 219 个任务；Run 与独立 Read 均实际 `0`。保留 `-Shards 1`、Gradle、单 worker、`P0_KEEP_FIXTURE=1`、自动重试 `0`。[2a4 功能源码](https://github.com/MaginaLW/agent-for-mobile/tree/2a4ccdb82783046c987689bb28d5d89000f4284d) 已一次 create-only 发布至特性分支并远端读回精确 SHA，main 保持 `030db3238cd08eadd3f9e652c5dd57ab4e233088`、未合入 main。2a4 的 A1 实际会话 26871 native `0`，独审核对 240 份 raw 和 8 份实际 capture，无确定 P0/P1；PrepareSources 的实际 Run/独立 Read 及主调用均 native `0`，5 份生成源码 source-only 独审已闭合，Parser `0`、18 项新路径正例及混合 slash 反例通过。1359 份文件、695 个目录和 3 份日志已移出保全，hash 全部一致、A1 marker `0`、删除 `0`，不计作正式 HA archive。Pair 首次主调用因 StagingRoot 尚不存在而 native `1`；补普通空目录后的新 Pair-attempt-r2 实际 Run/独立 Read/主调用均 `0`，首次失败保留，工件生成与 BuildOnly once 分开。R14 实际 Run/独立 Read/主调用均 `0`。随后 Preflight 主调用 native `1`：PrepareSources 传入 cmd/git.exe，transformer 的三次 GetDir 假定 mingw64/bin/git.exe，扫描 ProgramFiles 时遇到 reparse；5 项 failure、cleanup `0`、quiescence `true`，实际 child PID 50008 自然 exit `1`、双流 EOF。失败收据已发布且 pass 为 false，2a4 保存为 frozen_failed，不再 Git/check、覆写或重跑；BuildOnly 未启动、无 once 消费，Ready/设备未执行。生成前 canonical mingw64/bin 布局 guard、既有 16-case 回归及 runbook 修复正在可变源码推进，后继 SHA 和完整门仍待实际结果，见[本轮记录](docs/runs/2026-09-30-C1b-goal与正式证据闭合.md)。
>
> 最小启动诊断实际孩子在 1000 ms 窗内自然 native `0`、elapsed 840 ms、双 EOF/Job 清理完成；诊断 CLI 错把 JSON `Int64` PID 拒为非 `[int]`，driver/group 实际 exit `1`，预热没有启动。原件保留、不重跑；新 reader 仅离线修正，不能解释原 intake 失败或替代完整门。private ADB server 单 case 定义已完成 source-only 独审、无确定 P0/P1，实际诊断未运行，旧 final_substage 仍 unknown。
>
> R6 的三份文档增量已由 [PR #2](https://github.com/MaginaLW/agent-for-mobile/pull/2) 合入 main `20398130c27bb7038f0d7ffc37851d7e2b82a6cf`。后续复验失败、fixture 保全、新 4a 输入准备及诊断记录已作为独立单文件增量，由 [PR #3](https://github.com/MaginaLW/agent-for-mobile/pull/3) 合入 main `030db3238cd08eadd3f9e652c5dd57ab4e233088`；Git 与 GitHub 的 PR、父提交、完整 tree 和 blob 读回一致，精确只有一份文档变化。仓库无配置 CI，未声明 CI 通过。通过完整门的 [4a 功能源码](https://github.com/MaginaLW/agent-for-mobile/tree/4a65150db9826d668341ad6d9b11cb9883f5c524) 已在实际会话 82517 自然 exit `0` 后完成一次 create-only 特性分支发布，远端 Git 读回精确对应该 SHA；main 更新、强推、自动重试均为 `0`，尚未合入 main。完整 R6 文档依赖包及新主机链仍待闭合。
>
> 旧冻结候选 `4b37f344d5af988ce9b2f7610df98387a49cd2d0` 的唯一 UAC BuildOnly 已实际退出 `0`，提升令牌成立，launcher/helper 各一次、重试 `0`。独立读回 `accepted_no_device`，57 项输入 pins 再读一致，69 份原始材料封存；ADB/安装/T0/采集均为 `0`，授权已消费，同 SHA 不重跑。PC Suite `closeMode` 已精确恢复，应用 UI 未动态验证；见[旧候选主机结果](docs/runs/2026-09-30-C1b-4b37f34-BuildOnly与续办.md)。
>
> 用户已陈述平板“已连接并保持该现场”（USB、横屏微信“应用多窗”、键盘隐藏）；这是现场陈述，唯一设备发现、Ready 与显示回退仍待实际证据。R1/R4/R5 保留已完成的离线证据，真人确认边界和 intent_send 落地仍待真机；R6 的文档闭合与受测功能发布分别按实际版本和远端读回完成。

> 2026-09-28：09-27 审查项的离线进展见 [backlog §4](docs/backlog.md#09-27-审查待办)。R1、R2、R4、规则精简与 M1b 能力标注已有独立提交；R3 设备发现证据消费链在实现分支 `7c5511621f9972f2bf2877591e6d19e3b69e7593` 提交，9/9 离线用例通过。R5 的 `intent_send` 离线修复 `7814fac` 已通过 Debug/Release 各 7 个 JVM 用例，仍未经真机验收；P3 候选维护源迁移 `68776e4` 已通过 10/10 离线用例和一次 prepare smoke，尚未经固定候选发布验证。
>
> 同一 SHA 的新 C1b 独占普通 clone 已完成 A1：clean、42 项原始输入逐项匹配 HEAD Git blob，独立对象库无 alternates。第一次 A2 全量门因单分支克隆缺少两枚受信 baseline commit object 在 fake-ADB E2E 项失败；补取精确对象且 HEAD 不变后，第二次完整门实际退出 0、13/13 项通过，R3 消费链另有 9/9、26 项断言通过。A3 exact pair/r14 和一次只读 preflight 已通过；获单次授权的 BuildOnly 因调用方漏传 mandatory launcher 参数在脚本主体前 exit 1，未进入 helper/构建/ADB，已封存且不补参重跑。见[本轮失败记录](docs/runs/2026-09-28-C1b-7c55116-BuildOnly参数绑定失败.md)。没有成功 BuildOnly、Ready 或新设备 r2，原零设备根因与显示回退真机结果仍未知。

> 2026-09-29：独占候选 `14edb4a477ddd71c82f029008c0772e485d682bf` 的唯一 BuildOnly 在 `elevation_check` 因未提升令牌 exit `1`，helper/构建/ADB 均未进入，已封存不重跑。见[失败记录](docs/runs/2026-09-29-C1b-14edb4a-BuildOnly权限失败.md)。获用户同意后的独立 UAC 探针取得管理员令牌；新独占候选 `4b37f344d5af988ce9b2f7610df98387a49cd2d0` 完成 A1 42/42、A2 全量门 exit `0`/13/13、R3 专项 9/9、exact pair/r14 及唯一只读 preflight exit `0`，`prepared_not_authorized=true`。提升启动脚本已静态核验、尚未运行；新 SHA 的单次 BuildOnly 授权仍待取得。见[本轮主机准备](docs/runs/2026-09-29-C1b-4b37f34-A1-A3主机准备.md)。PC Suite 原关闭设置待主机阶段结束后恢复；没有新 BuildOnly、Ready 或设备 r2。

> 2026-09-27：项目审查待办已纳入 [backlog §4](docs/backlog.md#09-27-审查待办)，优先级、依赖与完成标准在该处维护；[审查记录](docs/runs/2026-09-27-项目审查与待办.md)保留证据。本次仅登记待办，修复、新候选与设备流程均未启动，以下验收状态不变。

> 2026-09-13 收尾：本目录 `codex/agent-workflow` 维护当前协调状态；下列 09-08 记录仅为历史快照。

**本阶段已收尾：** 设备发现证据的离线修复已提交 `1be3e4badde8c5d1c8b9ec3bc9beb56a92c5ee2f`，位于普通开发分支 `codex/c1b-display-context-fallback`。安装前和采集后分别留证，首次失败也能保存记录。C1b 主机聚合门实际退出 0、32/32 coverage，C1a 回归 15/15、50/50 coverage；收尾复核 16 份验证材料、14 份输入与提交绑定一致，实现工作树 clean。获授权的 485 份临时副本已清理，536 份归档完整保留。详见[收尾与待完成项](docs/runs/2026-09-13-C1b-收尾与待完成项.md)及[离线修复证据](docs/runs/2026-09-13-C1b-设备发现证据离线修复.md)。

**下次从新候选准备开始：** 以完整 SHA 建立独占普通 clone，在冻结前完成项目全量门，随后完成 exact pair/r14/preflight、BuildOnly 及设备入口准备；新 collector/reader/freezer 必须纳入两个 checkpoint JSON 和尚无 run ID 的失败。本次仅整理状态，没有启动这些阶段；当前没有新 Ready 或设备 r2，显示回退尚未获真机验收、实现未合入 main。当前无待回答的设计问题。

旧 `a878d12/r1` 因“当前识别到 0 台”失败并封存，wrapper/runner 均退出 1；reader 242 项和终审 1,795 项仅核定失败记录。后续独立三次查询均为 1 台 `device`，未复现原失败。原具体调用点、安装/T0/c1/c2 次数、宿主整体清理及根因仍未知，显示回退未获真机验收。见[设备发现诊断](docs/runs/2026-09-13-C1b-a878d12-设备发现诊断.md)和[设备执行](docs/runs/2026-09-13-C1b-a878d12-设备执行.md)。

**旧候选 a878d12 的主机阶段：** 固定候选的 A1—A5 已通过，Ready 原始记录为 `host_ready_waiting_for_device_assistance`。八个 A5 主机阶段实际退出均为 0；支撑审计 15,833 项、313 份原始文件通过，绑定发布及 59 项主机预检通过，最终独审 7,708 项、82 份原始文件通过。Ready 和读回记录已只读保存。同 SHA 的 A1—A4 证据包括完整门 13/13、JVM 1156 项，以及唯一 BuildOnly、789 项读回和封存通过；A5 没有在冻结候选运行普通 Git、Gradle/check 或重跑 BuildOnly，ADB/设备操作 0。见 [A5 主机准备](docs/runs/2026-09-13-C1b-a878d12-A5主机准备.md)、[BuildOnly](docs/runs/2026-09-13-C1b-a878d12-BuildOnly.md)与[候选准备](docs/runs/2026-09-13-C1b-a878d12-候选准备.md)。旧 `c43652a/r1` 的 wrapper/runner 退出 1，错误 `capture_c1_display_unsupported`，失败已封存；见[设备执行及离线修复](docs/runs/2026-09-13-C1b-c43652a-设备执行.md)。

- 旧 `c43652a/r1` 已越过安装与 fresh T0 前置，c1 accepted 1、c2 accepted 0、committed tokens 空；provider abort cleanup 完成，宿主整体清理独立验收仍 unknown。旧 `501761f/r1` 安装失败及其根因未知结论不变。
- 旧设备轮只执行一次、未重试；a878d12 的显示修复只处理 context display getter 的 UnsupportedOperationException 回退，Security/其他异常及原有门继续生效。尚未证明旧轮具体异常调用点或真机修复成功。A5 后新“确认”授权的 a878d12/r1 已执行并消费；当前“0 台设备”诊断不足以证明显示回退实现失败，后续需新的单次复验条件。原冻结轮不重跑，原项目继续负责协调文档。
- 手机批次 4 仍暂停、0/4；语义意图生产接线、布局/P0/T-L2 及其他待真机项保持原边界。本轮没有实现合入 main。

## 09-08 历史快照

以下候选与待办描述仅代表当时状态，不作为当前执行队列；当前来源与下一步见上方和 [backlog](docs/backlog.md)。历史细节见 [归档](docs/status-archive.md)。

- **协作改为 A 协调、开发与直接 ask，C 按需验固定候选**；取消常驻 B，独立研究/实现/审查交给子代理。当前队列与有效决定见 [backlog](docs/backlog.md)，旧过程见[历史归档](docs/backlog-archive.md)。派工携带实际协调来源，不固定读 main 或历史任务 ID；冻结候选不因通用复核重复构建。当前分支与 HEAD 以 Git 实测为准。
- **本次执行器修订与验证（09-08）**：两份站规改用任务设备证据，移除固定手机型号/分辨率假设；gateway 配置模板补齐超时。派单离线 50/50、监督式 runner 86/86、台账 7/7 及凭据扫描通过。原 `check.ps1 -SkipGradle` 记录为 **11 PASS / 1 FAIL / 1 SKIP**，唯一失败是 C1b 宿主全局 mutex 占用；原日志 `.checks/agent-workflow-check.log` 与限定诊断原样保留。
- **C1b 锁冲突已补验闭环（09-08）**：锁释放后，在 clean `da9ab5321ef0ca16e4972089e22cb8d0747d759a` 单独复跑 C1b host 离线聚合门，exit 0；包括 build-environment 27/27、verifier 19/19 零跳过、fake-ADB 29/29，真实 ADB 0。日志 `.checks/agent-workflow-c1b-host-recheck.log`、同名 `.summary.json` 与 `.receipt.json` 绑定本次输入和结果。未改互斥机制或门限，未干预其他任务；未重跑整套检查，Android JVM/Lint/构建仍未覆盖，不改称原整合门全绿或真机验收通过。
- **功能开发基线 `463304c`，未合入 main。** 无真机工作分阶段完成：离线门/暂停件修复 `7c0a5ba`、Kotlin AST 指标 `512fe92`、语义基础模块 `48f8dd8`、C1b r14 源码生成 `b0aaa28`，随后 `463304c` 补齐 launcher 进度抑制、有界 stderr 诊断及真实数组清零。仍待新固定候选完整验收；本次协作与提示词修订不把历史候选自动升为已验。入口见[离线开发与验证](docs/runbooks/离线开发与验证.md)。
- **`6fbb157` 全量门 13/13 PASS**：gateway Debug 555/555、Release 401/401、runner 86/86、host fake-ADB 29/29 全过，真实 ADB 调用 0。日志 `.checks/tablet-ready-full-20260907.log`；它是该固定候选的结果，不自动覆盖后续代码改动。
- **Windows 符号链接缺口已补齐**：开启开发者模式后，真实 verifier 为 19 passed / 0 failed / 0 skipped。运行仓库门仍使用 `<repos-root>/_toolchain/powershell-7.6.5/pwsh.exe`；默认 7.4.19 不满足版本要求。
- **`6fbb157` exact pair、r14 发布及唯一只读 preflight 已通过**：外层 exit 0、terminal closed、primary/cleanup/recording 全 0；Git 前后全树与字节 canary 成立。**随后唯一 build-only 已失败冻结**：helper exit 0，但 stderr 2,439,272 bytes 且捕获溢出，launcher/caller exit 1。构建、签名、aapt2 已执行，设备/ADB 0、环境清理完成；不能以 helper 摘要替代整轮通过。见[本轮记录](docs/runs/2026-09-07-C1b-6fbb157-构建输出流失败.md)。
- **语义意图已有离线实现，不能再称“全仓零实现”**：一次性 store、90s/360s/II 300s/I 0 三时钟、真实 reader 装配断言、a11y/OCR 重建三态与不可拆改内容基线，新增 57 用例。**SafetyGate 生产接线、Android 证据安装及执行链仍未实现**；按 C 队列未清规则保留未接线，详见 [spec §5](docs/specs/2026-08-02-语义意图审批-design.md)。
- **手机 C 道暂停**，历史批次 1/2/3 已验收；手机语义意图批次 4 仍 0/4，原离线候选 `67ef56cc8289b34d09843701d7b83986a206ad0e` 在 `codex/batch4-precheck-unify`，未合 main。本轮不改变其验收结论。
- **当前真机基线仍为 PA2553 / Android 16 / 日常横屏应用多窗**；项目适配设备原生能力，不关闭功能换绿。C1a 只成立 trusted origin/read-only，diagnostic/layout/P0/execution 未通过；C1b 七次旧 one-shot（末次 `a661f36`）及随后 `6fbb157` build-only 均失败冻结，不得同轮重跑。
- **Git 信任根已在本轮实测**：9576 文件、catalog `4c5e585b…7458`、9489 identities、85 内部 hardlink groups，r14 前后内容与 identity catalog 一致；JDK、Gradle 和三个 Android package 树也通过只读复核。无需沿旧 A→E 重装阶梯继续。
- **待真机项**：分享落地 activity 全类名/冷启动反例（白名单保持空，不猜填）、审计 `filesDir` 的 `run-as` 只读复验、S5 RemoteInput、S2 Shizuku 重启存活；install/采集/navigation/conversation/target/regions/layout/editor/action/P0/T-L2 均未放行。
- **函数长度已改用真实 Kotlin PSI**：`scripts/measure-kotlin.ps1 -Offline` 生成 `.checks/kotlin-metrics/` 报告；`callInternal` 的旧“180 行待拆”已过时，排名和指标按实际输入重跑，不再用 grep/括号计数推断。

# 项目状态

> 2026-09-08 更新；只保留影响下一步的结论，历史细节见 [归档](docs/status-archive.md)。

- **协作改为 A 协调、开发与直接 ask，C 按需验固定候选**；取消常驻 B，独立研究/实现/审查交给子代理。当前队列与有效决定见 [backlog](docs/backlog.md)，旧过程见[历史归档](docs/backlog-archive.md)。派工携带实际协调来源，不固定读 main 或历史任务 ID；冻结候选不因通用复核重复构建。当前分支与 HEAD 以 Git 实测为准。
- **本次执行器修订与验证（09-08）**：两份站规改用任务设备证据，移除固定手机型号/分辨率假设；gateway 配置模板补齐超时。派单离线 50/50、监督式 runner 86/86、台账 7/7 及凭据扫描通过。原 `check.ps1 -SkipGradle` 记录为 **11 PASS / 1 FAIL / 1 SKIP**，唯一失败是 C1b 宿主全局 mutex 占用；原日志 `.checks/agent-workflow-check.log` 与限定诊断原样保留。
- **C1b 锁冲突已补验闭环（09-08）**：锁释放后，在 clean `da9ab5321ef0ca16e4972089e22cb8d0747d759a` 单独复跑 C1b host 离线聚合门，exit 0；包括 build-environment 27/27、verifier 19/19 零跳过、fake-ADB 29/29，真实 ADB 0。日志 `.checks/agent-workflow-c1b-host-recheck.log`、同名 `.summary.json` 与 `.receipt.json` 绑定本次输入和结果。未改互斥机制或门限，未干预其他任务；未重跑整套检查，Android JVM/Lint/构建仍未覆盖，不改称原整合门全绿或真机验收通过。
- **C1b 接入后的受控尝试已失败冻结，尚未安装或访问平板。** `463304c` 的主机前置确已通过；随后 r1 被外层环境注入挡住，r2 被共享目录 HEAD 漂移挡住，独立目录 r3 的实际 Gradle 构建 exit 1。具体 Gradle 错误丢失，不把失败归因于平板或追认为唯一根因。见[本轮记录](docs/runs/2026-09-08-C1b-463304c-接入后主机构建失败.md)。
- **Kotlin 状态隔离与失败诊断修复已完成专项验证**：项目持久状态重定向至已有 fresh runtime，关闭 `.gradle` 兼容写；生产与新 helper 各保留有界脱敏 stdout/stderr。readonly 80/80、candidate-source 10/10、build-env 28/28、Host E2E（runner 9 / fake Gradle 8 / real ADB 0 / input 42）通过，独审无 P0/P1。`codex/c1b-device-build-diagnostics` 尚未合 main；后续固定候选实际结果及当前阻塞见下方 `4cafd99` 记录，旧一次性工件不重跑。
- **新 clone 的 `0386ee7` 完整门未通过**：10 PASS / 3 FAIL / 0 SKIP；三处测试数量消费者已同步，fake CMD 换行修复后纯 LF 源码 runner 86/86 通过。候选生成器已改绑最终目录的七项 loader 与 verifier 原始字节，source 14/14、真实冻结模板纯内存适配 5/5 通过。原失败日志保留，后续新候选的实际验收另记，见[整合门记录](docs/runs/2026-09-08-C1b-0386ee7-候选整合门失败.md)。
- **`4cafd99` 主机前置已全部通过**：全量 13/13、源码独审 476 项、PairRender/r14/preflight exit 0。首次 UAC 取消记录保留；用户确认后的唯一 BuildOnly 实际 caller/launcher/helper exit 0，独立复核 789 项断言通过，错误流为空、资源清理完成。三处旧缓存仍隔离，项目 Kotlin/Gradle 首次创建路径未被预置目录掩盖；本轮 real ADB 0。用户已确认平板现场，下一步为固定候选设备流程。见[本轮主机记录](docs/runs/2026-09-08-C1b-4cafd99-主机验收.md)。
- **本轮已按用户要求收尾，平板尚未安装或访问。** `4cafd99` 设备入口 r1 的外部观察器在 wrapper 启动前因原生 `DirectoryInfo` 缺少 `PSIsContainer` 扩展属性而 exit 1。原工具/绑定/日志冻结，四份 r2 修复与验证草稿已保存；Parser/派生核对通过，真实路径守卫合同尚未执行，r2 未启动。恢复时先补实际合同测试及审查，再进入设备流程。见[设备入口与收尾记录](docs/runs/2026-09-08-C1b-4cafd99-设备入口.md)。
- **`463304c` 主机验收已闭合**：全量 13/13、gateway Debug 555/555、Release 401/401、exact pair/r14、唯一只读 preflight 与唯一真实 build-only 均通过；build-only 外层/launcher/helper exit 0、stderr 0、清理完成。该结果只归属于固定 `463304cb56809d96fd97af6c71650dfcad4fe3a0`，不能替代后来失败的生产 runner。见[主机验收记录](docs/runs/2026-09-07-C1b-463304c-平板接入前主机验收.md)。
- **`6fbb157` 全量门 13/13 PASS**：gateway Debug 555/555、Release 401/401、runner 86/86、host fake-ADB 29/29 全过，真实 ADB 调用 0。日志 `.checks/tablet-ready-full-20260907.log`；它是该固定候选的结果，不自动覆盖后续代码改动。
- **Windows 符号链接缺口已补齐**：开启开发者模式后，真实 verifier 为 19 passed / 0 failed / 0 skipped。运行仓库门仍使用 `<repos-root>/_toolchain/powershell-7.6.5/pwsh.exe`；默认 7.4.19 不满足版本要求。
- **`6fbb157` exact pair、r14 发布及唯一只读 preflight 已通过**：外层 exit 0、terminal closed、primary/cleanup/recording 全 0；Git 前后全树与字节 canary 成立。**随后唯一 build-only 已失败冻结**：helper exit 0，但 stderr 2,439,272 bytes 且捕获溢出，launcher/caller exit 1。构建、签名、aapt2 已执行，设备/ADB 0、环境清理完成；不能以 helper 摘要替代整轮通过。见[本轮记录](docs/runs/2026-09-07-C1b-6fbb157-构建输出流失败.md)。
- **语义意图已有离线实现，不能再称“全仓零实现”**：一次性 store、90s/360s/II 300s/I 0 三时钟、真实 reader 装配断言、a11y/OCR 重建三态与不可拆改内容基线，新增 57 用例。**SafetyGate 生产接线、Android 证据安装及执行链仍未实现**；按 C 队列未清规则保留未接线，详见 [spec §5](docs/specs/2026-08-02-语义意图审批-design.md)。
- **手机 C 道暂停**，历史批次 1/2/3 已验收；手机语义意图批次 4 仍 0/4，原离线候选 `67ef56cc8289b34d09843701d7b83986a206ad0e` 在 `codex/batch4-precheck-unify`，未合 main。本轮不改变其验收结论。
- **当前真机基线仍为 PA2553 / Android 16 / 日常横屏应用多窗**；项目适配设备原生能力，不关闭功能换绿。C1a 只成立 trusted origin/read-only，diagnostic/layout/P0/execution 未通过；C1b 七次旧 one-shot（末次 `a661f36`）及随后 `6fbb157` build-only 均失败冻结，不得同轮重跑。
- **Git 信任根已在本轮实测**：9576 文件、catalog `4c5e585b…7458`、9489 identities、85 内部 hardlink groups，r14 前后内容与 identity catalog 一致；JDK、Gradle 和三个 Android package 树也通过只读复核。无需沿旧 A→E 重装阶梯继续。
- **待真机项**：分享落地 activity 全类名/冷启动反例（白名单保持空，不猜填）、审计 `filesDir` 的 `run-as` 只读复验、S5 RemoteInput、S2 Shizuku 重启存活；install/采集/navigation/conversation/target/regions/layout/editor/action/P0/T-L2 均未放行。
- **函数长度已改用真实 Kotlin PSI**：`scripts/measure-kotlin.ps1 -Offline` 生成 `.checks/kotlin-metrics/` 报告；`callInternal` 的旧“180 行待拆”已过时，排名和指标按实际输入重跑，不再用 grep/括号计数推断。

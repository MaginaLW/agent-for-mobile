# 项目状态

> 2026-09-08 更新；只保留影响下一步的结论，历史细节见 [归档](docs/status-archive.md)。

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

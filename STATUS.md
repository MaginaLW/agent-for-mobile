# 项目状态

> 2026-09-07 更新；只保留影响下一步的结论，历史细节见 [归档](docs/status-archive.md)。

- **当前分支 `codex/security-hardening`，未合入 main；平板接入前的主机验收已完成。** 已验代码候选固定为 `463304cb56809d96fd97af6c71650dfcad4fe3a0`，本次收尾只提交 Markdown 记录，不把后续文档 SHA 冒称为构建验收 SHA。无真机工作分阶段完成：离线门/暂停件 `7c0a5ba`、Kotlin AST 指标 `512fe92`、语义基础模块 `48f8dd8`、C1b r14 源码 `b0aaa28`、输出流修复 `463304c`。入口见[离线开发与验证](docs/runbooks/离线开发与验证.md)。
- **`463304c` 全量门 13/13 PASS**：gateway Debug 555/555、Release 401/401、runner 86/86、host fake-ADB 29/29 全过；源码回归 9 cases，r14 1300 assertions / 28 mutations。日志 `.checks/tablet-ready-full-463304c.log`，只归属于该固定候选。
- **Windows 符号链接缺口已补齐**：开启开发者模式后，真实 verifier 为 19 passed / 0 failed / 0 skipped。运行仓库门仍使用 `<repos-root>/_toolchain/powershell-7.6.5/pwsh.exe`；默认 7.4.19 不满足版本要求。
- **`463304c` exact pair、r14、唯一只读 preflight 和唯一 build-only 全部通过**：caller/launcher/helper exit 均为 0，stderr 0 bytes、无溢出、Job 与环境清理完成；独立验收 preflight 602 条、build-only 315 条断言通过。GradleMain 1、apksigner 1、held aapt2 4、held Git 32；ADB/设备枚举/install/T0/capture 全 0。见[主机验收记录](docs/runs/2026-09-07-C1b-463304c-平板接入前主机验收.md)。旧 `6fbb157` stderr 溢出轮仍[失败冻结](docs/runs/2026-09-07-C1b-6fbb157-构建输出流失败.md)，未重跑或追认。
- **下一步：提示接入 PA2553 平板，尚未开始真机测试。** 使用 USB 数据线，亮屏解锁并确认 USB 调试授权，保持横屏和 vivo 应用多窗。真机 runner 前在同一受控目录恢复 `463304c` 的 clean checkout，完整 SHA 继续传给 `-ExpectedCommitSha`；文档提交保留在本分支，测试后返回记录结果。不得重跑已消费的 host one-shot。
- **语义意图已有离线实现，不能再称“全仓零实现”**：一次性 store、90s/360s/II 300s/I 0 三时钟、真实 reader 装配断言、a11y/OCR 重建三态与不可拆改内容基线，新增 57 用例。**SafetyGate 生产接线、Android 证据安装及执行链仍未实现**；按 C 队列未清规则保留未接线，详见 [spec §5](docs/specs/2026-08-02-语义意图审批-design.md)。
- **手机 C 道暂停**，历史批次 1/2/3 已验收；手机语义意图批次 4 仍 0/4，原离线候选 `67ef56cc8289b34d09843701d7b83986a206ad0e` 在 `codex/batch4-precheck-unify`，未合 main。本轮不改变其验收结论。
- **当前真机基线仍为 PA2553 / Android 16 / 日常横屏应用多窗**；项目适配设备原生能力，不关闭功能换绿。C1a 只成立 trusted origin/read-only，diagnostic/layout/P0/execution 未通过；历史 C1b 七次 one-shot（截至 `a661f36`）均失败冻结，不得同轮重跑。
- **Git 信任根已在本轮实测**：9576 文件、catalog `4c5e585b…7458`、9489 identities、85 内部 hardlink groups，r14 前后内容与 identity catalog 一致；JDK、Gradle 和三个 Android package 树也通过只读复核。无需沿旧 A→E 重装阶梯继续。
- **待真机项**：分享落地 activity 全类名/冷启动反例（白名单保持空，不猜填）、审计 `filesDir` 的 `run-as` 只读复验、S5 RemoteInput、S2 Shizuku 重启存活；install/采集/navigation/conversation/target/regions/layout/editor/action/P0/T-L2 均未放行。
- **函数长度已改用真实 Kotlin PSI**：`scripts/measure-kotlin.ps1 -Offline` 生成 `.checks/kotlin-metrics/` 报告；`callInternal` 的旧“180 行待拆”已过时，排名和指标按实际输入重跑，不再用 grep/括号计数推断。

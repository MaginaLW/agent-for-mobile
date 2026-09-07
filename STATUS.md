# 项目状态

> 2026-09-07 更新；只保留影响下一步的结论，历史细节见 [归档](docs/status-archive.md)。

- **当前分支 `codex/security-hardening`，本轮代码基线 `b0aaa28`；未合入 main。** 无真机工作分阶段完成：离线门/暂停件修复 `7c0a5ba`、Kotlin AST 指标 `512fe92`、语义基础模块 `48f8dd8`、C1b r14 源码生成 `b0aaa28`。入口见[离线开发与验证](docs/runbooks/离线开发与验证.md)。
- **最终全量门 12/13 PASS**，唯一 FAIL 是两条符号链接反例缺系统特权；gateway Debug 555/555、Release 401/401、runner 86/86、独立 fake-ADB 29/29 全过，真实 ADB 调用 0。详见 [09-07 离线记录](docs/runs/2026-09-07-离线开发与验证.md)。
- **主机仍缺 Windows 符号链接特权**：真实 verifier 两条反例跳过，不能记全绿。旧门另有硬编码 `7.6.4` 的缺陷，已改为父子运行时绑定；现在单独明确拒绝 skip。运行仓库门使用 `<repos-root>/_toolchain/powershell-7.6.5/pwsh.exe`；默认 7.4.19 不满足版本要求。
- **C1b r14 已有可复现源码与常驻反例**：Git 全树 pre/finally-post、primary-first 失败处理、字节返回 AST/runtime canary；9 cases 与 545 assertions/10 mutations 通过，真实冻结输入可派生五份 review 源码。**正式 exact pair/r14 工件未发布，preflight/build-only 未执行**；待全量门闭合后固定新 clean SHA，按[候选源码规程](docs/runbooks/T-L1-c1b-candidate-source.md)继续，旧 r12 pair 不复用。
- **语义意图已有离线实现，不能再称“全仓零实现”**：一次性 store、90s/360s/II 300s/I 0 三时钟、真实 reader 装配断言、a11y/OCR 重建三态与不可拆改内容基线，新增 57 用例。**SafetyGate 生产接线、Android 证据安装及执行链仍未实现**；按 C 队列未清规则保留未接线，详见 [spec §5](docs/specs/2026-08-02-语义意图审批-design.md)。
- **手机 C 道暂停**，历史批次 1/2/3 已验收；手机语义意图批次 4 仍 0/4，原离线候选 `67ef56cc8289b34d09843701d7b83986a206ad0e` 在 `codex/batch4-precheck-unify`，未合 main。本轮不改变其验收结论。
- **当前真机基线仍为 PA2553 / Android 16 / 日常横屏应用多窗**；项目适配设备原生能力，不关闭功能换绿。C1a 只成立 trusted origin/read-only，diagnostic/layout/P0/execution 未通过；C1b 七次 one-shot（末次 `a661f36`）均失败冻结，不得同轮重跑。
- **历史 Git 信任根恢复快照（本轮未实测全树）**：9576 文件、catalog `4c5e585b…7458`、9489 identities、85 内部 hardlink groups。此前漂移是多出单个文件，移出后恢复；无需沿旧 A→E 重装阶梯继续。r14 会按同规则重验，历史冻结证据与未知项见归档。
- **待真机项**：分享落地 activity 全类名/冷启动反例（白名单保持空，不猜填）、审计 `filesDir` 的 `run-as` 只读复验、S5 RemoteInput、S2 Shizuku 重启存活；install/采集/navigation/conversation/target/regions/layout/editor/action/P0/T-L2 均未放行。
- **函数长度已改用真实 Kotlin PSI**：`scripts/measure-kotlin.ps1 -Offline` 生成 `.checks/kotlin-metrics/` 报告；`callInternal` 的旧“180 行待拆”已过时，排名和指标按实际输入重跑，不再用 grep/括号计数推断。

# 大脑侧链路知识（headless / 按需挂载 / 两段式）

> 手机执行 harness 的设计素材集；harness 已立项落地（设计：[执行harness spec](../../specs/2026-07-17-执行harness-design.md)，入口 `scripts/dispatch.ps1`）。本册继续记录大脑侧链路的坑与原则。

## 已验证：headless 派单链路（M0 发现 #11）

```powershell
claude -p "<任务提示词>" --output-format json --mcp-config configs/mobile-mcp.json --allowedTools "mcp__mobile"
```

- JSON 输出自带精确 token/成本/轮次——M0 的 $6.44/$1.26 就是这么量出来的。
- ⚠️ 坑：headless 在不信任的工作区会**忽略 settings.json 的 permissions.allow**，必须用 `--allowedTools` 旁路（或先交互跑一次接受信任对话框）。
- 这条链路 = M2「手机上 Termux 跑大脑」的原型：主会话/入口派单，执行会话干活，天然隔离上下文。

## mobile server 按需挂载

2026-07-16 开发 harness 重组后，mobile server 不再常驻项目 `.mcp.json`（开发会话物理碰不到手机）。要跑真机：

```powershell
claude --mcp-config configs/mobile-mcp.json        # 交互式单跑
```

配置在 [configs/mobile-mcp.json](../../../configs/mobile-mcp.json)，版本锁定 `@mobilenext/mobile-mcp@0.0.62`（保证测试数据可比；升级需有意为之并记录）。中文输入依赖手机侧 devicekit APK（现有机制已死，见 [../android/common.md](../android/common.md)）。

## 已定原则（供执行 harness 设计继承）

1. **危险操作必须由人确认**（用户 2026-07-16 批准，2026-07-19 细化）：mobile 执行器在临界动作前停下，人工键盘确认后才走第二腿；gateway 在首次危险工具调用中等待现场人操作手机确认卡。gateway 只有在危险工具尚未调用时遇到纯人工前置条件，才允许暂停后恢复。
2. 全量 trace 落盘 `docs/runs/`，只让摘要进派单方上下文。
3. 每次派单记录 token/成本（JSON 计量），持续校准 [cost.md](cost.md)。

## 执行 harness（2026-07-17 已落地）

设计与协议全文见 [执行harness spec](../../specs/2026-07-17-执行harness-design.md)。入口 `scripts/dispatch.ps1`，站规 `scripts/prompts/executor-preamble.md`，任务卡 `scripts/tasks/`，台账 `docs/runs/ledger.csv`。

实施期实测的坑（claude 2.1.206）：

- **`--max-turns` 已从 CLI 移除**，机械上限改用 `--max-budget-usd`（wrapper 默认 $2）；轮数只能做站规软预算。
- **会话内派单的环境卫生**：子进程要清 `CLAUDE*` 环境变量（wrapper 已做），否则子会话带着宿主会话标记跑；`ANTHROPIC_BASE_URL` 有意保留——它是回落通道开关，派单认证异常先查它。
- 预检不做 npm registry 探测：国内网络假阴性多；版本锁定靠 configs/mobile-mcp.json，server 启不来会体现为首轮 fail。
- 确认门 `Read-Host` 在非交互 shell 直接抛错（实测）——代理经 Bash/PowerShell 无法代答 CONFIRM，两段式硬门机械成立。

## Claude Code 会话本地构建工具链（2026-07-24 补装）

- 这个仓库从未提交 gradle wrapper，本机也没装 Android Studio；此前"263 tests 全绿""debug APK 已重装验证"等构建结论都是在 Codex CLI 沙箱里跑出来的。2026-07-24 发现 Claude Code 会话本地跑不了任何 gradle task 后，征得用户同意下载官方 `gradle-8.9-bin.zip`（`https://services.gradle.org/distributions/gradle-8.9-bin.zip`）装到 `%USERPROFILE%\.local-tools\gradle-8.9`（本机已有 JDK 21，够用），再用它在 `app/` 下跑了一次 `gradle wrapper --gradle-version 8.9` 生成 `gradlew`/`gradlew.bat`/`gradle/wrapper/`。
- 现在 Claude Code 会话可以直接在 `app/` 目录用 `./gradlew testDebugUnitTest testReleaseUnitTest`、`./gradlew assembleDebug` 等自行验证改动，不必再等 Codex CLI 额度或求助 Android Studio；这几个 wrapper 文件目前还没提交 git（`.gitignore` 只排除了 `**/build/`、`**/.gradle/`、`**/local.properties`，wrapper 本身不受影响），要不要入库是单独的决定，入库前问一下用户。
- 测试结果统计走 `build/reports/tests/<variant>/index.html` 里的 `class="counter"`（tests/failures/ignored 三个数字），比 gradle 控制台默认输出（只报 BUILD SUCCESSFUL，不报具体条数）更可靠；单个测试类的结果在 `build/reports/tests/<variant>/classes/<全限定类名>.html`。

## 危险动作统一硬门（2026-07-19 离线测试）

- **风险等级只作元数据会产生旁路**：把 `Level.D` 写进工具注册信息并不会机械阻止 handler；统一安全门必须位于所有 handler 之前，静态等级和动态目标风险都在这里判定。
- **逐工具确认必然漏接**：只在 `ui_action` 等个别工具里弹确认，新工具、IME 回车或其他执行通道仍可能绕过。确认策略应集中，具体工具只负责执行已放行的本次动作。
- **自由文本 `confirm(action_desc)` 不是授权**：模型填写的描述无法绑定随后真正调用的工具，会形成“确认 A、执行 B”旁路。确认卡必须由网关根据实际工具、冻结参数以及当前 App/Activity/目标控件上下文生成，并在最终执行前复核。
- **安全失败不计 retry**：拒绝、超时、上下文或目标失效属于安全控制结果，不得累计为执行失败，否则可能诱导大脑换路或重试危险动作。
- **成功记账失败不能反向诱发动作重试**：动作 executor 已成功后，retry guard 的成功记账应 best-effort；记账异常只进审计，不能把已发生的动作包装成失败交给上层重试。

本轮已离线通过 `SafetyGate` 12 条、`SafetyPolicy` 7 条单测及 gateway debug 构建；未连接手机，三项 P0 真机 smoke 待验。

## 双 executor 派单接线（2026-07-19 离线测试）

- `dispatch.ps1 -Executor mobile|gateway` 共用锁、trace、ledger 和结果解析；默认仍是 `mobile`。gateway 的本地配置只允许放在已 gitignore 的 `configs/gateway-mcp.json`，仓库仅保存 example。
- **DryRun 的位置是安全契约**：必须在任何 adb 调用、私密配置内容读取、锁创建和 trace/暂停件/ledger 落盘之前返回。否则“无手机离线验装配”会意外触碰设备、凭据或台账。
- **暂停件必须持久化 executor**：确认腿自动继承原 profile，显式跨 profile 必须 fail-fast；无 executor 的旧暂停件只按 `mobile` 兼容，不能猜测或自动迁移到 gateway。
- **凭据不进入观测面**：gateway token 与 Authorization 不得写入 trace、ledger、错误消息、TEMP fixture 或测试快照。离线夹具只使用合成值，且不得读取工作区可能存在的真实私密配置。
- **发送无白名单**：旧 harness 的“文件传输助手免确认”已取消；自收消息也要通过相同安全门，任务卡不得保留豁免暗示。
- **safety terminal 没有第二腿**：gateway 的拒绝、确认超时、`E_STALE_REF`、blocked、缺权限/通道等结果必须常规失败；不得写成 `[AWAIT_CONFIRM]`，不得用 `-Confirm` 重试。AWAIT 仅用于危险工具尚未调用时的纯人工前置条件。

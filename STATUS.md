# 项目状态

> 每次会话收尾更新。保持 ≤ 20 行。

- **当前阶段**：P0 统一硬门尚未整体通过，但 `search_entry` 的代码级阻断已修复并通过构建验证。根因是改动遗漏而非新问题：`hasTopTitle`（微信标题）已用识别专用低阈值 `MIN_RECOGNITION_OCR_CONFIDENCE=0.45`，但同类的 `conversationTitle()`（撑起 `isConversationSurface`，从不作点击 ref）漏改，仍卡在点击级门槛 0.65——这正是"手动切到会话页也绕不开"的真实原因。已修：`conversationTitle()` 同步改用识别专用阈值，`findTargetConversation`（聊天列表行点击目标）保持不变，详见 knowledge #15。
- **本次修订**：`P0WeChatPrepareMacro.kt` 的 `conversationTitle()` 一行改动（`trustedVisualEvidence`→`trustedForRecognition`）。**Claude Code 会话本地此前无构建工具链**——已补装 Gradle 8.9（官方发行包，装在 `%USERPROFILE%\.local-tools`）并为 `app/` 生成 `gradlew`（未提交 git，需用户决定是否入库），详见 [harness.md](docs/knowledge/brain/harness.md)。
- **构建验证（2026-07-24，本次改动后，Claude Code 本地跑）**：`testDebugUnitTest`+`testReleaseUnitTest` 全绿——Debug 170 + Release 93 = 263 tests，0 failures，与改动前基线一致；`P0WeChatPrepareMacroTest` 单类 51/51；`assembleDebug` 成功。
- **监督式 runner**：已离线实现且真机验证 provision/sensitive_entry/unrecognized_entry 均可正确通过；业务动作仍只走 `dispatch.ps1 → gateway MCP → SafetyGate → executor`。用户只核对目标会话、明文 preview 与 12 位确认编号并点真人决定；Allow/Stale 尚未真正跑到确认卡这一步。
- **下一步（按序）**：
  1. 真机重装本次改动后的 debug APK，走"人工预先切到「文件传输助手」会话页"流程重跑 `run-p0-safety-smoke.ps1 -Legs Allow,Stale -Executor gateway -Provision`。
  2. 两腿真实证据通过后再把 P0 整体判过；随后处理 D3 OCR 输入读回、Shizuku、IME 自动切换及任务 4/2 端到端链路。
- **遗留/障碍**：真实 Allow/Stale 尚未触发确认卡（待上述真机重跑）；Deny 确认卡截图沿用既有证据缺口；vivo 无障碍绑定/appops 已知问题已修复，其余厂商权限风险仍可能触发 `setup-fail`；S5 RemoteInput、S2 Shizuku 重启存活、`dispatch.ps1 -Confirm` 收口、`share_file` activity 级 verify 待补；Codex 订阅额度已耗尽（2026-07-30 恢复，现已非构建阻塞项）。

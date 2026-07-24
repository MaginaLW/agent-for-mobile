# 项目状态

> 每次会话收尾更新。保持 ≤ 20 行。

- **当前阶段**：P0 统一硬门尚未整体通过。2026-07-24 全天真机验证约 25 轮（含只读诊断），修了 5 处真实问题：①`conversationTitle`/`P0FocusProbeValidator` 识别级阈值不一致；②`Start-P0TargetApp` 无条件重启微信；③`OcrEngine` 加对比度增强双跑合并（真机证实能把「文件传输助手」标题从"零候选"顶到 0.5+ 可识别）；④宏顶层加感知阶段（点击前）有限次重试；⑤**当天最后定位到的更关键问题**：OCR 把标题识别成"文件传输助手8"（尾随多识别出字符，confidence 正常，不是置信度问题），而 `conversationTitle`/`P0FocusProbeValidator`/`P0FixedQueryValidator` 三处用严格 `==` 比对，永远匹配不上——已改用 `contains`，点击目标（`findTargetConversation`/`P0StageRefActionValidator`）严格匹配保持不动，见 knowledge #17。
- **真机结论**：以上 5 处修复单独看都是真实、已测试验证的改进（Debug 178 + Release 93 = 271 tests 全绿），但今天始终没能凑出一次完整跑通到确认卡——排查过程中排除了截图管线陈旧、屏幕锁屏（`stay_on_while_plugged_in=7`，设备确认唤醒）两个疑虑，剩余卡点是 **OCR 抖动与微信自身前台状态漂回聊天列表两个概率性因素叠加**，后者不受这几处代码改动控制。用户已自行提交全部改动（commit "测试"/"测试4"）。
- **监督式 runner**：已离线实现且真机验证 provision/sensitive_entry/unrecognized_entry 均可正确通过；业务动作仍只走 `dispatch.ps1 → gateway MCP → SafetyGate → executor`。Allow/Stale 仍未真正跑到确认卡这一步。
- **下一步（按序）**：
  1. 找个精力/时间充分的时段重新真机验证，导航到会话页后立刻跑（缩短间隔），必要时连续多试几次吃掉概率性因素；诊断优先用 `dispatch.ps1 -Task "只读..."` 而非整套 `-Provision`（省钱见 knowledge #16 尾注）。
  2. 通过后两腿真实证据过了再把 P0 整体判过；随后处理 D3 OCR 输入读回、Shizuku、IME 自动切换及任务 4/2 端到端链路。
- **遗留/障碍**：真实 Allow/Stale 尚未触发确认卡（OCR 抖动+微信状态漂移复合阻断，见上）；Deny 确认卡截图沿用既有证据缺口；S5 RemoteInput、S2 Shizuku 重启存活、`dispatch.ps1 -Confirm` 收口、`share_file` activity 级 verify 待补；Codex 订阅额度已耗尽（2026-07-30 恢复，现已非构建阻塞项）。

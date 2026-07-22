# 项目状态

> 每次会话收尾更新。保持 ≤ 20 行。

- **当前阶段**：P0 统一硬门尚未整体通过。2026-07-22 真机 smoke（[记录](docs/runs/2026-07-22-P0安全硬门-smoke.md)）中拒绝腿已有通过结论；允许一次腿因 D1 安全向误杀而未通过，失效腿未跑，全程零消息发出、零 `.pause.md`。
- **本次修订**：D1 已完成离线严格修复：窗口事件按 active `TYPE_APPLICATION`（无 active 才 focused）windowId 归属，前台身份显式 `Known/Unknown`，`Unknown` 时 W/D 统一阻断。完整 JVM 回归由原 19 增至 39，39/39 通过；debug 构建通过并生成 APK。该结论不代表 D1 已真机验证。
- **下一步（按序）**：
  1. D2：确认卡展示输入文本并避开输入条。
  2. 在独立受控跑测会话由 Agent 经 `scripts/dispatch.ps1` 主导允许腿和失效腿：Agent 负责准备、派单、监看、留证与收尾；用户只在旁核对危险确认卡并选择拒绝/允许。两腿都通过后 P0 才能整体判过；拒绝腿沿用已有结论。
  3. D3：`type_text` 输入条 OCR 读回扩边重试，恢复 `verified` 语义。
  4. 接入 Shizuku：`system_set_state` 直写 + `am start` 破 BAL。
  5. IME 自动切换（`WRITE_SECURE_SETTINGS`）；重跑任务 4/2 大脑端到端链路。
- **遗留/障碍**：仅监督式分工已明确，但主控 runner 尚未设计/实现；拒绝腿确认卡截图缺失（口头+事后无气泡截图替代，已记录）；网关进程被 OriginOS 清理过→最近任务须锁定、进程死会静默回退输入法；S5 RemoteInput、S2 Shizuku 重启存活、`dispatch.ps1 -Confirm` 收口、`share_file` activity 级 verify 待补；深色灰字 OCR 漏识 ~40%；vivo `install -r` 重置权限且 a11y 需 toggle 重绑。

# 项目状态

> 每次会话收尾更新。保持 ≤ 20 行。

- **当前阶段**：P0 统一硬门尚未整体通过。2026-07-22 真机 smoke（[记录](docs/runs/2026-07-22-P0安全硬门-smoke.md)）的 Deny 腿已有通过结论；Allow 因旧 D1 误杀未通过，Stale 未跑，全程零消息发出、零 `.pause.md`。新的 Allow/Stale 尚未真机执行。
- **本次修订**：D1 已将前台身份收紧为 active/focused `TYPE_APPLICATION` 归属与 `Known/Unknown`，Unknown 对 W/D fail-closed；D2 已实现输入与短时目标会话证据、确认前后复检、目标标签/明文 preview/12 位确认编号、顶部确认卡、按钮证据就绪门和 gateway 自有 overlay 操作隔离。规格复审收尾已闭环：prepared target 存续期 `type_text` 禁带 ref、宏返回后强 fresh 终验 + 记录失败回滚、焦点身份按节点/IME 双命名空间分别复核（节点 id 统一由共享 `FocusedInputIdentity` 生成，含真实 producer 格式契约测试）。Codex 会话在该修复中段因额度耗尽中断，本会话已接续核验为完整落地。
- **监督式 runner**：已离线实现 debug 私有 test-control/确认截图/stale hook、微信准备宏、provision/清理、严格 Allow→Stale 编排、trace/ledger/audit/manifest 判定与 token 脱敏。业务动作仍只走 `dispatch.ps1 → gateway MCP → SafetyGate → executor`；用户只核对目标会话、明文 preview 与 12 位确认编号并点真人决定，其余证据由 runner 机械验证。
- **离线验证（2026-07-23 晚，接续会话复验）**：Debug 169 + Release 93，JVM XML 合计 262 tests，0 failures/errors/skipped（`--rerun-tasks` 全量重跑）；P0 runner 离线测试 32/32（须空闲机器单独跑，与构建并发会假超时，见 knowledge）；debug/release APK 构建通过。以上不代表真实 Allow/Stale 已通过。
- **下一步（按序）**：
  1. 在独立受控真机执行会话由 Agent 运行 `pwsh -NoProfile -File scripts/run-p0-safety-smoke.ps1 -Legs Allow,Stale -Executor gateway -Provision`；用户不执行命令，只分别核对确认卡并点一次“允许本次”。任一腿不符立即停止，不补跑。
  2. 两腿真实证据均通过后再把 P0 整体判过；随后处理 D3 OCR 输入读回、Shizuku、IME 自动切换及任务 4/2 端到端链路。
- **遗留/障碍**：真实 Allow/Stale 尚未执行；Deny 确认卡截图沿用既有证据缺口；vivo 厂商权限/进程回收仍可能触发 `setup-fail`；S5 RemoteInput、S2 Shizuku 重启存活、`dispatch.ps1 -Confirm` 收口、`share_file` activity 级 verify 待补；深色灰字 OCR 漏识约 40%；Codex 订阅额度已耗尽（2026-07-30 恢复），期间 codex 腿/派单不可用。

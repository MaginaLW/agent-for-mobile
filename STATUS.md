# 项目状态

> 每次会话收尾更新。保持 ≤ 20 行。

- **当前阶段**：P0 统一硬门尚未整体通过，但 2026-07-23 晚首次真机执行 runner，13 轮迭代修完 12 个只在真机才现形的坑（provision 5 个 + `sensitive_entry`/`unrecognized_entry` 识别 7 个，详见 knowledge #1~14），确认这两道门槛在真机上已能正确通过。当前卡在更下一层：`search_entry` 阶段，「文件传输助手」文字在聊天列表行与会话页标题两处 OCR 置信度均仅 ~0.55，低于点击目标门槛 `MIN_ACTION_OCR_CONFIDENCE=0.65`；手动切页面到会话页验证过不能绕开，是同一处 OCR 漏识（非弹窗/竞态类 bug），未改代码，按用户决定原地暂停。
- **本次修订**：D1/D2/规格复审收尾（焦点双身份分别复核、prepared target 全链路）已确认完整落地，详见上次收尾记录；本次新增的 12 处真机修复见 [knowledge/android/common.md](docs/knowledge/android/common.md) #9~14（GatewayA11yService 状态栏/TOCTOU、P0WeChatPrepareMacro 敏感面扫描范围与识别阈值、provision 脚本 5 处机械坑）。
- **监督式 runner**：已离线实现且真机验证 provision/sensitive_entry/unrecognized_entry 均可正确通过；业务动作仍只走 `dispatch.ps1 → gateway MCP → SafetyGate → executor`。用户只核对目标会话、明文 preview 与 12 位确认编号并点真人决定；Allow/Stale 尚未真正跑到确认卡这一步。
- **离线验证（2026-07-23 晚）**：Debug 170 + Release 93 = 263 tests，0 failures；P0 runner 离线测试 31/31（须空闲机器单独跑）；debug APK 已含全部真机修复并重装验证过。
- **下一步（按序）**：
  1. 解决「文件传输助手」OCR 置信度不足问题（三个方向待选：手机调大字体/显示比例重试；专门为该硬编码目标文本降低识别阈值；或验证 OCR 引擎本身能否针对深色灰字调优）——不解决此项，Allow/Stale 无法真正触发确认卡。
  2. 解决后重跑 `run-p0-safety-smoke.ps1 -Legs Allow,Stale -Executor gateway -Provision`，两腿真实证据通过后再把 P0 整体判过；随后处理 D3 OCR 输入读回、Shizuku、IME 自动切换及任务 4/2 端到端链路。
- **遗留/障碍**：真实 Allow/Stale 尚未触发确认卡（OCR 置信度阻断，见上）；Deny 确认卡截图沿用既有证据缺口；vivo 无障碍绑定/appops 已知问题已在本轮修复，其余厂商权限风险仍可能触发 `setup-fail`；S5 RemoteInput、S2 Shizuku 重启存活、`dispatch.ps1 -Confirm` 收口、`share_file` activity 级 verify 待补；深色灰字 OCR 漏识（本轮实测约 40%→点击阈值下命中率）已从"已知风险"升级为 P0 阻断项；Codex 订阅额度已耗尽（2026-07-30 恢复）。

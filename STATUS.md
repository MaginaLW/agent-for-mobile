# 项目状态

> 每次会话收尾更新。保持 ≤ 20 行。

- **当前阶段**：M1b OCR 融合层已落地并于 2026-07-19 真机验收通过（[记录](docs/runs/2026-07-19-M1b-OCR融合.md)）：微信选择页、OCR ref 校验点击、`type_text` IME/OCR 读回、`wait_for` OCR 感知链路已走通。P0 危险动作统一硬门代码已落地，19 条 JVM 单测（SafetyGate 12 + SafetyPolicy 7）及 gateway debug 构建通过；**P0 三项真机 smoke 待验，不能记为通过**。
- **下一步（按序）**：
  1. 最小 gateway executor 接入 `scripts/dispatch.ps1`。
  2. 用户连接手机后，经派单通道跑 P0 三项 smoke：Enter 发送前准确确认、拒绝零发送/允许仅一次、切页后上下文失效拒绝。
  3. Shizuku 接入：`system_set_state` 直写，并以 `am start` 处理 vivo/Android 16 后台启动三方 app 的 BAL 实锤阻塞。
  4. IME 自动切换（`WRITE_SECURE_SETTINGS`）及 `type_text` IME+OCR 读回真机闭环。
  5. 任务 4/2 大脑端到端重跑；文件传输助手不保证选择页首屏，走短子串 + `scroll_search` 或搜索框通道。
- **遗留/障碍**：S5 RemoteInput、S2 Shizuku 重启存活、`dispatch.ps1 -Confirm` 收口、`share_file` activity 级 verify 待补；微信深色模式灰字 OCR 漏识约 40%；vivo `install -r` 会重置运行时权限且 a11y 需 toggle 重绑；confirm 后台弹窗仍待 vivo「后台弹出界面」授权。

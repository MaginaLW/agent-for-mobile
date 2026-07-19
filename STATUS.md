# 项目状态

> 每次会话收尾更新。保持 ≤ 20 行。

- **当前阶段**：M1b OCR 融合层已于 2026-07-19 真机验收通过（[记录](docs/runs/2026-07-19-M1b-OCR融合.md)）。P0 危险动作统一硬门代码已离线验收：19 条 JVM 测试及 gateway debug 构建通过；**P0 三项真机 smoke 尚未执行，不能记为通过**。
- **派单离线状态**：`dispatch.ps1` 已支持双 profile，默认 `mobile`、显式 `-Executor gateway`；离线脚本 14/14、3 个 PowerShell 脚本解析零错误、差异检查通过，gateway 安全站规、三张任务卡及 [runbook](docs/runbooks/P0-safety-hard-gate-smoke.md) 已就绪。
- **下一步（按序）**：
  1. 用户连接手机后按 runbook 检查或更新被 Git 忽略的 gateway 配置、填入现场 token 并完成人工权限预检，再经派单通道依次跑 P0 三项 gateway smoke。
  2. 接入 Shizuku：`system_set_state` 直写，并以 `am start` 处理 vivo/Android 16 后台启动三方 app 的 BAL 阻塞。
  3. 完成 IME 自动切换（`WRITE_SECURE_SETTINGS`）及 `type_text` IME+OCR 读回真机闭环。
  4. 重跑任务 4/2 大脑端到端链路；文件传输助手选择走短子串 + `scroll_search` 或搜索框通道。
- **遗留/障碍**：S5 RemoteInput、S2 Shizuku 重启存活、人工前置条件的 `dispatch.ps1 -Confirm` 收口、`share_file` activity 级 verify 待补；微信深色模式灰字 OCR 漏识约 40%；vivo `install -r` 会重置运行时权限且 a11y 需 toggle 重绑；confirm 悬浮卡仍需真机核对 vivo「后台弹出界面」权限。

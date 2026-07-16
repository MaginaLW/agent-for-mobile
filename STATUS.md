# 项目状态

> 每次会话收尾更新。保持 ≤ 20 行。

- **当前阶段**：执行 harness 已落地并真机验证（2026-07-17）：① 只读 ✅ $0.44/5 轮；③ 预算熔断 ✅；④ 任务成功但触 $2 顶（$2.01/55 轮，三坑对策已固化进站规 v2 与任务卡）；② 两段式暂停 ✅（蓝牙版），待人工 CONFIRM 收口。台账 docs/runs/ledger.csv 六种结果态齐活；cost.md 已校准。
- **下一步（按序）**：
  1. 人工收口两段式第二腿（动作=关蓝牙）：`scripts/dispatch.ps1 -Confirm "docs/runs/traces/20260717-062135-drill-confirm-bt-claude-leg1.pause.md"`，按提示键入 CONFIRM。
  2. M1 执行器 App 立项与设计细化：硬需求清单见 docs/runs/2026-07-16-M0.md 结论节，本轮新增实锤——IME 通道（预测输入法吞空格）、截图坐标 ×3.5 缩放、微信选图器回弹（devices.md / apps.md）。
  3. 遗留复测（均等 M1 IME 通道）：中文输入 m0-2 卡；消息版演练 drill-confirm.md（已标阻塞）。
- **障碍**：无。顺手清理：微信文件传输助手输入框留有无害草稿 "harness"。

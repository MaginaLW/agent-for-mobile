# 项目状态

> 每次会话收尾更新。保持 ≤ 20 行。

- **当前阶段**：M0 已完成（2026-07-16）；开发 harness 已重组（同日）；执行 harness 已批准并落地（2026-07-17，spec+wrapper+站规+任务卡+台账；离线三验通过：DryRun / 预检 fail-fast / 确认硬门拒代理）。
- **下一步（按序）**：
  1. 连手机跑真机验证四步（spec §10.4，按序）：
     ① `scripts/dispatch.ps1 -TaskFile scripts/tasks/check-bluetooth.md`（只读干跑）
     ③ 同上加 `-MaxBudgetUsd 0.05`（触预算上限 → step-cap）
     ② `scripts/dispatch.ps1 -TaskFile scripts/tasks/drill-confirm.md`，暂停后按提示 `-Confirm ...`（人工键入 CONFIRM）
     ④ `scripts/dispatch.ps1 -TaskFile scripts/tasks/m0-4-wechat-screenshot.md`（对比 M0 $1.26 基准）→ 校准 cost.md
  2. M1 执行器 App 立项与设计细化（硬需求清单见 docs/runs/2026-07-16-M0.md 结论节）。
  3. 遗留复测：任务 2 中文输入（等 devicekit 修复或 M1 IME 通道；任务卡已备 scripts/tasks/m0-2-wechat-text.md）。
- **障碍**：无（真机验证只差设备连接）。

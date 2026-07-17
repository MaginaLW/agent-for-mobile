# 项目状态

> 每次会话收尾更新。保持 ≤ 20 行。

- **当前阶段**：执行 harness 已落地并真机验证（2026-07-17）：① 只读 ✅ $0.44/5 轮；③ 预算熔断 ✅；④ 任务成功但触 $2 顶（$2.01/55 轮，三坑对策已固化进站规 v2 与任务卡）；② 两段式暂停 ✅（蓝牙版），待人工 CONFIRM 收口。台账 docs/runs/ledger.csv 六种结果态齐活；cost.md 已校准。
- **下一步（按序）**：
  1. 人工收口两段式第二腿（动作=关蓝牙）：`scripts/dispatch.ps1 -Confirm "docs/runs/traces/20260717-062135-drill-confirm-bt-claude-leg1.pause.md"`，按提示键入 CONFIRM。
  2. **M1 已批准（2026-07-17，7 决策点全按推荐项），当前 = Spike 周（需真机）**：按 docs/runbooks/M1-spike-runbook.md 跑 S1–S5，S1（微信树可读性）最优先；探针工程 spikes/probe/ 已备好（云端产出未编译，首次构建按 runbook §0）。跑完回填 spec §11/§12 再动工 M1a。设计：docs/specs/2026-07-17-M1执行网关-design.md；主设计三处修订已同步。
  3. 遗留复测（均等 M1 IME 通道）：中文输入 m0-2 卡；消息版演练 drill-confirm.md（已标阻塞）。
- **障碍**：无。顺手清理：微信文件传输助手输入框留有无害草稿 "harness"。

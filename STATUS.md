# 项目状态

> 每次会话收尾更新。保持 ≤ 20 行。

- **当前阶段**：执行 harness 已落地并真机验证（2026-07-17）：① 只读 ✅ $0.44/5 轮；③ 预算熔断 ✅；④ 任务成功但触 $2 顶（$2.01/55 轮，三坑对策已固化进站规 v2 与任务卡）；② 两段式暂停 ✅（蓝牙版），待人工 CONFIRM 收口。台账 docs/runs/ledger.csv 六种结果态齐活；cost.md 已校准。
- **下一步（按序）**：
  1. 人工收口两段式第二腿（动作=关蓝牙）：`scripts/dispatch.ps1 -Confirm "docs/runs/traces/20260717-062135-drill-confirm-bt-claude-leg1.pause.md"`，按提示键入 CONFIRM。
  2. **M1a 网关 App 已写完并云端编译通过（2026-07-17），待真机日一次性验证**：按 docs/runbooks/M1-真机日清单.md 走（上午 Spike S1–S5 + 下午网关首装联调）。工程 app/gateway（22 工具面/信封错误模型/审计/IME/确认层/MCP server）；gateway-debug.apk 已经会话附件发出，探针 APK 需本地构建。OCR 融合层排期等 S1 结果。设计：docs/specs/2026-07-17-M1执行网关-design.md（已批准）。
  3. 遗留复测（均等 M1 IME 通道）：中文输入 m0-2 卡；消息版演练 drill-confirm.md（已标阻塞）。
- **知识预习（2026-07-17 云端）**：docs/knowledge/sys-cli.md 新增（系统命令/真值源/Shizuku/IME 切换，🔵 多为查阅未实测）；deeplinks.md 补京东/淘宝/支付宝候选深链（🔵）；技能包 assets 同步。真机日逐条验证后上正表。
- **障碍**：无。顺手清理：微信文件传输助手输入框留有无害草稿 "harness"。

# 项目状态

> 每次会话收尾更新。保持 ≤ 20 行。**这里只放"影响下一步怎么做"的事**；
> 已闭环批次的详细复盘移出到 [docs/status-archive.md](docs/status-archive.md)（只写不读），
> 教训的正式落点是 [knowledge/](docs/knowledge/README.md) 与 [backlog 复核清单](docs/backlog.md)。

- **已通过并合入 main 的：批次 1**（干掉每跑一腿的人工前后置，`337113c`）· **批次 2**（通知栏审批）· **批次 3**（Deny 带外验证），后两批 `f08cda2`。详细复盘见归档。
- **工序按人的成本分 A/B/C 三道**（[backlog](docs/backlog.md)）：A 离线独立闭环，B 用户一次决定，C 用户在真机旁；C 只验钉住的 commit，失败只取证、不开发、不重跑。
- **批次 4 基线 SHA `3ed077d` 的新 C 道已冻结**：task `019ff0c0-1c5f-79e1-823a-ee2acdc452b0`、run `20260811T202517-0e176d3f08b9`。Allow 真人 `allowed` 后，最终 fresh title OCR 误选日期文本，`E_VERIFY_FAIL` 正确 fail-closed，未发送；Stale/Deny/Reentry 未运行，cleanup clean。该 run 不是基础设施失败，也不单独判批次功能 PASS/FAIL；批次 4 仍 **0/4、未判定**。
- **针对该现象的 A 道修复已离线闭环，待提交新 SHA；main 行为仍未改变。** 标题带下沿改为最短边 24%，来源可信度优先，排序与输入顺序无关且歧义 fail-closed；最终标题证据成为硬门，按 phase 与 audit/token/trace 同源校验并只持久化脱敏摘要。独立复审 Approved；完整 gate 全绿：dispatch 58/58、gateway Debug/Release/assembleDebug、runner 144/144、凭据扫描。
- **旧 C 道 run `20260809T203420-6cf147532b9f` 只判验收基础设施失败**：当时 `-Brain codex` 固定占位 exit 2，尚未进入安全门；不得归因为 Allow/语义意图功能失败。旧 C 道冻结且不复用，批次 4 仍 **0/4、未判定**。
- **Codex 0.147 `view_image` 无禁用键的有界 residual 已获用户明确接受**：空 cwd、无 shell/文件枚举、prompt/MCP 不提供本机路径、未知 item fail closed；该决定无需再询问。
- **唯一下一步**：提交上述修复并钉住新 SHA，再创建另一条 clean C；机械确认 HEAD，显式 `-Brain codex`，APK 只构建/安装一次、runner 只启动一次，按 **Allow → Stale → Deny → Reentry** 连跑。不得复用两条已冻结 C 或旧 run。
- **批次 4 现场防误判仍有效**：Stale 腿几十秒终态是对的，理由必须是“等前台恢复超时”而非“包变了”；OCR 抖动的 `Unverified` 是正确 fail-closed；`-Provision` 装 debug APK，通过不能证明 release 行为。
- **跑前物理前置**：微信停在「文件传输助手」· 输入框空 ·「回车发送」开着 · `zen_mode=0` · 输入栏上方无系统浮层 · 切 App 要真的显示出来再点通知 · 跑真机时不并行离线闸门。
- **遗留/障碍**：非宏危险 `ui_action` 仍 fail-closed 为 `E_STALE_REF`，接任务 4/2 端到端前必须解决；审计目录迁 filesDir、S5 RemoteInput、S2 Shizuku 重启存活、`share_file` activity 级 verify 待补。

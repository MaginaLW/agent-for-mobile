# 项目状态

> 每次会话收尾更新。保持 ≤ 20 行。**这里只放"影响下一步怎么做"的事**；
> 已闭环批次的详细复盘移出到 [docs/status-archive.md](docs/status-archive.md)（只写不读），
> 教训的正式落点是 [knowledge/](docs/knowledge/README.md) 与 [backlog 复核清单](docs/backlog.md)。

- **已通过并合入 main 的：批次 1**（干掉每跑一腿的人工前后置，`337113c`）· **批次 2**（通知栏审批）· **批次 3**（Deny 带外验证），后两批 `f08cda2`。详细复盘见归档。
- **工序按人的成本分 A/B/C 三道**（[backlog](docs/backlog.md)）：A 离线独立闭环，B 用户一次决定，C 用户在真机旁；C 只验钉住的 commit，失败只取证、不开发、不重跑。
- **批次 4 最终安全修复 + Codex CLI 派单通道已离线闭环，逻辑 SHA `3ed077d`，分支 `claude/serene-faraday-42d1fb`；main 行为仍未改变。** 独立 Critical/Important 复审 Approved；`check.ps1 -Shards 3` 全绿：dispatch 58、runner 142、Debug/Release/assembleDebug、凭据扫描。
- **旧 C 道 run `20260809T203420-6cf147532b9f` 只判验收基础设施失败**：当时 `-Brain codex` 固定占位 exit 2，尚未进入安全门；不得归因为 Allow/语义意图功能失败。旧 C 道冻结且不复用，批次 4 仍 **0/4、未判定**。
- **新 C 道前只剩一个 B 道决定**：Codex 0.147 没有可用的 `view_image` 禁用键。当前边界为空 cwd、无 shell/文件枚举、prompt/MCP 不提供本机路径、未知 item fail closed；用户明确接受该版本 residual 后才新建 clean C，否则先升级或加 OS 级隔离。
- **获放行后的唯一下一步**：从 `3ed077d` 新建 clean worktree，机械确认 HEAD，显式 `-Brain codex`，APK 只构建/安装一次、runner 只启动一次，按 **Allow → Stale → Deny → Reentry** 连跑；任一腿失败即停止并保留脱敏证据。
- **批次 4 现场防误判仍有效**：Stale 腿几十秒终态是对的，理由必须是“等前台恢复超时”而非“包变了”；OCR 抖动的 `Unverified` 是正确 fail-closed；`-Provision` 装 debug APK，通过不能证明 release 行为。
- **跑前物理前置**：微信停在「文件传输助手」· 输入框空 ·「回车发送」开着 · `zen_mode=0` · 输入栏上方无系统浮层 · 切 App 要真的显示出来再点通知 · 跑真机时不并行离线闸门。
- **遗留/障碍**：非宏危险 `ui_action` 仍 fail-closed 为 `E_STALE_REF`，接任务 4/2 端到端前必须解决；审计目录迁 filesDir、S5 RemoteInput、S2 Shizuku 重启存活、`share_file` activity 级 verify 待补。

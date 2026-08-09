# Codex 派单通道接通与批次 4 再验收执行计划

> **For agentic workers:** REQUIRED EXECUTION FLOW: Use `subagent-driven-development` to execute this plan task-by-task when subagents are available. If no subagent capability is available, execute inline with the same task checklist and review checkpoints.

**Goal:** 在不触碰旧 C 道的前提下，让 `scripts/dispatch.ps1 -Brain codex` 通过官方 Codex CLI 登录安全驱动唯一选中的手机 MCP，并把 Codex JSONL 归一进现有 trace、ledger、runner 和真人确认窗口。

**Approach:** 先用可失败离线夹具钉住占位退出、CLI 参数/MCP 隔离、Codex JSONL 解析和 child 提前退出归因，再做最小 brain adapter；Claude 现有路径保持不变。开发提交经独立安全复审和完整离线/Android gate 后钉住新 SHA，随后才创建另一条 clean C 道任务做 Allow→Stale→Deny→Reentry 一次性整轮验收。

**Materials:** `CLAUDE.md`；`AGENTS.md`；`scripts/dispatch.ps1`；`scripts/run-p0-safety-smoke.ps1`；`scripts/lib/dispatch-profile.ps1`；`scripts/tests/dispatch-offline.ps1`；`scripts/tests/p0-supervised-runner-offline.ps1`；`docs/specs/2026-07-17-执行harness-design.md` §4–§8；失败 run `20260809T203420-6cf147532b9f`（只读证据）；官方 OpenAI Codex CLI developer commands、non-interactive mode、MCP/config reference。

**Validation:** 离线测试证明 Codex 分支不再固定 exit 2，使用 fake Codex 产出 Codex JSONL、trace、ledger 和 paused/真人确认可见状态；runner 能把 child 提前退出归因为 dispatch 基础设施失败而非真人 confirm-timeout；完整 `scripts/check.ps1 -Shards 3` 通过；独立复审无未处置的 Critical/Important。Codex 0.147 没有可用的 `view_image` 禁用键，必须如实记录为版本限定 residual，并在用户明确接受（空 cwd、无 shell/文件枚举、prompt/MCP 不提供本机路径、未知 item fail closed）或升级/增加 OS 隔离后，才可创建新 SHA 的 clean C 道四腿整轮并给功能结论。

---

### Task 1: 固化 Codex CLI 与 MCP 隔离契约

**Artifacts / Locations:**
- Modify: `scripts/tests/dispatch-offline.ps1`
- Review: `scripts/dispatch.ps1`
- Review: `scripts/lib/dispatch-profile.ps1`

- [x] **Step 1: 建立占位与参数 RED**

用 fake `codex` 运行非 DryRun `-Brain codex`，断言旧代码固定 exit 2、没有调用 fake Codex、没有 trace/ledger。保留该 RED 日志。

- [x] **Step 2: 建立启动隔离 RED**

fake Codex 记录 argv 与允许的非敏感环境变量名，断言目标参数包含 `exec --json --ephemeral --ignore-user-config --ignore-rules --strict-config --sandbox read-only --disable shell_tool`。Process cwd 与 `-C` 必须同时指向仓库外新建的空临时目录，并配合 `--skip-git-repo-check`、`project_doc_max_bytes=0`，避免加载项目或全局 AGENTS。显式关闭 0.147 实际支持的 apps、browser/computer、hooks、plugins、image generation、workspace dependencies、memories/goals、multi-agent、web、agents；不得声称已关闭 0.147 不支持配置的 `view_image`。只配置当前 executor 的 `mcp_servers.<name>`，设置 `required=true`、`default_tools_approval_mode=approve` 和足够的 `tool_timeout_sec`。不得记录 bearer 值。

- [x] **Step 3: 验证 gateway token 生命周期**

从现有私密配置只在内存提取 token，写入随机命名的一次性环境变量供 `bearer_token_env_var` 使用；大脑启动后清理父环境，fake 子进程证明 shell 环境策略不继承该变量，console/trace/ledger 不含值。

- [x] **Step 4: 记录结果**

保存 RED/GREEN 日志到 gitignored `.checks/`；生产/测试 PowerShell AST 必须通过。

- [x] **Step 5: 用真实 Codex 验证 headless MCP**

在系统临时目录启动真实 Codex 0.147 与唯一一个无副作用 stdio fake MCP，断言 `default_tools_approval_mode=approve` 没有自动取消工具调用，JSONL 出现唯一成功 `mcp_tool_call`，且没有 shell/web/插件/其他工具、仓库读取或 secret 泄漏。此项是重新派 C 道前的阻断 gate，不放进可离线复现的常规单测冒充通过。

### Task 2: 实现 brain adapter 与双 JSONL 归一

**Artifacts / Locations:**
- Modify: `scripts/dispatch.ps1`
- Modify or create: `scripts/lib/dispatch-brain.ps1`
- Modify: `scripts/tests/dispatch-offline.ps1`

- [x] **Step 1: 抽出启动规格**

把 executable、arguments、模型、prompt 输入和临时环境构造成 brain-aware 规格；Claude 规格保持现有 argv 和 trace 行为逐字兼容，Codex 规格使用本机 `codex exec` 且默认不传 `sonnet`。

- [x] **Step 2: 解析 Codex JSONL**

按真实事件结构读取 `thread.started`、`turn.started`、`item.started|completed(agent_message|mcp_tool_call)`、诊断 `item.error|error` 和唯一终态 `turn.completed|turn.failed`。共享读取器返回 structured terminal、nullable usage 与带 `StartedOrdinal/CompletedOrdinal/CompletedBeforeNext` 的调用；started/completed 的 id、server、tool、arguments 必须同源。成功 turn 允许多条中间 `agent_message`，但最终正文必须是最后一条且晚于全部 MCP completed、早于 `turn.completed`；前序正文不进入 canonical transcript。顶层 error 只是诊断，required MCP 初始化失败还可能没有 JSONL。非空畸形 JSON、缺唯一终态、失败 MCP 调用、孤儿/重复/错序事件均 fail closed，错误正文不得跨 helper 进入 console/ledger。

- [x] **Step 3: 生成 ledger 与 paused 产物**

Codex 成功报告写 `brain=codex`、订阅通道 cost 留空、token usage 有值、trace basename 含 `-codex-`；最终文本含 `[AWAIT_CONFIRM]` 时写 `.pause.md` 并打印明确的真人确认窗口提示。

- [x] **Step 4: 保持 gateway 正向证明**

让 `Get-GatewayPauseTraceProof` 按 brain 解析 Claude 或 Codex MCP 事件，仅允许既有只读 gateway 工具且要求每次调用有唯一成功结果；pause/trace 的 brain、slug、leg、session 必须同源。

- [x] **Step 5: 验证兼容性**

运行 dispatch 全套；预期所有既有 Claude 用例全绿，新增 Codex fake success/fail/paused/malformed/tool-failure 用例全绿。

### Task 3: 让监督 runner 理解 Codex trace 与基础设施提前退出

**Artifacts / Locations:**
- Modify: `scripts/run-p0-safety-smoke.ps1`
- Modify: `scripts/tests/p0-supervised-runner-offline.ps1`

- [x] **Step 1: 建立提前退出归因 RED**

fake dispatch 在确认状态出现前退出并写基础设施错误；断言旧 runner 错记 confirm-timeout。GREEN 必须记录 dispatch/executor failure，且用户未点卡不得被写成真人超时。

- [x] **Step 2: 增加 Codex trace 读取器用例**

用 `mcp_tool_call` 的 started/completed 对构造 Allow/Deny/Stale/Reentry 的 4/3/3/4 调用序列、结构化 gateway envelope 和终态 agent message，验证调用次数、参数、结果及敏感扫描与 Claude 等价。最低负例矩阵同时覆盖：生命周期身份/错序/重复/孤儿；多条 agent message 与“最终正文早于工具完成”；MCP transport failure 与合法 `ok=false` gateway 终态；实测 `item.error→error→turn.failed`；session/usage/ledger 精确一致且未知值留空；无 trace 提前退出、已有失败 ledger（含 success/paused/aborted/wrong-brain/wrong-leg）提前退出、仍活 child 真超时；各 JSONL 字段与无-JSONL stderr 的敏感值；`command_execution/file_change/unknown item` 越权事件。

- [x] **Step 3: 接入 brain-aware trace parser**

共享 dispatch 的 `Read-DispatchTraceTranscript -TracePath -Brain`，runner 只保留 P0 调用序列与 marker 语义，避免维护第二份事件 schema；unknown brain/unknown item/失败调用一律拒绝。确认等待必须显式区分 `decision|deadline|dispatch-exited`：只有仍活 child 超过 deadline 或设备明确 `timed_out` 才是 confirm-timeout；child 先退出应 drain、复用已有 dispatch ledger，确无 row 才补 `executor-exited-before-confirmation` 基础设施行，并写 `human_decision=not_observed`、空 safety code。

- [x] **Step 4: 运行 runner 分片**

运行三分片 offline suite；每片必须有完整 summary、exit 0，无遗留进程或 `.dispatch.lock`。

### Task 4: 独立复审、完整回归与提交

**Artifacts / Locations:**
- Review: 本计划涉及的全部 diff
- Update: `STATUS.md`
- Update: `docs/backlog.md`

- [x] **Step 1: 独立规格复审**

只读 reviewer 检查官方登录通道、MCP 单服务器隔离、token 不可见、无本机 shell/web/子代理、Job/lease 生命周期、双 JSONL fail-closed、runner 归因。Critical/Important 必须清零。

- [x] **Step 2: 完整 gate**

运行 `pwsh -NoProfile -File scripts/check.ps1 -Shards 3`；要求 dispatch、runner 三分片、Android Debug/Release、assembleDebug 和凭据扫描全部 exit 0。

- [ ] **Step 3: 固化提交**

提交一次逻辑变更，记录新 SHA；确认开发 worktree clean。STATUS/backlog 只写“Codex 通道已可再验收、批次 4 仍 0/4 未判定”，不得把旧 run 计为功能失败。

- [ ] **Step 4: 回传旧 C 道**

向任务 `019fe674-b19a-7fa1-853e-d8c4e8fc825f` 回传开发/验证 task id、新 SHA、gate 证据和再验收触发条件。

### Task 5: 新建 clean C 道四腿整轮

**Artifacts / Locations:**
- Create: 新 Codex C 道任务与独立 clean worktree
- Preserve: `C:/Users/Magina/.codex/worktrees/df27/agent-for-mobile` 仅作旧 run 取证

- [ ] **Step 1: 创建新任务**

从新提交 SHA 创建全新 clean worktree；任务说明钉 HEAD、APK 单次构建、runner 单次启动、不得重试或现场开发。

- [ ] **Step 2: 执行同批次顺序**

严格 Allow→Stale→Deny→Reentry；任一 setup/infra/功能失败即停止整组并保留 cleanup 证据。

- [ ] **Step 3: 完成判定**

只有四腿全部有 trace、ledger、manifest、真人确认与独立判据，且 cleanup.ok=true，才可判批次 4 完成；基础设施失败继续与功能结论分离。

- [ ] **Step 4: 双向回执**

新 C 道把最终 run id、HEAD/APK hash、四腿结论和证据路径回传主控；主控再更新 STATUS/backlog。

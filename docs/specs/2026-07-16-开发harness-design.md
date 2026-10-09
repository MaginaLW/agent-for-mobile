# 历史设计摘要：项目开发 harness（会话组织与上下文预算）

- 日期：2026-07-16（用户批准方案 A 并随即实施）
- 现行状态：**已被取代**。开发会话的规则以仓库根 `AGENTS.md` / `CLAUDE.md` 与 [离线开发与验证](../runbooks/离线开发与验证.md) 为准，知识路由见 [knowledge/README.md](../knowledge/README.md)。本页只保留当时的问题与仍在生效的决定，不作操作依据。

## 当时的问题

M0 期间主会话很快撑满上下文：主会话亲自驾机（每轮带截图或大段 UI 树）、无入口文档导致每次重读全部文档、mobile MCP 常驻加载工具 schema、归档内容与常读内容混放。

## 仍在生效的决定

1. **开发会话不直接操作手机**：mobile MCP server 不挂载（`.mcp.json` 与对应预批准已删除，配置移到 `configs/mobile-mcp.json`）。临时单跑与成体系派单见 [执行 harness spec](2026-07-17-执行harness-design.md)。
2. **危险操作两段式确认**作为既定原则交由执行 harness 继承；现行载体见执行 harness spec §5 与 [危险动作统一硬门](2026-07-19-危险动作统一硬门-design.md)。
3. **文档分层、按需读取**：入口文档只放静态规则与指针；动态状态放 `STATUS.md`；沉淀知识放 `docs/knowledge/`；跑测记录归档 `docs/runs/`（只写、按证据指针读）。
4. 规则以规约为主（方案 A）。曾考虑 hooks 机械强制（方案 B），因维护 Windows hook 脚本的成本不划算而放弃，规约失守时再升级。

## 已被替代的细节

- 当时的 CLAUDE.md 骨架、“冷启动 ≤2K token”目标、knowledge 先分 5 册的布局与一次性迁移清单均已完成或被后续入口文档与 knowledge 目录结构替代。
- “手机执行 harness 待立项”的开放问题已由 [执行 harness spec](2026-07-17-执行harness-design.md) 收口。

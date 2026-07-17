# 设计说明：项目开发 harness（会话组织与上下文预算）

- 日期：2026-07-16
- 状态：方案 A 已获批准（用户），随批准即实施
- 决策人：Magina（用户）

## 1. 问题与范围

**问题**：主会话很快达到上下文上限。M0 期间的实测成因，按严重程度：

1. 主会话亲自驾机——任务 2 跑 186 轮、任务 4 跑 35 轮，每轮带截图（约 1–2K token）或 UI 树 dump（重页面 30–100KB）；任务 1/3/5 由主会话 raw adb 代驾，同一会话还兼环境装配与文档写作。
2. 无 CLAUDE.md——每个新会话需重读全部文档（约 12K token）才能上手。
3. mobile MCP server 常驻 `.mcp.json`——每个会话固定加载 24 个工具 schema，哪怕只写文档。
4. 文档只增不分层——归档型内容（跑测记录）与常读型内容混放。

**范围（关键边界，用户 2026-07-16 明确）**：本设计只覆盖**开发这个项目**的 Claude Code 工作环境。「手机执行 harness」（派单脚本、执行通道、token 计量协议）是后续重点，单独立项设计。本次只固定两条边界：

- 开发会话不直接操作手机（mobile server 不挂载）。
- 已定原则「危险操作两段式确认」（临界动作前停下汇报 → 人工确认 → resume/二次派单继续）记录在案，供执行 harness 设计继承。

## 2. 目标

开发会话冷启动时，项目侧自动加载的上下文 ≤ 2K token（CLAUDE.md + STATUS.md），其余全部按需读取；单会话单主题，重探索外移子代理，长输出落盘。

## 3. 方案选择

- **方案 A · 规约版（选定）**：所有规则写进瘦 CLAUDE.md，靠会话遵守。零脚本维护；软约束失守的代价只是浪费一次上下文，可承受。
- 方案 B · 机械版（备选升级路径）：A + hooks（SessionStart 注入状态 / Stop 提醒更新 / PreToolUse 拦截越界工具）。约束硬但要维护 Windows PowerShell hook 脚本，现阶段复杂度不划算。规约失守时再升级。

## 4. 文件布局

```
CLAUDE.md              # 瘦索引 ~50 行（静态规则，内含 @STATUS.md 导入）
STATUS.md              # 动态状态 ~20 行：干到哪/下一步/障碍——每次会话收尾更新
README.md              # 对外门面（保持，链接与里程碑状态更新）
docs/
  specs/               # 设计说明（沿用现有命名惯例）
  runbooks/            # 操作规程（M0-runbook.md 迁入，顶部加环境变更横幅）
  knowledge/           # 沉淀知识，按需加载，宁粗勿细，先 5 册：
    devices.md         #   ROM/adb/输入通道的坑
    apps.md            #   微信/小红书/京东实测特性（M1 内容多了再拆）
    deeplinks.md       #   实测深链库（将来 App 技能包的原料）
    cost.md            #   成本模型与实测校准
    brain-harness.md   #   大脑侧链路知识（headless、按需挂载、两段式原则）
  runs/                # 跑测记录归档（只写不自动读）
    2026-07-16-M0.md   #   M0 测试记录原件（保持原貌，顶部加指针）
configs/
  mobile-mcp.json      # mobile server 配置（从 .mcp.json 摘出）
```

M0 测试记录的处理：**原件整体归档**入 `runs/`（不改写历史），12 条发现**整理常青版**进 knowledge 五册（注明来源）。两处并存是有意的：归档保完整，知识册保可用。

## 5. CLAUDE.md 骨架

- 项目一句话 + 架构一句话 + 指向方向一设计说明 + `@STATUS.md` 导入
- 铁律：合规红线摘要；开发会话不操作手机（临时单跑用 `claude --mcp-config configs/mobile-mcp.json`）；危险操作两段式原则
- 文档地图：按需读表（做什么 → 读什么；runs 只写不读）
- 会话纪律（§6）
- 约定：中文文档与交流；spec 命名惯例；提交惯例

## 6. 会话纪律（写入 CLAUDE.md）

1. 一个会话一个主题，跨主题开新会话。
2. 广探索、长文阅读派子代理（Explore 类），只让结论进主上下文。
3. 构建日志、logcat、长命令输出先落盘再 grep/尾读，不整段读入。
4. 大文件按行区间读。
5. 会话收尾两件事：更新 STATUS.md；新踩的坑写入对应 knowledge 册。

## 7. MCP 卫生

- `.mcp.json` 删除（唯一内容 mobile server 迁至 `configs/mobile-mcp.json`）。
- `.claude/settings.json` 删除（唯一内容是对 mobile 的预批准，随 server 摘除而失效；headless 场景本就用 `--allowedTools` 旁路，见 knowledge/brain/harness.md）。
- 效果：开发会话零 MCP 开销，且物理上杜绝误驾手机。

## 8. 迁移清单

1. `git mv docs/M0-runbook.md docs/runbooks/`，顶部加横幅（配置已变更、挂载方式）并修复相对链接。
2. `git mv docs/M0-测试记录.md docs/runs/2026-07-16-M0.md`，顶部加 knowledge 指针。
3. 写 knowledge 五册（12 条发现 + runbook 中的品牌矩阵要点归册）。
4. 写 CLAUDE.md、STATUS.md、configs/mobile-mcp.json。
5. `git rm .mcp.json .claude/settings.json`。
6. README：M0 里程碑状态更新为完成、链接修正、补文档结构一行。
7. 全库链接完整性检查；一次提交。

## 9. 验证

1. 冷启动测试：新开会话，只靠自动加载内容能在 30 秒内说清「项目是什么、干到哪、下一步干什么」。
2. 链接检查：全部文档相对链接可达。

## 10. 风险与开放问题

| 风险 | 对策 |
|---|---|
| CLAUDE.md 规约失守 | 升级方案 B（hooks 机械强制） |
| STATUS.md 忘更新 | 收尾纪律写入 CLAUDE.md；屡犯再加 Stop hook |
| knowledge 过早拆细 | 先 5 册粗粒度，M1 内容多了再拆 |

开放问题：手机执行 harness 的完整设计（派单脚本形态、计量协议、trace 落盘格式、与 M1 App 确认层的衔接）——下一个 brainstorm 立项，素材已备于 knowledge/brain/harness.md。

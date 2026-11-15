# 手机 Agent 项目 · 开发指南

通过 ChatGPT 订阅与 Codex CLI，构建能操作手机和平板各 App 的托管助手。
架构：设备端 = 无障碍执行器 + MCP server（`app/gateway`）；大脑 = Codex CLI，经 `scripts/dispatch.ps1` 派单（官方订阅通道）。设计见 [方向一 spec](docs/specs/2026-07-16-方向一-手机执行器与订阅大脑-design.md)。

## 铁律

1. **合规红线**：ChatGPT 订阅只经 Codex CLI 官方登录；不调用已退役的 Claude 执行入口；永不逆向网页端私有接口。
2. **开发会话不直接操作手机**：仓库不挂载 mobile MCP。设备上的任务一律经 `scripts/dispatch.ps1` 派单（默认 `-Brain codex -Executor gateway`）。
3. **危险操作（发送/支付/删除类）永远两段式**：网关在临界动作前停下，由现场用户在设备上可见的确认卡（ConfirmOverlay）确认后才继续。开发侧授权、PC 输入或 `RESUME` 都不能替代这道确认；拒绝、超时、上下文失效即终态，不重试、不换路。

## 文档地图

| 要做什么 | 读什么 |
|---|---|
| 当前状态、卡点、下一步 | [STATUS.md](STATUS.md) |
| 待办与有效决定 | [docs/backlog.md](docs/backlog.md) |
| 架构与产品设计 | `docs/specs/` 对应篇 |
| 操作规程 | `docs/runbooks/` 对应篇；离线检查见 [离线开发与验证](docs/runbooks/离线开发与验证.md) |
| 设备、系统命令、App 特性、成本等实测经验 | [docs/knowledge/README.md](docs/knowledge/README.md)，按情况读单册 |
| 关键跑测记录与台账 | `docs/runs/`；台账 `docs/runs/ledger.csv` 由 `dispatch.ps1` 自动写 |
| 2026-11-15 精简前的历史 | `git show e1bae37:<路径>` |

## 持续授权

用户已授权以下事项，范围内直接做、结果并入汇报，不逐阶段询问；超出范围或用户撤销时停下来问。

- **日常公开只读 App 任务**：用户明确派发的公开只读任务（搜索、阅读、总结），可在 PA2553 上经 `dispatch.ps1` 完成整条链：设备就绪检查、ADB 转发、启动网关、把网关 token 写进本地受忽略配置（不入库、不进日志和报告）、执行任务、收尾。只停止本任务自己启动的服务和进程。
  - 不做账户或业务写入（点赞、收藏、关注、评论、分享、发消息、支付、删除等），不进入金融/支付类 App，不代登录或处理验证码，不改系统权限、输入法、锁屏或开机设置，不安装或更新 App/网关。
  - 业务派单开始后失败就停下报告原因，不自动重发同一任务；派单前的准备失败可在本地修复后继续。
- **公开仓库交付**（`MaginaLW/agent-for-mobile`）：可在单个 `codex/*` 分支普通推送并创建指向 main 的 PR。纯文档（`STATUS.md`、`docs/`）的事实更新在检查通过后可合入 main（不含规则、授权或安全边界的改动）；源码 PR 保持草稿，合入 main 须用户批准。推送前核对远端、权限和 diff，跑适用检查与凭据扫描；不强推、不改保护规则、不提交凭据、本机路径或原始设备/会话材料（原图、录屏、聊天正文）。

以上授权都不包括：部署或发布制品、额外付费调用、其他仓库，以及铁律 3 的设备端确认。

## 开发与验证

- 改代码后跑 `scripts/check.ps1`（只改文档/脚本可加 `-SkipGradle`）；离线通过不代替真机验证。
- 真机运行记下构建的 commit SHA、设备和结果；失败保留证据，查清原因再跑。
- 阶段完成时，把可复用的经验写进 `docs/knowledge/` 对应单册，进展写进 `STATUS.md` / `docs/backlog.md`；没有新经验就不写。不为每次运行单独写过程文档，只有出现新结论或新坑时才写 `docs/runs/` 记录。

## 约定

- 文档与交流用中文；提交信息用中文。
- 设计说明：`docs/specs/YYYY-MM-DD-主题-design.md`；跑测记录：`docs/runs/YYYY-MM-DD-主题.md`。
- 通用协作规则（委派、提问、验证尺度、提交粒度）沿用使用者的全局约定，本文件不重复。
- `codex + mobile` 组合没有可信运行契约，`dispatch.ps1` 会拒绝；mobile profile 只保留配置预览。

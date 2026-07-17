# 大脑侧链路知识（headless / 按需挂载 / 两段式）

> 手机执行 harness 的设计素材集；harness 已立项落地（设计：[执行harness spec](../../specs/2026-07-17-执行harness-design.md)，入口 `scripts/dispatch.ps1`）。本册继续记录大脑侧链路的坑与原则。

## 已验证：headless 派单链路（M0 发现 #11）

```powershell
claude -p "<任务提示词>" --output-format json --mcp-config configs/mobile-mcp.json --allowedTools "mcp__mobile"
```

- JSON 输出自带精确 token/成本/轮次——M0 的 $6.44/$1.26 就是这么量出来的。
- ⚠️ 坑：headless 在不信任的工作区会**忽略 settings.json 的 permissions.allow**，必须用 `--allowedTools` 旁路（或先交互跑一次接受信任对话框）。
- 这条链路 = M2「手机上 Termux 跑大脑」的原型：主会话/入口派单，执行会话干活，天然隔离上下文。

## mobile server 按需挂载

2026-07-16 开发 harness 重组后，mobile server 不再常驻项目 `.mcp.json`（开发会话物理碰不到手机）。要跑真机：

```powershell
claude --mcp-config configs/mobile-mcp.json        # 交互式单跑
```

配置在 [configs/mobile-mcp.json](../../../configs/mobile-mcp.json)，版本锁定 `@mobilenext/mobile-mcp@0.0.62`（保证测试数据可比；升级需有意为之并记录）。中文输入依赖手机侧 devicekit APK（现有机制已死，见 [../android/common.md](../android/common.md)）。

## 已定原则（供执行 harness 设计继承）

1. **危险操作两段式派单**（用户 2026-07-16 批准）：执行器停在临界动作（发送/支付/删除）前、汇报屏幕状态后结束；人工确认后用 `--resume <session-id>` 或二次派单继续（手机屏幕状态本身就停在原地，二次派单可行）。
2. 全量 trace 落盘 `docs/runs/`，只让摘要进派单方上下文。
3. 每次派单记录 token/成本（JSON 计量），持续校准 [cost.md](cost.md)。

## 执行 harness（2026-07-17 已落地）

设计与协议全文见 [执行harness spec](../../specs/2026-07-17-执行harness-design.md)。入口 `scripts/dispatch.ps1`，站规 `scripts/prompts/executor-preamble.md`，任务卡 `scripts/tasks/`，台账 `docs/runs/ledger.csv`。

实施期实测的坑（claude 2.1.206）：

- **`--max-turns` 已从 CLI 移除**，机械上限改用 `--max-budget-usd`（wrapper 默认 $2）；轮数只能做站规软预算。
- **会话内派单的环境卫生**：子进程要清 `CLAUDE*` 环境变量（wrapper 已做），否则子会话带着宿主会话标记跑；`ANTHROPIC_BASE_URL` 有意保留——它是回落通道开关，派单认证异常先查它。
- 预检不做 npm registry 探测：国内网络假阴性多；版本锁定靠 configs/mobile-mcp.json，server 启不来会体现为首轮 fail。
- 确认门 `Read-Host` 在非交互 shell 直接抛错（实测）——代理经 Bash/PowerShell 无法代答 CONFIRM，两段式硬门机械成立。

# 大脑侧链路知识（headless / 按需挂载 / 两段式）

> 手机执行 harness 的设计素材集。执行 harness 本身尚未立项（下一个 brainstorm 重点）；本册记录已验证的链路和已定的原则。

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

配置在 [configs/mobile-mcp.json](../../configs/mobile-mcp.json)，版本锁定 `@mobilenext/mobile-mcp@0.0.62`（保证测试数据可比；升级需有意为之并记录）。中文输入依赖手机侧 devicekit APK（现有机制已死，见 [devices.md](devices.md)）。

## 已定原则（供执行 harness 设计继承）

1. **危险操作两段式派单**（用户 2026-07-16 批准）：执行器停在临界动作（发送/支付/删除）前、汇报屏幕状态后结束；人工确认后用 `--resume <session-id>` 或二次派单继续（手机屏幕状态本身就停在原地，二次派单可行）。
2. 全量 trace 落盘 `docs/runs/`，只让摘要进派单方上下文。
3. 每次派单记录 token/成本（JSON 计量），持续校准 [cost.md](cost.md)。

## 待设计（执行 harness 立项时）

派单脚本形态（PowerShell wrapper？）、计量协议、trace 落盘格式、失败重试与步数上限、与 M1 App 确认层的衔接、Codex 对照通道。

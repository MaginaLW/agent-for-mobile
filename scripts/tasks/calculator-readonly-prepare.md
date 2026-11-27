# 计算器只读前置核对

打开计算器并只读核对当前拉起状态、面板模式与可见显示区，写进「关键观察」。未获明确计算指示时不主动按键或清空历史记录。

- 首步直接调用 `skill_macro_exec(name="calculator_readonly_prepare", params={})`（不要前置 `skill_macro_list`、`device_info`、`foreground_app` 或 `skillpack_lookup`）；收到 `data.status="completed"` 后直接消费 `data.final_snapshot` 与 `ctx.app`，禁止紧接着重复调用 `ui_snapshot`。
- 若返回 `data.status="handoff_required"`（如命中系统拦截弹窗或遮挡弹窗），立即按站规停下输出 `[AWAIT_CONFIRM]` 或如实报告。
- **纯只读纪律**：严禁点击删除、清空（C/AC）或无指令按键。

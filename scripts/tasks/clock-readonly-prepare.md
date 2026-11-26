# 闹钟时钟只读前置核对

打开闹钟时钟并只读汇总当前页面可见的闹钟/时钟列表信息（仅限文本摘要，如时间、标签或页面状态），写进「关键观察」。严禁新增、修改、开关或删除任何闹钟，严禁启动或重置计时器/秒表。

- 首步直接调用 `skill_macro_exec(name="clock_readonly_prepare", params={})`（不要前置 `skill_macro_list`、`device_info`、`foreground_app` 或 `skillpack_lookup`）；收到 `data.status="completed"` 后直接消费 `data.final_snapshot` 与 `ctx.app`，禁止紧接着重复调用 `ui_snapshot`。
- 若返回 `data.status="handoff_required"`（如命中系统拦截弹窗或遮挡弹窗），立即按站规停下输出 `[AWAIT_CONFIRM]` 或如实报告。
- **纯只读纪律**：严禁点击开关（`switch`）、新建、编辑或删除按钮。

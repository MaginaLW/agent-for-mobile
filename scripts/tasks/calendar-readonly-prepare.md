# 日历只读前置核对

打开日历并只读核对当前页面结构、当前日期视图或可见日程摘要，写进「关键观察」。严禁新建、修改、删除日程或订阅/导入日历。

- 首步直接调用 `skill_macro_exec(name="calendar_readonly_prepare", params={})`（不要前置 `skill_macro_list`、`device_info`、`foreground_app` 或 `skillpack_lookup`）；收到 `data.status="completed"` 后直接消费 `data.final_snapshot` 与 `ctx.app`，禁止紧接着重复调用 `ui_snapshot`。
- 若返回 `data.status="handoff_required"`（如命中系统拦截弹窗或遮挡弹窗），立即按站规停下输出 `[AWAIT_CONFIRM]` 或如实报告。
- **纯只读与隐私约束**：严禁点击新建、编辑或删除按钮；遇权限弹窗或隐私详情遮挡即停。

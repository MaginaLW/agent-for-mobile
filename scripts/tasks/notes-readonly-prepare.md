# 原子笔记只读前置核对

验证原子笔记只读前置宏能否安全拉起应用并采集首屏结构状态。

- 首步直接调用 `skill_macro_exec(name="notes_readonly_prepare", params={})`（不要前置 `skill_macro_list`、`device_info`、`foreground_app` 或 `skillpack_lookup`）。
- 收到返回后读取 `data.status`、`ctx.app` 与 `data.final_snapshot`：
  - 若 `data.status="completed"`，在终态「关键观察」中**只允许报告**以下 4 项结构元数据：前台包名（`ctx.app` / `data.final_snapshot.package`）、`window_topology`、`blocking_overlay`、可见元素数量（`count`）。
  - 若 `data.status="handoff_required"`（如命中系统拦截弹窗、应用锁或账号登录遮挡），立即停下并按站规输出 `[AWAIT_CONFIRM]` 或如实报告，绝不代登录或解锁。
- **隐私与纯只读硬约束**：严禁在报告中摘录任何私人笔记标题、正文或文件夹内容；严禁点击、输入、新建、编辑、删除或分享笔记，或第二次调用 `ui_snapshot`。

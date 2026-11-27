# 文件管理只读前置核对

打开文件管理并只读核对首屏分类入口与页面结构状态，写进「关键观察」。严禁删除、移动、重命名、压缩、解压、安装 APK 或触发一键清理。

- 首步直接调用 `skill_macro_exec(name="filemanager_readonly_prepare", params={})`（不要前置 `skill_macro_list`、`device_info`、`foreground_app` 或 `skillpack_lookup`）；收到 `data.status="completed"` 后直接消费 `data.final_snapshot` 与 `ctx.app`，禁止紧接着重复调用 `ui_snapshot`。
- 若返回 `data.status="handoff_required"`（如命中系统拦截弹窗或存储权限遮挡），立即按站规停下输出 `[AWAIT_CONFIRM]` 或如实报告。
- **纯只读与隐私约束**：仅报告页面结构与大类入口（不摘录私人文档正文）；严禁点击清理、删除、移动、重命名、安装或分享按钮。

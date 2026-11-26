# 相册只读前置与媒体元信息核对

安全核对相册结构状态或最新媒体元信息，把观察摘要（仅元数据或目录结构）写进「关键观察」。严禁删除、移动、重命名、编辑或分享任何照片/视频。

- 若仅需查询最新照片或截图的文件名、时间与相册名，优先直接调用 `media_query(type="image", limit=5)` 或 `media_query(type="screenshot", limit=5)`（如遇 `E_PERM_MISSING` 立即停下报告缺 `READ_MEDIA_IMAGES` 权限）。
- 若需核对相册 App 页面结构，首步直接调用 `skill_macro_exec(name="gallery_readonly_prepare", params={})`（不要前置 `skill_macro_list`、`device_info`、`foreground_app` 或 `skillpack_lookup`）；收到 `data.status="completed"` 后直接消费 `data.final_snapshot` 与 `ctx.app`，禁止紧接着重复调用 `ui_snapshot`。
- 若返回 `data.status="handoff_required"`（如命中系统拦截弹窗或遮挡弹窗），立即按站规停下输出 `[AWAIT_CONFIRM]` 或如实报告。
- **纯只读与隐私约束**：严禁点击删除、分享、编辑或重命名按钮，严禁向任何第三方应用外发图片。

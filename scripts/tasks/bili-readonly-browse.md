# 哔哩哔哩公开视频列表只读浏览

打开哔哩哔哩，直接从公开首页或推荐列表浏览并汇总 5 条不同视频的标题与可见信息（如 UP 主、播放量或时长，每条一行写进「关键观察」）。

- 首步直接调用 `skill_macro_exec(name="bili_readonly_prepare", params={})`（或已转正的深化只读宏 `bili_readonly_feed_prepare`；不要前置 `skill_macro_list`、`device_info`、`foreground_app` 或 `skillpack_lookup`）；注意从工具返回 JSON 的 `ctx.app` 与 `data.final_snapshot` 读取字段。收到 `data.status="completed"` 后直接消费 `data.final_snapshot` 中的列表元素，禁止紧接着重复调用 `ui_snapshot`。
- 若 `data.final_snapshot` 中不足 5 条公开视频，可对 `role=list` 且 `flags` 含 `S` 的列表容器执行一次 `scroll(direction="forward")` 后再调用一次 `ui_snapshot(scope="full")` 补足；跳过广告或直播推广卡片。
- 若返回 `data.status="handoff_required"`（如命中系统拦截弹窗或强制遮挡登录弹窗），立即按站规停下输出 `[AWAIT_CONFIRM]` 或如实报告，绝不代登录或处理验证码。
- **纯列表只读纪律**：严禁点击 `text=""` 且 `desc=""` 的无标签卡片或进入视频播放页；严禁点赞、投币、收藏、关注、发评论/弹幕或触发大会员/充值页。

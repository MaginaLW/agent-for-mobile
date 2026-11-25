# 微信只读前置宏验证

验证微信只读前置宏能否安全拉起微信并采集首屏结构状态。

- 首步直接调用 `skill_macro_exec(name="wechat_readonly_prepare", params={})`（不要前置 `skill_macro_list`、`device_info`、`foreground_app` 或 `skillpack_lookup`）。
- 收到返回后读取 `data.status`、`ctx.app` 与 `data.final_snapshot`：
  - 若 `data.status="completed"`，在终态「关键观察」中**只允许报告**以下 4 项元数据：前台包名（`ctx.app` / `data.final_snapshot.package`）、`window_topology`、`blocking_overlay`、可见元素数量（`count`）。
  - 若 `data.status="handoff_required"`（如命中 `LOGIN_WALL` 或 `SYSTEM_BLOCKER`），立即停下并按站规输出 `[AWAIT_CONFIRM]` 或如实报告，绝不代登录或处理验证码。
- **隐私与纯只读硬约束**：严禁报告任何联系人名称、群聊名称或消息正文内容；严禁执行任何点击（`click`）、滚动（`scroll`）、输入（`type_text`）、发送，或第二次调用 `ui_snapshot`。

# IME 单命名空间降级链 · 只读诊断任务卡

目的：验证 2026-07-25 新增的 IME 单命名空间降级门在真机上能否成链。
**本任务不发送任何消息、不按 Enter、不触发任何危险动作。**

前提：微信已由现场用户手动停在「文件传输助手」会话页，输入栏为文字模式且文本框为空。

按顺序做，任一步失败就立即停下并按第 8 条格式报告失败：

1. 调用一次 `foreground_app`，确认前台是 `com.tencent.mm`。不是就直接报失败，不要自己去导航。
2. 调用一次 `keyboard_state`，记录输入法是否为「执行网关」、InputConnection 是否可用。
3. 调用一次 `ui_snapshot(scope="interactive")`，记录三件事并原样抄进「关键观察」：
   - `focused_identity_source` 字段的值（期望 `ime_only`）；
   - `focused_input_id` 是否为 null；
   - a11y 来源的元素有几个、分别是什么（期望只有状态栏那一批，会话标题/气泡/输入框都来自 ocr）。
4. 调用一次 `macro_run(name="p0_wechat_file_transfer_prepare")`。这是本次诊断的核心：
   - 成功时，把返回里的 `identity_source`、`input_focused`、`focused_input_id`、`ime_session_id`、
     `focused_input_bounds`、`coordinate_fallback_used` 原样抄进「关键观察」；
   - 失败时，把错误码与完整错误消息原样抄下来（尤其 `focus_ready` 超时里列出的缺失条件逐条抄全），
     这比"跑通"更有诊断价值。
5. 到此为止。**不要调用 `type_text`，不要调用 `press_key`**，不要为了让宏成功而自行点击或改屏幕状态。

「新坑」一栏写：这台机器上微信会话页的 a11y 树实际形态与你观察到的差异（若与上面预期不符）。

# IME 降级链 · prepare → type_text 只读诊断（不发送）

目的：定位 `type_text` 前"已准备目标已变化"的具体差异项。
**本任务只把文字打进输入框，绝不发送：禁止调用 `press_key`（尤其 enter），不点任何发送控件。**

前提：微信已由现场用户手动停在「文件传输助手」会话页。

1. 调用一次 `macro_run(name="p0_wechat_file_transfer_prepare")`。把返回里的
   `identity_source`、`ime_session_id`、`focused_input_id` 原样抄进「关键观察」；失败就抄错误码与完整消息后结束。
2. **紧接着**（中间不要插入任何其他工具调用，包括 ui_snapshot）调用一次
   `type_text(text="P0降级链诊断", mode="replace")`。
   - 成功：把返回的 `channel`、`committed`、`verified`、`readback` 原样抄进「关键观察」；
   - 失败：把错误码与**完整错误消息**原样抄下来（消息现在会逐条点名哪一项对不上，务必抄全，
     不要概括）。这比成功更有诊断价值。
3. 到此为止。**不要调用 `press_key`**，不要重试 `type_text`，不要为了让它成功而改屏幕状态。

「新坑」一栏写：若 `type_text` 失败，消息里点名的是哪一项（前台包 / 身份来源 / IME 会话 / a11y 节点 / 焦点位置 / TTL）。

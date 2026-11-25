# 哔哩哔哩（tv.danmaku.bili）

> 来源：PA2553 真机实测（2026-11-25，[2026-11-25-PA2553-B站只读宏验收.md](../../runs/2026-11-25-PA2553-B站只读宏验收.md)；2026-11-26，[2026-11-26-PA2553-阶段5A深化宏与冷态起服验收.md](../../runs/2026-11-26-PA2553-阶段5A深化宏与冷态起服验收.md)）。已转正 `bili_readonly_prepare.json`（`verified: "2026-11-25"`）与 `bili_readonly_feed_prepare.json`（`verified: "2026-11-26"`）。

## PA2553 实测结论（2026-11-25 至 2026-11-26）

- **公开列表免登录可读**：PA2553 上无需登录即可通过 `bili_readonly_prepare` 5/5 步稳定拉起首页公开推荐流；跳过首页顶栏非阻断入口后，经 1 次列表滚动直接汇总出 5 条不同视频的标题、UP 主、播放量与时长（`35s / 151,966 in_tok`、`result=success`、0 `ConfirmOverlay`、0 `E_VERIFY_FAIL`/0 `E_BLOCKED`）。
- **深化只读前置宏 `bili_readonly_feed_prepare`（2026-11-26 转正）**：在首页稳定后以 `optional + save_ref` 探测「暂不开启」推送弹窗，并借助 `skip_if_ref_missing` 在弹窗未出现或非唯一匹配时安全跳过 `ui_action`；PA2553 实测 `m3-bili-feed-promote-20261125` 1 轮 **`27s / 50,739 in_tok` `result=success`**（`skipped_steps=["find_dismiss_push_prompt","dismiss_push_prompt"]`，0 `ConfirmOverlay`），直接消费 `final_snapshot` 汇总 5 条公开视频，晋级 `verified: "2026-11-26"`。
- **应用内推送提示**：宏返回后若首页出现「开启推送通知」提示，执行器具名点击「暂不开启」即可继续读取推荐列表（不触发确认卡）。
- **系统跳转拦截**：从网关主界面冷启动跳转哔哩哔哩时可能命中 vivo `com.vivo.appfilter` 弹窗，宏引擎准确返回 `handoff_required(blocker_detected=true)` 并由大脑以 `[AWAIT_CONFIRM]` 优雅暂停，待现场用户放行后重跑即可一次完成。

## 接入边界与只读规则

- **`login_wall_keywords` 避坑**：`apps.json` 仅配置明确阻断词（`手机号登录`、`扫码登录`、`一键登录`、`请先登录`、`登录后即可`），切勿写入裸词 `"登录"` 以免把顶栏非阻断入口误判为登录墙。
- **纯列表浏览纪律**：仅汇总公开列表卡片已有的标题、UP 主、播放量或时长摘要；严禁点击无标签卡片或进入播放页，不点赞、不投币、不收藏、不关注、不发弹幕/评论，不进入大会员或付费充值页。
- **阻塞处理**：遇 `com.vivo.appfilter` 等系统拦截弹窗或强制遮挡登录弹窗立即停下交现场用户处理，绝不代登录或处理验证码。

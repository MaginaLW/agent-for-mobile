# M0-3 小红书搜索并总结

打开小红书，搜索「东京三日游」，浏览前 5 条笔记的标题与要点，在报告「关键观察」里逐条汇总（每条一行）。

- 首步直接调用 `skill_macro_exec(name="xhs_search_prepare", params={"keyword": "东京三日游"})`（不要前置 `skill_macro_list`、`device_info`、`foreground_app` 或 `skillpack_lookup`；只有任务明确要求从现有结果页接读时才跳过宏）。收到 `data.status="completed"` 且附带 `data.final_snapshot` 后，直接消费 `data.final_snapshot` 与 `ctx.app`，禁止紧接着重复调用 `ui_snapshot`；若首屏上方是 AI 综合攻略，直接对 `data.final_snapshot` 中的笔记列表容器（`role=list` 且 `flags` 含 `S`）执行一次 `scroll(direction="forward")` 后再读 `ui_snapshot`。若宏返回 `data.status="handoff_required"` 且 `data.handoff_allowed=true`，再按下方常规规则断点接管。
- 手工兜底（仅在宏未执行或返回 `data.status="handoff_required"` 时使用）：先核对前台。若已在小红书，从可见搜索入口输入「东京三日游」，读回关键词后提交并核对结果页；若不在小红书，可用深链 `xhsdiscover://search/result?keyword=%E4%B8%9C%E4%BA%AC%E4%B8%89%E6%97%A5%E6%B8%B8` 启动，深链未落地先核前台，遇系统弹窗即停下交给现场用户。
- 纯列表摘要优先：跳过 AI 综合攻略与广告，直接根据列表卡片的标题与正文摘要归纳要点并逐条标明「列表摘要」；若当前可见笔记不足 5 条，向下滚动 `role=list`（`flags` 含 `S`）的列表容器获取后续卡片。**严禁点击无标签卡片按钮（`text=""` 且 `desc=""`）进入详情页**（其包含嵌套可交互子节点且会触发 ConfirmOverlay）；若某卡片仅有标题而无足够摘要，直接跳过并读取/滚动下一条，若最终不足 5 条则如实报告实际读到的条数。
- 结果页先核对分类。若出现用户卡片，选择「全部」或「笔记」后再读。滚动时选择笔记列表，整页容器可能会翻到相邻分类。
- 横屏同应用平行视界下（`window_topology=same_app_multi`），可结合元素的 `pane=left/right` 区分左侧列表与右侧详情直接阅读，减少反复返回。
- 只读纪律：不点赞、不评论、不关注、不下载；详情页图片区**双击=点赞**，一律单击。
- 单窗竖屏模式下，「进详情 → 返回 → 进下一条」的多步模式已实测可行（feed 位置会精准恢复）。

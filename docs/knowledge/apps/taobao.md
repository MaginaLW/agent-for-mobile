# 淘宝（com.taobao.taobao）

> 来源：PA2553 真机实测（2026-11-18，[2026-11-18-PA2553非微信主验收.md](../../runs/2026-11-18-PA2553非微信主验收.md)；2026-11-26，[2026-11-26-PA2553-阶段5A深化宏与冷态起服验收.md](../../runs/2026-11-26-PA2553-阶段5A深化宏与冷态起服验收.md)）。已转正 `taobao_readonly_prepare.json`（`verified: "2026-11-25"`）与 `taobao_orders_prepare.json`（`verified: "2026-11-26"`）。

## PA2553 物流查询实测（2026-11-18、11-24 至 11-26）

- 首轮无现场协助完成查最近一笔订单物流状态（显示「已签收」）：`app_launch("淘宝")` 起手后经 UI 导航直达「全部订单」核对明确签收状态，全轮 11 次工具调用、耗时 90 秒（含 438k 合计三轮中的淘宝单轮）。
- 常见已验证 UI 路径：我的淘宝 → 我的订单 / 全部订单 → 查看物流（或订单卡片直接显示「已签收」等物流状态）。
- **闪购/外卖与已关闭订单边界（2026-11-24/25 归因与单变量诊断）**：
  - 2026-11-24 `r3-taobao-readonly-20261124` 点击「查看物流」回到订单列表的原因已由用户确认：该笔「交易成功」订单实为**淘宝闪购/外卖订单**，无快递物流详情页，点击「查看物流」后会回弹回订单列表。
  - 2026-11-25 `r3-taobao-logistics-diag-20261125` 实测（`TBMainActivity` `foreground_window_id=515`）：`全部订单` 页列表为 `list/S`，卡片含状态关键词（如 `交易关闭`、`交易成功`）与分类标签 `待收货`；对顶部 `交易关闭` 订单点击 `更多` 弹出浮窗（`foreground_window_id=528`）后，菜单**仅暴露 `删除订单`（`button/C`）而无 `查看物流`**。
  - **执行规则**：查快递物流时**跳过闪购/外卖订单与 `交易关闭` 订单**，优先进入 `待收货` 标签或核对明确实物快递订单卡片；**严禁触碰 `删除订单`**。
- 前置宏与守卫：查订单物流优先首步调用 `skill_macro_exec(name="taobao_orders_prepare", params={})`（`verified: "2026-11-26"`）直达「全部订单」页，或使用首页兜底宏 `taobao_readonly_prepare`（`verified: "2026-11-25"`），直接消费返回的 `data.final_snapshot` 与 `ctx.app`；若被系统拦截弹窗（如 `com.vivo.appfilter`）阻断或进入账号登录墙，立即按站规停止并如实报告前置条件，绝不代登录或处理验证码。
- **深化订单宏 `taobao_orders_prepare` 选择器边界与转正（2026-11-26，`verified: "2026-11-26"`）**：首轮 PA2553 实测（`m3-taobao-orders-promote-20261125`）发现淘宝首页底栏同时存在 `role=button, desc="我的淘宝", flags="C"` 与子节点 `role=text, text="我的淘宝", flags=""`，导致 `ui_find(text="我的淘宝")` 双命中未写入 `save_ref`；且「我的淘宝」页订单入口真实节点为 `role=button, desc="我的订单全部", flags="C"`（同页另一含「订单」按钮为 `desc="订单评价"`）。收窄为 `ui_find(role="button", desc="我的淘宝", scroll_search=false)` 与 `ui_find(role="button", desc="我的订单", scroll_search=false)` 后，复测 `m3-taobao-orders-promote-r2-20261126`（`c4ae700`，[验收记录](../../runs/2026-11-26-PA2553-阶段5A深化宏与冷态起服验收.md)）以 11/11 子步全 `OK`、`25s / 52,530 in_tok`（0 `ConfirmOverlay`）直达「全部订单」页，正式转正。
- 只读纪律：严禁点击下单、立即购买、去结算、支付或跳转支付宝等危险/黑名单路径。
- 深链候选（🔵 未实测）：`taobao://`、`taobao://s.taobao.com?q=<词>`，均标 `🔵 未实测`（`deeplinks.json` 中 `verified: ""`），见 [deeplinks.md](deeplinks.md)。

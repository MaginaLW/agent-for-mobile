# 淘宝查订单物流（只读）

打开淘宝，查看最近一笔有物流记录的订单状态，把结果写进「关键观察」。只读：严禁下单、立即购买、去结算、支付或跳转支付宝。

- 首步优先调用 `skill_macro_exec(name="taobao_readonly_prepare", params={})`；收到 `status="completed"` 后直接消费返回的 `final_snapshot` 继续后续只读导航，避免紧接着重复调用 `ui_snapshot`。若宏返回 `handoff_required`，再按下方常规规则断点接管。
- 手工兜底（仅在宏未执行或返回 `handoff_required` 时使用）：先调 `skillpack_lookup(app="淘宝")` 核对前置守卫与深链状态（`taobao://` 尚属未实测候选，优先使用 `app_launch(name="淘宝")`）；启动后先核对前台包名，若遇系统拦截弹窗或账号登录墙（且尚未调用任何危险工具），立即按站规停下输出 `[AWAIT_CONFIRM]` 或如实报告，绝不代登录或处理验证码。
- 推荐只读路径：我的淘宝 → 我的订单 / 全部订单 → 查看物流（若订单卡片已明确显示「已签收」等物流状态可直接读回核对）。

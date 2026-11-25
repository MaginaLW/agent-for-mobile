# M0-5 查京东订单物流

打开京东，查看最近一笔订单的物流状态，写进「关键观察」。只读：不下单、不进任何支付页面。

- 首步优先调用 `skill_macro_exec(name="jd_readonly_prepare", params={})`；收到 `data.status="completed"` 后直接读取 `ctx.app` 与返回的 `data.final_snapshot` 继续后续只读导航，避免紧接着重复调用 `ui_snapshot`。若宏返回 `data.status="handoff_required"`（如 `LOGIN_WALL` 或 `SYSTEM_BLOCKER`），立即停下输出 `[AWAIT_CONFIRM]` 或如实报告前置条件，严禁代登录或处理验证码。
- 手工兜底（仅在宏未执行或非登录墙/系统拦截的断点接管时使用）：先调 `skillpack_lookup(app="京东")` 核对前置守卫与深链状态（`openapp.jdmobile://` 尚属未实测候选，优先用 `app_launch(name="京东")`）；启动后先核对前台包名，若遇系统拦截弹窗阻断或进入账号登录墙（未调用任何危险工具时），同样立即按站规输出 `[AWAIT_CONFIRM]` 或如实报告，严禁代登录或处理验证码。
- 已验证路径：京东 → 我的 → 全部订单 → 订单详情 → 更多 → 查看物流。
- ⚠️「更多」弹出菜单里**「删除订单」与「查看物流」相邻**，点击前务必二次确认落点。
- 京东首页动画重，UI 树可能取不到（M0 实测 uiautomator 超时），预期部分依赖截图。

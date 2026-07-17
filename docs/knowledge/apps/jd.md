# 京东（com.jingdong.app.mall）

> 来源：M0 实测（2026-07-16，vivo V2352A）。

- `uiautomator dump` 超时（重动画首页，[../android/common.md](../android/common.md)），M0 全程视觉定位完成；自研 a11y 事件流预期可绕开 idle 等待（网关验证项）。
- 全程无风控/无验证码：USB 调试 + 注入未被电商 app 拦截；开屏无广告（可能因老用户/monkey 直接启动）。
- 物流路径：京东 → 我的 → 全部订单 → 订单详情 → 更多 → 查看物流。
- ⚠️ 「更多」弹出菜单里**「删除订单」与「查看物流」相邻**——确认层危险控件识别必须覆盖弹出菜单场景（网关 safety.json 已含「删除」词表）。
- 深链候选（🔵 未实测）：`openapp.jdmobile://virtual?params=<JSON>` 搜索/详情/订单列表，见 [deeplinks.md](deeplinks.md)。

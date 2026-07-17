# 微信（com.tencent.mm）

> 来源：M0/M0.5 实测（2026-07-16/17，vivo V2352A）。原始记录：[../../runs/2026-07-16-M0.md](../../runs/2026-07-16-M0.md)。

## 感知通道

- **uiautomator 通道下无障碍树恒空**：`mobile_list_elements_on_screen` 在微信内始终返回空，只能截图+视觉定位 → 微信类任务在 M0 是纯视觉任务，成本高一个数量级（见 [../brain/cost.md](../brain/cost.md)）。
- ⭐ **该结论绑定在 uiautomator 通道上**：自研 AccessibilityService（flags 拉满）能否读到微信树 = Spike S1（收益弹性最大的单一未知数），结果回填此处。

## 操作坑（实测）

- M0 发生 2 次误触（点开联系人资料页、点开聊天内敏感 PDF），均立即退出无改动。成因：键盘弹出坐标错位 + 视觉定位偏差。→ 网关已内建：敏感对话/文件黑名单、点击前二次校验、键盘状态感知。
- 发送闭环可行（ASCII 消息实测成功）；中文输入卡在 devicekit 剪贴板机制（见 [../android/common.md](../android/common.md)）→ 等网关 IME 通道复测。
- **聊天列表条目点击偶发不导航**（M0.5 复测：坐标正确也可能不进会话，两次单击无效）；跨 app 发图更稳的路径是系统分享面板 → 微信。
- **微信内相册选择器的「截屏」下拉筛选会回弹**（M0.5 复测 3 次复现，烧 ~10 轮）→ 选图环节改走系统相册 App 或 media_query+share_file（网关新链路）。
- **vivo 相册 App（com.vivo.gallery）a11y 树完整可用**：相册 → 截屏 → 打开图片 → 分享 → 微信 → 文件传输助手，全程元素定位，已实测走通——跨 app 图片任务的推荐兜底路径。

## 深链 / 分享（🔵 待验证项见 [deeplinks.md](deeplinks.md)）

- **无公开「直达指定聊天」深链**；`weixin://dl/*` 多已失效——微信类任务以 UI/分享通道为主。
- 分享直达组件 `com.tencent.mm.ui.tools.ShareImgUI`（🔵 现版本有效性 = Spike S5，结果回填技能包 apps.json）。
- 通知 RemoteInput：预期国内版无直接回复（Spike S5 实证）。

## 安全

- 「文件传输助手」自发自收零风险，站规白名单免确认（harness 决策点 5）；其余联系人的发送均为危险级走两段式。

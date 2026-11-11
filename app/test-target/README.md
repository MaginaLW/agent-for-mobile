# 本地测试靶标

独立包 `dev.magina.testtarget`，仅合成页面，无权限、账号、网络、Provider 或真实发送能力。构建入口为 `:test-target:assembleDebug`；运行在隔离 API 36 模拟器，构建继续使用工程已有 compile/target 35。主工程通过 `-PlocalTestbench=true` 显式纳入本模块；默认构建和 C1b 隔离构建不应因此扩大。

固定深链 `agent-testbench://target/<route>`，route 为 `list`、`search`、`conversation`、`opaque`、`degenerate`、`ime`。列表→搜索→会话保留真实 UI 路径；自动台架可通过既有 `intent_send` 的 VIEW 深链路由进入各页，不将它冒充实际点击导航覆盖。

会话页输入框、发送按钮和回调计数分别使用 `target_composer`、`target_send`、`target_action_count` 资源 ID。发送按钮只增加本 Activity 的内存计数；新页面/Activity 重建会重置，不出网、不写业务存储。用于证明未经确认时 callback 仍为 0，或现场真人允许一次后恰好为 1；测试器不得自点 gateway 确认卡。

`opaque` 仅造隐藏可访问子树的 Canvas 内容；`degenerate` 仅提供一个不可见、零矩形的应用节点。系统可能裁剪/规范化这些声明，实际结果必须由 gateway 采样核对；均不证明重现微信系统 root。`ime` 仅请求系统显示键盘，不证明实际可见性。系统窗口 type=-1、枚举截断、OriginOS 多窗/IME 悬浮形态留宿主语料变异或真机差异验证，不能由普通 App 伪造。

完整边界与链路见[本地测试台设计](../../docs/specs/2026-11-11-本地测试台-design.md)。模块本身不授予安装、设备操作或生产执行许可。

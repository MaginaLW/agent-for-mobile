# 本地测试靶标

独立包 `dev.magina.testtarget`，仅合成页面，无权限、账号、网络、Provider 或真实发送能力。构建入口为 `:test-target:assembleDebug`；运行在隔离 API 36 模拟器，构建继续使用工程已有 compile/target 35。主工程通过 `-PlocalTestbench=true` 显式纳入本模块；默认构建和 C1b 隔离构建不应因此扩大。

固定深链 `agent-testbench://target/<route>`，route 为 `list`、`search`、`conversation`、`stale-conversation`、`opaque`、`degenerate`、`ime`、`ime-only`。列表→搜索→会话保留真实 UI 路径；自动台架可通过既有 `intent_send` 的 VIEW 深链路由进入各页，不将它冒充实际点击导航覆盖。

R5受控失败候选另用 `dev.magina.testtarget.R5NoDisplayActivity`：`ACTION_VIEW`、package 定向 `dev.magina.testtarget`、URI 必须完整匹配 `agent-testbench://r5/finish?nonce=r5-<32个小写十六进制字符>`，不接受其他参数、片段、编码或任意文本。独立 filter 不落原 MainActivity；gateway 的显式 component 受技能包注册限制，台架不能为此改生产注册表。该 Activity 使用平台 `Theme.NoDisplay`，有效请求只追加接收记录，并在 `onCreate` 的 `finally` 中调用 `finish()`，没有 UI、替代启动或网络。无效请求直接结束且不记记录。独立 `taskAffinity=dev.magina.testtarget.r5_finish` 避免 gateway 的 NEW_TASK 复用普通靶标页面的任务；[Android任务规则](https://developer.android.com/guide/components/activities/tasks-and-back-stack#HandlingAffinities)说明同 affinity 的既有任务可被复用。Android [Theme.NoDisplay](https://developer.android.com/reference/android/R.style#Theme_NoDisplay) 面向恢复前自行结束的无界面 Activity；[Activity.onCreate](https://developer.android.com/reference/android/app/Activity#onCreate(android.os.Bundle)) 允许在其中 `finish()`。这只支持候选设计，不静态保证前台采样不会瞬时命中或必然产生 timeout。

接收记录为应用私有 `files/r5-finish-receipts.jsonl`，通过已授权台架的 `run-as dev.magina.testtarget cat files/r5-finish-receipts.jsonl` 只读提取；只记录严格合成 nonce，不记录任意 URI/extras。每次有效 `onCreate` 追加一行 JSON，字段固定为 `schema=1`、`source=test_target_onCreate`、`scenario=r5_no_display_finish`、`nonce`、`package=dev.magina.testtarget`、`component=dev.magina.testtarget.R5NoDisplayActivity`、`pid`、`process_start_elapsed_realtime_ms`、`received_elapsed_realtime_ms`。两个时间均用同次 Android 启动的 elapsed realtime 毫秒；记录不自动去重或覆盖，重复 nonce 必须由 host 判失败，不能悄悄复用旧行。host 要先核非靶标前台及该 nonce 无历史行，再将本次唯一新增行与调用时间和原 gateway audit 对应。此记录只证明自有合成入口收到请求，是应用自报，不能当作系统独立来源、前台未到达证明或原第三方强负例。真实 `E_VERIFY_FAIL`/timeout、audit 对应及前台轮询仍待新固定候选和独立运行许可；整体 R5 不因此关闭。

search 路由在初始化完控件与监听器后，让可聚焦的内容容器请求输入焦点，避免 EditText 自动成为初始输入焦点；这只作用于 search，不改变 ime 路由。`target_search_focus` 显示 `输入框焦点：true/false`，初始及变化后都读取实际 `search.hasFocus()`，不硬编码未聚焦。该标签只观测输入焦点；gateway 现行 `ui_action focus` 使用 `ACTION_ACCESSIBILITY_FOCUS`，不能将无障碍焦点与输入焦点混为同一判据，实际动作结果与状态仍需台架核对。

同一 search 场景渲染时，通过 `AccessibilityManager.isTouchExplorationEnabled()` 只读取得实际状态并显示 `触摸探索：true/false`；不增加权限、Service 或状态写入，也不宣称该标签持续监听后续变更。触摸探索关闭时，无障碍 focus 的拒绝属于待核对的负向能力结果，不计为动作成功；可独立用真实 `set_text` 和精确读回验证受控输入正向链。旧 run04 未读取该状态，不能由新标签倒推旧轮的唯一根因。

`ime-only` 是独立的输入通道靶标：真实 EditText（ID `target_composer`）只对无障碍 `ACTION_SET_TEXT` 返回 false，其余无障碍行为继续调用父类；没有覆盖或伪造 `InputConnection`，保留普通 IME `commitText`、焦点与可访问文本。页面直接请求输入焦点和显示当前 IME，省掉一次点击；这不切换或启用输入法，也不证明 IME 实际就绪。`无障碍 SET_TEXT 拒绝次数：N` 只在实际 SET_TEXT 回调被拒绝时递增，新页面实例为零。页面没有发送按钮，也不自行写入输入文本；IME 正向验证必须同时核对 gateway 实际返回 `channel=ime_commit` 与输入框精确文本，不能只凭拒绝计数或手填文本声称走过 IME。本新增源码尚不是已安装包或 F3 设备写入许可。

会话页输入框、发送按钮和回调计数分别使用 `target_composer`、`target_send`、`target_action_count` 资源 ID。发送按钮只增加本 Activity 的内存计数；新页面/Activity 重建会重置，不出网、不写业务存储。用于证明未经确认时 callback 仍为 0，或允许一次后恰好为 1；默认无人链不点 gateway 确认卡。自有合成UI子项若另获明确computer-use许可，须按实际操作者记录为自动化UI证据，不计真人允许，也不据此扩大未来、真实业务或生产权限。

`stale-conversation` 复用会话布局和真实本地发送按钮，只此路由额外保存应用私有 `files/stale-callback-state.json`：初始化计数 0 时写一次，每次真实按钮回调先递增计数、再写状态，写失败向上传递。JSON 固定字段为整数 `schema=1`、`process_id`、`page_generation`、`page_generated_elapsed_realtime_ms`、`callback_count`，及字符串 `activity_instance`（每个 Activity 实例随机 UUID）。每次渲染此路由递增 generation，生成时间为 Android elapsed realtime 毫秒；Activity 重建换实例 UUID。这是应用自报的本地回调计数，不是系统独立来源。host 在切离目标前后通过 `run-as dev.magina.testtarget cat files/stale-callback-state.json` 各只读一次，必须核对相同 PID/实例/generation/生成时间且计数均为 0；后台不得以 snapshot 或重开会话读取计数，重路由或重建后的新零值不能代替原实例的零回调证据。普通 `conversation`、`ime` 及其他路由不创建、更新或删除此文件；旧文件存在本身不证明当前路由或同一实例。

`opaque` 仅造隐藏可访问子树的 Canvas 内容；`degenerate` 仅提供一个不可见、零矩形的应用节点。系统可能裁剪/规范化这些声明，实际结果必须由 gateway 采样核对；均不证明重现微信系统 root。`ime` 仅请求系统显示键盘，不证明实际可见性。系统窗口 type=-1、枚举截断、OriginOS 多窗/IME 悬浮形态留宿主语料变异或真机差异验证，不能由普通 App 伪造。

完整边界与链路见[本地测试台设计](../../docs/specs/2026-11-11-本地测试台-design.md)。模块本身不授予安装、设备操作或生产执行许可。

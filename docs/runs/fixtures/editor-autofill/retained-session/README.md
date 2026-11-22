# 保留自动填充会话后切换输入法

2026-11-22，API 36 的合成右框在切换输入法前后始终持焦，自动填充会话也始终为 `ACTIVE`。新输入连接收到探针，框架仍未发起第二次结构请求。此前空响应会使会话结束；本场补测了会话仍存活的条件。[空响应对照](../README.md#持焦切换时的客户端方法轨迹)

| 时段 | 系统、靶应用与观察器的独立读数（设备单调时间，毫秒） |
|---|---|
| 原输入法下右框首次持焦 | 会话 1545867361 启动时响应过期位为 `false`。请求 896 在 110616–110617 采集结构，111064 到达观察器。靶应用在 110622 记录右框已经持焦、有连接、探针为 0。观察器于 111197 返回无数据集、无保存字段的响应。 |
| 保持同一 Activity 和右框，切换到实验输入法 | 第 1 代输入连接于 127286 建立，靶应用于 127291 记录右侧探针 1、左侧 0。切换前后的客户端均为同一活动会话，系统均只有响应 896。靶进程的方法轨迹中，两框合计新增 `onProvideAutofillStructure` 调用 0；系统新增结构请求、派发、服务回调均为 0。宿主观察 14.099 秒，取得靶回执后留观 7.642 秒。`UNKNOWN / NO_NEW_CALLBACK`，该连接的结构采集时间、选中侧和四边均为空。 |
| 窗口结束后的独立自然聚焦正控 | 在同一进程另建合成 Activity。原会话在 155837 的 `VIEW_EXITED` 事件报告过期位已为 `true`。新会话 1867638957 产生请求 898，实验输入法第 3 代于 155994 建立，结构于 156011–156012 采集，156040 到达。采样前后同代。两框结构写入合计 2 次，选中的右框 `[2100,32,2300,102]` 与该 Activity 实测相符。 |

两场手动自动填充请求、触摸与 `restartInput` 均为 0。主场靶回执中的左、右两框各有一次结构写入，属于首次自然请求。切换阶段的单独方法轨迹给出新增量。系统详细日志在切换窗口内没有过期位读数，首次后验读数来自原会话退出右框时，因此其赋值时刻未知。Android 16 源码在相应条件满足时把旧响应标记为过期，后续字段进入可触发新请求。本次右框持续持焦期间没有新的进入调用。[输入法切换处理](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-16.0.0_r1/services/autofill/java/com/android/server/autofill/Session.java#L674-L718)

实验输入法和自动填充服务均在清单元数据声明支持内联建议。请求 896 的 `getInlineSuggestionsRequest()` 为空。切换窗口中实验输入法创建内联请求的回调为 0。正控中这一回调在 155992 实际发生，请求 898 的同一字段有值。两个填充响应都没有数据集或内联展示内容。观察器只提供 `SaveInfo.FLAG_DELAY_SAVE | FLAG_DONT_SAVE_ON_FINISH`，系统两次读回旧响应均为 `datasets=[]`、`requiredIds=null`、`flags=6`。观察日志未出现保存回调。Android 16 的空响应判断会考虑延迟保存标志。[公开 SaveInfo 标志](https://developer.android.com/reference/android/service/autofill/SaveInfo.Builder#setFlags(int)) · [系统响应判定](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-16.0.0_r1/services/autofill/java/com/android/server/autofill/Session.java#L2080-L2111)

这些结果覆盖由系统选作自动填充服务的实验应用及其真实 `AssistStructure` 回调。只有当前输入法身份的应用无法返回该服务的 `FillResponse`。实验未改变生产网关的角色或设备服务设置。光标锚点、输入连接返回的原点及无障碍树分别有自己的来源和关联条件。[既有 IME 几何实验](../../editor-origin/README.md)

## 复现与原件核对

1. 用 `python prepare_observer.py <全新观察器源码目录>` 从上一级观察器生成单独变体。该变体复用原来的靶包校验、自动回调、采集时刻和代次判定，只在两个自然观察阶段返回 [RetainedReply.java](RetainedReply.java) 的响应，另为两组件启用内联协议。两份主体 APK 的实装 SHA-256 分别为靶应用 `42f7e09634e876d125c27085cc23a982c99c1e3bd323c5066203fb1e69049451`、观察器 `1b9d554cdc5c9493254c119c53b0406527223f03aea5b45e3d186f50bb2d52a0`。重新签署会改变观察器摘要。
2. 沿用[双场隔离运行与方法跟踪](../README.md#持焦切换时的客户端方法轨迹)。保存两次 `dumpsys activity dev.magina.autofilltarget`、`dumpsys autofill`、带阶段标记和 `RetainedReply` 标签的单调时钟日志、两个 ART 文件及两包私有回执。先在原输入法下启动主场，等服务返回首个响应再打开切换阶段，正控在窗口关闭后单独建立。运行期间禁用 USB 与 mDNS，私有 ADB 启动前实读空设备表，核对唯一模拟器的 serial、AVD 名称、API 36 和 qemu 标记。
3. 用 [read_result.py](read_result.py) 对一轮原件目录执行 `python -B read_result.py <目录>`。沿用上一级实验的 `A2`、`control`、`state.json`、`switch.trace`、`control.trace`、`framework-trace.log` 以及带序号的 `*-{system,activity}-{before,after}.stdout.txt`。脚本按请求号和会话号对照前后，检查 ART 的无溢出标志、记录总数及正控中的结构写入，分别输出切换窗口内和窗口后的过期位读数。

首次编译因本地公开 SDK 没有 `SaveInfo.getFlags()` 而停止，随后改为记录传入的标志，并用系统回执独立核实。首次启动的模拟器在安装前读取详细日志级别仍为 `debug`，该准备轮未测右框，142 秒收尾。有效轮在设备就绪后核实 `verbose`，226 秒收尾。两轮八项原设置与日志级别均恢复，私有 ADB、模拟器进程和端口均回收。有效轮另核实两包 UID 不同、已装包摘要匹配及卸载后查无。

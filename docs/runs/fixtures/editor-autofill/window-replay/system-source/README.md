# 用系统会话核对结构来源窗

2026-11-22，在独占 API 36 模拟器上先后启动同包同类的两个真实 Activity 实例。使用有 `DUMP` 权限的宿主采样，两个自动填充请求分别归属到无障碍窗口 **11** 和 **14**，均与靶应用事后独立读回的窗口号相同。两份来源记录保留各自真实的请求、会话和时序，交叉指定对方为期望窗口后，两次均拒绝，窗口号、侧别和四边全部为空。这两窗先后全屏显示；第二场三次 WindowManager 清单里都还有第一窗。[实采精简输入](recorded.json) · [判定与交叉回放](verify.py)

| 模拟器实采 | 第一次启动 | 第二次启动 |
|---|---:|---:|
| 任务号／无障碍窗口号 | 8／11 | 9／14 |
| 请求号／填充会话号 | 928／1480379174 | 932／1105342264 |
| 填充焦点与当前输入连接的原生字段号 | 均为 1073741825 | 均为 1073741825 |
| 输入法端的填充会话号 | 0 | 0 |
| 输入连接代次／开始时刻（毫秒） | 2／150253 | 4／195439 |
| 宿主释放请求标记／结构采集起止／服务记录／宿主看见回调（毫秒） | 155600／155626–155627／155637／155690 | 200890／200929–200929／200940／200970 |
| 右／左控件实际收到的探针次数 | 1／0 | 1／0 |
| 观察器与靶分别取得的右框四边 | 均为 `[2100,32,2300,102]` | 均为 `[2100,32,2300,102]` |

每场由靶发起一次手动结构请求。在请求前等候宿主读取活动窗和输入目标，服务沿用既有选框及 100 毫秒的连接复查，再延迟 3.6 秒返回空响应，以便取得两份仍在活动期的系统会话。结果适用于合成手动场。PA2553 切换输入法后的自然结构交付仍待验证。

## 窗口号的证据链

1. 从实际交付的 `FillRequest` 和最新 `FillContext` 取得同一请求号，从匹配节点与填充焦点各自的 `AutofillId.getSessionId()` 取得同一非零会话号。两份系统快照中，这个活动会话均只含该请求，当前字段亦一致。框架请求结构时传入该会话的 `mActivityToken`，会话转移到另一 Activity 时该值可能改变，故另核对两份快照中的 token 与 ActivityRecord。[API 36 字段接口](https://developer.android.com/reference/android/view/autofill/AutofillId#getSessionId()) · [Android 16 会话与结构请求](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-16.0.0_r1/services/autofill/java/com/android/server/autofill/Session.java)
2. 在请求前、请求中、请求后的三份 WindowManager 清单里按 **ActivityRecord 实例** 查找唯一应用窗，核对任务、包、显示屏、可见性、屏幕矩形、当前焦点和 IME 输入目标。若同一 Activity 有多个窗口、候选有附属窗、或另一窗口与候选有相同的客户端标记，均拒绝。两场实测的每个来源 Activity 各有一个所属窗口。[WindowState 诊断输出](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-16.0.0_r1/services/core/java/com/android/server/wm/WindowState.java)
3. 无障碍系统诊断按无障碍窗口号查回 `WindowInfo`，逐对输出。其 token 和 WindowManager 的 `mClient` 均取自同一窗口的 `mClient.asBinder()`。在前后两份清单中以该 token 唯一匹配，读出无障碍窗口号，再同实验服务用公开 `getWindows()` 读取的当前活动焦点窗号比对。这里使用同一轮、同一 `system_server` 内的诊断字符串，检查每份清单中匹配唯一。它只支持该短观察区间的事后判读；端点间瞬时切出并返回、系统服务重启或跨运行复用均未验证。[无障碍服务按 ID 配对输出](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-16.0.0_r1/services/accessibility/java/com/android/server/accessibility/AccessibilityWindowManager.java) · [WindowInfo 的 token 输出](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-16.0.0_r1/core/java/android/view/WindowInfo.java)

靶用独立私有回执记录 Activity 实例、任务号、自身控件的无障碍窗口号、实际收到输入法探针的一侧和 `getLocationOnScreen()` 四边。这些值在来源判定结束后才参与验收。`origin.json` 直接绑定请求与结构源。`result.json` 是同场唯一手动请求的观察器选框回执，本轮每场先核实旧回执已清除或目录全新，且系统仅有该次手动请求。它自身没有请求号和会话号，单独取出无法通用地证明四边属于哪个请求。

## 宿主回放

| 回放输入 | 结果 |
|---|---|
| 两套来源证据各自对本窗 | `MATCH`，右框，分别为窗 11、14 |
| 窗 11 来源指定目标 14；窗 14 来源指定目标 11 | 两次均 `WRONG_WINDOW`，两份原始时序各自有效 |
| 向第二场延迟交付第一场的旧样本；变异为连接开始前采集 | `STALE_COLLECTION` |
| 单独替换请求回执；移除一份系统会话 | `CALLBACK_REPLACED`、`SESSION_ABSENT` |
| 替换结束时的焦点窗；替换无障碍窗口与 token 对照 | `WRONG_WINDOW`、`ACCESSIBILITY_TOKEN` |
| 为同一 Activity 增加第二窗口；让另一窗口重复客户端标记 | `ACTIVITY_WINDOW_AMBIGUOUS`、`WINDOW_CLIENT_AMBIGUOUS` |

所有负例的窗号、侧别、四边均为空。交叉指定目标及替换、缺失、冲突均在宿主回放执行。两次 Android 真实请求各自正确送达；未观察到系统投错窗。

公开标题通道也做了实测。两个结构窗的 `getTitle()` 都返回相同的 Activity 组件名，两次公开无障碍窗口标题则都为应用标签 `双编辑框实验`。标题匹配连本窗都无法接受；改为只按组件名匹配又会接受两个实例。另一条候选是让输入法的 inline suggestions 请求附带标记。Android 16 输入法框架判断能否创建这个请求时只比较包名和原生字段号，这两项在本次两个实例中真实碰撞。此项只核框架源码，本轮未开启 inline suggestions。普通 App 的公开回执仍缺通用的来源窗绑定。[结构窗口标题](https://developer.android.com/reference/android/app/assist/AssistStructure.WindowNode#getTitle()) · [无障碍窗口标题](https://developer.android.com/reference/android/view/accessibility/AccessibilityWindowInfo#getTitle()) · [Android 16 输入法匹配逻辑](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-16.0.0_r1/core/java/android/inputmethodservice/InlineSuggestionSessionController.java)

## 复核

在本目录用 Python 3.10 或更高版本运行 `python verify.py recorded.json`。精简输入保留各段时间、窗口清单头、客户端标记、相关实例关系、填充与无障碍诊断字段；临时系统对象标记已一致替换。用 `python verify.py <场次总目录>` 可直接从原始合成回执复核相同判定。每个实例目录名为 `first` 或 `second`，含 `snapshots.txt`、`origin.json`、`result.json`、`oracle.json`。脚本逐段检查设备时间不逆序，并以本次无休眠模拟器的 `/proc/uptime` 10 毫秒精度核对请求释放、结构采集、服务记录、宿主看见回调的次序。

重新实测时，运行 `python prepare.py <全新源码目录>`，以 API 35 编译生成的两个 APK，API 36 公共字段方法通过反射调用。按[既有隔离规程](../../README.md#复现)在新建、禁用 USB 与 mDNS 的专用 AVD 上验证空表、身份、包摘要与不同 UID，断网后选用实验 IME、自动填充服务，并仅在该 AVD 启用 `.OriginWindows`。以 `FLAG_ACTIVITY_NEW_TASK | FLAG_ACTIVITY_MULTIPLE_TASK` 连续启动两次 `scenario=right`，每场都等候靶包的 `files/origin-ready`，再以 shell 执行 [collect.sh](collect.sh)。第一场空响应结束后清除、读回旧阶段标记与回执，再开第二场。[独立实验源码准备](prepare.py) · [服务端请求回执](OriginEvidence.java) · [公开窗口观察](OriginWindows.java)

本轮基线为 `177f002`。已装靶 APK 的 SHA-256 为 `6e9e9df21d4a7838032dd073a37690e0f0f1afec039482b6d51496add3349d02`，观察器为 `eb12c578e68c0ab0b94f4172527d76b1eea44000bb65a223380e7d3b65fc8900`，均与宿主制品一致。运行 298 秒，恢复并逐项读回十项设置，包括无障碍启用清单及开关、原输入法及启用清单、原自动填充服务。两实验包卸载后查无，专用模拟器与 ADB 已停止，三个端口均已释放。

实测后补入采集脚本本身的入口检查。首次系统转储前，再核对 qemu、API 级别、靶私有就绪标记与旧回执。宿主替身覆盖实体设备、API 35、靶未就绪、已有回执、观察器目录不可读和就绪六例，只有最后一例到达模拟的首次转储。此项复核在宿主完成。

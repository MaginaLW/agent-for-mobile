# 用自动填充标识核对当前输入连接

这个 Android 16 隔离实验安装两个合成 APK。靶应用显示横屏左右两个标准 `EditText`，两框均无资源 ID，输入类型相同。另一个应用提供实验输入法和自动填充服务。观察器只读取当前连接、候选标识、焦点及几何。它不读取文本、不提供填充数据。

输入法从系统交付的 `EditorInfo` 取得 `AutofillId`。自动填充服务从同一靶 Activity 的最新手动 `FillRequest` 取得 `AssistStructure`，枚举两框。Android 在传给自动填充服务前给树中的标识附加会话号，所以实验保留完整 ID 相等的计数作对照，并用 API 36 公开的 `getViewId()` 比对同一窗口内两个不同的原生自动填充标识。普通资源 ID 和自动填充标识是两套编号。虚拟字段不进入这条判定路径。[建立输入连接](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-16.0.0_r1/core/java/android/view/inputmethod/InputMethodManager.java#L5007-L5025) · [自动填充服务的会话标识](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-16.0.0_r1/services/autofill/java/com/android/server/autofill/Session.java#L877-L881) · [公开标识方法](https://developer.android.com/reference/android/view/autofill/AutofillId)

输入法还向实际的 `InputConnection` 发出一次屏幕外的只读 `requestTextBoundsInfo`。靶应用分别记录左、右连接收到探针的次数，返回不支持几何查询。手动场在收到探针后才请求自动填充结构。观察器无法读取靶应用私有回执，也不用探针返回值选框。宿主最后把选中侧、完整屏幕四边与靶应用自己测量的结果逐项比对。

### 隔离模拟器实测

2026-11-22，API 36 横屏单窗口为 2340 × 1080 像素。以下四场使用同一套 `3937543` 实验源码。模拟器读回的 APK 摘要与宿主一致，靶应用和观察器属于不同 UID。表中的探针次数由靶应用按实际收到请求的连接记录，选择结果来自观察器。坐标顺序为左、上、右、下，单位为屏幕像素。

| 场景 | 左／右连接收到探针的次数 | 观察器结果 | 选中框的四边 |
|---|---|---|---|
| 左框先持有连接 | 1／0 | `MATCHED · LEFT` | `[40, 32, 240, 102]` |
| 同一对控件交接给右框 | 0／1 | `MATCHED · RIGHT` | `[2100, 32, 2300, 102]` |
| 两框四边完全重合 | 1／0 | `UNKNOWN · INDISTINGUISHABLE_BOUNDS` | 无 |
| 连接在左，结构焦点在右 | 1／0 | `CONFLICT · FOCUS_DISAGREES` | 无 |

左、右两场的 Activity 实例和两个控件实例逐一相同。唯一前台窗口属于靶应用，触点上方无遮挡。右框中心的一次触摸产生一对按下与抬起事件，建立一个新的右连接，`restartInput` 调用为 0。两场选中矩形的四个坐标均与靶应用用 `getLocationOnScreen()` 和控件尺寸计算的结果相同。

四场中，树节点与输入法的完整 `AutofillId.equals()` 命中数均为 0，按原生 `getViewId()` 比较均恰好命中 1 个。重合场两框均为 `[40, 32, 240, 102]`。冲突场只有一个结构节点报告聚焦，它和自动填充请求都指向右框，输入连接标识命中左框。两场的 `selected_side` 和 `selected_bounds` 均为空。

本轮结束时，八项设置全部恢复并读回，两个实验包已卸载，专属模拟器、私有 ADB 已停止，端口已释放。此结论覆盖配合发起手动自动填充请求的合成 Activity 和标准原生控件。微信双窗是否提供同样的结构仍未知，现有网关也没有启用这项自动填充服务。

### 连接交接的两次未通过记录

- 首轮使用 `d1faa7d`。同一 Activity 收到第二个 intent 后，控件焦点已到右框，但两框新建连接次数和收到探针次数均为 0。15 秒后靶应用超时，观察器没有给出选择。该轮左框、四边重合、焦点冲突三个场景均取得独立回执。
- 第二轮使用 `3937543`，改为向实测右框内部触摸。左框再次命中。触摸前，宿主未能确认唯一前台窗口，实际触摸次数为 0，右框未受测。该轮只记录了前台校验失败，无法据此判断当时是哪一个窗口。关闭临时模拟器前，七项设置中六项读回一致，已启用输入法列表未恢复到原值。模拟器与私有 ADB 均已停止，专用端口已释放。

### 复现

1. 使用[本地测试台](../../../runbooks/本地测试台.md)的全新 API 36 AVD、禁用 USB 和 mDNS 的私有 ADB、启动前空设备表及专属端口。准备两个目录的独立 APK；构建步骤同[原点实验](../editor-origin/README.md#构建)，每个 APK 仅编译各自目录的 Java。靶应用无资源目录，链接清单时省略资源包。观察器有两个 XML 资源；用 API 35 编译时，通过方法名调用 API 36 的公开接口。两包用一次性实验签名签署。
2. 在已核实归属的模拟器上，安装实验包前记录默认输入法、已启用输入法的完整清单、自动填充服务、沉浸模式提示、飞行模式、Wi-Fi 和两项旋转设置。关闭模拟器网络，安装两包并读回包摘要和 UID。预设沉浸模式提示已确认，选用实验组件 `dev.magina.autofillobserver/.ProbeIme` 和 `dev.magina.autofillobserver/.ProbeAutofillService`。
3. 启动 `dev.magina.autofilltarget/.TargetActivity`，传入字符串参数 `scenario=left`。保存靶应用私有的 `files/oracle.json` 与观察器的 `files/result.json`。复核这两份回执后，移除两包私有目录里的旧回执并核实不存在。核对输入分发器、窗口管理器及已恢复的前台 Activity 均指向唯一靶窗口，确认触点上方无遮挡。仅在专属模拟器上向左场回执中已测得的右框内部执行一次触摸。核实实例标记相同、两框均沿用，实际收到探针的连接已从左换到右。
4. 分别以干净状态运行 `overlap` 和 `conflict`。前者把两框放在同一屏幕矩形；后者让左框保持实际焦点和连接，在右框请求自动填充，并在结构中报告右侧焦点。验收同时检查具体拒绝原因、选中侧为空、最终矩形为空。每场单独保存回执。
5. 恢复服务并卸载实验包，将已启用输入法完整清单及其余设置恢复到入场值，逐项读回。关闭本轮创建的模拟器和私有 ADB，核对专属端口已释放。

### 系统自动请求

在全新 API 36 横屏模拟器上，`scenario=automatic` 让同一对无资源 ID 的原生编辑框先后持有连接。先由左框取得焦点，再向实测右框中心触摸一次。靶应用按实际收到连接探针的控件写入私有回执，两阶段的 `requestAutofill()` 调用数都必须为零。另用 `scenario=left` 检验手动请求能否走通。

宿主在观察器私有的 `files/natural-stage` 写入阶段号，为左、右场分别用 `1`、`2`。每次确认该阶段没有旧回执，手动对照前移除标记。观察器只接受合成靶 Activity 的请求，使用 `FLAG_MANUAL_REQUEST` 区分来源，始终返回空填充响应。在显式排除场（`scenario=optout`，阶段 `3`），观察器在读取节点前结束，记录拒绝原因和回调到达时间。宿主逐条要求候选数为零，选中侧、四边、连接代次和结构采集时间均为空。这个对照检验观察器自己的拒绝逻辑。[Android FillRequest](https://developer.android.com/reference/android/service/autofill/FillRequest) · [Android FillCallback](https://developer.android.com/reference/android/service/autofill/FillCallback)

按设备单调时钟核对每个样本。输入连接须始于本阶段，结构采集须晚于该连接开始，采集与连接开始同毫秒时也不选框。观察器核对采样前后连接代次相同，再由宿主将焦点、所选侧别和四边与靶应用的独立回执比对。跨阶段回调和未结项的样本均不能证明当前框归属。

首次自然请求实测中，左场的结构采集比输入连接开始晚 8 毫秒，四边与靶应用相符。右场独立回执证实同一 Activity 中右连接收到探针，在 12.591 秒窗口内未记录可归属的回调，选中侧和四边均为空。手动左场阳性对照通过。显式排除场初版仍返回了选择，该项失败。修正后，观察器先检查实验参加范围，并在允许遍历时遵守节点的排除属性。

使用修正版 `3935880` 在另一台全新模拟器上复核。两轮的观察窗口均从宿主打开阶段标记计时，右场包含该次触摸，取得靶应用的连接回执后都另留了 6 秒。表中四边采用屏幕像素，依次为左、上、右、下。

| 场景 | 靶应用收到连接探针 | 手动请求数 | 观察器回执 |
|---|---|---:|---|
| 首次聚焦左框 | 仅左框 | 0 | 1 个自动回调。采集晚于连接开始 18 毫秒，选中左框 `[40, 32, 240, 102]` |
| 同窗触摸切到右框 | 仅右框 | 0 | 10.840 秒内可归属回调为 0，`UNKNOWN`，无选中侧和四边 |
| 靶应用显式排除 | 仅左框 | 0 | 1 个自动回调，`UNKNOWN / TARGET_OPTED_OUT`。候选为 0，采集时间、连接代次、选中侧和四边均为空 |
| 手动请求阳性对照 | 仅左框 | 1 | 选中左框 `[40, 32, 240, 102]`，四边与靶应用相同 |

两轮分别耗时 411 秒和 347 秒。每轮靶应用和观察器的 UID 不同，已安装 APK 的摘要均与宿主一致。收尾逐项读回八项模拟器设置，专属模拟器和私有 ADB 均已停止，端口全部释放。本阶段只在合成应用运行。

将首次左场的真实合成样本离线回放到右场，原样回放得到 `PRE_STAGE_CALLBACK`，模拟延迟送达但保留原采集时间得到 `PRE_STAGE_STRUCTURE`。两种情况都不能把左框四边带到右框。

前两轮只记录了观察器收到的回调。随后在同版夹具上追踪了框架的会话和请求。

### 空响应后的会话与右框请求

2026-11-22，在全新 API 36 模拟器上复用 `3935880` 的两份实验 APK。临时开启自动填充详细日志，分别在启动左场和触摸右框前放置日志标记。按靶应用与系统服务各自的进程筛选事件，用系统请求历史的会话号核对空响应，并将靶 Activity 布局中的两个字段标识、控件实例及矩形与其私有回执逐项对应。

左框独占连接时，靶应用手动请求数为零。系统记录了 1 次结构请求和 1 次向服务派发，两者的请求号相同。服务回调后，系统明确记录因空响应结束该会话。靶应用进程紧接着记录 `ACTIVE → FINISHED`，独立读取的 Activity 状态也是 `FINISHED`。系统及客户端记录的字段列表都含有左、右两框，此时右框尚未被触摸。[系统处理空响应](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-16.0.0_r1/services/autofill/java/com/android/server/autofill/Session.java#L6368-L6399) · [客户端登记字段](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-16.0.0_r1/core/java/android/view/autofill/AutofillManager.java#L3673-L3692)

在同一 Activity 内触摸右框一次，只有右连接收到只读探针。客户端 `AutofillManager` 明确记录了 1 次忽略进入事件，原因是会话处于 `FINISHED` 且该字段已登记。日志所指的字段与右框标识一致，手动请求标志为零。系统请求历史仍只有左场那一条，右场新增会话启动、结构请求、向服务派发及服务回调均为零。右场观察窗口从开启阶段标记计时共 10.033 秒，其中取得连接回执后留观 6 秒。断点位于客户端处理右框进入事件时，观察器未输出选中侧或四边。[客户端过滤进入事件](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-16.0.0_r1/core/java/android/view/autofill/AutofillManager.java#L1813-L1833)

本轮共 207 秒。八项原设置全部恢复并逐项读回，自动填充日志级别也已从临时的 `verbose` 恢复为入场时的 `debug`。两个实验包已卸载，专属模拟器和私有 ADB 已停止，端口已释放。本次只覆盖这对合成控件和返回空响应的实验服务，未连接 PA2553。

### 右框首次持焦与持焦后切换输入法

2026-11-22，复用双框布局、原自动填充观察器和空响应，在两个全新 API 36 模拟器上分别验证两种起点。两份实验 APK 的 SHA-256 分别为靶应用 `42f7e09634e876d125c27085cc23a982c99c1e3bd323c5066203fb1e69049451`、观察器 `318afc76cd5fb7506ebb8832242164de7d80a3b9b384550b0f934de11b455e95`。

A1 在实验输入法已经选中时启动 `scenario=automatic-right`。靶应用最先聚焦右框，左框新建连接数为 0，右框为 2。靶应用收到的只读探针为左 0、右 1，手动结构请求、触摸和 `restartInput` 均为 0。实验输入法在设备单调时钟 165110、165279 毫秒先后开始第 1、2 代连接。唯一自动回调的采集时间为 165317–165320 毫秒，回调到达时间为 165521 毫秒。采样前后都是第 2 代，采集比该代连接建立晚 38 毫秒。观察器选中右框，四边 `[2100, 32, 2300, 102]` 与靶应用独立测量逐项相同。宿主观察窗口为 16.411 秒，其中取得靶回执后留观 9.892 秒。

A2 以原输入法启动 `scenario=automatic-right-switch`。靶应用在 147676 毫秒记录右框已持焦、已有连接，此时探针为 0。首次自动结构采于 147666–147667 毫秒，回调在 148064 毫秒到达；实验输入法尚无连接，原回执为 `NO_CURRENT_IME`。保持同一 Activity 和右控件，再选用实验输入法。第 1 代连接在 164572 毫秒建立，靶应用于 164575 毫秒记录右侧收到探针。手动请求、触摸和 `restartInput` 均为 0。切换阶段的 15.164 秒观察窗口中，取得靶回执后继续留观 8.443 秒，自动填充服务新增可归属回调为 0。结果为 `UNKNOWN / NO_NEW_CALLBACK`，该代的结构采集时间、采样前后代次、选中侧和四边均为空。靶应用独立测得右框仍为 `[2100, 32, 2300, 102]`。本场能定位到服务未收到新回调，框架内的具体断点未知。

首轮准备在启动靶 Activity 前就因宿主读取私有文件的引号处理失败。该轮两包卸载、进程与端口回收，八项设置中六项恢复，沉浸模式空值与含分号的输入法清单恢复失败。修正后，A1 所在轮的首版宿主检查因整个启动期间出现两代连接而报错，原始 Android 回执保留。按采样前后代次与最新连接开始时间重核同一批回执后得到上述 A1 结果。A1、A2 所在轮分别于 266、256 秒关闭，均核实靶应用与观察器 UID 不同，已装 APK 摘要与宿主一致，八项设置逐项恢复，两个包卸载且查无，专属模拟器与私有 ADB 停止，端口释放。

复现时沿用上文的私有 ADB、空表、独占模拟器身份、已装 APK 摘要与不同 UID 核验。A1 在启动右框前把观察器私有 `files/natural-stage` 置为 `1`，首先确认该场回执不存在。取得 A1 阳性后，在全新 AVD 核对原输入法仍被选用，将阶段设为 `1` 并启动 A2。先读靶应用私有的 `files/right-ready.json`，再确认当前输入法仍为原值，保存切换前的 `natural-1.json`。核实 `natural-2.json` 不存在，将阶段改为 `2`，切到实验输入法并读回。两场均保存靶应用的 `files/oracle.json`，取得后继续观察至少 6 秒，再读取服务对应阶段的私有目录、回执及实验 IME 的 `SyntheticProbeIme` 日志。

以每场目录为参数运行 [verify_right_first.py](verify_right_first.py)。`oracle.json` 来自靶应用，A2 另存 `right-ready.json`。`ime.txt` 使用 `logcat -d -v threadtime -s SyntheticProbeIme:I AutofillObserver:W`。将阶段回执原文存为 `journal-read.txt`，解析后存为 `ledger.json`。经成功列目录确认文件不存在时，前者写 `ABSENT`，后者只记录阶段、`host_observation=journal_absent_at_close`、空样本和零回调数。`observation.json` 使用同一宿主单调时钟的毫秒值记录标记读回、靶回执读到与最终目录检查完成的时刻，对应 `marker_readback_ms`、`oracle_read_ms`、`journal_read_ms`。连接、采集和回调之间的先后关系取自设备单调时钟。

### 持焦切换时的客户端方法轨迹

在另一台全新 API 36 模拟器复用上述两份 APK。右框保持焦点时，切换输入法重建了输入连接，靶进程内没有发生新的 View 焦点变化或自动填充进入、退出调用。上一节只能定位到服务无新回调，本场将断点定位到客户端的焦点通知入口。

| 设备单调时间（毫秒） | 直接回执 |
|---|---|
| 157825–158605 | 原输入法下，客户端以右框字段启动会话。系统请求 54 的结构采于 157923–157926，观察器在 158461 收到回调并返回空响应。系统在 158604 记录无法增强填充并结束会话，客户端在 158605 从 `ACTIVE` 转为 `FINISHED`，登记了左右两个字段。 |
| 182815–204639 | 设备日志标出开始切换及观察结束。实验输入法在 184314 建立第 1 代连接，同一靶 Activity 和右框于 184317 记录收到探针。切换前后客户端均为 `FINISHED`、服务已启用、登记字段集合相同，右框保持焦点。系统常规请求历史仍只有原会话 1613176740，新增结构请求、派发和实验服务回调均为 0。 |
| 225700–233245 | 在同一靶进程（PID 4198）新建另一个 Activity，让右框自然取得焦点。系统为新会话 1247239946 发起并派发请求 56。实验输入法第 3 代始于 227169，采集在 227180–227181，回调在 227231 到达。观察器选中的右框四边与该 Activity 的独立回执相同。 |

用 Android 方法跟踪器只记录该靶进程，关闭采样，以类名和方法名汇总所有线程及同名重载的**入口次数**。正控涵盖整个新 Activity 启动，表中焦点入口计数属于进程；具体右框由靶回执及结构字段另外核实。两场手动请求均为 0。

| 靶进程的方法 | 持焦切换 | 新 Activity 自然聚焦 |
|---|---:|---:|
| `View.onFocusChanged` | 0 | 3 |
| `View.onWindowFocusChanged` | 0 | 14 |
| `View.notifyEnterOrExitForAutoFillIfNeeded` | 0 | 12 |
| `AutofillManager.notifyViewEntered / notifyViewExited` | 0 / 0 | 2 / 1 |
| `AutofillManager.notifyViewEnteredForFillDialog` | 0 | 2 |
| `AutofillManager.shouldIgnoreViewEnteredLocked`（判断是否忽略进入） | 0 | 1 |
| 靶编辑框 `onCreateInputConnection` / 靶 Activity `receiveProbe` | 3 / 1 | 1 / 1 |

切换段和正控段的方法轨迹分别覆盖 27.218051 秒（242585 条记录）和 12.560102 秒（306997 条）。两段均实读 ART 的 `data-file-overflow=false`，二进制记录数与 ART 头部声明逐条计数相等。切换场的服务回执观察窗口另由宿主计时 19.341 秒，收到靶回执后保留 8.779 秒，选中侧和四边均为空。Android 16 的 View 源码把焦点变化接到自动填充进入/退出通知。结合本次实测，当前连接已换，但右框持续持焦，没有产生新的进入调用；同窗触摸换框那一场曾走到的「字段已登记」拒绝分支，在本场没有被调用。[Android 16 View 焦点分发](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-16.0.0_r1/core/java/android/view/View.java#L8782-L8838)

复现时先在专属模拟器保存自动填充日志级别并设为 `verbose`，沿用上一节 A2。分别在切换前后保存 `dumpsys activity dev.magina.autofilltarget`、`dumpsys autofill`、阶段标记和带单调时钟的目标/系统日志。运行切换前，用 `am profile start --clock-type wall dev.magina.autofilltarget /data/local/tmp/switch.trace` 开启无采样方法跟踪，服务观察窗口结束后执行 `am profile stop dev.magina.autofilltarget` 并取回文件。之后换用 `control.trace` 同法记录同 PID 的全新 Activity 自然聚焦，独立保存新靶和服务回执。用 [count_focus_methods.py](count_focus_methods.py) 复算两份原件，命令为 `python count_focus_methods.py switch.trace control.trace`，会核查时钟、溢出标志和记录数。设备侧命令均经已核实归属的私有 ADB 运行。本轮 327 秒收尾，八项设置逐项恢复，自动填充日志从 `verbose` 恢复为入场的 `debug`，两包已卸载，自建模拟器、私有 ADB 与端口全部回收。

另一次隔离实验把原会话保持在 `ACTIVE` 后再切换输入法，并分别核对旧请求、新连接及靶应用写入结构的次数。右框持续持焦期间仍未取得新结构。[保留会话的对照](retained-session/README.md)

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

Android 16 源码中，空填充响应在特定条件下会结束会话，客户端随后可忽略已登记字段的自动进入事件。本实验没有记录框架走到的分支，右框缺少新结构的具体原因仍待核对。[系统处理空响应](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-16.0.0_r1/services/autofill/java/com/android/server/autofill/Session.java#L6384-L6400) · [客户端过滤进入事件](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-16.0.0_r1/core/java/android/view/autofill/AutofillManager.java#L1813-L1833)

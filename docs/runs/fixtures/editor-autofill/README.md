# 用自动填充标识核对当前输入连接

这个 Android 16 隔离实验安装两个合成 APK。靶应用显示横屏左右两个标准 `EditText`，两框均无资源 ID，输入类型相同。另一个应用提供实验输入法和自动填充服务。观察器只读取当前连接、候选标识、焦点及几何。它不读取文本、不提供填充数据。

输入法从系统交付的 `EditorInfo` 取得 `AutofillId`。自动填充服务从同一靶 Activity 的最新手动 `FillRequest` 取得 `AssistStructure`，枚举两框。Android 在传给自动填充服务前给树中的标识附加会话号，所以实验保留完整 ID 相等的计数作对照，并用 API 36 公开的 `getViewId()` 比对同一窗口内两个不同的原生自动填充标识。普通资源 ID 和自动填充标识是两套编号。虚拟字段不进入这条判定路径。[建立输入连接](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-16.0.0_r1/core/java/android/view/inputmethod/InputMethodManager.java#L5007-L5025) · [自动填充服务的会话标识](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-16.0.0_r1/services/autofill/java/com/android/server/autofill/Session.java#L877-L881) · [公开标识方法](https://developer.android.com/reference/android/view/autofill/AutofillId)

输入法还向实际的 `InputConnection` 发出一次屏幕外的只读 `requestTextBoundsInfo`。靶应用分别记录左、右连接收到探针的次数，返回不支持几何查询。收到探针后才请求自动填充结构。观察器无法读取靶应用私有回执，也不用探针返回值选框。宿主最后把选中侧、完整屏幕四边与靶应用自己测量的结果逐项比对。

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

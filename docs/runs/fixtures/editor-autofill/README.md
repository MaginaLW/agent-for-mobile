# 用自动填充标识核对当前输入连接

这个 Android 16 隔离实验安装两个合成 APK。靶应用显示横屏左右两个标准 `EditText`，两框均无资源 ID，输入类型相同。另一个应用提供实验输入法和自动填充服务。观察器只读取当前连接、候选标识、焦点及几何。它不读取文本、不提供填充数据。

输入法从系统交付的 `EditorInfo` 取得 `AutofillId`。自动填充服务从同一靶 Activity 的最新手动 `FillRequest` 取得 `AssistStructure`，枚举两框。Android 在传给自动填充服务前给树中的标识附加会话号，所以实验保留完整 ID 相等的计数作对照，并用 API 36 公开的 `getViewId()` 比对同一窗口内两个不同的原生自动填充标识。普通资源 ID 和自动填充标识是两套编号。虚拟字段不进入这条判定路径。[建立输入连接](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-16.0.0_r1/core/java/android/view/inputmethod/InputMethodManager.java#L5007-L5025) · [自动填充服务的会话标识](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-16.0.0_r1/services/autofill/java/com/android/server/autofill/Session.java#L877-L881) · [公开标识方法](https://developer.android.com/reference/android/view/autofill/AutofillId)

输入法还向实际的 `InputConnection` 发出一次屏幕外的只读 `requestTextBoundsInfo`。靶应用分别记录左、右连接收到探针的次数，返回不支持几何查询。收到探针后才请求自动填充结构。观察器无法读取靶应用私有回执，也不用探针返回值选框。宿主最后把选中侧、完整屏幕四边与靶应用自己测量的结果逐项比对。

### 复现

1. 使用[本地测试台](../../../runbooks/本地测试台.md)的全新 API 36 AVD、禁用 USB 和 mDNS 的私有 ADB、启动前空设备表及专属端口。准备两个目录的独立 APK；构建步骤同[原点实验](../editor-origin/README.md#构建)，每个 APK 仅编译各自目录的 Java。靶应用无资源目录，链接清单时省略资源包。观察器有两个 XML 资源；用 API 35 编译时，通过方法名调用 API 36 的公开接口。两包用一次性实验签名签署。
2. 仅在核实归属的模拟器上安装两包，读回包摘要和 UID。保存默认输入法、已启用输入法清单和自动填充服务。选用实验组件 `dev.magina.autofillobserver/.ProbeIme` 和 `dev.magina.autofillobserver/.ProbeAutofillService`。
3. 启动 `dev.magina.autofilltarget/.TargetActivity`，传入字符串参数 `scenario=left`。保存靶应用私有的 `files/oracle.json` 与观察器的 `files/result.json`。取走旧回执后，以 single-top 将 `scenario=right` 传给原 Activity。核实实例标记相同、两框均沿用，实际收到探针的连接已从左换到右。
4. 分别以干净状态运行 `overlap` 和 `conflict`。前者把两框放在同一屏幕矩形；后者让左框保持实际焦点和连接，在右框请求自动填充，并在结构中报告右侧焦点。验收同时检查具体拒绝原因、选中侧为空、最终矩形为空。每场单独保存回执。
5. 将三项设置恢复到入场值并读回，关闭本轮创建的模拟器和私有 ADB，核对专属端口已释放。

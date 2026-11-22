# 合成右框的输入法菜单对照

本场测试标准 EditText 能否在右框持续持焦、切换输入法后，通过实验输入法上的可见选项取得新的自动填充结构。靶内两个字段均为空，并显式设置 `IMPORTANT_FOR_AUTOFILL_YES`。仅右框在自己的输入连接上标记本次实验许可。两包同签、不同 UID，输入法另核对系统提供的连接包名和绑定 UID。没有该右框许可时，输入法不显示实验选择。靶应用源码没有调用 `requestAutofill`。实验服务仅核对结构元数据，返回空响应。

Android 16 的标准编辑器会把被选中的自动填充菜单动作转交给 TextView，再由框架向 AutofillManager 发出手动请求。输入法提交动作的布尔读数仅表示提交结果。靶场的连接入口、TextView 入口和实验服务的 `FillRequest.FLAG_MANUAL_REQUEST` 分别记录。这个方法依赖自有靶的独立许可和输入法上的显式选择。[Android 16 编辑器分发](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-16.0.0_r1/core/java/com/android/internal/inputmethod/EditableInputConnection.java#L167-L173) · [TextView 菜单处理](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-16.0.0_r1/core/java/android/widget/TextView.java#L14226-L14230)

## 复现

1. 在已有 Windows Android SDK 35 与 JDK 21 的环境中，执行 `python -B build.py <新私有构建目录> --jdk <JDK目录>`。分别得到 `target.apk` 和 `observer.apk`。构建复用上一级夹具的几何与当前连接核验代码。编译时使用本机平台 35 的公开存根，实验服务在运行时使用 API 36 的公开字段标识。
2. 沿用上一级[隔离实验](../README.md)的私有 ADB 和全新 API 36 AVD。验证起始设备表为空、模拟器身份唯一，再离线安装两包，核实包摘要与 UID。从原输入法启动合成靶，等待右框首次获得输入连接和原输入法阶段的自然回调。切到实验输入法，待新连接的右侧独立探针到达，并稳定至少 1 秒。
3. 在实验输入法上依次显式选择「空操作」「过期对照」「为本测试框请求自动填充」。前两场各留观至少 1 秒。过期对照用同一发送守卫核实已过 200 毫秒有效期。正控仅允许同一代连接提交一次，不打开靶 EditText 原生上下文菜单。测试驱动在隔离 AVD 上选择这三个可见选项，记录为合成 UI 操作。
4. 保存合成进程标签 `MenuOracle`、`MenuChoice` 和 `MenuFill` 的 `logcat -d -v brief` 记录，执行 `python -B verify.py <日志>`。核对前两场没有新结构及服务回调，右框焦点与连接未变，正常请求触达靶右框的连接与 TextView，采样晚于提交、早于回调，服务返回唯一匹配的右侧及其四边，靶侧独立位置与其一致。收尾逐项恢复入场设置，卸载两包并回收专属 AVD、私有 ADB 与端口。

## 2026-11-22 隔离实测收尾

本轮在 API 36 专用模拟器上止于输入法选项就绪检查，宿主报 `no_menu_event_event=button name=request`。靶应用启动时右框持焦。原输入法阶段系统采集结构的时间为 170447–170449 毫秒，服务在 171276 毫秒收到自然回调，`flags=0`。切换后实验输入法在 178937 毫秒建立第 1 代连接，右框在 178938 毫秒收到探针。同一右框仍报告窗口和控件均持焦。

宿主在 25 秒就绪等待中没有读到“为本测试框请求自动填充”的位置回执。此次未取得足以区分键盘显示、按钮布局与日志条件的证据。三个选项的点击、菜单动作投递、靶控件菜单入口以及手动服务回调均为 0。切换后的结构采集时间、选中侧及选中四边均未知。靶端单独记录的框位置只作为对照。

切换期间，同一个右框依次创建第 3、4、5 号连接对象，探针送达第 4 号。受测靶的菜单守卫要求对象编号等于最后创建的编号，因此“最新创建”与“当时接到探针”在这组读数中不同。菜单调用没有抵达该守卫，本场无法判定实际的后续转发结果。

本轮 345 秒关闭，模拟器报告 API 36 和 qemu，私有 ADB 起始设备表为空。两包 UID 不同，在机摘要与宿主一致。八项设置逐项恢复，两包均已卸载并查无，自有模拟器、私有 ADB 和三个监听端口全部回收。核对已保存的本轮原件可运行 `python -B verify.py --stopped-run <本轮私有回执目录>`。上方第 3、4 步描述计划验收，未在本轮触达。

发布前在宿主复核了构建脚本。每次构建生成临时签名口令，两份合成 APK 均通过验签且使用同一证书。本次复核仅构建制品。

## 根因定位与四场景对照修复（待隔离模拟器实测）

基于 AOSP Android 16（`android-16.0.0_r1`）源码复核，2026-11-22 首轮停点的两项根因如下：

1. **未见到输入法按钮位置（`no_menu_event_event=button name=request`）**：
   - `pixel_5` 模拟器默认带硬键盘且 `show_ime_with_hard_keyboard=0`，原输入法隐式 `showSoftInput(right, 0)` 未使当前窗处于已请求显隐态；切到 `MenuIme` 后，IMMS `attachNewInputLocked` 与 `InputMethodService.doStartInput` 不会主动弹出新输入法窗口，原 `MenuIme` 也未调用 `requestShowSelf(InputMethod.SHOW_EXPLICIT)`，导致 `onCreateInputView` 从未触发。
   - 同时，原 `MenuIme` 仅在按钮 `OnLayoutChangeListener` 中单次上报坐标，若首次布局发生在窗口尚未显示或动画入场期，或跨连接代次复用视图，均会漏报 `event=button`。
   - 修复：在 `visible-opted-in` 模式下于 `onStartInput` 显式有界调用 `requestShowSelf(SHOW_EXPLICIT)`，并在 `onStartInputView` / `onWindowShown` 及布局稳定后基于 `WindowManager.getMaximumWindowMetrics()` 去重上报三个按钮坐标与完整生命周期日志。
2. **连接对象编号失配（#3/#4/#5 间探针落到 #4，守卫要求等于最后创建的 #5）**：
   - 切输入法时，`InputMethodManager` 在 `MSG_UNBIND` 经 `startInputInner(UNBOUND_FROM_IMMS)` 创建并送出连接 #4，将 `mServedConnecting` 置 `false`；随后收到 `MSG_BIND` 时 `startInputInner(BOUND_TO_IMMS)` 先无条件调用 `View.onCreateInputConnection()`（创建 #5），再检查 `!mServedConnecting` 后丢弃 #5 并继续沿用 #4。
   - 因此，原靶场 `mine != generation` 守卫以及 `onTextContextMenuItem`/`onProvideAutofillStructure` 记录 `generation` 必然把仍活跃的 #4 误判为旧连接。
   - 修复：改为在 `InputConnectionWrapper.closeConnection()` 跟踪实际失效态，并以未关闭的实测探针连接 `probedConnection` 作为当前连接标识，同时另记 `latest_created` 透明保留 #5 丢弃观测。
3. **零配合标准 `EditText` 与零 UI 输入法对照（AOSP 16 语义与对抗场景）**：
   - AOSP 16 `TextView` 构造会把默认 `IMPORTANT_FOR_AUTOFILL_AUTO` 提升为 `IMPORTANT_FOR_AUTOFILL_YES`；`EditableInputConnection.performContextMenuAction(android.R.id.autofill)` 经 `TextView.onTextContextMenuItem(ID_AUTOFILL)` 调用 `AutofillManager.requestAutofill(this)`（带 `FLAG_MANUAL_REQUEST`），不依赖靶应用的 `privateImeOptions`、同签名、输入连接包装或可见键盘；且 `FLAG_MANUAL_REQUEST` 同时绕过已结束会话的字段已登记拦截，并在活跃会话中强制重新采集结构。
   - 此外，`IRemoteInputConnection.performContextMenuAction` 为 `oneway` IPC，输入法侧返回 `true` 仅表示提交请求，无法感知靶应用吞掉动作返回 `false`；而 `AssistStructure` 对 `FLAG_MANUAL_REQUEST` 会附带 `AUTOFILL_FLAG_INCLUDE_NOT_IMPORTANT_VIEWS`，因此观察服务必须自行尊重 `IMPORTANT_FOR_AUTOFILL_NO` 拒绝选框。
   - 夹具现覆盖四场独立对照，并由 `build.py` 另签一份异签名的 `target-diffsig.apk`，配合 `verify.py --scenario ...` 与隔离驱动 `run_isolated.py` 验收：
     - `opted-in`（同签名 + 可见 3 按钮 IME + #3/#4/#5 守卫修复 + `noop`/`expired`/`request`）；
     - `plain-auto`（异签名 + 未子类化原生 `EditText`、默认 `IMPORTANT_FOR_AUTOFILL_AUTO`、`NO_ID`、零 `privateImeOptions` + 零 UI IME 零布局偏移）；
     - `optout-no`（异签名 + `IMPORTANT_FOR_AUTOFILL_NO` + 零 UI IME，要求 `UNKNOWN / TARGET_OPTED_OUT` 或 0 手动回调，fail-closed）；
     - `swallow-ic`（异签名 + 自定义 `InputConnection` 吞掉 `android.R.id.autofill` 并对 `requestTextBoundsInfo` 返回 `CODE_UNSUPPORTED` + 零 UI IME，要求 0 手动回调、fail-closed）。

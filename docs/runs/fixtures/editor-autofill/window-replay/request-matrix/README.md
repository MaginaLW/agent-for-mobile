# 从逐请求矩阵与无障碍布局尺寸核对匿名编辑窗

**B 仍未通过（真实微信不适用；窄 AOSP 显式像素布局边界已在 API 36 隔离模拟器实测收口）。** 修复后的实验包在全新 API 36 横屏隔离模拟器上完成全部 4 项几何对照与 3 项微信等价对抗对照（共 145 秒，零崩溃，10 项设置与双包卸载全部读回还原）：在显式正像素 `LayoutParams` 且无遮挡的原生空白 `EditText` 上，逐请求仿射矩阵与无障碍 `ExtraRenderingInfo.getLayoutSize()` 可在两窗同时可见时双向识别唯一来源并拒绝单侧错窗，也能在屏幕外框和原点完全重合时区分不同缩放/局部宽；但几何完全重合（`east` vs `overlap`）必然退回 `ambiguous`，而三项微信等价条件（`MATCH_PARENT`/`WRAP_CONTENT`、`CODE_UNSUPPORTED`、透明/不可见焦点节点）全部按预期 fail-closed，不能为 PA2553 微信提供可交付的独立来源窗。[实采脱敏回执](receipts.json) · [历史两次失败收尾](setup-attempt.json) · [宿主复核](verify.py)

候选 `2289925` 使用输入连接的 `requestTextBoundsInfo` 查询屏外空区间，在 PA2553 微信 `e994c71` 实测中已返回 `no_verified_geometry`。#47 本地跟踪版本 `ae93377` 与它的 `app/gateway` 树对象相同。上轮两个匿名实例各自的前后原点都为 `[2100,32]`。本页实测完整矩阵与**从另一条接口得到的本地布局尺寸**的能力边界与失效条件。[固定候选的原点实现](https://github.com/MaginaLW/agent-for-mobile/blob/22899252918ba05abd0cfd393ec1b97a5bcecce3/app/gateway/src/main/java/dev/magina/gateway/ime/EditorOriginProbe.java) · [固定候选实采](../candidate-permissions/receipts.json)

## 两端如何取数

- 输入法沿当前连接先后发出两个不同的屏外空区间请求（`-7`、`-11`）。每个请求有自己的回调，保存发起时刻、应答时刻和九个矩阵元素。只接受 `CODE_SUCCESS`、空范围、可逆的仿射变换；遇到 `InputType.TYPE_NULL` 或 `CODE_UNSUPPORTED` 等非成功码立刻 fail-closed 停采并记录状态。第二次回调后复核同一连接、同一代次及采样前后无障碍窗清单逐字节一致。[输入法观察器](observer/ImeProbe.java) · [InputConnection](https://developer.android.com/reference/android/view/inputmethod/InputConnection#requestTextBoundsInfo(android.graphics.RectF,java.util.concurrent.Executor,java.util.function.Consumer)) · [Android 16 TextView](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-16.0.0_r1/core/java/android/widget/TextView.java#L13747-L13785)
- 无障碍服务在采样前后清缓存，枚举显示屏 0 上所有 `TYPE_APPLICATION` 窗口。对每个靶应用根遍历节点：统计 `isEditable() && !isVisibleToUser()` 的隐藏编辑框数量（`hidden_editors`），对可见可编辑节点先用可写 `new Bundle()` 请求 `EXTRA_DATA_RENDERING_INFO_KEY` 刷新后再原子读取窗内/屏幕四边与 `ExtraRenderingInfo.getLayoutSize()`。`WindowProbe` 只检查 `node.isEditable()` 节点：未知根、目标窗无可见编辑框（`editors=[]`）、存在隐藏编辑框（`hidden_editors > 0`）或 `layout_size` 缺失/非正，均按 `incomplete` fail-closed；若某假想同包窗同时包含一个可见编辑框和另一个被 delegate 剥除 `isEditable=false` 的真实输入节点，则超出本夹具覆盖范围。屏幕阅读、截图、字符位置、剪贴板和编辑动作均未用于采样。[无障碍观察器](observer/WindowProbe.java) · [AccessibilityNodeInfo](https://developer.android.com/reference/android/view/accessibility/AccessibilityNodeInfo#EXTRA_DATA_RENDERING_INFO_KEY) · [ExtraRenderingInfo](https://developer.android.com/reference/android/view/accessibility/AccessibilityNodeInfo.ExtraRenderingInfo#getLayoutSize())
- 参照来自同包同类的空白原生浮动 Dialog Activity（底层由普通横屏全屏空白 `LandscapeHost` 维持 `2340 × 1080` 横屏）。每个实例以独立任务（`FLAG_ACTIVITY_NEW_TASK | FLAG_ACTIVITY_MULTIPLE_TASK`）启动，独立记录自己的窗号、任务号、屏幕四边、实际测量尺寸与 `requestTextBoundsInfo` 回调时刻。靶回执只用于验收，匹配函数只接收 IME 矩阵和无障碍节点尺寸/四边，不依赖无障碍的 `active`/`focused` 标记。[合成靶](target/TargetActivity.java) · [横屏底窗](observer/LandscapeHost.java)

## 历史两次失败根因与修复

- 首次准备（187 秒，`no_target_west.json`）：靶仅声明 `setFocusedByDefault(true)`，西窗未建立焦点回执。
- 第二次准备（273 秒，`no_target_east.json`）：(1) `ImeProbe.onStartInput` 在调用 `collect()` 前先调 `WindowProbe.read()`，而 `WindowProbe.read()` 将不可写 `Bundle.EMPTY` 传入 `refreshWithExtraData`，直接抛出 `UnsupportedOperationException: ArrayMap is immutable`，导致西窗虽有 5 次连接但矩阵请求为 0；(2) 半透明 Dialog 靶剥离 `screenOrientation` 后缺少 `LandscapeHost` 继承竖屏，且未以 `FLAG_ACTIVITY_MULTIPLE_TASK` 拉起东窗，导致东窗未生成独立实例回执。[两次失败记录](setup-attempt.json)
- 本轮修复并新增构建脚本与对抗项：改用可写 `new Bundle()`、刷新后原子读几何、`CharSequence` `contentEquals` 校验、`hidden_editors` 计数与 fail-closed、`ImeProbe` 有界重试与全分支状态记录、`TargetActivity` `setFinishOnTouchOutside(false)` 与 `AtomicFile`/同步保护，以及 `match_parent` / `unsupported` / `opaque` 三项微信等价对抗对照；两包使用各自独立的一次性 RSA-3072 密钥签名。[构建脚本](build.py) · [材料组装](prepare.py) · [代码与编译指纹](prepared.json)

## API 36 隔离实测判定表

2026-11-22，全新 API 36 横屏（`2340 × 1080`）隔离模拟器，私有 ADB `ADB_USB=0` / `ADB_MDNS=0` / `ADB_EMU=1`、启动前实读空设备表。靶与观察器分属不同 UID（`10216` / `10217`）与独立签名密钥，在机 APK SHA-256 与构建摘要逐字节一致，全程 145 秒，零 `AndroidRuntime` 异常。

| 场景 / 对照 | 实测观测（API 36 实时回执） | 判定器结果 | 结论 |
|---|---|---|---|
| **活体双窗 `east`**（`west` 同时可见） | 窗 11 活跃 `[2056,188,2256,258]`，窗 10（`west`）同时可见 `[652,188,852,258]`，两框均匿名且无障碍 `focused=true`；IME 矩阵 `[1,0,2056,0,1,188,0,0,1]`，两发回调时刻与靶严格嵌套 | `unique_within_supplied_nodes`，`compatible_window=11`（实时排除窗 10） | PASS（空间分离正控） |
| **活体双窗 `west`**（`east` 同时可见） | 窗 13 活跃 `[652,188,852,258]`，窗 12（`east`）同时可见 `[2056,188,2256,258]`；IME 矩阵 `[1,0,652,0,1,188,0,0,1]`，两发回调严格嵌套 | `unique_within_supplied_nodes`，`compatible_window=13`（实时排除窗 12） | PASS（反向双窗正控） |
| **同外框同原点 `scaled` vs `east`** | 窗 14 外框 `[2056,188,2256,258]`、原点 `[2056,188]` 与窗 11 完全重合，局部宽 `100`、矩阵 `scaleX=2`（`[2,0,2056,0,1,188,0,0,1]`） | 冻结双窗双向唯一选中自身（11 / 14）；单错窗投入双向返回 `different_geometry`、`compatible_window=null` | PASS（同原点缩放区分 + 双向拒错） |
| **同外框同尺寸 `overlap` vs `east`** | 窗 15 外框 `[2056,188,2256,258]`、局部 `[200,70]`、矩阵 `[1,0,2056,0,1,188,0,0,1]` 与窗 11 完全相同 | 双向返回 `ambiguous`，`compatible_window=null` | PASS（几何重合诚实拒判） |
| **微信对抗 1：`match_parent`** | 窗 16 标准 `MATCH_PARENT`/`WRAP_CONTENT` `EditText`，实测局部尺寸 `[608,124]`，无障碍 `getLayoutSize()` 返回 **`[-1,-2]`** | `incomplete`，`unresolved_windows=[16]`，`compatible_window=null` | PASS（证实真实非显式像素布局不可用） |
| **微信对抗 2：`unsupported`** | 靶 `InputConnectionWrapper` 返回 `CODE_UNSUPPORTED`（`0`），靶收到 1 次请求；观察器 `probe-state=result_code_0`，`matrix.json` 不存在 | 零矩阵落盘，`compatible_window=null` | PASS（复现 PA2553 `e994c71` 拒判） |
| **微信对抗 3：`opaque`** | 窗 18 `AccessibilityDelegate` 置 `visible=false, focused=false`；`WindowProbe` 实读 `hidden_editors=1, editors=[]` | `incomplete`，`unresolved_windows=[18]`，`compatible_window=null` | PASS（复现 PA2553 隐藏焦点节点拒判） |
| 宿主负控（删 `layout_size` / `hidden_editors=1` / `unknown` 根） | 基于活体实采节点注入单侧缺失、隐藏或未知根 | 三项均为 `incomplete`，`compatible_window=null` | PASS（fail-closed） |

收尾核验：10 项系统设置逐项读回与入场值完全相等，两实验包卸载后 `pm path` 均为空，专属模拟器、私有 ADB 服务、临时 AVD 与全部专用端口均已释放。

## 离线复核

```powershell
python docs/runs/fixtures/editor-autofill/window-replay/request-matrix/verify.py
```

默认入口复核：历史两次失败记录（`setup-attempt.json`）、本次 API 36 完整脱敏实采回执（`receipts.json`，含活体双窗双向、冻结同原点缩放、重合拒判与三项微信等价实机对抗）、编译与源码指纹（`prepared.json`）以及宿主模型断言。命令退出 0 表示全部断言通过。独立编译脚本入口：`python build.py <不存在的输出目录> --sdk <SDK35路径> --jdk <JDK21路径>`。[核对脚本](verify.py) · [实采回执](receipts.json)

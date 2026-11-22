# 同包两窗口的结构来源回放

**公开观察器的 B 回放未通过。** 在 JDK 宿主上把同一右框输入连接分别配给本窗结构和同包另一窗口的结构，当前观察器两次都给出 `MATCH / RIGHT / [2160,32,2360,102]`。两份终结回执的全部 JSON 字段相同。正确窗的侧别和坐标碰巧与模型真值一致，观察器缺少独立认定来源的证据。错误窗的字段号一旦与本窗重复，也会通过。两场可归属于活动右窗的侧别与四边均留空。

后续在 API 36 模拟器上，以有系统诊断权限的宿主取得了两个真实实例的请求、窗口客户端及无障碍窗口号。各自正配都通过，保持来源证据原样、交叉指定目标窗时均拒绝。该结果覆盖单来源窗的合成手动请求。[两窗系统来源实测](system-source/README.md)

随后在另一台空白 API 36 模拟器上实测了 #47 固定候选的普通权限。有资源名的两个右框均返回各自的活动窗号和相同四边，匿名框都在请求几何之前停止。补充观察器能识别活动窗 22、24，输入绑定和原生字段号在两个实例间重复。整份回执遇到外部目标窗号可以比对，只交换几何来源假设时缺少独立的窗号。B 仍未通过。[固定候选的四场与双向对照](candidate-permissions/README.md)

另一条普通权限路线尝试把每次输入连接回调中的完整变换矩阵，与无障碍节点的布局尺寸及屏幕四边配对。修复前两次 API 36 尝试有效请求对为 0；修复版在全新隔离 API 36 横屏模拟器实测收口（145 秒，10/10 设置与双包卸载读回还原）：在显式正像素原生 `EditText` 上通过了活体双窗双向归属与同原点不同缩放区分，几何完全重合（`east` vs `overlap`）退回 `ambiguous`，而三项微信等价对抗（`MATCH_PARENT`/`WRAP_CONTENT` 返回 `[-1,-2]`、`CODE_UNSUPPORTED`、透明/不可见焦点节点 `hidden_editors=1`）全部 fail-closed。该路线收口为窄 AOSP 边界结论，不适用真实微信。[矩阵与布局尺寸的实采边界和回放](request-matrix/README.md)

## 判定表

坐标均为屏幕像素，顺序为左、上、右、下。“可归属结果”需要来自观察器以外的相应参照。单窗口旧模拟器实测、此次宿主模型和 PA2553 真机各有独立的证据范围。

| 场景与参照 | 候选数 | 原始消费结果 | 可归属结果与验收 |
|---|---:|---|---|
| 单窗口内右框，历史 API 36 手动场。唯一前台靶窗口，右连接独占探针，靶应用另测四边；宿主 `single-right` 复核同一组数值 | 2 | `MATCH / RIGHT / [2100,32,2300,102]` | 该单窗实测选中右框，四边吻合 |
| `correct-window`。模型活动窗和结构来源均为 `active-right`，只有该窗右连接收到探针 | 2 | `MATCH / RIGHT / [2160,32,2360,102]` | 侧别空，四边空。双窗正例未通过 |
| `wrong-window`。模型活动窗仍为 `active-right`，结构来自同包同类另一实例 `other`，该实例两框探针数均为 0 | 2 | `MATCH / RIGHT / [2160,32,2360,102]` | 侧别空，四边空。应拒绝，实际误接受 |
| `wrong-distinct-ids`。另一个来源窗的两个字段号与连接均不同 | 2 | `NO_ID_MATCH` | 侧别空，四边空。按字段号不匹配拒绝 |
| `overlap`。连接在左，两框均为 `[40,32,240,102]`，有历史 AVD 独立参照 | 2 | `INDISTINGUISHABLE_BOUNDS` | 侧别空，四边空 |
| `focus-conflict`。靶左连接收到探针，结构焦点与请求都在右，有历史 AVD 独立参照 | 2 | `FOCUS_DISAGREES` | 侧别空，四边空 |
| `previous-left`。旧阶段左连接收到探针。历史首次自然左场另有靶测四边 | 2 | `MATCH / LEFT / [40,32,240,102]` | 只在左阶段有左框和四边 |
| `delayed-old-structure`。同一对控件切至右连接，向观察器延迟送入上行的原结构 | 2 | `STALE_STRUCTURE` | 侧别空，四边空。采集时刻早于新连接 |
| 既有宿主按阶段复核已完成的 AVD 左场回执，原样投至右场／仅延迟回调时间 | 沿用旧回执 | 分别为 `PRE_STAGE_CALLBACK`、`PRE_STAGE_STRUCTURE` | 侧别空，四边空。这两项引用既有回放记录 |
| `optout`。沿用合成实验阶段 3 的显式排除约定，历史 AVD 有排除回执 | 0 | `TARGET_OPTED_OUT`；读窗口根 0 次 | 侧别空，四边空。连接代次与采集开始时间均空 |

历史场景的靶应用在实际收到探针时按控件计数，用 `getLocationOnScreen()` 和控件宽高取得四边。历史右框阳性来自 2340 × 1080 的**单一应用窗口**。同包两窗回放中的活动窗位于屏幕右部，其窗口原点、矩形和来源均为模型量。PA2553 既有回执只核实了活动右窗及标题，第五读 `missing_id / before_sample / field_id_unresolved`，没有该轮的结构来源窗或编辑框四边。[既有 AVD 回执与旧样本回放](../README.md) · [靶应用](../target/TargetActivity.java) · [PA2553 只读复核](../../../../knowledge/apps/wechat.md#横屏编辑框的四边能否单独确定输入目标)

## 来源与可观察输入

| 待核实的量 | 回放如何取得参照 | 观察器实际可见的量 |
|---|---|---|
| 哪个窗口持有连接 | 宿主绑定 `active-right` 的右控件，真正调用实验输入法的 `onStartInput`，由收到探针的连接单独计数。窗口实例标签只供宿主输出 | 靶 UID、包名、当前连接及代次、`EditorInfo` 的原生字段号 |
| 结构来自哪个实例 | 两个独立的合成 Activity 各自构造自己的树。宿主用对象身份记录每棵树的生产者，换来源时仍用同一个输入连接 | 同一 Activity 组件名、一个结构窗口、相同的结构采集和回调时刻、字段号及焦点。两个同类实例可共享组件名 |
| 完整屏幕四边 | 宿主布局将窗口放在 `x=1200`，宽 1200；右框局部左缘为 960，宽 200，顶边 32，高 70。两窗布局相同 | 观察器从窗口原点累加节点局部偏移，得到屏幕四边。两场右框矩形均在预设活动窗范围内 |

两场从同一个输入连接快照分别运行。正确窗的自动填充会话号为 7，错误窗为 13。宿主断言两场会话号不同，每棵树的两个字段均与该场请求焦点同号。各窗内左右字段号不同，两窗的右字段号相同。观察器保留完整标识相等、节点属于会话等布尔值和计数，这些结果在两场相同。实际选框使用原生 `getViewId()`，它在这里剥离了会话差异。Android 16 的 `Activity.getNextAutofillId()` 将唯一性限定在 Activity 实例内。[观察器](../observer/ProbeAutofillService.java) · [Android 16 Activity](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-16.0.0_r1/core/java/android/app/Activity.java)

结构窗口的 `getDisplayId()` 标识显示屏。#47 候选的 `window_id` 来自无障碍窗口和节点检查；本次两种数据之间仍缺可对齐的来源回执。这个构造验证消费者能否拒绝这样的输入，Android 是否实际向微信送达过这种错窗组合仍未知。[WindowNode](https://developer.android.com/reference/android/app/assist/AssistStructure.WindowNode) · [#47 候选中的无障碍窗口检查](https://github.com/MaginaLW/agent-for-mobile/blob/ae93377c71cdb9b3a488b6205003b31871a32099/app/gateway/src/main/java/dev/magina/gateway/tools/EditorBoundsDiagnostic.kt#L528-L533)

## 离线复现

在仓库根目录用 Python 3 与 JDK 17 或更高版本运行。JSON 库沿用项目单测已缓存的 `org.json:json:20240303`，也可用 `--json-jar` 指定本机已存在的 JAR。`--jdk` 可指定 JDK 根目录。

```powershell
python docs/runs/fixtures/editor-autofill/window-replay/replay.py
```

脚本从当前工作树读取实验输入法与观察器完整 Java 源，仅把 Android 导入指向宿主适配类。九场都走 `onFillRequest`，由观察器写出原有格式回执，再由宿主核对。适配类提供固定时钟、同步完成的延迟回调、固定的原生控件和坐标，适用范围是已给定连接和结构时的消费逻辑。输出中的 `host_*` 属于模型参照，`observer_*` 来自原始回执。`window_acceptance=BLOCKED` 表示窗口归属验收未通过。退出码 0 仅表示上述九场行为已复现，包括错窗误接受。基于 `2f80e36` 的观察器于 2026-11-22 用 JDK 21 复核。[回放入口](replay.py) · [场景与断言](WindowReplay.java) · [宿主适配](HostAndroid.java)

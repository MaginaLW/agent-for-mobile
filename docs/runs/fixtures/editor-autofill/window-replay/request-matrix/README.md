# 从逐请求矩阵与无障碍布局尺寸核对匿名编辑窗

**B 仍未通过。两次隔离 API 36 尝试共取得 0 组可验收的 IME 矩阵与无障碍布局尺寸。** 已知的西窗四边只来自合成靶。修复后的两个实验 APK 已编译；收尾时没有安装或运行该版本。宿主模型验证了一个条件：屏幕外框和原点重合时，若两窗有不同的显式本地尺寸和比例变换，两条独立接口的数据可能排除错窗。完全同矩阵、同尺寸时，该方法保留两个相容来源。候选与微信的独立来源窗、侧别及四边均空。[两次设备收尾](setup-attempt.json) · [宿主复核](verify.py)

候选 `2289925` 使用输入连接的 `requestTextBoundsInfo` 查询屏外空区间。实现验证请求前后为同一会话和连接，在成功的空结果中读取矩阵，最后只导出屏幕原点。#47 本地跟踪版本 `ae93377` 和它的 `app/gateway` 树对象相同。上轮两个匿名实例各自的前后原点都为 `[2100,32]`。本页检验完整矩阵与**从另一条接口得到的本地布局尺寸**能否增加区分力。[固定候选的原点实现](https://github.com/MaginaLW/agent-for-mobile/blob/22899252918ba05abd0cfd393ec1b97a5bcecce3/app/gateway/src/main/java/dev/magina/gateway/ime/EditorOriginProbe.java) · [固定候选实采](../candidate-permissions/receipts.json)

## 两端如何取数

- 输入法沿当前连接先后发出两个不同的屏外空区间请求。每个请求有自己的回调，保存发起时刻、应答时刻和九个矩阵元素。只接受成功、空范围、可逆的仿射变换。第二次回调后再次检查同一连接和代次。原生 `TextView` 在空文本或空查询范围时返回其局部到全局的变换矩阵。[输入法观察器](observer/ImeProbe.java) · [InputConnection](https://developer.android.com/reference/android/view/inputmethod/InputConnection#requestTextBoundsInfo(android.graphics.RectF,java.util.concurrent.Executor,java.util.function.Consumer)) · [Android 16 TextView](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-16.0.0_r1/core/java/android/widget/TextView.java#L13747-L13785)
- 无障碍服务分别在采样前后清缓存，枚举默认显示屏上服务可见的应用窗。对每个合成靶根枚举可见可编辑节点，取得窗内/屏幕四边。节点声明支持时，通过 `EXTRA_DATA_RENDERING_INFO_KEY` 单独请求 `getLayoutSize()`。这是布局参数中的宽高，只有两个维度都是显式正像素时才用于本实验的投影。未知根、目标窗没有可用节点、尺寸缺失，均不能据以宣布唯一来源。屏幕阅读、截图、字符位置、剪贴板和任何编辑动作均未用于采样。[无障碍观察器](observer/WindowProbe.java) · [AccessibilityNodeInfo](https://developer.android.com/reference/android/view/accessibility/AccessibilityNodeInfo#EXTRA_DATA_RENDERING_INFO_KEY) · [ExtraRenderingInfo](https://developer.android.com/reference/android/view/accessibility/AccessibilityNodeInfo.ExtraRenderingInfo#getLayoutSize())
- 参照来自同包同类的空白原生 Activity。每个实例独立记录自己的窗号、任务号、屏幕四边、控件实际尺寸，以及自己的输入连接收到请求与发回结果的时刻。合成 Activity 首次取得窗焦点时让唯一的空白编辑框获得初始焦点，并检查结果。两个只读请求期间不移动焦点。靶回执只用于验收，匹配函数只接收 IME 矩阵和无障碍节点尺寸/四边。[合成靶](target/TargetActivity.java) · [匹配与核对](verify.py)

对本次显式正尺寸、正向轴对齐变换的原生控件，宿主分别把每个节点的 `(0,0)` 和 `(宽,高)` 经该次 IME 矩阵投影。只有投影的四边与该节点的实测屏幕四边逐边相等，才计作与该矩阵相容。会话代次及请求序号只核对采样归属、顺序与新鲜度。该判据依赖所见窗口集及几何差异，没有把任何一个几何量定义为窗口身份。

`LayoutParams` 是请求的尺寸。即使宽高均为正，父布局也可能给子控件分配不同的实际测量尺寸。本夹具对每个正常样本另用靶内 `getWidth()/getHeight()` 验证该前提。候选一般无法读取另一应用的靶内测量值。缩放、裁剪、放大、未枚举的应用窗及虚拟节点均会限制可用范围。[布局尺寸接口](https://developer.android.com/reference/android/view/accessibility/AccessibilityNodeInfo.ExtraRenderingInfo#getLayoutSize())

首次新建模拟器只声明默认编辑框，西侧窗口没有写出已获焦点的靶内回执，187 秒后收尾。第二次准备在靶首次获得窗焦点时建立初始右焦点。靶内测到西窗和右框，输入连接收到的矩阵请求仍为零。观察器曾把不可写的 `Bundle.EMPTY` 传给 `refreshWithExtraData`；框架会在参数中写入请求键，引发观察器自身的 `ArrayMap is immutable` 异常。东窗随后没有靶内回执，其直接原因未确认。第二场耗时 273 秒。两次均未得到有效请求对，十项设置恢复，自有进程和端口均释放。最终观察器使用新的可写空 Bundle。[两次准备失败及收尾](setup-attempt.json) · [Android 16 的请求键写入](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-16.0.0_r1/core/java/android/view/accessibility/AccessibilityNodeInfo.java#L1287-L1296)

## 判定表

| 材料 | 检查 | 结果 |
|---|---|---|
| 既有原版候选，匿名窗 17 与 19 | 正常请求各自的前后原点 | 两窗均为 `[2100,32]`。原版回执省略矩阵中的缩放元素。 |
| 本轮 API 36 第二次准备 | 西窗靶内独立记录 | 窗 15，四边 `[556,324,756,394]`，实际本地尺寸 `[200,70]`，连接建立 5 次、矩阵请求 0 次。未取得同时刻的无障碍窗清单，单次可见同包窗数与匿名节点数未知。 |
| 宿主正控，两个屏幕位置分离 | 两个不同矩阵分别与两窗比较 | 两个方向都只和自身相容。 |
| 宿主正控，同原点、同屏幕四边 | 两窗局部宽 200、100，对应横向比例 1、2，高均为 70 | 两个方向都只和自身相容。丢弃缩放后，两个原点相同。 |
| 宿主碰撞，同原点、同尺寸、同矩阵 | 只更换假设来源，两种遍历顺序 | 均保留两个相容节点，归属空。 |
| 宿主缺失，另一个节点尺寸不定或应用窗没有根 | 已知一个节点的几何吻合 | 两类未决材料都保留，归属空。 |

后三种几何和位置分离正控的窗口号、尺寸和变换由宿主提供。没有实测两窗同时可见或在真实回调上双向排除错配。修复版加入了普通横屏底窗、显示范围内的布局和启动状态回执；它们属于已编译夹具。观察器只绑定既有的输入法和无障碍两种角色。[材料组装](prepare.py) · [横屏底窗](observer/LandscapeHost.java)

## 离线复核

```powershell
python docs/runs/fixtures/editor-autofill/window-replay/request-matrix/verify.py
```

默认入口读取本页两次关闭记录、上轮原版候选回执，并运行四项宿主控制。输出的 `recorded_android.accepted_live_request_pairs` 为 0，`synthetic_model` 单列模型结果。命令退出 0 表示上述证据和断言复现。源码组装入口 `prepare.py <不存在的输出目录>` 只生成两个实验 App 的构建输入。[核对脚本](verify.py) · [代码与编译指纹](prepared.json)

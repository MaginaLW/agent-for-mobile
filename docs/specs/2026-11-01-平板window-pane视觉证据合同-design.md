# 平板 window/pane 视觉证据合同设计与评审

日期：2026-11-01。源码审查基线：`02aa177e7991d1244596b9391666553694ee799d`。

本设计承接[平板视觉需求稿](2026-08-23-Android平板适配-design.md#后续视觉合同的离线准备)及[CCC 真机观察](../runs/2026-11-01-C1b原字节传输候选验收.md)。它规定后续实现必须证明的证据关系，**不是已实现的机器合同或运行许可**。本轮不新增 schema、fixture、producer、依赖或生产接线，不更改冻结的 C1a/v2 与现行 C1b 合同，不采截图/OCR、不操作设备。

## 1. 评审结果与范围

设计选择：以唯一目标 window 内的唯一 conversation pane 为作用域，各阶段独立采集；来源、身份、几何、时序、完整性任一项不足即停止对应消费。保持单 display、原生应用多窗和设备端 ConfirmOverlay 逐次确认，不采用整屏坐标或 IME-only 兜底。

设计可以进入后续来源可行性核定；**当前实施与真机准入均未满足**。本轮已有的有效 C1b 采集，只证明两帧中保存了两个微信窗口且 root 完整但 opaque；inventory 不完整，拓扑、pane 语义、标题/输入/消息区域、可靠 IME 及 safe-area 均未证。T-L1/T-L2/P0/execution 状态不变。

选择先核定来源，再定 wire/schema 和实现：仅给现有 Bitmap 包装一组 caller 自报字段，不能补出窗口绑定或可信时序。只有窗口 inventory 诊断也不能解决 opaque 树的 pane 语义；两类缺口分别跟踪，不要求以重复 C1b 采集代替视觉来源设计。

## 2. 已实现能力与复用边界

| 源码入口 | 已有能力 | 本合同仍缺的证明 |
|---|---|---|
| [GatewayA11yService.captureBitmap](../../app/gateway/src/main/java/dev/magina/gateway/a11y/GatewayA11yService.kt) | 对 DEFAULT_DISPLAY 调 takeScreenshot，转换为软件 Bitmap；另有内部节流重试 | 返回值未携带原生 window identity、截图结果时间戳、geometry/epoch、遮挡/覆盖与 pane 归属；不是 window-bound capture |
| [TabletC1bProbe](../../app/gateway/src/main/java/dev/magina/gateway/tablet/c1b/TabletC1bProbe.kt) | a11y window/root exact binding、内存 raw identity、帧内 revision、受限树读取、截断标记 | 没有图像；run-local awN/apN 不能直接成为视觉或跨运行身份，revision 不是视觉 layout epoch |
| [FreshVisionCache](../../app/gateway/src/main/java/dev/magina/gateway/a11y/FreshVisionCache.kt) | forceFresh 绕过缓存调用 loader，可主动 invalidate | loader 是否真采新图、来源时间与 pane/geometry 不在该类保证范围内 |
| [FreshVisionSession / FreshActionAtomicity](../../app/gateway/src/main/java/dev/magina/gateway/a11y/FreshActionAtomicity.kt) | fresh loader 及采集前后 revision 一致性检查，可作为局部复用点 | 全局 a11y revision 不是 window/pane 视觉 epoch，loader 与跨源同代仍须另证 |
| [SnapshotRefRegistry](../../app/gateway/src/main/java/dev/magina/gateway/a11y/SnapshotRefRegistry.kt) | session/generation 防跨进程、跨快照静默重绑 | 不证明原生 window/pane，不授予动作；不沿用旧 ref 来绑定新阶段截图 |
| [PreparedTargetEvidenceStore](../../app/gateway/src/main/java/dev/magina/gateway/core/PreparedTargetEvidence.kt) 与 [FocusIdentity](../../app/gateway/src/main/java/dev/magina/gateway/core/FocusIdentity.kt) | 进程内单条证据、单调 TTL，package/identity/bounds 不匹配即清除；a11y/IME 命名空间分离 | 没有 pane、DisplayGeometry 或 layout epoch；默认 120 秒不是视觉 TTL 的已验依据，已有 IME-only 能力不能接作平板退路 |
| [VisionTrustPolicy](../../app/gateway/src/main/java/dev/magina/gateway/a11y/VisionTrustPolicy.kt) | 页面识别与动作 OCR 门槛分开、最小 OCR 裁图尺寸 | 手机像素带/比例不能迁为平板目标区域；置信度不证明语义归属、完整性或新鲜度 |
| [ConfirmCardCapture](../../app/gateway/src/main/java/dev/magina/gateway/overlay/ConfirmCardCapture.kt) | 卡片底色条采样判据 | 不证明整卡、双按钮可见可触达及横屏 safe-area，frame commit 也不等同合成画面已含卡 |

这次只查仓库已使用的接口，不认定其他 Android API 或通道在 PA2553 可用，也不假设服务就绪即能截图。截图失败、受保护内容、节流或超时须可区分，不自动切换通道或继承现有内部重试。

## 3. 必须形成的证据关系

下列名称描述语义，不是新 JSON 字段、枚举或已定协议。未来机器合同须独立版本化、闭合校验；来源证明由实际采集路径和可信验证边界提供，不能由 observation 自报或模型判断替代。

| 对象 | 必须证明的关系 | 缺失或冲突时 |
|---|---|---|
| 采集与时钟 | 固定代码/制品、进程会话、run 与唯一 capture；请求/实际采集/完成时序，图像与关联树/IME 所属采集代；单调时钟域及跨源关联依据 | 时钟域未知、回退、进程重启、token 重用、仅墙钟字符串相同：拒绝时序消费 |
| display 与 geometry | 唯一真实 display，旋转、物理/图像尺寸、缩放、坐标原点、insets/cutout、各坐标空间的变换和 geometry 版本 | 未知、多 display、相互矛盾或变换无依据：停止裁图与动作定位，不默认 display 0 或零 inset |
| window | 原生 identity 在会话内的连续性，owner/display、bounds、可见/遮挡状态、所属 capture/geometry；图像与该 identity 的独立绑定 | 同包多窗不能择一猜测；编号、包名、位置或 bounds 相同不能跨命名空间认同一窗口 |
| pane | 从已绑定 window 内识别的语义 pane，唯一 conversation 角色、bounds、证据来源与连续性；不是一窗一 root 的投影 | unknown role、多个目标、只有左右位置或标题文本：目标准备停止 |
| 区域 | toolbar/title、message viewport、input/editor 各自完整区域，同目标 pane/window/capture/geometry/epoch；标题匹配来自已授权 query | 列表同名行、跨 pane、缺区域、不可见或不唯一：不得生成目标/输入/后验成功 |
| 裁图与 OCR | 先定位绑定 pane 再裁图，在 pane 内识别目标区域；原图→window→pane→crop→OCR 的 X/Y 变换和范围都可校验 | 不能先整屏 OCR 聚类再按 Y 挑入；裁剪不足、退化、越界、变换未知、内容不确定分别停止 |
| IME 与确认 surface | IME 模式/几何/editor 归属、同代 token、insets；确认卡整卡及两个按钮处于可见可触达 safe-area，绑定当前意图 | IME 未知/浮动、错 editor、卡或按钮遮挡：不批准动作；hidden 证据不推广到输入态 |
| epoch 与有效期 | geometry、window/pane 身份/区域、IME/insets 变化引发失效；每阶段有限 TTL、同一单调域内的采集年龄与阶段先后约束 | 过期、未知或漏事件不可排除时停止并销毁相应证据；缓存命中不续 TTL |

原生 raw identity 只在可信采集进程内做 exact 比较，不落盘、不将其无盐哈希当跨运行身份。run-local 标签只作脱敏引用；可信绑定的生成、验证与失效路径必须有源码和受测候选证据。

## 4. 阶段、布局变化与批准生命周期

每个阶段 fresh capture，图像/树/OCR/IME 需有可验证的同代关系；同阶段的起止范围内发生相关布局变化即无效。两个端点看似一致或两个 revision 数相等，不自动证明中间无变化；失效事件覆盖、采集原子性或保守检测方案必须在来源核定中证明。

| 阶段 | 允许消费的证据 | 退出条件 |
|---|---|---|
| 目标准备 | 新 title/toolbar、唯一目标 pane、完整区域和当前 geometry | 目标不唯一/缺区域则不建立准备证据 |
| 输入准备及读回 | 当前 editor 与目标 pane 绑定，输入动作前后分别有新证据，读回只证明 input 内容 | IME/布局变化即停旧链；不能把 input 回显当消息 |
| 确认意图 | 当前目标、输入内容/动作、geometry/epoch 与卡片可见性绑定 | 仅设备端可见 ConfirmOverlay 的本次允许才构成危险动作批准 |
| 确认后、Enter 前 | 新采集；目标身份、内容与意图仍匹配，批准后无相关布局/IME/insets 漂移，TTL 有效 | 漂移或证据不足使旧批准不可消费；不自动续跑/重弹卡 |
| 动作后验 | 有明确晚于动作的独立新采集，在同目标 pane 的消息区域检查效果 | 动作已分派但区域不可观测时记“效果未核实”；不当作零发送、不据此重发 |
| teardown | 终止状态、关联证据/批准/缓存清除结果，以及可证明的资源释放范围 | 清理未知独立报告，不冒充清理成功；不得因此再执行动作 |

预期弹出 IME 也是布局变化，不能作为忽略 epoch 的例外。完整输入/准备/确认链需要显式重准备设计：新布局下先重新证明目标和输入，再建立新意图；旧批准永不跨 epoch 复活。本轮只确定“旧链失效即停止”，**未批准自动重准备或自动重新确认流程**。stage 之间的内容变化不自动等同 layout epoch 变化，但其判据必须来自有证据的 producer，不能让消费者自行决定“变化可忽略”。

确认卡自身造成的 a11y event 与底层目标布局变化需要来源层区分，不能把任意 event 都等同漂移，也不能因“可能是卡事件”忽略底层漂移。现有手机 revision 特判不是新视觉 epoch 的证明。

批准仅限当前调用的一次执行；失败/终止不复活，也不因 epoch 相同转授给新调用。既有离线 IntentApprovalStore 尚未接入生产，本设计不宣称已补齐该链路。

所有阶段 TTL、允许采集跨度及跨源同步误差上限，必须依据来源的延迟/时钟/失效覆盖证据定量说明。当前数值未获证明，故运行准入阻塞；不默认沿用 120 秒或任意新的阈值，不在本轮为其造“正例”。

## 5. 不完整 window inventory 的独立诊断边界

CCC 两帧各保存四条窗口，不代表原始只返回四条。`windowsTruncated` 可由枚举失败、输入数超过 maximumWindows=16、或窗口必要字段读取失败/非法后丢弃造成；失败细项在 probe 内部存在，但 [C1bRawFrame.toJson / assembler](../../app/gateway/src/main/java/dev/magina/gateway/tablet/c1b/TabletC1bModel.kt)不序列化 diagnosticCodes，当前持久化 observation 不提供足够的原始数量/逐类丢弃依据来归因。unknown type 另使类型 inventory 不完整，不能与丢弃或超限混为一类。

在本轮固定生产链的条件下可以进一步收窄：[Provider](../../app/gateway/src/debug/java/dev/magina/gateway/tablet/c1b/TabletC1bContentProvider.kt)未覆写默认 16 上限，assembler/relabel 不删窗口。单纯枚举失败应保存 0 条，单纯超限且没有 shell rejection 应保存 16 条；实际每帧 4 条且 truncated，故至少各有一次必要字段失败/非法导致的 shell rejection。是否同时超限、丢弃数、失败字段与异常/坏值类别仍未知；这是存量证据与源码的条件推论，不证明 getter 抛错、ROM 缺陷或 probe bug，不改写原始收据。

下一份离线诊断设计只需要回答“枚举失败、预算超限、必要字段失败/非法中的哪类导致缺失”，并保持原有阻断：

- 有界记录枚举成功与否、预算值、输入/尝试/保存/丢弃/未尝试数量的可验证关系；超出可表示上限时用显式溢出状态，不截成看似精确计数。
- 仅用闭合失败阶段/原因和计数；同一窗口按首次停止点归类，短路未读取字段不得当作读取成功或失败。坏值不落盘，不收集原文、异常消息/堆栈、title、raw ID 或图像。
- 分开枚举失败与空清单、超过预算与字段丢弃、合法 unknown type 与读错、root opaque 与树采集不完整。输出不提供业务角色或 topology/layout grant。
- 与固定 run/候选、capture token 和原 observation 绑定；producer/consumer 可对持久数据重算完整性。字段和承载格式需另行审查版本兼容，不直接给现行 closed schema 塞额外字段，也不补写旧 observation。

这只是最小后续设计输入，不创建新代码候选或待真机批次。即使查明丢弃原因，也不能推定“只缺系统窗所以可忽略”、放宽 topology/IME 门，或让视觉来源跳过完整性证明。

## 6. 最小反例评审矩阵

本表是纸面反例推演，**没有新增或执行 fixture**。未来实现应把每行变成对实际 producer/consumer 有效的独立检查，不能让 fake 自报绑定即通过。

| 编号 | 改变的输入 | 必须得到的结果 |
|---|---|---|
| V01 | 同名 query 仅在另一 window 的列表行，目标 toolbar 不匹配 | 不选目标；文本命中不等于会话身份 |
| V02 | marker 的 Y 不变，X/window/pane 换为另一窗 | 不得作目标消息后验，禁止重发 |
| V03 | identity 相同但窗口移动/缩放，旧 crop 不变 | geometry/epoch 失效，旧 rect/ref/批准停止 |
| V04 | 同 bounds 的窗口被另一原生 identity 替换，或进程重启复用标签 | identity 连续性失败，不靠编号重绑 |
| V05 | 旋转、第二 display、图像尺寸与 geometry 不一致 | 拒绝几何/来源消费，不归一化掩盖冲突 |
| V06 | IME/insets 改变或 editor 属于另一 pane | 旧输入/意图/批准链失效，停止，不自动重弹 |
| V07 | 图像、树、IME 来自不同 capture，caller 写相同 token/时间 | 来源/同代校验失败；字段相等不自证 |
| V08 | 裁图遗漏 toolbar/输入/消息区，或卡/双按钮被遮挡 | 明确不可观测，不当作区域不存在或卡已证明 |
| V09 | 存在两个候选 conversation pane 或标题候选 | 唯一性失败；不按左/右、layer、focused 选择 |
| V10 | 过 TTL、单调钟回退/域未知、缓存命中但未新采集 | 失效并清除关联证据；不续 TTL |
| V11 | 一例 root 完整但 opaque，另一例 read_error/节点截断 | 分别为语义不可用/采集不完整，均不能输出区域成功 |
| V12 | 只有整屏变化或 marker 仅在输入区 | 不证明目标消息变化/发送成功 |
| V13 | 后验图早于动作，或动作与采集时钟无法比较 | 效果未核实，不推定未发送，不自动重试 |
| V14 | inventory 为空、枚举失败、超预算、字段丢弃、unknown type | 分别保留来源；不把已存两微信窗当完整 topology，不判 IME hidden |
| V15 | 解码/截图/识别成功后才发现来源错绑，或动作后清理未知 | 拒绝相应结论；保留实际动作/未知清理状态，不反推无副作用 |

## 7. 隐私、兼容与后续准入

后续离线核定见[图像来源可行性](2026-11-01-平板图像来源可行性-design.md)与[窗口清单最小诊断](2026-11-01-窗口清单最小诊断-design.md)：下表第 1 步已形成具体候选与边界，尚未达到第 2 步所需的完整来源证明。原生窗口定向截图不提供自动 pane 结构或严格跨源同代保证；后续最小只读取证范围已列出，尚未取得设备准入。

当前 C1b 截图/OCR 调用恒为零，权限不扩展。未来任何图像方案须在运行前明确最小采集范围、遮挡/保护内容行为、聊天明文及 OCR 临时数据的内存生命周期、保存/脱敏/保留期限、是否离开设备与目标服务；未获相应范围授权前不采集、不上传。当前不选新的第三方视觉服务，不把图像/文本及其内容 hash 写入 Git；不通过后台 display、关闭应用多窗、改权限或降安全门绕过。

| 顺序 | 责任与可交付结果 | 通过所需依据；当前结论 |
|---|---|---|
| 1（可独立并行） | A 核定图像来源；另核定最小 inventory 诊断设计 | 前者需原生 window/图像绑定、时钟、geometry/遮挡与同代证明方案；后者需闭合分类与计数、版本/隐私/consumer 可重算方案。现有来源不足，两者均未实施 |
| 2（依赖来源核定） | A 固定新机器合同、producer/consumer 范围与离线反例 | 每项来源可实现且有验证方法；阶段 TTL/采集跨度/同步误差有依据；不得只增加 metadata 自证。未满足时保持阻塞，不生成运行卡 |
| 3（依赖合同与队列） | A 建受限候选并完成离线门和独立审查 | 只做已核定范围；保持手机与 C1b 冻结边界，按 backlog 配额排期，本轮未启动 |
| 4（依赖固定候选及现场） | C 在新就位报告与专属开跑令后仅做获批采集 | 固定完整 SHA/制品、单设备独占、失败冻结、证据归档；图像/OCR 另有明确范围。本轮没有此许可 |
| 5（依赖真实证明） | A 判 T-L1、再核 T-L2 横屏安全实现 | 来源/完整性/语义/区域全部有真机证据，后续确认卡与 P0 仍各自验收；没有自动跨阶段通过 |

本轮完成标准是需求闭合、真实来源边界可回指、全部反例有停止结果、独立设计审查无遗留阻断性文案问题。**完成设计评审不代表解除上述实施或真机阻塞**。评审过程、验证和当前接力点见[本轮记录](../runs/2026-11-01-平板视觉合同评审.md)。

# Mika 参考：任务闭环、知识组织与后台屏

> 2026-11-01 查阅；🔵 未实测。对象：[wangzan101/Mika](https://github.com/wangzan101/Mika)，固定上游 SHA `daa6efab22ee88444bbe5de295897f23cf09b1fd`；本项目对照基线 `b65b7d6c309ac3c2d27f86e4a669948f4f6952a1`。仅公开文档与源码静态核对，未安装、构建或运行 Mika，未操作设备。下文建议未实施，不代表验收通过或新增运行许可。

## 结论与架构差异

值得参考的是执行与观察闭环、按需知识加载，以及为失败和接管定义正确结局。独立后台屏是较大的执行架构增量，不能作为当前 vivo 撤销无障碍的已知解法。

| 维度 | Mika（固定 SHA） | 本项目与借鉴边界 |
|---|---|---|
| 大脑与设备 | 手机自带 Agent 循环，连接配置的模型；电脑通过 CLI/MCP 交任务 | 大脑经 Claude Code / Codex CLI 官方订阅通道；设备提供执行器，不引入第二套设备端大脑 |
| MCP | 启动任务、状态、等待、回答、追加、取消 | 本地网关提供设备工具，harness 协调运行；都用 MCP 不代表分层相同 |
| 观察与执行 | a11y、OCR、视觉配合，执行后报告界面效果 | 本地已有 OCR 融合、ref 新鲜度和部分动作后验，先比较实际缺口 |
| 危险动作 | 默认询问主要拦花钱；发送、提交、删除可直接做；自主模式进一步放宽 | 不采纳：本项目发送/支付/删除等仍逐次经设备可见 ConfirmOverlay |
| 兼容范围 | README 自述主要在一台 Android 14 手机上测试 | 不推出 OriginOS、Android 16、PA2553 或本项目平板多窗兼容结论 |

依据：[上游 README][readme]、[架构 §2–6][architecture]、[MCP 说明][mcp]；本地见 [方向一设计](../../specs/2026-07-16-方向一-手机执行器与订阅大脑-design.md) 与 [McpServer.kt](../../../app/gateway/src/main/java/dev/magina/gateway/mcp/McpServer.kt)。

## 1. 动作结果与任务结果分开核实

**适用条件**：工具没抛错，但目标页面、输入内容或最终任务是否完成仍不明确。

**已查见的做法**：Mika 的 [ActionEffect][effect] 区分明显变化、局部变化、无变化、换 App/页面，另报输入读回、可能仍在加载、树无法观察目标区域等信息。“树看不到变化”不等于“没有点上”。[EvidenceLedger][evidence] 保存观察并过滤输入框回显，避免把助手自己输入的字当作答案证据。

**本地映射与建议**：已有 [IntentTools.kt](../../../app/gateway/src/main/java/dev/magina/gateway/tools/IntentTools.kt) 对指定目标缺少前台正证据返回 `E_VERIFY_FAIL`；[UiTools.kt](../../../app/gateway/src/main/java/dev/magina/gateway/tools/UiTools.kt) 有 IME 提交后 OCR 读回和 Enter 后验。后续有报告改进需求时，优先明确“已分派 / 界面有变化 / 内容读回一致 / 任务仍未核实”，不把输入框清空当成对方收到，不因未观察到变化自动重发危险动作。

**验证依据与限制**：上述实现已静态核对；上游 [TaskRun.kt][taskrun] 主循环实际设置 `reviewFinalAnswer = false`。有核查器源码、`verified` 字段或来源列表，不代表产品路径已启用最终独立核查，必须看装配点。

## 2. 单步、批量与回放走同一执行入口

**适用条件**：以后增加批量动作、脚本或路线回放，需要避免新入口绕过安全层。

**已查见的做法**：[ActionExecutor][executor] 在执行前处理守卫、目标与审批，持有执行凭证；[架构 §4、§9][architecture] 要求复合工具的子动作回到同一入口，记录 Model / Batch / Script / Replay 等来源，回放逐步核对、对不上交还模型。

**本地映射与建议**：已有 [SafetyGate.kt](../../../app/gateway/src/main/java/dev/magina/gateway/core/SafetyGate.kt) 与 [派单安全前言](../../../scripts/prompts/gateway-executor-preamble.md)。借鉴“每个子动作走原安全链”，不引入新框架，不将回放历史当作本次批准；拒绝、超时、stale 等安全失败仍是终态，不能通过回放或换通道恢复执行。

**验证依据与限制**：核对了上游入口及架构说明，未审计全部调用图，不能保证 Mika 所有工具都无旁路。本地 P0 证据缺口仍以 [安全冒烟规程](../../runbooks/P0-safety-hard-gate-smoke.md) 为准。

## 3. 目标编号便于追踪，不等于放宽旧 ref

**适用条件**：连续读屏后追踪同一元素，或列表滚动导致同名按钮复用。

**已查见的做法**：[RefStabilizer][refs] 以角色、名称、资源 ID、上下文、位移和滚动条件约束编号沿用；同名重复列表项重新分配，退役编号不复用，执行仍解析到当前端口快照。

**本地映射与建议**：已有 [SnapshotRefRegistry.kt](../../../app/gateway/src/main/java/dev/magina/gateway/a11y/SnapshotRefRegistry.kt) 的 session + generation 防跨快照、跨进程静默重绑定。可借鉴重复项、滚动、累计位移反例检查错误提示，不能直接允许旧 ref 指向新快照；危险确认后仍复核目标与证据。

**验证依据**：上游 `next/resolve` 与本地 `beginSnapshot/lookup` 静态对照，未做行为或性能比较。

## 4. 知识写事实，技能写步骤，准入由代码负责

**适用条件**：整理 App 知识，或评估知识如何交给执行器大脑。

**已查见的做法**：[知识格式][knowledge] 分 App、网站事实与跨 App 技能；正文限长，大资料放 references，技能写清完成与停止条件。[KnowledgeIndex][knowledge-index] 扫描元数据、生成索引；架构 §11 描述先给技能索引、按需读全文，App 知识随进入页面补给。

**本地映射与建议**：沿用 [知识库索引](../README.md) 的按需载入，App 事实写对应手册；经证据核实的稳定包名、深链等按现有规则同步 [SkillPack.kt](../../../app/gateway/src/main/java/dev/magina/gateway/core/SkillPack.kt) 的 assets。执行器数据与模型阅读的 Markdown 不是同一种资产，不为格式重做加载器。

**验证依据与限制**：核对格式、索引源码与架构说明；自动加载、自学、试用转正式的效果未验证。上游格式去掉 `verified_on` 等字段，本项目继续保留设备、日期、证据和“🔵 未实测”。外部说明、自学草稿不能改变授权或自动进入安全白名单。

## 5. 评测包含正确失败，隔离调优题与保留题

**适用条件**：未来补充评测，或判断提示词、知识更新是否有效。

**已查见的做法**：[评测说明][eval] 除查询和本机写入，还分不可完成、登录/验证码障碍、不可逆动作；动态答案要求与观察相符。调优题与保留题分池，配对题同池，保留题参与调优后须更换。写入题用运行标记定位自身产物，人工改判要有运行证据。

**本地映射与建议**：复用 [harness 判据经验](harness.md) 和现有任务模板，补题时写清正确终态及证明材料：目标不存在应如实失败、登录墙应接管、证据过期应终止。已有 [派单反例](../../../scripts/tests/dispatch-offline.ps1)，不新建框架；分池先作为出题原则，有足够题量和具体需求再安排。

**验证依据与限制**：只查题集与判据，未运行或复算成功率。该 SHA 的 eval README 仍警告“开发阶段固定自主执行”，而 `TaskRun` 已按 `runApproval` 装配，需交叉核实，不能照抄跑测命令或把不可逆题当安全测试。本文不引入这些题、不重跑一次性运行。

## 后续采用顺序

| 顺序 | 有具体需求时的最小动作 | 前置条件 |
|---|---|---|
| 先参考 | 结果层级、任务负例与证据要求 | 复用已有机制；本轮仅研究归档 |
| 后评估 | 读屏质量诊断、动作效果表达、知识发现体验 | 先从已有失败记录定位缺口，再选小范围候选 |
| 远期研究 | 独立后台屏、路线回放、设备端沙箱 | 明确需求与验收范围，不占当前 C 队列 |

后台屏权限、焦点与本地阻断条件见 [Android 通用知识](../android/common.md#mika-独立后台屏参考)。当前优先解决 C1b 与既有安全验收，不新增真机批次，不改变单显示/只读采集边界。

## 可复查来源

以下均固定到同一上游 SHA；重查时另固定版本，不把 main 的新行为归入本次结论。本文未复制实现代码，后续移植须另核查文件及组件许可证。

[readme]: https://github.com/wangzan101/Mika/blob/daa6efab22ee88444bbe5de295897f23cf09b1fd/README.md
[architecture]: https://github.com/wangzan101/Mika/blob/daa6efab22ee88444bbe5de295897f23cf09b1fd/docs/architecture.md
[mcp]: https://github.com/wangzan101/Mika/blob/daa6efab22ee88444bbe5de295897f23cf09b1fd/docs/mcp.md
[executor]: https://github.com/wangzan101/Mika/blob/daa6efab22ee88444bbe5de295897f23cf09b1fd/core/src/main/kotlin/com/wangzan101/mika/core/action/ActionExecutor.kt
[effect]: https://github.com/wangzan101/Mika/blob/daa6efab22ee88444bbe5de295897f23cf09b1fd/core/src/main/kotlin/com/wangzan101/mika/core/uistate/ActionEffect.kt
[evidence]: https://github.com/wangzan101/Mika/blob/daa6efab22ee88444bbe5de295897f23cf09b1fd/core/src/main/kotlin/com/wangzan101/mika/core/verify/EvidenceLedger.kt
[taskrun]: https://github.com/wangzan101/Mika/blob/daa6efab22ee88444bbe5de295897f23cf09b1fd/app/src/main/java/com/wangzan101/mika/task/TaskRun.kt#L706-L713
[refs]: https://github.com/wangzan101/Mika/blob/daa6efab22ee88444bbe5de295897f23cf09b1fd/core/src/main/kotlin/com/wangzan101/mika/core/uistate/RefStabilizer.kt
[knowledge]: https://github.com/wangzan101/Mika/blob/daa6efab22ee88444bbe5de295897f23cf09b1fd/docs/knowledge-format.md
[knowledge-index]: https://github.com/wangzan101/Mika/blob/daa6efab22ee88444bbe5de295897f23cf09b1fd/core/src/main/kotlin/com/wangzan101/mika/core/knowledge/KnowledgeIndex.kt
[eval]: https://github.com/wangzan101/Mika/blob/daa6efab22ee88444bbe5de295897f23cf09b1fd/eval/README.md

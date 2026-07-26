# IME 单命名空间降级门 · 设计说明（2026-07-25）

> 状态：**已获项目所有者policy 批准（"允许 Enter 门"）；离线实现已完成，两套单测全绿，真机未验。**
> 实现落点：`FocusIdentity`（新，唯一降级决策点）、两个证据 store、`UiTools`、`SafetyGate`/`SafetyPolicy`、
> `P0WeChatPrepareMacro`、`P0PreparedTargetRecorderValidator`。§6 的 `Start-P0TargetApp` 仍未修。
> 背景根因见 [knowledge/android/common.md #18](../knowledge/android/common.md)。

## 1. 为什么要改

真机确认：本机微信会话页**对无障碍树基本不透明**——`ui_snapshot` 的 a11y 元素恒为状态栏 13 项，
标题/气泡/输入框 100% 来自 OCR，`findFocus(FOCUS_INPUT)` 取不到焦点节点；而 IME 侧（激活状态、
InputConnection、`focusedInputId`）全部正常。与"微信 ≥8.0.52 有意混淆 a11y 节点对抗自动化"吻合。

现有身份模型以 **a11y 焦点节点 id + bounds** 为主键贯穿全链，a11y 一盲则：
`type_text` 成功但不记录输入证据 → `PreparedTargetEvidence` 无法形成 → Enter 必被 SafetyGate 拦。
2026-07-22 的"人工预聚焦 + 无 ref type_text"老路同样被这道门堵死（属有意加固，非回退选项）。

## 2. 改什么（范围：5~6 个安全核心组件）

| 组件 | 现状 | 目标 |
|---|---|---|
| `P0WeChatPrepareMacro.waitForReadyFocus` | 要求 a11y 节点 ready | 允许 IME-only 就绪判据 |
| `P0PreparedTargetRecorderValidator` | `focusValid` 要 a11y 焦点+bounds | IME-only 分支 |
| `PreparedTargetEvidence(Store)` | 以 a11y id+bounds 为键 | 增加身份来源标记 |
| `UiTools.recordInputEvidence` | `focusedInputId(a11y)` 为 null 则不记录 | IME-only 时以 IME 会话身份记录 |
| `InputCommitEvidenceStore` | `record` 硬性要求 id 非空 | 接受 IME-only 身份 |
| `SafetyGate`（Enter 分支） | 要求 a11y id+bounds+IME 三者齐全 | 显式双模式 |

## 3. 设计要点（务必照此实现，不要简化成"删检查"）

1. **降级必须显式，不能靠空值平凡通过。** 直接删掉 a11y 两项检查会让 `blank == blank` 恒真，
   绑定悄悄退化为"无绑定"。必须引入显式身份来源标记（如 `identitySource: A11Y | IME_ONLY`），
   并在每条证据上持久化该标记。
2. **能严则严：a11y 可得时必须走原严格路径。** 仅当 a11y 侧身份**结构性缺失**才允许 IME-only；
   a11y 侧一旦存在就不得降级（防止攻击面从"最严"滑到"最松"）。
3. **IME-only 模式的成链要求**：`imeSessionId` 非空且在 prepared/target/input 三处一致；
   a11y 字段必须**一致地缺失**（不允许一边有一边没有的错配）；`prepared.label`（OCR 会话标题）
   非空且包名匹配。
4. **不要合并两套命名空间做比较**（knowledge #43 的既有教训）：IME-only 是"另一条独立链"，
   不是"把 IME id 当 a11y id 用"。
5. **读回验证不得放弃**：a11y 读不回时走既有 `UiTools.ocrReadbackResult` OCR 读回路径，
   IME-only 模式必须要求读回成功（这是"打进去的字确实落到框里"的唯一剩余机械证据）。
6. **确认卡展示**：焦点 bounds 不可得时，卡片改为展示 OCR 会话标题与输入预览/长度/哈希；
   不得因缺字段而静默少展示一项供真人核对的信息。

## 4. 降级后的证据链与安全权衡（须在 knowledge 落盘）

- **保留**：IME 会话身份、输入长度/SHA-256/预览、OCR 读回校验、OCR 会话标题、包名、
  12 位确认编号、**真人在手机上逐项核对并点击确认**（两段式硬门本身不受影响）。
- **失去**：a11y 焦点节点身份与 bounds，即 knowledge #43"两套命名空间分别复核"中的一套。
- **判断**：真人确认卡仍是最终闸门，且用户能直接看到微信真实界面；OCR 读回补上了"内容确实落框"
  的机械证据。可辩护，但**确实是一次真实的安全强度让步**，必须在 knowledge 中显式记录，
  不得表述为"等价替换"。

## 5. 实现顺序建议

1. 先加身份来源标记与 IME-only 判据的**纯 Kotlin 单测**（`SafetyGateTest`/`PreparedTargetEvidenceTest`
   已有夹具可扩展），把"a11y 可得时不得降级""空值不得平凡通过"两条写成回归用例。
2. 再改证据 store 与 `UiTools` 记录路径。
3. 最后改宏侧就绪判据与 recorder validator。
4. 全量 `testDebugUnitTest`+`testReleaseUnitTest` 绿后再上真机；真机先用
   `dispatch.ps1 -Task "只读..."` 诊断，勿直接整套 `-Provision`（成本见 knowledge #16）。

## 6. 已知附带待修（与本设计相邻，勿混为一谈）

`Start-P0TargetApp` 改为"已在前台就跳过 `am start`"后，网关服务重启后无窗口状态事件触发，
`ForegroundWindowTracker` 拿不到 activity 名 → `foreground_known=false` → W 级工具被拒。
当前靠"人工回桌面让脚本拉起微信"绕过，正式修法是让 tracker 在服务连接时自举当前前台身份。

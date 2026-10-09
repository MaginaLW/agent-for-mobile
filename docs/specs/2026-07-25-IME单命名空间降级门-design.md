# IME 单命名空间降级门 · 设计说明（2026-07-25）

- 决定：项目所有者 2026-07-25 批准该 policy（"允许 Enter 门"）；已离线实现
- 实现落点：`FocusIdentity`（唯一降级决策点）、两个证据 store、`UiTools`、`SafetyGate`/`SafetyPolicy`、`P0WeChatPrepareMacro`、`P0PreparedTargetRecorderValidator`
- 当前状态见 [STATUS.md](../../STATUS.md)；背景与真机实锤见 [knowledge/android/common.md「App 屏蔽无障碍树与 IME 单命名空间降级」](../knowledge/android/common.md)
- 上游：[危险动作统一硬门](2026-07-19-危险动作统一硬门-design.md) §4.3

## 1. 为什么要改

真机确认：微信会话页**对无障碍树基本不透明**——a11y 元素只剩状态栏，标题/气泡/输入框全部来自 OCR，`findFocus(FOCUS_INPUT)` 取不到焦点节点；而 IME 侧（激活状态、InputConnection、`focusedInputId`）全部正常。

原身份模型以 **a11y 焦点节点 id + bounds** 为主键贯穿全链，a11y 一盲则 `type_text` 不记录输入证据 → `PreparedTargetEvidence` 无法形成 → Enter 必被 SafetyGate 拦。2026-07-22 的"人工预聚焦 + 无 ref type_text"老路同样被这道门堵死（属有意加固，非回退选项）。

## 2. 改动范围

| 组件 | 原状 | 目标 |
|---|---|---|
| `P0WeChatPrepareMacro.waitForReadyFocus` | 要求 a11y 节点 ready | 允许 IME-only 就绪判据 |
| `P0PreparedTargetRecorderValidator` | `focusValid` 要 a11y 焦点+bounds | IME-only 分支 |
| `PreparedTargetEvidence(Store)` | 以 a11y id+bounds 为键 | 增加身份来源标记 |
| `UiTools.recordInputEvidence` | a11y `focusedInputId` 为 null 则不记录 | IME-only 时以 IME 会话身份记录 |
| `InputCommitEvidenceStore` | `record` 硬性要求 id 非空 | 接受 IME-only 身份 |
| `SafetyGate`（Enter 分支） | 要求 a11y id+bounds+IME 三者齐全 | 显式双模式 |

## 3. 设计约束（不得简化成"删检查"）

1. **降级必须显式，不能靠空值平凡通过。** 直接删掉 a11y 两项检查会让 `blank == blank` 恒真，绑定悄悄退化为"无绑定"。必须使用显式身份来源标记（`identitySource: A11Y | IME_ONLY`），并在每条证据上持久化。
2. **能严则严：a11y 可得时必须走原严格路径。** 仅当 a11y 侧身份**结构性缺失**才允许 IME-only；a11y 侧一旦存在就不得降级。
3. **IME-only 成链要求**：`imeSessionId` 非空且在 prepared/target/input 三处一致；a11y 字段必须**一致地缺失**（不允许一边有一边没有）；`prepared.label`（OCR 会话标题）非空且包名匹配。
4. **不合并两套命名空间做比较**：IME-only 是另一条独立链，不是"把 IME id 当 a11y id 用"。
5. **读回验证不得放弃**：a11y 读不回时走 OCR 读回，IME-only 模式必须要求读回成功（"字确实落到框里"的唯一剩余机械证据）。
6. **确认卡展示**：焦点 bounds 不可得时，卡片改为展示 OCR 会话标题与输入预览/长度/哈希；不得因缺字段而静默少展示供真人核对的信息。

## 4. 安全权衡

- **保留**：IME 会话身份、输入长度/SHA-256/预览、OCR 读回校验、OCR 会话标题、包名、12 位确认编号、**真人在手机上逐项核对并点击确认**（两段式硬门本身不受影响）。
- **失去**：a11y 焦点节点身份与 bounds，即"两套命名空间分别复核"中的一套。
- **判断**：真人确认卡仍是最终闸门，用户能直接看到微信真实界面，OCR 读回补上"内容确实落框"的机械证据。可辩护，但**确实是一次真实的安全强度让步**，在 knowledge 中显式记录，不得表述为"等价替换"。

## 5. 回归要求

纯 Kotlin 单测须把"a11y 可得时不得降级"和"空值不得平凡通过"写成回归用例；`testDebugUnitTest` 与 `testReleaseUnitTest` 全绿后才上真机。真机先用只读派单诊断，不直接整套 `-Provision`。

## 6. 相邻待修（不属于本设计）

`Start-P0TargetApp` 改为"已在前台就跳过 `am start`"后，网关服务重启后无窗口状态事件触发，`ForegroundWindowTracker` 拿不到 activity 名 → `foreground_known=false` → W 级工具被拒。正式修法是让 tracker 在服务连接时自举当前前台身份；是否已修以 [STATUS.md](../../STATUS.md) 与 backlog 为准。

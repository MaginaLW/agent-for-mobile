package dev.magina.gateway.core

/**
 * 语义意图：审批对象从「证据快照」上移之后，人真正批准的那一条东西。
 *
 * 设计见 [语义意图审批 spec](../../../../../../../../docs/specs/2026-08-02-语义意图审批-design.md) §2.1。
 * 字段只放**人能判断、且跨时间稳定**的东西；windowId / activityName / focusIdentity /
 * focusedInputBounds / 身份来源 / 参数指纹**都不在里面**——它们不是不重要，
 * 而是在**执行那一刻**仍被完整校验，只是不再要求「与批准那一瞬相同」。
 *
 * [approvedAtMs] 初始为空，**仅在真人「允许」胜出时原子写入一次且不可刷新**：
 * 拒绝、超时、执行失败与重复回调都不得设置或刷新它（spec §2.4）。本类只负责把这条约束
 * 表达成"可空且没有 setter"，真正的一次性由 `IntentApprovalStore` 保证（落地切分第 2 片）。
 */
data class ApprovalIntent(
    /** 一次性；与 `confirmationId`/nonce 绑定，一条意图只授权一次执行。 */
    val intentId: String,
    /** 档位。II 级才走「批准后延后执行」，I 级仍要求批准与执行紧挨着（spec §6 决定四）。 */
    val riskTier: RiskTier,
    /** 语义动作（「发送消息」），不是 `press_key(enter)` 这种物理动作。 */
    val actionKind: String,
    /** 硬相等，不放宽。 */
    val targetPackage: String,
    /** 人在卡上核对的那一行，来自 `PreparedTargetEvidence.label`。 */
    val targetLabel: String,
    /** 机器比的那一份。 */
    val contentSha256: String,
    /** 与 [contentSha256] 一起锁死内容；单独比 sha256 已经够，长度用于让失败信息可读。 */
    val contentLength: Int,
    /** 人看的那一份明文预览。 */
    val preview: String,
    /** 审批请求建立时刻，**只**用于 `decisionTimeout`，不用于 `intentTtl`。 */
    val createdAtMs: Long,
    /** 真人允许胜出的时刻；`intentTtl` 从这里起算。为空表示尚未获批。 */
    val approvedAtMs: Long? = null,
)

/** [IntentMatchPolicy.matches] 的结论。拒绝一定带原因——失败信息要能直接指出是哪一行不匹配。 */
sealed interface IntentMatch {
    data object Matched : IntentMatch
    data class Rejected(val reason: String) : IntentMatch
}

/**
 * 执行前把「当下的上下文」与「人批准过的意图」对齐。
 *
 * 这是 spec §2.3 判据对照表的**唯一实现点**，表里每一行在这里都有对应判断，
 * 且每一行都在 `ApprovalIntentMatchTest` 里有一条正例和一条反例。
 * **表里任何一行的松动都是安全姿态变更，要改先回 B 道。**
 *
 * 与今天相比刻意**不比**的三项（spec 已如实评估为"更弱"并由用户 08-02 接受）：
 * `activityName`、`identityBootstrapped`、以及 `focusIdentity`/`focusedInputBounds` 的
 * **跨时间相等**。补偿是 [ApprovalIntent.targetLabel] 硬相等——会话名恰恰是人真正核对过的那一项。
 * 执行这一刻三处证据的身份必须**互相自洽**，那一条仍由 `SafetyPolicy` 的既有 `chainValid` 承担，
 * 不在本函数职责内；本函数只管「当下」与「批准那一刻」的对齐。
 */
object IntentMatchPolicy {

    /**
     * @param requiresTargetSession 该动作类是否要求目标会话证据。按 spec §2.5（B 道 2026-09-02
     *   拍板「按档位收窄」）：`press_key(enter)`/`type_text` 与 **II 级** `ui_action` 为 `true`；
     *   **I 级** `ui_action` 为 `false`——它没有会话可言，要求它等于逼实现造一个合成会话。
     * @param nowMs 单调时钟毫秒，与两类证据的 `expiresAtMs` 同源。
     */
    fun matches(
        intent: ApprovalIntent,
        context: SafetyContext,
        nowMs: Long,
        requiresTargetSession: Boolean,
    ): IntentMatch {
        if (context.packageName != intent.targetPackage) {
            return IntentMatch.Rejected(
                "前台包与批准的意图不符：${intent.targetPackage} → ${context.packageName}",
            )
        }

        val input = context.target?.inputCommitEvidence
            ?: return IntentMatch.Rejected("执行前没有短时输入提交证据")
        // 内容锁死：放宽的是可等待时长，不是内容完整性（spec §2.4 末段）。
        if (input.sha256 != intent.contentSha256 || input.length != intent.contentLength) {
            return IntentMatch.Rejected(
                "内容与批准的不一致：长度 ${intent.contentLength} → ${input.length}",
            )
        }
        // 证据必须**未过期**：意图有效期放宽了，证据 TTL 一个字没放宽。
        if (nowMs >= input.expiresAtMs) {
            return IntentMatch.Rejected("短时输入提交证据已过期")
        }

        if (requiresTargetSession) {
            val prepared = context.target?.preparedTargetEvidence
                ?: return IntentMatch.Rejected("执行前没有短时目标会话证据")
            if (prepared.label != intent.targetLabel) {
                return IntentMatch.Rejected(
                    "目标会话与批准的不符：${intent.targetLabel} → ${prepared.label}",
                )
            }
            if (prepared.packageName != intent.targetPackage) {
                return IntentMatch.Rejected("目标会话证据的包与意图不符")
            }
            if (nowMs >= prepared.expiresAtMs) {
                return IntentMatch.Rejected("短时目标会话证据已过期")
            }
        }

        return IntentMatch.Matched
    }

    /**
     * 意图本身是否仍在有效期内。
     *
     * 与 [matches] **刻意分开**：三个时钟必须分开（spec §2.4），`decisionTimeout` 从
     * [ApprovalIntent.createdAtMs] 起算、`intentTtl` 从 [ApprovalIntent.approvedAtMs] 起算，
     * 而 [matches] 管的是证据 TTL——把它们揉进一个函数就没法分别断言了。
     *
     * 未获批（`approvedAtMs == null`）一律不算存活：**没有批准就没有有效期可谈**。
     */
    fun isIntentLive(intent: ApprovalIntent, nowMs: Long, intentTtlMs: Long): Boolean {
        val approvedAt = intent.approvedAtMs ?: return false
        return nowMs - approvedAt < intentTtlMs
    }
}

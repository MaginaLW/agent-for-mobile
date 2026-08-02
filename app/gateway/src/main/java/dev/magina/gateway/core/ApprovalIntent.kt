package dev.magina.gateway.core

/**
 * 语义意图：**人批准的那件事**（spec `2026-08-02-语义意图审批` §2.1）。
 *
 * 字段只放两类东西：人能判断的，以及跨时间稳定的。**windowId / activityName / focusIdentity /
 * focusedInputBounds / 身份来源一个都不在里面**——它们不是不重要，而是要在**执行那一刻**
 * 被完整校验（[IntentMatchPolicy] + 进入前的证据链），不再要求"与批准那一瞬逐字节相同"。
 *
 * 纯数据，不持有任何 Android 对象。
 */
data class ApprovalIntent(
    /** 一次性标识，与 confirmationId/nonce 同源；只在进程内存里，不落盘、不进信封。 */
    val intentId: String,
    val riskTier: RiskTier,
    /** 语义动作，如"发送消息"；不是 `press_key(enter)` 这种实现说法。 */
    val actionKind: String,
    val targetPackage: String,
    /** 人在卡上核对的那一行"目标会话"，来自 `preparedTargetEvidence.label`。 */
    val targetLabel: String,
    /** 内容锁死：有输入内容的动作必须给；没有内容的动作（如点击）为 null。 */
    val contentSha256: String? = null,
    val contentLength: Int? = null,
    val createdAtMs: Long,
)

/** 意图与"执行这一刻"的匹配结论。失败一律带上**逐条点名**的原因。 */
sealed interface IntentMatch {
    data object Matched : IntentMatch

    /**
     * 不匹配。[reason] 必须点名是哪一项、旧值→新值——把"A 或 B 或 C 变了"合并成一句话
     * 是真机排查里最贵的反模式（本仓已记）。
     */
    data class Mismatch(val reason: String) : IntentMatch
}

/**
 * 执行前的意图匹配（spec §2.3 那张表的机械实现）。
 *
 * **这里没有一条是"少比一项"**：跨时间的实现细节相等被换成了**同一时刻的语义相等 + 证据自洽**，
 * 而顶上来的两项（`targetLabel` / `contentSha256`）恰恰是人真正核对过的那两项。
 * 表里任何一行的松动都是安全姿态变更，**要改先回 B 道**。
 */
object IntentMatchPolicy {

    fun matches(
        intent: ApprovalIntent,
        context: SafetyContext,
        nowMs: Long,
        intentTtlMs: Long,
    ): IntentMatch {
        if (nowMs - intent.createdAtMs >= intentTtlMs) return IntentMatch.Mismatch(
            "意图已过期：创建于 ${intent.createdAtMs}，现在 $nowMs，上限 ${intentTtlMs}ms",
        )
        if (!context.foregroundKnown) return IntentMatch.Mismatch("执行前前台身份未知")
        if (context.packageName != intent.targetPackage) return IntentMatch.Mismatch(
            "前台包与意图不符：${intent.targetPackage} → ${context.packageName}",
        )

        val target = context.target
        val prepared = target?.preparedTargetEvidence
            ?: return IntentMatch.Mismatch("执行前没有短时目标会话证据")
        if (prepared.packageName != intent.targetPackage) return IntentMatch.Mismatch(
            "目标会话证据的包与意图不符：${intent.targetPackage} → ${prepared.packageName}",
        )
        if (prepared.label != intent.targetLabel) return IntentMatch.Mismatch(
            "目标会话与意图不符：${intent.targetLabel} → ${prepared.label}",
        )

        if (intent.contentSha256 != null) {
            val input = target.inputCommitEvidence
                ?: return IntentMatch.Mismatch("执行前没有短时输入提交证据")
            if (input.sha256 != intent.contentSha256) return IntentMatch.Mismatch(
                "内容摘要与意图不符：${intent.contentSha256.take(12)} → ${input.sha256.take(12)}",
            )
            if (intent.contentLength != null && input.length != intent.contentLength) {
                return IntentMatch.Mismatch(
                    "内容长度与意图不符：${intent.contentLength} → ${input.length}",
                )
            }
        }
        return IntentMatch.Matched
    }
}

/**
 * 意图的一次性保管处（spec §3）。
 *
 * 不变量 4 改写后的措辞：**一次确认只授权当前这一个意图的唯一一次执行，不生成可重放的通用
 * 令牌；意图不因执行失败而复活。** 这个类就是那两句话的机械实现：
 *
 * - **同一时刻只存一条**：新的一次确认直接顶掉旧的。
 * - **[consume] 取走即销毁**，第二次取一定是 null。
 * - **执行失败也要销毁**——[consume] 发生在执行**之前**，所以"失败后重来"必然拿不到旧意图，
 *   只能重新走一次人的批准。否则"有界等待 + 可重试"凑在一起就长成了决定四那种
 *   看起来有上限、其实是重放口子的东西。
 *
 * 不落盘、不进 MCP 信封 / trace / 审计 / 台账——大脑没有任何路径能拿到它。
 */
class IntentApprovalStore {

    private var pending: ApprovalIntent? = null

    @Synchronized
    fun open(intent: ApprovalIntent) {
        pending = intent
    }

    /** 取走并销毁。返回 null 表示"没有可用的意图"，调用方必须按失败处理，不得放行。 */
    @Synchronized
    fun consume(intentId: String): ApprovalIntent? {
        val current = pending ?: return null
        pending = null
        return if (current.intentId == intentId) current else null
    }

    /** 主动作废（确认被拒、超时、异常收尾）。 */
    @Synchronized
    fun discard(intentId: String) {
        if (pending?.intentId == intentId) pending = null
    }

    @get:Synchronized
    val isPending: Boolean get() = pending != null
}

/**
 * 语义意图路径的装配（[SafetyGate] 的可选构造参数）。
 *
 * [awaitForeground] 没有默认实现，**必须由调用方显式给**：它是"批准后等前台恢复"那段有界等待，
 * 给个默认值等于替调用方决定"不用等也行"。返回 true = 前台已经是目标包。
 */
class IntentApproval(
    val intentIdFactory: () -> String,
    val awaitForeground: (targetPackage: String, budgetMs: Long) -> Boolean,
    val clocks: IntentApprovalClocks = IntentApprovalClocks(),
    val store: IntentApprovalStore = IntentApprovalStore(),
    val clock: () -> Long = System::currentTimeMillis,
)

/**
 * 三个时钟（spec §2.4，用户 2026-08-02 拍定值）。
 *
 * **构造即断言**：`decisionTimeout + foregroundWaitBudget <= 证据 TTL`。这条约束不是风格问题——
 * 一旦越界，人批准之后证据必然已经过期，链**重建不起来**，动作照样做不成，而失败会长得像
 * 一个莫名其妙的 stale。spec 明确要求它"写成断言而不是注释"：写成注释的约束早晚被人改坏。
 *
 * 上限来自两处短时证据的 TTL（[InputCommitEvidence] / [PreparedTargetEvidence] 各自的
 * `DEFAULT_TTL_MS`），**这里引用它们而不是抄一个 120_000**——抄下来的数字会在别人改 TTL 时
 * 悄悄失真，那正是本仓反复栽的那一族。
 */
data class IntentApprovalClocks(
    val decisionTimeoutMs: Long = DEFAULT_DECISION_TIMEOUT_MS,
    val foregroundWaitBudgetMs: Long = DEFAULT_FOREGROUND_WAIT_BUDGET_MS,
    val evidenceTtlMs: Long = minOf(
        InputCommitEvidenceStore.DEFAULT_TTL_MS,
        PreparedTargetEvidenceStore.DEFAULT_TTL_MS,
    ),
) {
    init {
        require(decisionTimeoutMs > 0) { "decisionTimeoutMs 必须大于 0" }
        require(foregroundWaitBudgetMs >= 0) { "foregroundWaitBudgetMs 不能为负" }
        require(decisionTimeoutMs + foregroundWaitBudgetMs <= evidenceTtlMs) {
            "决定期 ${decisionTimeoutMs}ms + 等前台 ${foregroundWaitBudgetMs}ms 超过了短时证据 " +
                "TTL ${evidenceTtlMs}ms：人批准之后证据必然过期，链重建不起来"
        }
    }

    /** 意图自身的有效期：不超过证据 TTL，否则意图还"活着"而证据已经没了。 */
    val intentTtlMs: Long get() = evidenceTtlMs

    /**
     * 按档位取"批准后等前台恢复"的预算（spec §2.2 + §6 题四）。
     *
     * **只有 II 级走"批准后延后执行"**；I 级为 0，批准与执行仍然紧挨着——I 级动作的页面往往
     * 等不起（支付确认页会超时、会话会跳走），而"人已经批准了一笔转账、几分钟后它才真的发生"
     * 这件事本身也不好。
     *
     * **两档仍然都逐次确认**：这里决定的是"批准之后多久执行"，**不是"要不要人点头"**。
     * 分级至今不产出任何免确认路径，这次也没有。
     */
    fun foregroundWaitBudgetFor(tier: RiskTier): Long = when (tier) {
        RiskTier.IRREVERSIBLE -> 0L
        RiskTier.RETRACTABLE -> foregroundWaitBudgetMs
    }

    companion object {
        /** 60 → 90s：人机延迟不再是安全事件之后，可以给人更宽的响应时间。 */
        const val DEFAULT_DECISION_TIMEOUT_MS = 90_000L
        const val DEFAULT_FOREGROUND_WAIT_BUDGET_MS = 30_000L
    }
}

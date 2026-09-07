package dev.magina.gateway.core

/** 只描述本次内存状态转换；不承载可向大脑交付的批准凭据。 */
enum class IntentApprovalOutcome {
    APPROVED,
    DENIED,
    ALREADY_DECIDED,
    ID_MISMATCH,
    NONCE_MISMATCH,
    EXPIRED,
    NO_PENDING,
}

/**
 * 一次确认专用的、最多一条的进程内意图仓；尚未接入 [SafetyGate]。
 *
 * 构造时绑定未批准意图与本次确认的编号/随机 nonce。只有真实审批回调可调用 [decide]，
 * 本类不判断回调来源；今后装配仍须复用本机真人审批的唯一决定入口，不得增加网络写接口。
 *
 * **一个实例只活一轮**：没有 open/reset，不接受已经批准的数据。终态删除整条记录，无法在
 * 原实例重开同 ID，也不需要无限增长的已消费 ID 集合。下一轮必须新建确认与随机凭据，重新
 * 取得真人允许；跨实例的编号/nonce 唯一性由确认创建方承担。
 *
 * [consume] 在返回执行数据之前原子删除记录，调用者随后执行失败也不能复活。返回值只是该次
 * 调用内的数据，调用者仍须保证只执行一次，完成前台复核、参数指纹与严格证据链检查。
 * 不落盘、不进 MCP 信封、trace、审计或台账。
 */
class IntentApprovalStore(
    intent: ApprovalIntent,
    confirmationId: String,
    nonce: String,
    private val timing: IntentApprovalTiming = IntentApprovalTiming(),
    private val clock: () -> Long = { System.nanoTime() / 1_000_000L },
) {
    private data class Entry(
        val intent: ApprovalIntent,
        val confirmationId: String,
        val nonce: String,
    )

    private var pending: Entry? = Entry(intent, confirmationId, nonce)
    private var lastObservedAtMs = intent.createdAtMs

    init {
        require(intent.intentId.isNotBlank()) { "intentId 不能为空" }
        require(confirmationId.isNotBlank()) { "confirmationId 不能为空" }
        require(nonce.isNotBlank()) { "nonce 不能为空" }
        require(intent.approvedAtMs == null) { "意图仓只接受尚未获批的意图" }
    }

    /** 允许与拒绝共用同一把锁；胜出的允许只写一次 approvedAtMs，其他回调不能刷新它。 */
    @Synchronized
    fun decide(confirmationId: String, nonce: String, allowed: Boolean): IntentApprovalOutcome {
        val current = pending ?: return IntentApprovalOutcome.NO_PENDING
        if (current.confirmationId != confirmationId) return IntentApprovalOutcome.ID_MISMATCH
        if (!constantTimeEquals(current.nonce, nonce)) return IntentApprovalOutcome.NONCE_MISMATCH
        val now = readTime() ?: return IntentApprovalOutcome.EXPIRED
        if (!isCurrentAt(current, now)) {
            pending = null
            return IntentApprovalOutcome.EXPIRED
        }
        if (current.intent.approvedAtMs != null) return IntentApprovalOutcome.ALREADY_DECIDED
        if (!allowed) {
            pending = null
            return IntentApprovalOutcome.DENIED
        }
        pending = current.copy(intent = current.intent.copy(approvedAtMs = now))
        return IntentApprovalOutcome.APPROVED
    }

    /**
     * 只消费当前 intentId。匹配的消费尝试先删除再校验；未批准/过期也终结这一轮。
     * 错 ID 不得取走或取消别人的意图。
     */
    @Synchronized
    fun consume(intentId: String): ApprovalIntent? {
        val current = pending ?: return null
        if (current.intent.intentId != intentId) return null
        pending = null
        val now = readTime() ?: return null
        return current.intent.takeIf { IntentMatchPolicy.isIntentLive(it, now, timing.intentTtlMs) }
    }

    /** 定时器只能在对应时钟到期时删除；允许胜出后决策时钟不再取消已批准意图。 */
    @Synchronized
    fun expire(): Boolean {
        val current = pending ?: return false
        val now = readTime() ?: return true
        if (isCurrentAt(current, now)) return false
        pending = null
        return true
    }

    /** 失败/取消收尾；旧调用不能销毁别的意图。 */
    @Synchronized
    fun discard(intentId: String): Boolean {
        if (pending?.intent?.intentId != intentId) return false
        pending = null
        return true
    }

    /** 只反映是否还占用内存槽，不表示已批准或仍在有效期内。 */
    @get:Synchronized
    val isPending: Boolean get() = pending != null

    private fun isCurrentAt(entry: Entry, nowMs: Long): Boolean =
        if (entry.intent.approvedAtMs == null) {
            withinIntentWindow(entry.intent.createdAtMs, nowMs, timing.decisionTimeoutMs)
        } else {
            IntentMatchPolicy.isIntentLive(entry.intent, nowMs, timing.intentTtlMs)
        }

    /** 回退（包括退到批准之后但早于上次观察）必须终结，不能增加剩余预算。 */
    private fun readTime(): Long? {
        val now = try {
            clock()
        } catch (failure: Exception) {
            pending = null
            throw failure
        }
        if (now < lastObservedAtMs) {
            pending = null
            return null
        }
        lastObservedAtMs = now
        return now
    }

    private fun constantTimeEquals(expected: String, supplied: String): Boolean {
        if (expected.length != supplied.length) return false
        var difference = 0
        for (i in expected.indices) difference = difference or (expected[i].code xor supplied[i].code)
        return difference == 0
    }
}

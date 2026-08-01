package dev.magina.gateway.core

/**
 * 「批准 → `E_STALE_REF` → 再批准」这条循环的次数闸门（批次 2，B 道决定四）。
 *
 * **为什么批次 2 必须顺带做这个**：两条错误路径的兜底本来就不对称——
 * 超时 `E_CONFIRM_TIMEOUT` 的 fallback 是"输出 [AWAIT_CONFIRM] 停下报告"，
 * 而批准后 stale 的 fallback 是"重新感知后再发起一次新调用"，**没有次数上限**。
 * 今天这条路几乎不触发（人盯着屏幕两秒点完）；通知审批把窗口拉到十几秒到一分钟，
 * 目标 App 期间来一条新消息就足以让证据不再逐字段相等。所以不选也是选：
 * 现状会随批次 2 一起发货成一个无界循环。
 *
 * 上限 [MAX_RECONFIRMS] = 2 次重弹（连同第一次共 3 张卡）；第 3 次重弹直接拒绝并要求
 * 大脑走 `[AWAIT_CONFIRM]` 停下报告——**不是静默放弃**，用户必须知道自己批准过的事没做成。
 */
class StaleReconfirmGuard(
    private val maxReconfirms: Int = MAX_RECONFIRMS,
    private val ttlMs: Long = TTL_MS,
    private val clock: () -> Long = System::currentTimeMillis,
) {

    private class Entry(var count: Int, var lastAtMs: Long)

    private val entries = HashMap<String, Entry>()

    /** 该键是否已经用完重弹次数；true 表示这次**不该再弹卡**。 */
    @Synchronized
    fun isExhausted(key: String): Boolean = current(key) >= maxReconfirms

    /** 已经重弹过几次（过期即归零）。 */
    @Synchronized
    fun reconfirmCount(key: String): Int = current(key)

    /** 记一次"批准之后才发现 stale"。只有这一种情况计数——超时、拒绝、门前阻断都不算。 */
    @Synchronized
    fun recordStaleAfterApproval(key: String) {
        val now = clock()
        val entry = entries[key]
        if (entry == null || now - entry.lastAtMs > ttlMs) {
            entries[key] = Entry(1, now)
        } else {
            entry.count += 1
            entry.lastAtMs = now
        }
    }

    /** 动作真正成功后清零：这一串重试已经有结果了，不该拖累下一个语义动作。 */
    @Synchronized
    fun clear(key: String) {
        entries.remove(key)
    }

    private fun current(key: String): Int {
        val entry = entries[key] ?: return 0
        if (clock() - entry.lastAtMs > ttlMs) {
            entries.remove(key)
            return 0
        }
        return entry.count
    }

    companion object {
        /** B 道决定四：最多重弹 2 次。 */
        const val MAX_RECONFIRMS: Int = 2

        /**
         * 计数只在一小段时间内有效。没有 TTL 的话，一个跑满次数的键会永久拒绝后续同名动作；
         * 有了它，"很久以后又做一次同样的事"从零开始，而"刚刚那一串重试"仍被正确串起来。
         */
        const val TTL_MS: Long = 5 * 60 * 1000

        /**
         * 计数键。B 道只钉了三条不变量，键的定义归 A 道；这里逐条对齐：
         *
         * 1. **不得把两个不同的语义动作并成一次**（否则第二个动作会莫名其妙被拒）。
         * 2. **不得把同一个语义动作的重试拆成多次**（否则限次形同虚设，退化回无界循环）。
         * 3. 停下时走 `[AWAIT_CONFIRM]`，不是静默放弃——那条在调用方。
         *
         * 于是**参数指纹与 ref 都不能直接当键**，B 道已点名：`press_key(enter)` 的参数恒为
         * `{key:"enter"}`，指纹跨重试完全相同（违反 1）；`ui_action` 的 `ref` 重新感知后必变
         * （违反 2）。
         *
         * 取的四段各司其职：
         * - `toolName`、`riskTier` —— 最粗的区分。
         * - `targetLabel` —— 目标会话（`PreparedTargetEvidence.label`）。重新感知后不变，
         *   不同会话则不同。
         * - `contentKey` —— 区分"同一个目标上的两件不同的事"。`press_key` 用**已提交文本的
         *   SHA-256**：重打同一段文字得同一个值（满足 2），换一段文字就是另一个动作（满足 1）；
         *   `ui_action` 用目标控件文本，它跨重新感知稳定，而 `ref` 不稳定。
         *
         * **已知残留**：同一页上两个文案完全相同的按钮（例如两行各有一个「删除」）会共用一个键。
         * 缓解是 TTL 与成功清零；真要再细分只能引入几何或行号，而那两样恰恰是重新感知后会变的，
         * 会直接违反不变量 2。这里选择宁可偶尔多拒一次，也不让限次退化成无界循环。
         */
        fun key(
            toolName: String,
            riskTier: RiskTier,
            targetLabel: String?,
            contentKey: String?,
        ): String = listOf(
            toolName,
            riskTier.name,
            targetLabel.orEmpty().ifBlank { "-" },
            contentKey.orEmpty().ifBlank { "-" },
        ).joinToString("|")

        /** 从安全上下文取内容键：press_key 用输入摘要，ui_action 用目标控件文本。 */
        fun contentKeyOf(toolName: String, context: SafetyContext): String? = when (toolName) {
            "press_key" -> context.target?.inputCommitEvidence?.sha256
            else -> context.target?.text
        }
    }
}

package dev.magina.gateway.core

/**
 * 「批准 → `E_STALE_REF` → 再批准」这条循环的次数闸门。
 *
 * # 当前状态：纵深防御，**在现行站规下走不到**（2026-08-02 用户重新拍板）
 *
 * 它是批次 2「决定四」的产物，而那条决定**已作废**——用户当初选它时的前提是错的。
 * 前提错在哪：重弹靠的是**大脑再调一次 `press_key`**，不是网关内部循环；而站规
 * `gateway-executor-preamble.md` §4 明令「安全失败就是终态」，`E_CONFIRM_REQUIRED`
 * 与 `E_STALE_REF` 都在它列举的终态码里，且**不得重试同一危险动作**。
 * 于是大脑在第一次 stale 就必须停下报告失败，**计数器连 1 都到不了**。
 *
 * 重新拍板的结果是维持站规、**不开有界重试的口子**。已知并接受的代价：
 * **stale 一发生，用户就白批了一次，整件事得从头再来。**
 *
 * # 那为什么不删掉
 *
 * 上限本身是对的：将来若真有路径能重试（例如把审批对象上移到语义意图那篇 spec 落地），
 * 上限仍该是 2。留着的是判据，不是正在生效的机制。
 *
 * **但请不要以为它在工作。** 本仓栽过「过时预期靠巧合存活」：一条断言/一段代码看起来在
 * 保护什么，实际早已不可达，而没人发现。这段注释就是为了不让它变成第三次。
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
        /** 最多重弹 2 次。当前站规下走不到（见类注释），保留作为纵深防御的上限。 */
        const val MAX_RECONFIRMS: Int = 2

        /**
         * 次数用尽时给大脑的错误消息与下一步。
         *
         * **fallback 必须与站规一致：报告「结果：失败」，不得指示 `[AWAIT_CONFIRM]`。**
         * 站规 §4 把 `E_CONFIRM_REQUIRED` 列为终态并明令不得输出 `[AWAIT_CONFIRM]`；
         * 这里原来写的恰恰是"输出 [AWAIT_CONFIRM] 暂停报告"，**代码反过来教大脑违规**。
         * 2026-08-02 改正。放在这里而不是内联进 ToolRegistry，是为了能被离线用例钉住——
         * 内联的字符串没有任何判据看得见它。
         */
        const val EXHAUSTED_MESSAGE: String =
            "同一危险动作已在批准后连续 $MAX_RECONFIRMS 次因证据变化未能执行，不再重复打扰用户"

        const val EXHAUSTED_FALLBACK: String =
            "按站规报告「结果：失败」并说明已获批准但目标状态反复变化；不得重试同一危险动作，不得输出 [AWAIT_CONFIRM]"

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

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
 * 批准之后重建输入证据的结论（spec §2.4 选项 C）。
 *
 * **三态，"判不了"有自己的名字**——这是发送后验 `sent/not_sent/unverified` 的同一课：
 * 把"读不出来"折进"不匹配"，会让一条**通道故障**长得像一条**内容被换掉**；折进"通过"更糟。
 * 三态都不放行（fail-closed），但**失败原因必须分得开**，否则现场只能靠猜。
 */
sealed interface EvidenceRebuild {
    /** 重新读回来的内容与**卡上给人看过的那份**逐位相同。 */
    data class Rebuilt(val sha256: String, val length: Int) : EvidenceRebuild

    /** 读到了，但与已批准的意图不符——内容在人批准之后被改过。 */
    data class Mismatch(val reason: String) : EvidenceRebuild

    /** 读不回来（OCR 一个字没出、通道不可用、未装配）。**不是"不匹配"，也绝不是"通过"。** */
    data class Unverified(val reason: String) : EvidenceRebuild
}

/**
 * 重建证据的纯判据。
 *
 * **基线是 [ApprovalIntent.contentSha256]——卡上给人看过的那一份**，不是任何一次读回来的串。
 * 这条不是风格问题：发送后验踩过一次假阳性，基线取了 Enter 前那次 OCR 读回的噪声串，
 * 于是"读回来的和读回来的一样"平凡成立。**读回来的东西永远只能当被检验方。**
 *
 * 锚点也只认语义（内容摘要 + 长度），**不认 IME 会话身份**——身份每次 `onStartInput` 必变，
 * 拿它当锚点等于永远重建失败。
 */
object EvidenceRebuildPolicy {

    /**
     * [surfaceLabel] 是**重新读回来的会话页标题**（宏那条 `isConversationSurface` 的同一个信号）。
     *
     * **两处证据都要重建，缺一不可**：目标会话证据与输入证据的 TTL 都是 120s，而用户拍的是
     * 5 分钟——只重建输入证据的话，回来时会以「执行前没有短时目标会话证据」失败，
     * 而那条失败与今天长得一模一样，最难发现。
     *
     * **先验会话、再验内容**：内容对不对，只有在"还在同一个会话"成立之后才有意义。
     * 而且这里重建的是「**还在**同一个会话」这件事，**不是「目标是谁」**——后者等于让被测
     * 组件自己制造它要证明的前提。基线永远来自意图（卡上那份），不来自这次读数。
     */
    fun judge(
        intent: ApprovalIntent,
        readback: String?,
        channel: String,
        surfaceLabel: String?,
    ): EvidenceRebuild {
        if (surfaceLabel == null) return EvidenceRebuild.Unverified(
            "目标会话标题读不回来（channel=$channel）",
        )
        if (surfaceLabel.isEmpty()) return EvidenceRebuild.Unverified(
            "读回的目标会话标题为空，判不了（channel=$channel）",
        )
        if (surfaceLabel != intent.targetLabel) return EvidenceRebuild.Mismatch(
            "目标会话与已批准的不符：${intent.targetLabel} → $surfaceLabel（channel=$channel）",
        )

        val expected = intent.contentSha256
            ?: return EvidenceRebuild.Unverified("意图没有锁定内容，无需也无法重建（channel=$channel）")
        if (readback == null) return EvidenceRebuild.Unverified("输入框内容读不回来（channel=$channel）")
        // 空串是**读不出来**，不是"框被清空了"：OCR 一个字没出与框里真没字，在这条链上
        // 分不开。把它判成 Mismatch 会诬告"内容被换了"，判成通过则是换了触发条件的谎报成功
        // ——`fromOcrReadback` 那次就是后者，而且被自己的用例固化成了预期行为。
        if (readback.isEmpty()) return EvidenceRebuild.Unverified("读回内容为空，判不了（channel=$channel）")

        val actual = InputCommitEvidence.sha256(readback)
        if (actual != expected) return EvidenceRebuild.Mismatch(
            "内容摘要与已批准的不符：${expected.take(12)} → ${actual.take(12)}（channel=$channel）",
        )
        if (intent.contentLength != null && readback.length != intent.contentLength) {
            return EvidenceRebuild.Mismatch(
                "内容长度与已批准的不符：${intent.contentLength} → ${readback.length}（channel=$channel）",
            )
        }
        return EvidenceRebuild.Rebuilt(sha256 = actual, length = readback.length)
    }
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
    /**
     * 批准之后**重建**输入证据（选项 C）：重读输入框、与意图比对，成功则把证据按**当前**身份
     * 重新落进证据仓，返回 [EvidenceRebuild]。
     *
     * **默认是 fail-closed 的 [EvidenceRebuild.Unverified]**：没装配就等于重建不了，
     * 绝不因为"没实现"而放行。
     *
     * **重建的是证据，不是批准**：它不新开意图、不重置一次性，也不延长任何时钟。
     */
    val rebuildEvidence: ((ApprovalIntent) -> EvidenceRebuild)? = null,
) {
    init {
        // **让"5 分钟"这个决定不会悄悄落空的那条断言**，放在这里而不是放在时钟里：
        // 这里能看见通道到底装没装（`!= null`），而时钟只能拿一个**可以写错的布尔**当依据。
        // 判据要挂在能被机械验证的东西上。
        require(
            clocks.foregroundWaitBudgetMs <= clocks.evidenceTtlMs || rebuildEvidence != null,
        ) {
            "等前台预算 ${clocks.foregroundWaitBudgetMs}ms 超过短时证据 TTL ${clocks.evidenceTtlMs}ms，" +
                "却没有装配证据重建通道：人回来时证据必然已经过期，这组数兑现不了"
        }
    }

    /** 没装配就是"重建不了"，**绝不因为没实现而放行**。 */
    fun rebuild(intent: ApprovalIntent): EvidenceRebuild =
        rebuildEvidence?.invoke(intent) ?: EvidenceRebuild.Unverified("未装配证据重建通道")
}

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
    val intentTtlMs: Long = DEFAULT_INTENT_TTL_MS,
    val evidenceTtlMs: Long = minOf(
        InputCommitEvidenceStore.DEFAULT_TTL_MS,
        PreparedTargetEvidenceStore.DEFAULT_TTL_MS,
    ),
) {
    init {
        require(decisionTimeoutMs > 0) { "decisionTimeoutMs 必须大于 0" }
        require(foregroundWaitBudgetMs >= 0) { "foregroundWaitBudgetMs 不能为负" }
        // 意图必须活到等待结束：否则人在预算内回来了，意图却已经先过期——
        // 而现场看到的是一条"照常 E_STALE_REF"的腿，与今天长得一模一样，**最难发现**。
        require(intentTtlMs >= foregroundWaitBudgetMs) {
            "意图有效期 ${intentTtlMs}ms 短于等前台预算 ${foregroundWaitBudgetMs}ms：" +
                "人在预算内回来了意图却先过期，等前台这件事等于白做"
        }
    }

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

    /**
     * 缩短等前台预算的副本。**只许缩短，不许延长**——延长会让"人走开多久还算数"这件事
     * 被调用方悄悄改掉，而那是用户拍板的行为；缩短只会更早终态，方向上是 fail-closed 的。
     *
     * 存在的理由是监督式跑测的 Stale 腿：它按定义**不会**把目标 App 切回来，用满 5 分钟预算
     * 只是让人在手机旁干等（见 runbook §3.3）。
     */
    fun withShorterForegroundWait(budgetMs: Long): IntentApprovalClocks {
        require(budgetMs in 0..foregroundWaitBudgetMs) {
            "只许缩短等前台预算：当前 ${foregroundWaitBudgetMs}ms，给的是 ${budgetMs}ms"
        }
        return copy(foregroundWaitBudgetMs = budgetMs)
    }

    companion object {
        /** 60 → 90s：人机延迟不再是安全事件之后，可以给人更宽的响应时间。 */
        const val DEFAULT_DECISION_TIMEOUT_MS = 90_000L

        /**
         * **用户 2026-08-02 拍板的那 5 分钟就是这个数**（题五）：批准之后最多隔多久回到目标 App
         * 还算数。原话是"足够覆盖『批准了、顺手处理别的事、回来』这个真实场景，而 5 分钟内
         * 基本还记得自己批的是什么"。
         *
         * **它超过短时证据 TTL（120s）是有意的**，正因如此必须装配证据重建通道——
         * 上面那条构造断言把这层依赖钉死，改这个数时躲不开它。
         */
        const val DEFAULT_FOREGROUND_WAIT_BUDGET_MS = 300_000L

        /**
         * 意图有效期。要盖住"等前台"整段，再留一点重建与重新感知的余量。
         * **它不再等于证据 TTL**：选项 C 落地后证据可以重建，两者的耦合理由已经没了
         * （spec §6.1 拍板记录）。
         */
        const val DEFAULT_INTENT_TTL_MS = 360_000L
    }
}

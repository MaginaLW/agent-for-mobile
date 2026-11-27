package dev.magina.gateway.core

import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest
import java.util.UUID

/** 确认前后需要绑定的前台与动态目标证据。revision 仅供审计，不参与硬相等。 */
data class SafetyContext(
    val packageName: String,
    val activityName: String,
    val revision: Long,
    val foregroundKnown: Boolean = packageName.isNotEmpty(),
    /**
     * 前台身份是服务重启后由窗口自举出来的 package 级身份（[activityName] 必为空），
     * 不是窗口事件给出的完整身份。参与确认前后的硬相等，并在确认卡上如实标注。
     */
    val identityBootstrapped: Boolean = false,
    /** 是否处于同应用多窗口（如 vivo 平板横屏平行视界）。 */
    val sameAppMultiWindow: Boolean = false,
    val target: SafetyTarget? = null,
)

data class SafetyTarget(
    val ref: String? = null,
    val text: String = "",
    val description: String = "",
    val bounds: String = "",
    val source: String = "",
    /** 焦点输入身份（含身份来源）；解析不出合法身份时为 null，Enter 门直接拒。 */
    val focusIdentity: FocusIdentity? = null,
    /** a11y 可得时的焦点几何；IME-only 降级时一致地缺失。 */
    val focusedInputBounds: String? = null,
    val inputCommitEvidence: InputCommitEvidence? = null,
    val preparedTargetEvidence: PreparedTargetEvidence? = null,
    /** 同应用多窗口下的所在窗格（left/right/top/bottom 等）；单窗为 null。 */
    val windowPane: String? = null,
)

/**
 * 危险动作风险档位（spec `2026-08-01-危险动作风险分级` 与 `2026-08-02-语义意图审批`）。
 *
 * 判据是**用户在动作完成后，能否用自己手上的手段把它撤销**——不看金额、不看动作名。
 *
 * **两档仍然都逐次确认，不产出任何免确认路径**（硬门不变量 4「一次确认只授权当前这一个
 * 意图的唯一一次执行，不生成可重放的通用令牌。意图不因执行失败而复活」；`SafetyGateTest`
 * 持续钉住：任一档位下，未确认时 handler 调用次数仍为 0）。
 *
 * **两档执行时机差异**（`2026-08-02-语义意图审批` §2.2 / §6 题四）：
 * - **I 级·不可逆**：`foregroundWaitBudget = 0`，批准与执行紧挨着，不进入延后等待；
 * - **II 级·有撤回窗口**：当且仅当具备目标会话与输入锚点时，批准（仅限可见 `ConfirmOverlay`）
 *   后支持 `300s` 有界前台恢复等待与 `360s` 意图有效期；执行前必须通过只读证据重建（或
 *   未超 120s 证据 TTL 的活证据）、严格执行瞬间身份自洽链与 `IntentMatchPolicy.matches`。
 */
enum class RiskTier {
    /** I 级·不可逆：做完之后用户无自救手段，或撤销成本远高于执行成本。 */
    IRREVERSIBLE,

    /** II 级·有撤回窗口：目标 App 提供明确的撤回入口，且窗口未过期。 */
    RETRACTABLE,
}

sealed interface SafetyDecision {
    data object Allowed : SafetyDecision

    data class ConfirmationRequired(
        val toolName: String,
        val action: String,
        val initialPackage: String,
        val actionSummary: String,
        val evidence: List<String>,
        val argsFingerprint: String,
        /** 本次动作的风险档位；新增构造点必须显式给出。 */
        val riskTier: RiskTier,
        val inputLength: Int? = null,
        val inputSha256: String? = null,
    ) : SafetyDecision {
        fun cardText(confirmationId: String): String = buildString {
            require(confirmationId.isNotBlank()) { "confirmationId 不能为空" }
            append("确认编号：").append(confirmationId)
            append("\n")
            append(actionSummary)
            evidence.forEach { append("\n").append(it) }
            append("\n参数指纹：").append(argsFingerprint.take(12))
        }
    }

    data class Blocked(
        val code: ErrorCode,
        val reason: String,
    ) : SafetyDecision
}

/**
 * 纯 Kotlin 风险判定；不持有 Android UI 或执行器对象。
 *
 * 词表按 [RiskTier] 分两档。技能包资产（`assets/skillpack/safety.json`）的键名保持
 * `danger_words` / `send_words` 不变——**映射规则写在这里：
 * `danger_words` 即 I 级，`send_words` 即 II 级**。
 */
class SafetyPolicy(
    private val irreversibleWords: List<String> = DEFAULT_IRREVERSIBLE_WORDS,
    private val retractableWords: List<String> = DEFAULT_RETRACTABLE_WORDS,
    private val sensitiveTargets: List<String> = emptyList(),
    private val actionConfirmWords: List<String> = DEFAULT_ACTION_CONFIRM_WORDS,
) {
    fun assess(
        toolName: String,
        level: Level,
        args: JSONObject,
        context: SafetyContext,
    ): SafetyDecision {
        val enterPressed = toolName == "press_key" &&
            args.optString("key").equals("enter", ignoreCase = true)
        if (enterPressed) {
            val target = context.target
            val input = target?.inputCommitEvidence
            val prepared = target?.preparedTargetEvidence
            val identity = target?.focusIdentity
            if (
                context.sameAppMultiWindow &&
                (identity?.source == IdentitySource.IME_ONLY ||
                    target?.focusedInputBounds == null ||
                    target.windowPane.isNullOrBlank())
            ) {
                return SafetyDecision.Blocked(
                    ErrorCode.E_BLOCKED,
                    "同应用多窗口下缺少输入框几何或窗格归属，拒绝盲按 Enter；请改用 ui_action 点击目标窗口内的具体按钮",
                )
            }
            val baseValid = identity != null &&
                input != null && input.identity == identity &&
                FocusIdentity.boundsConsistent(identity.source, target.focusedInputBounds) &&
                (!identity.degraded || input.readbackVerified)
            val preparedValid = prepared == null || (
                prepared.label.isNotBlank() &&
                    prepared.packageName == context.packageName &&
                    prepared.identity == identity &&
                    prepared.bounds == target.focusedInputBounds
                )
            if (!baseValid || !preparedValid) return SafetyDecision.Blocked(
                ErrorCode.E_BLOCKED,
                "当前焦点输入框缺少有效的短时输入证据或目标会话证据不匹配，拒绝按下 Enter",
            )
        }

        // 档位与"要不要确认"是两件独立的事：具名普通点击直接放行；仅命中词表或无标签纯图标才确认。
        var tier: RiskTier? = null
        val dynamicReason = when {
            enterPressed -> {
                tier = enterTier(context)
                "按下 Enter，可能发送或提交当前输入内容"
            }

            toolName == "ui_action" && args.optString("action") in setOf("click", "long_click") -> {
                val label = listOf(context.target?.text, context.target?.description)
                    .filterNotNull().joinToString(" ").trim()
                val sensitiveHit = sensitiveTargets.firstOrNull { matchesLabelWord(label, it) }
                if (sensitiveHit != null) {
                    return SafetyDecision.Blocked(
                        ErrorCode.E_BLOCKED,
                        "点击目标命中敏感黑名单（“$sensitiveHit”），拒绝执行",
                    )
                }
                // 匹配顺序：I 级危险词 → II 级发送词 → 泛化动作确认词（I 级），保持「命中“X”」主顺序不变。
                val hit = (irreversibleWords + retractableWords + actionConfirmWords)
                    .firstOrNull { matchesLabelWord(label, it) }
                when {
                    hit != null -> {
                        tier = tierOfWord(hit)
                        "${args.optString("action")} 危险目标（命中“$hit”）"
                    }
                    label.isBlank() -> {
                        tier = RiskTier.IRREVERSIBLE
                        "${args.optString("action")} 目标无文本/描述（纯图标按 fail-closed 要求确认）"
                    }
                    else -> null
                }
            }

            else -> null
        }

        if (dynamicReason == null && level != Level.D) return SafetyDecision.Allowed

        val reason = dynamicReason ?: "工具静态风险等级为 D"
        val resolvedTier = tier ?: RiskTier.IRREVERSIBLE
        return SafetyDecision.ConfirmationRequired(
            toolName = toolName,
            action = if (toolName == "press_key") args.optString("key") else args.optString("action"),
            initialPackage = context.packageName,
            actionSummary = "工具：$toolName\n动作：$reason",
            evidence = confirmationEvidence(toolName, args, context, resolvedTier),
            argsFingerprint = fingerprint(args),
            riskTier = resolvedTier,
            inputLength = context.target?.inputCommitEvidence?.length,
            inputSha256 = context.target?.inputCommitEvidence?.sha256,
        )
    }

    /**
     * 判断点击目标标签是否按现行词表优先级归属为 II 级可撤回发送动作（与 [assess] 同源）。
     * 用于在突变清理与 UI 上下文装配前识别发送按钮，绝不另写第二份词表判据。
     */
    internal fun isRetractableSendLabel(label: String): Boolean {
        val trimmed = label.trim()
        if (trimmed.isEmpty()) return false
        if (sensitiveTargets.any { matchesLabelWord(trimmed, it) }) return false
        val hit = (irreversibleWords + retractableWords + actionConfirmWords)
            .firstOrNull { matchesLabelWord(trimmed, it) } ?: return false
        return tierOfWord(hit) == RiskTier.RETRACTABLE
    }

    /**
     * 判定文本是否命中任一危险词、发送/撤回词、泛化确认词或敏感目标黑名单（含去空白 OCR 归一匹配）。
     * 供普通具名 OCR 精确导航兜底直接复用，绝不另抄一份弱词表。
     */
    internal fun containsProtectedActionKeyword(text: String): Boolean {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return false
        val normText = TextNorm.ocr(trimmed)
        return (sensitiveTargets + irreversibleWords + retractableWords + actionConfirmWords)
            .any { word ->
                if (word.isBlank()) return@any false
                if (trimmed.contains(word, ignoreCase = true)) return@any true
                val normWord = TextNorm.ocr(word)
                normWord.isNotEmpty() && normText.contains(normWord)
            }
    }

    private fun matchesLabelWord(label: String, word: String): Boolean {
        if (word.isBlank()) return false
        if (label.contains(word, ignoreCase = true)) return true
        val foldedLabel = TextNorm.foldTraditionalToSimplified(label)
        val foldedWord = TextNorm.foldTraditionalToSimplified(word)
        return foldedLabel.contains(foldedWord, ignoreCase = true)
    }

    private fun tierOfWord(word: String): RiskTier =
        if (retractableWords.any { it.equals(word, ignoreCase = true) }) {
            RiskTier.RETRACTABLE
        } else {
            RiskTier.IRREVERSIBLE
        }

    private fun enterTier(context: SafetyContext): RiskTier {
        val target = context.target
        val signals = listOfNotNull(
            target?.preparedTargetEvidence?.label,
            target?.text,
            target?.description,
        ).filter { it.isNotBlank() }
        return if (hasSensitiveSurfaceSemantics(signals, sensitiveTargets)) {
            RiskTier.IRREVERSIBLE
        } else {
            RiskTier.RETRACTABLE
        }
    }

    private fun confirmationEvidence(
        toolName: String,
        args: JSONObject,
        context: SafetyContext,
        riskTier: RiskTier,
    ): List<String> = buildList {
        add(ConfirmNotificationContent.tierEvidenceLine(riskTier, context.packageName))
        add(
            "前台：${context.packageName.ifEmpty { "未知" }} / " + when {
                context.identityBootstrapped -> "Activity 未知（服务重启后由窗口自举的包级身份）"
                else -> context.activityName.ifEmpty { "未知" }
            }
        )
        val target = context.target
        if (toolName == "ui_action" && target != null) {
            add("目标：ref=${target.ref} text=${target.text.take(40)} desc=${target.description.take(40)}")
            add("位置：${target.bounds} source=${target.source}")
            target.preparedTargetEvidence?.let { prepared ->
                add("目标会话：${prepared.label}")
            }
            target.windowPane?.takeIf { it.isNotBlank() }?.let { pane ->
                add("所在窗口：${paneDisplayName(pane)}")
            }
            target.inputCommitEvidence?.let { input ->
                add("实际输入预览：${input.preview}")
                add("输入长度：${input.length}")
                add("输入 SHA-256：${input.sha256}")
            }
        } else if (toolName == "press_key") {
            val identity = target?.focusIdentity
            add("按键：${args.optString("key")}")
            add("目标会话：${target?.preparedTargetEvidence?.label ?: "未绑定会话标题，请核对屏幕"}")
            target?.windowPane?.takeIf { it.isNotBlank() }?.let { pane ->
                add("所在窗口：${paneDisplayName(pane)}")
            }
            when (identity?.source) {
                IdentitySource.A11Y -> {
                    add("焦点输入：${identity.a11yInputId}")
                    add("焦点位置：${target.focusedInputBounds ?: "不可识别"}")
                }
                IdentitySource.IME_CURSOR_ANCHOR -> {
                    add("焦点输入：a11y 节点被应用屏蔽，已由 IME 光标锚点归属窗口 #${identity.cursorAnchorWindowId}")
                    add("焦点位置：${target.focusedInputBounds ?: "不可识别"}")
                    add("IME 会话：${identity.imeSessionId}")
                    add("落框验证：OCR 读回${if (target.inputCommitEvidence?.readbackVerified == true) "已通过" else "未通过"}")
                }
                IdentitySource.IME_ONLY -> {
                    add("焦点输入：a11y 不可见（App 屏蔽无障碍树），已降级为 IME 单命名空间")
                    add("IME 会话：${identity.imeSessionId}")
                    add("落框验证：OCR 读回${if (target.inputCommitEvidence?.readbackVerified == true) "已通过" else "未通过"}")
                }
                null -> add("焦点输入：不可识别")
            }
            target?.inputCommitEvidence?.let { input ->
                add("实际输入预览：${input.preview}")
                add("输入长度：${input.length}")
                add("输入 SHA-256：${input.sha256}")
            }
        } else {
            val keys = args.keys().asSequence().toList().sorted()
            add("关键参数：${keys.joinToString(", ") { key -> safeArg(key, args.opt(key)) }}")
        }
    }

    private fun safeArg(key: String, value: Any?): String = when (key.lowercase()) {
        "text", "message", "content" -> "$key=<${value?.toString()?.length ?: 0}字符>"
        else -> "$key=${value?.toString()?.take(60).orEmpty()}"
    }

    companion object {
        internal val DEFAULT_IRREVERSIBLE_WORDS = listOf(
            "删除", "清空", "移除", "卸载", "支付", "付款", "转账", "确认交易", "立即购买", "提交订单",
            "注销", "退出登录", "解绑", "修改密码", "安装", "格式化", "恢复出厂",
        )

        internal val DEFAULT_RETRACTABLE_WORDS = listOf("发送", "发布", "发表", "评论", "回复")

        internal val DEFAULT_ACTION_CONFIRM_WORDS = listOf(
            "确认", "确定", "提交", "下单", "购买", "结算", "去结算", "同意", "授权", "允许",
        )

        private fun paneDisplayName(pane: String): String = when (pane) {
            "left" -> "左侧窗口"
            "right" -> "右侧窗口"
            "top" -> "上方窗口"
            "bottom" -> "下方窗口"
            "middle" -> "中间窗口"
            else -> pane
        }

        internal fun hasSensitiveSurfaceSemantics(
            signals: Iterable<String>,
            additionalWords: Iterable<String> = emptyList(),
        ): Boolean {
            val words = (
                DEFAULT_IRREVERSIBLE_WORDS + additionalWords +
                    listOf("密码", "收款", "风险", "警告")
                ).filter(String::isNotBlank).distinct()
            return signals.any { signal -> words.any { word -> signal.contains(word, ignoreCase = true) } }
        }

        fun fingerprint(args: JSONObject): String {
            val canonical = canonicalJson(args)
            return MessageDigest.getInstance("SHA-256")
                .digest(canonical.toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it) }
        }

        private fun canonicalJson(value: Any?): String = when (value) {
            null, JSONObject.NULL -> "null"
            is JSONObject -> value.keys().asSequence().toList().sorted()
                .joinToString(prefix = "{", postfix = "}") { key ->
                    "${JSONObject.quote(key)}:${canonicalJson(value.opt(key))}"
                }
            is JSONArray -> (0 until value.length())
                .joinToString(prefix = "[", postfix = "]") { canonicalJson(value.opt(it)) }
            is Number, is Boolean -> value.toString()
            else -> JSONObject.quote(value.toString())
        }
    }
}

data class IntentConfirmationResult(
    val allowed: Boolean,
    val channel: ApprovalChannel?,
    val confirmationId: String,
    val nonce: String,
)

/**
 * 语义意图审批生产接线配置（spec `2026-08-02-语义意图审批`）。
 *
 * 所有时钟必须与证据仓同源单调时钟；[dependenciesForTier] 在弹卡前构造并机械断言重建通道在位。
 */
class SemanticIntentConfig(
    val timing: IntentApprovalTiming = IntentApprovalTiming(),
    val dependenciesForTier: (RiskTier) -> IntentApprovalDependencies,
    val clock: () -> Long = { System.nanoTime() / 1_000_000L },
    val sleep: (Long) -> Unit = { Thread.sleep(it) },
    val foregroundPollIntervalMs: Long = 250L,
    val intentIdGenerator: () -> String = { UUID.randomUUID().toString() },
    val confirmationIdGenerator: () -> String,
    val nonceGenerator: () -> String = ConfirmApprovalArbiter::newNonce,
    val intentConfirmer: (SafetyDecision.ConfirmationRequired, ApprovalIntent, String, String) -> IntentConfirmationResult,
    val currentForegroundPackage: () -> String?,
    val installRebuiltEvidence: (ApprovalIntent, EvidenceRebuild.Rebuilt) -> Boolean,
    val onAuditNote: (String) -> Unit = {},
    val disableForegroundWait: () -> Boolean = { false },
) {
    init {
        require(foregroundPollIntervalMs > 0) { "foregroundPollIntervalMs 必须大于 0" }
    }
}

/** 一次调用的一次性安全门：确认不产出令牌，复核通过后才触达 executor。 */
class SafetyGate(
    private val policy: SafetyPolicy,
    private val confirmer: (SafetyDecision.ConfirmationRequired) -> Boolean,
    private val contextProvider: (JSONObject) -> SafetyContext,
    private val onExecutionFailure: (Throwable) -> Unit,
    private val afterConfirmationAllowed: (String, JSONObject, SafetyContext) -> Unit = { _, _, _ -> },
    private val afterExecutionSuccess: (String, SafetyContext) -> Unit = { _, _ -> },
    private val onStaleAfterApproval: (String, SafetyContext) -> Unit = { _, _ -> },
    private val semanticIntent: SemanticIntentConfig? = null,
) {
    fun <T> execute(
        toolName: String,
        level: Level,
        args: JSONObject,
        executor: (JSONObject, SafetyContext) -> T,
    ): T {
        val frozenArgs = deepCopy(args)
        val initialArgsFingerprint = SafetyPolicy.fingerprint(frozenArgs)
        val initialContext = contextProvider(deepCopy(frozenArgs))
        requireKnownForeground(toolName, level, initialContext)
        val decision = policy.assess(toolName, level, deepCopy(frozenArgs), initialContext)

        val validatedContext = when (decision) {
            SafetyDecision.Allowed -> initialContext
            is SafetyDecision.Blocked -> throw GatewayError(decision.code, decision.reason)
            is SafetyDecision.ConfirmationRequired -> {
                val intentConfig = semanticIntent
                val initialIntent = intentConfig?.let {
                    buildApprovalIntentOrNull(
                        toolName = toolName,
                        decision = decision,
                        initialContext = initialContext,
                        intentId = it.intentIdGenerator(),
                        createdAtMs = it.clock(),
                    )
                }
                if (intentConfig != null && initialIntent != null) {
                    executeWithSemanticIntent(
                        toolName = toolName,
                        level = level,
                        args = args,
                        frozenArgs = frozenArgs,
                        initialArgsFingerprint = initialArgsFingerprint,
                        initialContext = initialContext,
                        decision = decision,
                        intent = initialIntent,
                        config = intentConfig,
                    )
                } else {
                    executeImmediateStrict(
                        toolName = toolName,
                        level = level,
                        args = args,
                        frozenArgs = frozenArgs,
                        initialArgsFingerprint = initialArgsFingerprint,
                        initialContext = initialContext,
                        decision = decision,
                    )
                }
            }
        }

        val result = try {
            executor(deepCopy(frozenArgs), validatedContext)
        } catch (error: Throwable) {
            val safetyFailure = error is GatewayError && error.code in setOf(
                ErrorCode.E_STALE_REF,
                ErrorCode.E_BLOCKED,
                ErrorCode.E_CONFIRM_REQUIRED,
                ErrorCode.E_CONFIRM_TIMEOUT,
            )
            if (!safetyFailure) runCatching { onExecutionFailure(error) }
            throw error
        }
        afterExecutionSuccess(toolName, validatedContext)
        return result
    }

    private fun executeImmediateStrict(
        toolName: String,
        level: Level,
        args: JSONObject,
        frozenArgs: JSONObject,
        initialArgsFingerprint: String,
        initialContext: SafetyContext,
        decision: SafetyDecision.ConfirmationRequired,
    ): SafetyContext {
        if (!confirmer(decision)) throw GatewayError(
            ErrorCode.E_BLOCKED,
            "用户拒绝了危险操作：$toolName",
            channel = "overlay",
            fallback = "按站规收尾，不要换路重试同一危险动作",
        )
        return try {
            if (SafetyPolicy.fingerprint(args) != initialArgsFingerprint) stale("确认后工具参数已变化")
            afterConfirmationAllowed(toolName, deepCopy(frozenArgs), initialContext)
            val currentContext = try {
                contextProvider(deepCopy(frozenArgs))
            } catch (error: Throwable) {
                stale("确认后无法重新获取目标上下文：${error.message.orEmpty()}")
            }
            requireKnownForeground(toolName, level, currentContext)
            validateContext(toolName, frozenArgs, initialContext, currentContext)
            currentContext
        } catch (error: GatewayError) {
            if (error.code == ErrorCode.E_STALE_REF) {
                runCatching { onStaleAfterApproval(toolName, initialContext) }
            }
            throw error
        }
    }

    private fun executeWithSemanticIntent(
        toolName: String,
        level: Level,
        args: JSONObject,
        frozenArgs: JSONObject,
        initialArgsFingerprint: String,
        initialContext: SafetyContext,
        decision: SafetyDecision.ConfirmationRequired,
        intent: ApprovalIntent,
        config: SemanticIntentConfig,
    ): SafetyContext {
        // 弹卡前机械校验：长等待路径必须实际装配真实读回通道（不能用可自报布尔代替）。
        val deps = config.dependenciesForTier(decision.riskTier)
        val initialInput = requireNotNull(initialContext.target?.inputCommitEvidence)
        val initialPrepared = requireNotNull(initialContext.target?.preparedTargetEvidence)

        val confirmationId = config.confirmationIdGenerator()
        val nonce = config.nonceGenerator()
        val store = IntentApprovalStore(
            intent = intent,
            confirmationId = confirmationId,
            nonce = nonce,
            timing = config.timing,
            clock = config.clock,
        )

        return try {
            val outcome = config.intentConfirmer(decision, intent, confirmationId, nonce)
            if (!outcome.allowed) {
                store.decide(outcome.confirmationId, outcome.nonce, allowed = false)
                throw GatewayError(
                    ErrorCode.E_BLOCKED,
                    "用户拒绝了危险操作：$toolName",
                    channel = "overlay",
                    fallback = "按站规收尾，不要换路重试同一危险动作",
                )
            }
            // 唯一批准来源硬约束：仅接受可见 ConfirmOverlay，通知或其他通道一律 fail-closed。
            if (outcome.channel != ApprovalChannel.OVERLAY) {
                throw GatewayError(
                    ErrorCode.E_BLOCKED,
                    "仅可见确认卡允许批准危险操作：$toolName",
                    channel = "overlay",
                    fallback = "按站规收尾，不要从非确认卡通道批准危险动作",
                )
            }
            when (store.decide(outcome.confirmationId, outcome.nonce, allowed = true)) {
                IntentApprovalOutcome.APPROVED -> Unit
                IntentApprovalOutcome.EXPIRED -> throw GatewayError(
                    ErrorCode.E_CONFIRM_TIMEOUT,
                    "带内确认已超时",
                    channel = "overlay",
                    fallback = SafetyFallbacks.CONFIRM_TIMEOUT,
                )
                else -> throw GatewayError(
                    ErrorCode.E_BLOCKED,
                    "确认状态无效，拒绝执行危险操作：$toolName",
                    channel = "overlay",
                    fallback = "按站规收尾，不要换路重试同一危险动作",
                )
            }

            try {
                if (SafetyPolicy.fingerprint(args) != initialArgsFingerprint) {
                    stale("确认后工具参数已变化")
                }
                afterConfirmationAllowed(toolName, deepCopy(frozenArgs), initialContext)

                val waitBudgetMs = if (config.disableForegroundWait()) {
                    0L
                } else {
                    config.timing.foregroundWaitBudgetMs(decision.riskTier)
                }
                var waited = false
                if (waitBudgetMs > 0L) {
                    val waitStart = config.clock()
                    while (true) {
                        if (store.expire()) stale("语义意图已过期，放弃前台恢复等待")
                        val fg = config.currentForegroundPackage()
                        if (fg == intent.targetPackage) break
                        val now = config.clock()
                        if (!withinIntentWindow(waitStart, now, waitBudgetMs)) {
                            stale("等待目标应用回到前台超时（${waitBudgetMs / 1000}s）")
                        }
                        waited = true
                        val elapsed = (now - waitStart).coerceAtLeast(0L)
                        val remaining = (waitBudgetMs - elapsed).coerceAtLeast(1L)
                        config.sleep(minOf(config.foregroundPollIntervalMs, remaining))
                    }
                    if (waited) config.onAuditNote("intent_wait=recovered")
                }

                // 原子消费：从这里往下无论重组、校验或执行成败，该意图不可再次恢复。
                val approvedIntent = store.consume(intent.intentId)
                    ?: stale("语义意图已过期或已消费")

                val nowBeforeCheck = config.clock()
                val evidenceAlreadyExpired =
                    nowBeforeCheck >= initialInput.expiresAtMs ||
                        nowBeforeCheck >= initialPrepared.expiresAtMs

                fun rebuildAndInstall(approved: ApprovalIntent) {
                    when (val rebuilt = deps.rebuildEvidence(approved)) {
                        is EvidenceRebuild.Rebuilt -> {
                            if (!config.installRebuiltEvidence(approved, rebuilt)) {
                                stale("重建证据通过但无法为当前焦点安装有效证据")
                            }
                            config.onAuditNote("intent_evidence=rebuilt")
                        }
                        is EvidenceRebuild.Mismatch -> stale("执行前证据重建不匹配：${rebuilt.reason}")
                        is EvidenceRebuild.Unverified -> stale("执行前证据重建无法验证：${rebuilt.reason}")
                    }
                }

                if (waited || evidenceAlreadyExpired) {
                    rebuildAndInstall(approvedIntent)
                }

                var currentContext = readCurrentContextOrStale(frozenArgs)
                val needsFocusFallbackRebuild =
                    !waited && !evidenceAlreadyExpired &&
                        deps.timing.requiresEvidenceRebuild(decision.riskTier) &&
                        (currentContext.target?.inputCommitEvidence == null ||
                            currentContext.target?.preparedTargetEvidence == null)
                if (needsFocusFallbackRebuild) {
                    rebuildAndInstall(approvedIntent)
                    currentContext = readCurrentContextOrStale(frozenArgs)
                }

                requireKnownForeground(toolName, level, currentContext)
                val nowAtExec = config.clock()
                if (!IntentMatchPolicy.isIntentLive(approvedIntent, nowAtExec, config.timing.intentTtlMs)) {
                    stale("语义意图已超过有效期")
                }
                validateExecutionTimeChain(toolName, frozenArgs, initialContext, currentContext)
                when (
                    val match = IntentMatchPolicy.matches(
                        intent = approvedIntent,
                        context = currentContext,
                        nowMs = nowAtExec,
                        requiresTargetSession = true,
                    )
                ) {
                    IntentMatch.Matched -> config.onAuditNote("intent_match=matched")
                    is IntentMatch.Rejected -> stale("执行前语义意图不匹配：${match.reason}")
                }
                currentContext
            } catch (error: GatewayError) {
                if (error.code == ErrorCode.E_STALE_REF) {
                    runCatching { onStaleAfterApproval(toolName, initialContext) }
                }
                throw error
            }
        } finally {
            store.discard(intent.intentId)
        }
    }

    private fun readCurrentContextOrStale(frozenArgs: JSONObject): SafetyContext = try {
        contextProvider(deepCopy(frozenArgs))
    } catch (error: Throwable) {
        stale("确认后无法重新获取目标上下文：${error.message.orEmpty()}")
    }

    private fun buildApprovalIntentOrNull(
        toolName: String,
        decision: SafetyDecision.ConfirmationRequired,
        initialContext: SafetyContext,
        intentId: String,
        createdAtMs: Long,
    ): ApprovalIntent? {
        val enterTool = toolName == "press_key" && decision.action.equals("enter", ignoreCase = true)
        val retractableUiAction = toolName == "ui_action" && decision.riskTier == RiskTier.RETRACTABLE
        if (!enterTool && !retractableUiAction) return null
        val target = initialContext.target ?: return null
        val input = target.inputCommitEvidence ?: return null
        val prepared = target.preparedTargetEvidence ?: return null
        if (prepared.label.isBlank() || prepared.packageName != initialContext.packageName) return null
        return ApprovalIntent(
            intentId = intentId,
            riskTier = decision.riskTier,
            actionKind = if (enterTool) "发送消息" else "${decision.action}消息",
            targetPackage = initialContext.packageName,
            targetLabel = prepared.label,
            contentSha256 = input.sha256,
            contentLength = input.length,
            preview = input.preview,
            createdAtMs = createdAtMs,
            approvedAtMs = null,
            ocrBaseline = input.ocrBaseline,
        )
    }

    private fun requireKnownForeground(
        toolName: String,
        level: Level,
        context: SafetyContext,
    ) {
        if (level == Level.R || context.foregroundKnown) return
        throw GatewayError(
            ErrorCode.E_BLOCKED,
            "前台 APPLICATION 身份未知，拒绝执行 $level 级工具：$toolName",
            channel = "safety",
            fallback = "等待有效的 APPLICATION 前台窗口事件后重新感知并重试",
        )
    }

    /**
     * 语义意图路径下的执行瞬间严格自洽检查（spec §2.3）：
     * 刻意不比较 `activityName`、`identityBootstrapped` 或跨时间 `focusIdentity`/`focusedInputBounds`，
     * 改为严格校验执行这一刻三处证据身份自洽、几何一致性与目标控件完整性。
     */
    private fun validateExecutionTimeChain(
        toolName: String,
        args: JSONObject,
        initial: SafetyContext,
        current: SafetyContext,
    ) {
        if (initial.packageName != current.packageName) {
            stale("确认后前台 App 已变化")
        }
        if (initial.sameAppMultiWindow != current.sameAppMultiWindow) {
            stale("确认后多窗口形态已变化")
        }
        val target = current.target ?: stale("执行前未解析到目标上下文")
        val identity = target.focusIdentity ?: stale("执行前解析不到焦点输入身份")
        if (
            current.sameAppMultiWindow &&
            (identity.source == IdentitySource.IME_ONLY ||
                target.focusedInputBounds == null ||
                target.windowPane.isNullOrBlank())
        ) {
            stale("同应用多窗口下执行前缺少输入框几何或窗格归属")
        }
        if (!FocusIdentity.boundsConsistent(identity.source, target.focusedInputBounds)) {
            stale("执行前焦点几何与身份来源不一致：${identity.describe()} bounds=${target.focusedInputBounds ?: "-"}")
        }
        val input = target.inputCommitEvidence ?: stale("执行前短时输入提交证据已过期")
        if (input.identity != identity) {
            stale("执行前输入提交证据与焦点身份不一致")
        }
        if (identity.degraded && !input.readbackVerified) {
            stale("执行前降级链缺少 OCR 落框读回验证")
        }
        val prepared = target.preparedTargetEvidence ?: stale("执行前短时目标会话证据已过期")
        if (
            prepared.label.isBlank() ||
            prepared.packageName != current.packageName ||
            prepared.identity != identity ||
            prepared.bounds != target.focusedInputBounds
        ) {
            stale("执行前短时目标会话证据与当前焦点不匹配")
        }

        if (toolName == "ui_action") {
            val before = initial.target ?: stale("确认前未解析到 UI 目标")
            if (target.ref.isNullOrBlank() || target.bounds.isBlank()) {
                stale("执行前 UI 目标已失效")
            }
            if (
                before.text != target.text ||
                before.description != target.description ||
                before.windowPane != target.windowPane
            ) {
                stale("执行前 UI 目标控件证据已变化")
            }
        } else if (toolName == "press_key" && args.optString("key").equals("enter", ignoreCase = true)) {
            if (initial.target?.windowPane != target.windowPane) {
                stale("确认后目标窗口位置已变化")
            }
        }
    }

    private fun validateContext(
        toolName: String,
        args: JSONObject,
        initial: SafetyContext,
        current: SafetyContext,
    ) {
        if (initial.packageName != current.packageName || initial.activityName != current.activityName) {
            stale("确认后前台 App/Activity 已变化")
        }
        if (initial.identityBootstrapped != current.identityBootstrapped) {
            stale("确认后前台身份来源已变化（自举包级身份 ↔ 窗口事件身份）")
        }
        if (initial.sameAppMultiWindow != current.sameAppMultiWindow) {
            stale("确认后多窗口形态已变化")
        }
        when {
            toolName == "ui_action" -> {
                val before = initial.target ?: stale("确认前未解析到 UI 目标")
                val after = current.target ?: stale("确认后 UI 目标已失效")
                if (before.bounds != after.bounds) {
                    stale("确认后 UI 目标边框已变化：${before.bounds} → ${after.bounds}")
                }
                if (
                    before.ref != after.ref || before.text != after.text ||
                    before.description != after.description ||
                    before.source != after.source || before.windowPane != after.windowPane
                ) stale("确认后 UI 目标证据已变化")
            }
            toolName == "press_key" && args.optString("key").equals("enter", ignoreCase = true) -> {
                if (initial.target?.windowPane != current.target?.windowPane) {
                    stale("确认后目标窗口位置已变化")
                }
                val before = initial.target?.focusIdentity
                val after = current.target?.focusIdentity
                if (before == null) stale("确认前未解析到焦点输入身份")
                if (after == null) stale("确认后解析不到焦点输入身份（确认前为 ${before.describe()}）")
                if (before != after) {
                    stale("确认后焦点输入身份已变化：${before.describe()} → ${after.describe()}")
                }
                val beforeBounds = initial.target.focusedInputBounds
                val afterBounds = current.target?.focusedInputBounds
                if (!FocusIdentity.boundsConsistent(before.source, beforeBounds)) {
                    stale("确认前焦点几何与身份来源不一致：${before.describe()} bounds=${beforeBounds ?: "-"}")
                }
                if (!FocusIdentity.boundsConsistent(after.source, afterBounds)) {
                    stale("确认后焦点几何与身份来源不一致：${after.describe()} bounds=${afterBounds ?: "-"}")
                }
                if (beforeBounds != afterBounds) {
                    stale("确认后焦点输入框位置已变化：${beforeBounds ?: "-"} → ${afterBounds ?: "-"}")
                }
                val beforeInput = initial.target.inputCommitEvidence
                val afterInput = current.target?.inputCommitEvidence
                if (beforeInput == null) stale("确认前没有短时输入提交证据")
                if (afterInput == null) stale("确认后短时输入提交证据已过期")
                if (beforeInput != afterInput) stale("确认后短时输入提交证据已变化")
                val beforeTarget = initial.target.preparedTargetEvidence
                val afterTarget = current.target?.preparedTargetEvidence
                if (beforeTarget != null && afterTarget == null) stale("确认后短时目标会话证据已过期")
                if (beforeTarget != afterTarget) stale("确认后短时目标会话证据已变化")
            }
        }
    }

    private fun stale(message: String): Nothing = throw GatewayError(
        ErrorCode.E_STALE_REF,
        message,
        channel = "safety",
        fallback = "重新感知当前页面和目标后再发起一次新调用",
    )

    private fun deepCopy(args: JSONObject): JSONObject = JSONObject(args.toString())
}

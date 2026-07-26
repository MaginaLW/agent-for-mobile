package dev.magina.gateway.core

import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest

/** 确认前后需要绑定的前台与动态目标证据。revision 仅供审计，不参与硬相等。 */
data class SafetyContext(
    val packageName: String,
    val activityName: String,
    val revision: Long,
    val foregroundKnown: Boolean = packageName.isNotEmpty(),
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
)

sealed interface SafetyDecision {
    data object Allowed : SafetyDecision

    data class ConfirmationRequired(
        val toolName: String,
        val action: String,
        val initialPackage: String,
        val actionSummary: String,
        val evidence: List<String>,
        val argsFingerprint: String,
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

/** 纯 Kotlin 风险判定；不持有 Android UI 或执行器对象。 */
class SafetyPolicy(
    private val dangerWords: List<String> = DEFAULT_DANGER_WORDS,
    private val sendWords: List<String> = DEFAULT_SEND_WORDS,
    private val sensitiveTargets: List<String> = emptyList(),
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
            // 两种身份模式共用同一条硬要求：三处证据的身份（含来源）必须逐字段一致，
            // 且几何证据与来源一致地存在或缺失——不允许 blank == blank 平凡通过。
            val chainValid = identity != null &&
                input != null && input.identity == identity &&
                prepared != null && prepared.label.isNotBlank() &&
                prepared.packageName == context.packageName &&
                prepared.identity == identity &&
                prepared.bounds == target.focusedInputBounds &&
                FocusIdentity.boundsConsistent(identity.source, target.focusedInputBounds) &&
                // IME-only 降级链失去了 a11y 焦点身份与几何，OCR 读回是仅剩的落框机械证据。
                (identity.source != IdentitySource.IME_ONLY || input.readbackVerified)
            if (!chainValid) return SafetyDecision.Blocked(
                ErrorCode.E_BLOCKED,
                "当前焦点输入框没有匹配的短时输入与目标会话证据，拒绝按下 Enter",
            )
        }

        val dynamicReason = when {
            enterPressed ->
                "按下 Enter，可能发送或提交当前输入内容"

            toolName == "ui_action" && args.optString("action") in setOf("click", "long_click") -> {
                val label = listOf(context.target?.text, context.target?.description)
                    .filterNotNull().joinToString(" ").trim()
                val hit = (dangerWords + sendWords + sensitiveTargets)
                    .firstOrNull { it.isNotBlank() && label.contains(it, ignoreCase = true) }
                hit?.let { "${args.optString("action")} 危险目标（命中“$it”）" }
            }

            else -> null
        }

        if (dynamicReason == null && level != Level.D) return SafetyDecision.Allowed

        val reason = dynamicReason ?: "工具静态风险等级为 D"
        return SafetyDecision.ConfirmationRequired(
            toolName = toolName,
            action = if (toolName == "press_key") args.optString("key") else args.optString("action"),
            initialPackage = context.packageName,
            actionSummary = "工具：$toolName\n动作：$reason",
            evidence = confirmationEvidence(toolName, args, context),
            argsFingerprint = fingerprint(args),
            inputLength = context.target?.inputCommitEvidence?.length,
            inputSha256 = context.target?.inputCommitEvidence?.sha256,
        )
    }

    private fun confirmationEvidence(
        toolName: String,
        args: JSONObject,
        context: SafetyContext,
    ): List<String> = buildList {
        add("前台：${context.packageName.ifEmpty { "未知" }} / ${context.activityName.ifEmpty { "未知" }}")
        val target = context.target
        if (toolName == "ui_action" && target != null) {
            add("目标：ref=${target.ref} text=${target.text.take(40)} desc=${target.description.take(40)}")
            add("位置：${target.bounds} source=${target.source}")
        } else if (toolName == "press_key") {
            val identity = target?.focusIdentity
            add("按键：${args.optString("key")}")
            add("目标会话：${target?.preparedTargetEvidence?.label ?: "不可识别"}")
            // 焦点几何不可得时不得静默少展示一项：改为展示 IME 会话身份并标注降级模式，
            // 让真人清楚知道这一次少了哪一套证据（design §3.6）。
            when (identity?.source) {
                IdentitySource.A11Y -> {
                    add("焦点输入：${identity.a11yInputId}")
                    add("焦点位置：${target.focusedInputBounds ?: "不可识别"}")
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
        private val DEFAULT_DANGER_WORDS = listOf(
            "删除", "清空", "移除", "卸载", "支付", "付款", "转账", "确认交易", "立即购买", "提交订单",
            "注销", "退出登录", "解绑", "修改密码", "安装", "格式化", "恢复出厂",
        )
        private val DEFAULT_SEND_WORDS = listOf("发送", "发布", "发表", "评论", "回复")

        /**
         * 页面级 fail-closed 判定供受控导航复用。与针对单个点击目标的 [assess] 共用
         * 危险词源，并允许调用方叠加技能包词表；发送类普通页面文案不在这里一概拦截，
         * 确认弹窗由调用方结合页面结构判断。
         */
        internal fun hasSensitiveSurfaceSemantics(
            signals: Iterable<String>,
            additionalWords: Iterable<String> = emptyList(),
        ): Boolean {
            val words = (
                DEFAULT_DANGER_WORDS + additionalWords +
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

/** 一次调用的一次性安全门：确认不产出令牌，复核通过后才触达 executor。 */
class SafetyGate(
    private val policy: SafetyPolicy,
    private val confirmer: (SafetyDecision.ConfirmationRequired) -> Boolean,
    private val contextProvider: (JSONObject) -> SafetyContext,
    private val onExecutionFailure: (Throwable) -> Unit,
    private val afterConfirmationAllowed: (String, JSONObject, SafetyContext) -> Unit = { _, _, _ -> },
    private val afterExecutionSuccess: (String, SafetyContext) -> Unit = { _, _ -> },
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
                if (!confirmer(decision)) throw GatewayError(
                    ErrorCode.E_BLOCKED,
                    "用户拒绝了危险操作：$toolName",
                    channel = "overlay",
                    fallback = "按站规收尾，不要换路重试同一危险动作",
                )
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

    private fun validateContext(
        toolName: String,
        args: JSONObject,
        initial: SafetyContext,
        current: SafetyContext,
    ) {
        if (initial.packageName != current.packageName || initial.activityName != current.activityName) {
            stale("确认后前台 App/Activity 已变化")
        }
        when {
            toolName == "ui_action" -> {
                val before = initial.target ?: stale("确认前未解析到 UI 目标")
                val after = current.target ?: stale("确认后 UI 目标已失效")
                if (
                    before.ref != after.ref || before.text != after.text ||
                    before.description != after.description || before.bounds != after.bounds ||
                    before.source != after.source
                ) stale("确认后 UI 目标证据已变化")
            }
            toolName == "press_key" && args.optString("key").equals("enter", ignoreCase = true) -> {
                // 逐条点名并给出旧值→新值：把"A 或 B 或 C 变了"合并成一句话，是真机排查里
                // 最贵的反模式（每撞一次多烧一轮派单，knowledge 已记）。判据本身一字未放宽。
                val before = initial.target?.focusIdentity
                val after = current.target?.focusIdentity
                if (before == null) stale("确认前未解析到焦点输入身份")
                if (after == null) stale("确认后解析不到焦点输入身份（确认前为 ${before.describe()}）")
                // 身份来源本身也参与比较：确认前严格链、确认后降级链一律判 stale。
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
                if (beforeTarget == null) stale("确认前没有短时目标会话证据")
                if (afterTarget == null) stale("确认后短时目标会话证据已过期")
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

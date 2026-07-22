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
    val focusedInputId: String? = null,
)

sealed interface SafetyDecision {
    data object Allowed : SafetyDecision

    data class ConfirmationRequired(
        val actionSummary: String,
        val evidence: List<String>,
        val argsFingerprint: String,
    ) : SafetyDecision {
        fun cardText(): String = buildString {
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
        val dynamicReason = when {
            toolName == "press_key" && args.optString("key").equals("enter", ignoreCase = true) ->
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
            actionSummary = "工具：$toolName\n动作：$reason",
            evidence = confirmationEvidence(toolName, args, context),
            argsFingerprint = fingerprint(args),
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
            add("按键：${args.optString("key")}")
            add("焦点输入：${target?.focusedInputId ?: "不可识别"}")
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

        return try {
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
                val before = initial.target?.focusedInputId
                val after = current.target?.focusedInputId
                if (before.isNullOrBlank() || after.isNullOrBlank() || before != after) {
                    stale("确认后焦点输入框已变化或无法识别")
                }
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

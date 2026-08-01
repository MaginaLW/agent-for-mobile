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
    /**
     * 前台身份是服务重启后由窗口自举出来的 package 级身份（[activityName] 必为空），
     * 不是窗口事件给出的完整身份。参与确认前后的硬相等，并在确认卡上如实标注。
     */
    val identityBootstrapped: Boolean = false,
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

/**
 * 危险动作风险档位（spec `2026-08-01-危险动作风险分级`）。
 *
 * 判据是**用户在动作完成后，能否用自己手上的手段把它撤销**——不看金额、不看动作名。
 *
 * **两档的行为完全一样**：都走完整确认链、都逐次确认。档位只是给下游（批次 2 通知栏审批的
 * 折叠态那一行）的措辞输入，**不产出任何免确认路径**——硬门不变量 4「一次确认只授权当前这一次
 * 调用，不生成可重放的通用令牌」一字未动。`SafetyGateTest` 里有一条回归断言钉住这件事：
 * 任一档位下，未确认时 handler 调用次数仍为 0。
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
        /**
         * 本次动作的风险档位。**本轮只产出、不消费**：`cardText` 一个字都没改（spec §7
         * 明确不动确认卡现有 8 项证据的内容与顺序），消费者是批次 2 的通知栏审批。
         * 不给默认值——档位判错比编译不过贵得多，新增构造点必须显式想一遍。
         */
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
 * `danger_words` / `send_words` 不变——它们的内容与本篇两档逐字相同（17 + 5 词），
 * 改键名只会让一份已发布的资产多一次格式迁移，换不来任何东西。**映射规则写在这里：
 * `danger_words` 即 I 级，`send_words` 即 II 级**，今后往哪张表里加词就是在选档位。
 */
class SafetyPolicy(
    private val irreversibleWords: List<String> = DEFAULT_IRREVERSIBLE_WORDS,
    private val retractableWords: List<String> = DEFAULT_RETRACTABLE_WORDS,
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

        // 档位与"要不要确认"是两件独立的事：这里先算出命中词与档位，放行判定在下面，
        // 一字未动。档位算错不会让任何动作少走一次确认，只会让批次 2 的措辞选错。
        var tier: RiskTier? = null
        val dynamicReason = when {
            enterPressed -> {
                tier = enterTier(context)
                "按下 Enter，可能发送或提交当前输入内容"
            }

            toolName == "ui_action" && args.optString("action") in setOf("click", "long_click") -> {
                val label = listOf(context.target?.text, context.target?.description)
                    .filterNotNull().joinToString(" ").trim()
                // 顺序与拆档前逐字相同（I 级 → II 级 → 敏感目标），因此"命中哪个词"这件事
                // 不会因为拆档而改变——卡上那句「命中“X”」是黄金回归钉住的文本。
                val hit = (irreversibleWords + retractableWords + sensitiveTargets)
                    .firstOrNull { it.isNotBlank() && label.contains(it, ignoreCase = true) }
                hit?.let {
                    tier = tierOfWord(it)
                    "${args.optString("action")} 危险目标（命中“$it”）"
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
            // 静态 D 级工具（走不到上面两条动态路）判不出档位——它们的危险性来自工具本身，
            // 不来自词表。按 fail-safe 归 I 级：宁可把可撤回的说成不可逆，不可反过来。
            riskTier = resolvedTier,
            inputLength = context.target?.inputCommitEvidence?.length,
            inputSha256 = context.target?.inputCommitEvidence?.sha256,
        )
    }

    /**
     * 命中词的档位。敏感目标（`sensitive_targets`，联系人/会话/文件关键词）没有撤销语义可言，
     * 按 fail-safe 归 I 级。
     */
    private fun tierOfWord(word: String): RiskTier =
        if (retractableWords.any { it.equals(word, ignoreCase = true) }) {
            RiskTier.RETRACTABLE
        } else {
            RiskTier.IRREVERSIBLE
        }

    /**
     * `press_key(enter)` 不吃词表，按**当前目标会话的性质**定档（spec §3 末段）：
     * 私聊/群聊会话 → II 级；落在 I 级页面上的 Enter（支付密码框之类）→ I 级。
     *
     * 只吃这一刻手上已有的页面级信号，**不新造感知面**。真正有内容的那一条是
     * `preparedTargetEvidence.label`——它就是确认卡上「目标会话」那一行，来自同一套已验证证据；
     * press_key 路径下 target 的 text/description 本来就是空的，一并带上只为将来别漏。
     */
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
        // L3 唯一的增量（批次 2）：现有 8 项内容与顺序一字不动，档位标注加在最前面——
        // 它回答的是"这件事做完能不能反悔"，先于任何身份/内容细节。
        add(ConfirmNotificationContent.tierEvidenceLine(riskTier, context.packageName))
        // 自举身份天生没有 Activity。若只写成"未知"，真人看到的这一项与"事件给了身份但
        // Activity 恰好为空"长得一模一样——同 IdentitySource.IME_ONLY 那两行的理由：
        // 少一套证据时不得静默少展示一项，要说清楚少的是哪一套（design §3.6）。
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
        /**
         * I 级·不可逆（spec §3）。三类：资金、数据、账号与系统完整性。
         * 与拆档前的 `DEFAULT_DANGER_WORDS` **逐字相同**，顺序也没动——
         * 拆档只是给同一批词贴上档位，不是改判据。
         */
        internal val DEFAULT_IRREVERSIBLE_WORDS = listOf(
            "删除", "清空", "移除", "卸载", "支付", "付款", "转账", "确认交易", "立即购买", "提交订单",
            "注销", "退出登录", "解绑", "修改密码", "安装", "格式化", "恢复出厂",
        )

        /**
         * II 级·有撤回窗口（spec §3）。
         *
         * **「发布」「发表」是 spec §3.1 显式标注的边界项**：它们确有撤回入口，但公开发表的撤回
         * 只删得掉副本、删不掉"已经被看到"这件事，弱于私聊撤回。本轮无实际后果（两档都照常
         * 逐次确认，档位只影响下游措辞）；**一旦将来有任何方案拿档位当免确认资格的键，
         * 这两个词的归档立刻变成承重的，必须重新走 B 道。**
         */
        internal val DEFAULT_RETRACTABLE_WORDS = listOf("发送", "发布", "发表", "评论", "回复")

        /**
         * 页面级 fail-closed 判定供受控导航复用。与针对单个点击目标的 [assess] 共用
         * 危险词源，并允许调用方叠加技能包词表；发送类普通页面文案不在这里一概拦截，
         * 确认弹窗由调用方结合页面结构判断。
         *
         * 拆档后这里仍**只吃 I 级词表**（加上密码/收款/风险/警告四个页面级词），与拆档前
         * 的 `DEFAULT_DANGER_WORDS` 完全一致：受控导航拦的是"这一页有没有不可逆语义"，
         * 把「发送」这类 II 级词并进来会让普通聊天页也被判成敏感页面。
         */
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

/** 一次调用的一次性安全门：确认不产出令牌，复核通过后才触达 executor。 */
class SafetyGate(
    private val policy: SafetyPolicy,
    private val confirmer: (SafetyDecision.ConfirmationRequired) -> Boolean,
    private val contextProvider: (JSONObject) -> SafetyContext,
    private val onExecutionFailure: (Throwable) -> Unit,
    private val afterConfirmationAllowed: (String, JSONObject, SafetyContext) -> Unit = { _, _, _ -> },
    private val afterExecutionSuccess: (String, SafetyContext) -> Unit = { _, _ -> },
    /**
     * **真人已经批准、随后复核判 stale** 时回调一次（批次 2 决定四的计数点）。
     *
     * 只在这一种情况回调：门前阻断、确认被拒、确认超时都不算——那三种里用户要么没批准过，
     * 要么本来就得到了"停下"的指示，不该占用重弹次数。
     */
    private val onStaleAfterApproval: (String, SafetyContext) -> Unit = { _, _ -> },
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
                // 从这里往下，真人已经批准过了。这一段里冒出来的每一个 E_STALE_REF 都属于
                // 「批准了、却因为证据变了没做成」——正是决定四要限次的那种。计数点放在这里，
                // 而不是放在 catch 全部 GatewayError 的地方：门前阻断与确认被拒不该占次数。
                try {
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
        // 身份来源也参与比较（同焦点身份的 IdentitySource）：确认前是自举的包级身份、确认后
        // 换成事件身份时，两边 activityName 可能都恰好为空而"平凡相等"，但那已经是另一套证据了。
        if (initial.identityBootstrapped != current.identityBootstrapped) {
            stale("确认后前台身份来源已变化（自举包级身份 ↔ 窗口事件身份）")
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

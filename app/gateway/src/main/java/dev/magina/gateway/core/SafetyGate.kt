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
 * **当前两档的行为完全一样**：都走完整确认链、都逐次确认。档位只是给下游（批次 2 通知栏审批的
 * 折叠态那一行）的措辞输入，**不产出任何免确认路径**——硬门不变量 4「一次确认只授权当前这一次
 * 调用，不生成可重放的通用令牌」一字未动。`SafetyGateTest` 里有一条回归断言钉住这件事：
 * 任一档位下，未确认时 handler 调用次数仍为 0。
 *
 * **已拍板、但尚未实现的将来差异**（2026-08-02，spec `2026-08-02-语义意图审批` §2.2/§6 题四）：
 * 审批对象上移到语义意图之后，**只有 II 级走"批准后延后执行"**（等前台恢复再重新感知），
 * I 级仍要求批准与执行紧挨着。**那时两档仍然都逐次确认**——差的是执行时机，不是要不要人点头，
 * 上面那条不变量与那条回归断言都原样有效。**在那次改动落地之前，本段第一句仍是当前事实**，
 * 别提前把它改成将来时。
 */
enum class RiskTier {
    /** I 级·不可逆：做完之后用户无自救手段，或撤销成本远高于执行成本。 */
    IRREVERSIBLE,

    /** II 级·有撤回窗口：目标 App 提供明确的撤回入口，且窗口未过期。 */
    RETRACTABLE,
}

/**
 * 按下 Enter 前那条**证据链是否自洽**：三处证据的身份（含来源）逐字段一致，且几何证据与来源
 * 一致地存在或缺失——不允许 blank == blank 平凡通过。
 *
 * 从 `SafetyPolicy.assess` 里原样抽出来（一字未改），因为**语义意图路径在执行前要再验一次**：
 * 那条路径不再比对"与批准那一瞬逐字节相同"，于是"这一刻的链是不是自洽"就从一次性检查
 * 变成了两处都要用的判据。**两处共用同一个实现**——判据一旦有两份，迟早只改一份。
 */
object EnterChainPolicy {
    fun isValid(context: SafetyContext): Boolean {
        val target = context.target
        val input = target?.inputCommitEvidence
        val prepared = target?.preparedTargetEvidence
        val identity = target?.focusIdentity
        return identity != null &&
            input != null && input.identity == identity &&
            prepared != null && prepared.label.isNotBlank() &&
            prepared.packageName == context.packageName &&
            prepared.identity == identity &&
            prepared.bounds == target.focusedInputBounds &&
            FocusIdentity.boundsConsistent(identity.source, target.focusedInputBounds) &&
            // IME-only 降级链失去了 a11y 焦点身份与几何，OCR 读回是仅剩的落框机械证据。
            (identity.source != IdentitySource.IME_ONLY || input.readbackVerified)
    }
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
            if (!EnterChainPolicy.isValid(context)) return SafetyDecision.Blocked(
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
     * **真人已经批准、随后复核判 stale** 时回调一次（[StaleReconfirmGuard] 的计数点；
     * 那条机制在当前站规下走不到，见其类注释）。
     *
     * 只在这一种情况回调：门前阻断、确认被拒、确认超时都不算——那三种里用户要么没批准过，
     * 要么本来就得到了"停下"的指示，不该占用重弹次数。
     */
    private val onStaleAfterApproval: (String, SafetyContext) -> Unit = { _, _ -> },
    /**
     * 语义意图审批（spec `2026-08-02-语义意图审批`）。**给了才走那条路径，默认 null =
     * 今天的行为一字不变。**
     *
     * 之所以做成开关而不是直接切过去：它改的是"批准之后拿什么去比"，属于安全姿态变更，
     * **必须经真机验收批次才能生效**。开关关着时这段代码只被离线用例执行到——那是有意的，
     * 而不是"写了没用"：判据先立，切换是另一件事、另一次验收。
     */
    private val intentApproval: IntentApproval? = null,
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
                // 「批准了、却因为证据变了没做成」——正是限次守卫要数的那种。计数点放在这里，
                // 而不是放在 catch 全部 GatewayError 的地方：门前阻断与确认被拒不该占次数。
                try {
                    if (SafetyPolicy.fingerprint(args) != initialArgsFingerprint) stale("确认后工具参数已变化")
                    afterConfirmationAllowed(toolName, deepCopy(frozenArgs), initialContext)
                    val approval = intentApproval
                    if (approval != null) {
                        resolveViaIntent(toolName, level, frozenArgs, decision, initialContext, approval)
                    } else {
                        val currentContext = try {
                            contextProvider(deepCopy(frozenArgs))
                        } catch (error: Throwable) {
                            stale("确认后无法重新获取目标上下文：${error.message.orEmpty()}")
                        }
                        requireKnownForeground(toolName, level, currentContext)
                        validateContext(toolName, frozenArgs, initialContext, currentContext)
                        currentContext
                    }
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

    /**
     * 语义意图路径（spec §2.2 第④～⑥步）。顺序是本方法的全部内容，改顺序等于改安全姿态：
     *
     * 1. 用**批准那一刻**的证据造意图（人核对过的那三项：档位 / 目标会话 / 内容摘要）。
     * 2. II 级按预算**有界等待**前台恢复到目标包；I 级预算为 0，等于不等。
     *    这段等待发生在**一次工具调用内部**，不是大脑重试——站规「安全失败即终态」一字未动。
     * 3. **重新感知**，重新要求前台已知。
     * 4. 意图匹配（[IntentMatchPolicy]）+ Enter 证据链自洽（[EnterChainPolicy]）**都要过**。
     * 5. **执行前**消费掉意图：执行成功与否都不再有第二次机会。
     */
    private fun resolveViaIntent(
        toolName: String,
        level: Level,
        frozenArgs: JSONObject,
        decision: SafetyDecision.ConfirmationRequired,
        initialContext: SafetyContext,
        approval: IntentApproval,
    ): SafetyContext {
        val prepared = initialContext.target?.preparedTargetEvidence
            ?: stale("确认前没有短时目标会话证据，无法构成语义意图")
        val input = initialContext.target?.inputCommitEvidence
        val intent = ApprovalIntent(
            intentId = approval.intentIdFactory(),
            riskTier = decision.riskTier,
            actionKind = decision.action.ifBlank { toolName },
            targetPackage = initialContext.packageName,
            targetLabel = prepared.label,
            contentSha256 = input?.sha256,
            contentLength = input?.length,
            // OCR 通道拿它做归一包含比对（sha256 不可逆，做不了包含）。**不传就等于
            // 微信这条 OCR-only 链上重建永远是 Unverified**——收益在唯一的目标 App 上
            // 一次都兑现不了，而失败形态与"通道坏了"长得一模一样，最难发现。
            contentNormalized = input?.normalizedText,
            contentPreview = input?.preview,
            createdAtMs = approval.clock(),
        )
        approval.store.open(intent)
        try {
            val waitBudget = approval.clocks.foregroundWaitBudgetFor(decision.riskTier)
            if (waitBudget > 0) {
                val wait = approval.awaitForeground(intent.targetPackage, waitBudget)
                if (!wait.reached) {
                    // **印的是实际生效的那个预算与真实等待时长**，不是上面按档位算出来问的那个：
                    // 两者可以不同（监督式跑测的 Stale 腿有短预算），而验收单让现场核的
                    // 恰恰是"短预算有没有生效"——印错那个数会得出完全相反的结论。
                    stale(
                        "批准后等前台恢复到 ${intent.targetPackage} 超时：" +
                            "实际等了 ${wait.waitedMs}ms（生效预算 ${wait.budgetMs}ms，" +
                            "读了 ${wait.reads} 次，最后看到 ${wait.lastPackage.ifBlank { "-" }}）",
                    )
                }
            }
            var currentContext = try {
                contextProvider(deepCopy(frozenArgs))
            } catch (error: Throwable) {
                stale("确认后无法重新获取目标上下文：${error.message.orEmpty()}")
            }
            requireKnownForeground(toolName, level, currentContext)

            // 证据重建（spec §2.4 选项 C）**只在证据真的没了时才做**，是恢复步骤而不是例行步骤：
            // 人慢但没离开输入会话时证据还在，这条路径一步都不走，行为与不开这功能时相同。
            //
            // 为什么会"没了"：输入证据按焦点身份取，而 IME 会话 id 每次 onStartInput 重新生成
            // （自增 generation 参与哈希）。切走再回来必然换身份 → 旧证据取不出来。
            // **不是判据太严，是证据本身不在了**——所以正解是重建证据，不是放宽判据。
            if (intent.contentSha256 != null && currentContext.target?.inputCommitEvidence == null) {
                when (val rebuild = approval.rebuild(intent)) {
                    is EvidenceRebuild.Mismatch ->
                        stale("重建输入证据与已批准的意图不符：${rebuild.reason}")
                    // **判不了单独一个错误码**：通道故障与"内容被换掉"必须在台账上分得开。
                    // 两者都不放行，但把它们记成同一个，下一轮就只能靠猜。
                    is EvidenceRebuild.Unverified -> throw GatewayError(
                        ErrorCode.E_VERIFY_FAIL,
                        "批准后重建输入证据判不了，拒绝执行：${rebuild.reason}",
                        channel = "safety",
                        fallback = "按站规收尾，不要换路重试同一危险动作",
                    )
                    is EvidenceRebuild.Rebuilt -> Unit
                }
                // 重建后必须**重新感知**：要比对的是重建之后那份上下文，不是重建之前那份。
                currentContext = try {
                    contextProvider(deepCopy(frozenArgs))
                } catch (error: Throwable) {
                    stale("重建证据后无法重新获取目标上下文：${error.message.orEmpty()}")
                }
                requireKnownForeground(toolName, level, currentContext)
            }

            when (val match = IntentMatchPolicy.matches(
                intent = intent,
                context = currentContext,
                nowMs = approval.clock(),
                intentTtlMs = approval.clocks.intentTtlMs,
            )) {
                is IntentMatch.Mismatch -> stale("执行前与已批准的意图不符：${match.reason}")
                IntentMatch.Matched -> Unit
            }
            val enterPressed = toolName == "press_key" &&
                frozenArgs.optString("key").equals("enter", ignoreCase = true)
            if (enterPressed && !EnterChainPolicy.isValid(currentContext)) throw GatewayError(
                ErrorCode.E_BLOCKED,
                "执行前焦点输入证据链不自洽，拒绝按下 Enter",
                channel = "safety",
                fallback = "按站规收尾，不要换路重试同一危险动作",
            )
            // **消费必须在执行之前**：执行失败后重来一定拿不到旧意图，只能重新走一次人的批准。
            approval.store.consume(intent.intentId)
                ?: stale("已批准的意图不再可用（被另一次确认顶掉或已消费）")
            return currentContext
        } finally {
            // 上面任何一步抛出时，意图不得留在保管处等着下一次调用捡走。
            approval.store.discard(intent.intentId)
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

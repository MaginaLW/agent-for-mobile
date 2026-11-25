package dev.magina.gateway.mcp

import dev.magina.gateway.core.RiskTier
import dev.magina.gateway.core.SafetyContext
import dev.magina.gateway.core.SafetyPolicy
import dev.magina.gateway.core.StaleReconfirmGuard
import dev.magina.gateway.testing.InactiveTestControlSession
import dev.magina.gateway.testing.TestConfirmationAttempt
import dev.magina.gateway.testing.TestControlSession
import dev.magina.gateway.tools.IntentSendObservation
import org.json.JSONArray
import org.json.JSONObject

/** MCP 工具注册与安全门执行外观（具体定义在 [ToolCatalog]，管线在 [ToolExecutionPipeline]）。 */
object ToolRegistry {

    /**
     * 一次工具调用期间、安全门几个回调之间共享的可变状态。
     */
    internal class CallScope(val toolName: String, val argsFingerprint: String) {
        var safetyNote: String = ""
        var intentObservation: IntentSendObservation? = null
        var contextReads: Int = 0
        var testSession: TestControlSession = InactiveTestControlSession
        var testAttempt: TestConfirmationAttempt? = null
        var staleKey: String = ""
        var targetLabel: String = ""
        var inputPreview: String? = null

        fun readContext(reader: () -> SafetyContext): SafetyContext {
            contextReads += 1
            if (contextReads > 1) safetyNote += ";context=rechecked"
            return reader().also { resolved ->
                if (contextReads == 1) {
                    captureApprovalScope(resolved, null)
                }
            }
        }

        fun appendSafetyNote(token: String) {
            if (token.isBlank()) return
            if (safetyNote.split(';').any { it == token }) return
            safetyNote = if (safetyNote.isEmpty()) token else "$safetyNote;$token"
        }

        fun captureApprovalScope(context: SafetyContext, riskTier: RiskTier?) {
            if (staleKey.isNotEmpty()) return
            targetLabel = context.target?.preparedTargetEvidence?.label.orEmpty()
            inputPreview = context.target?.inputCommitEvidence?.preview
            staleKey = StaleReconfirmGuard.key(
                toolName = toolName,
                riskTier = riskTier ?: RiskTier.IRREVERSIBLE,
                targetLabel = targetLabel,
                contentKey = StaleReconfirmGuard.contentKeyOf(toolName, context),
            )
        }
    }

    val tools: List<ToolSpec> = ToolCatalog.baseTools + MacroToolCatalog.tools

    private val byName = tools.associateBy { it.name }
    private val pipeline = ToolExecutionPipeline { byName }

    /** 敏感 app 前台时仍放行的工具（撤离、纯感知与静态技能包查询）；press_key 另限安全撤离键。 */
    internal val BLOCKED_APP_ALLOWED: Set<String> = ToolCatalog.BLOCKED_APP_ALLOWED

    internal const val OCR_REVERIFY_EXACT_NAV_NOTE = ToolExecutionPipeline.OCR_REVERIFY_EXACT_NAV_NOTE

    fun listToolsJson(): JSONArray = ToolCatalog.listToolsJson(tools)

    fun call(name: String, args: JSONObject): ToolResult =
        pipeline.call(name, args, CallOrigin.MODEL)

    /** 生产/调试宏子步骤统一入口：强制与大脑调用共用同一条黑名单、SafetyGate 与 ConfirmOverlay 管线。 */
    internal fun callFromMacro(name: String, args: JSONObject): ToolResult =
        pipeline.call(name, args, CallOrigin.MACRO)

    internal fun channelOf(name: String): String = ToolCatalog.channelOf(name)

    internal fun isExactNavFallbackEligible(
        policy: SafetyPolicy,
        action: String,
        isOcrOnly: Boolean,
        label: String,
        desc: String,
        bounds: String,
        source: String,
        windowPane: String?,
        baseContext: SafetyContext,
        args: JSONObject,
    ): Boolean = pipeline.isExactNavFallbackEligible(
        policy = policy,
        action = action,
        isOcrOnly = isOcrOnly,
        label = label,
        desc = desc,
        bounds = bounds,
        source = source,
        windowPane = windowPane,
        baseContext = baseContext,
        args = args,
    )

    internal fun requireExactNavStillAllowed(
        policy: SafetyPolicy,
        args: JSONObject,
        resolvedContext: SafetyContext,
    ) = pipeline.requireExactNavStillAllowed(policy, args, resolvedContext)
}

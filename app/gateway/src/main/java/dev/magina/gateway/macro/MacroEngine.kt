package dev.magina.gateway.macro

import dev.magina.gateway.core.ErrorCode
import dev.magina.gateway.core.GatewayError
import org.json.JSONArray
import org.json.JSONObject

/**
 * 生产宏确定性执行器：
 * - 逐步骤经 [stepExecutor]（生产为 `ToolRegistry.callFromMacro`）走统一黑名单 / SafetyGate / ConfirmOverlay / Audit；
 * - 任一步触发安全终态错误码（`E_BLOCKED` / `E_CONFIRM_REQUIRED` / `E_CONFIRM_TIMEOUT` / `E_STALE_REF` / `E_PERM_MISSING`），
 *   立刻原样抛出 `GatewayError` 且 `handoff_allowed = false`，禁止大脑重试或换路；
 * - 遇到非安全类失败或页面前提不满足时，返回 `handoff_required` 与断点摘要交大脑接管。
 */
internal class MacroEngine(
    private val catalog: MacroCatalog,
    private val isBlockedApp: (String?) -> Boolean,
    private val loginWallKeywordsForPackage: (String) -> List<String>,
    private val stepExecutor: (toolName: String, args: JSONObject) -> JSONObject,
) {

    fun run(args: JSONObject): JSONObject {
        val allowedTopKeys = setOf("name", "params")
        val unknownTop = args.keys().asSequence().filter { it !in allowedTopKeys }.toList()
        if (unknownTop.isNotEmpty()) {
            throw GatewayError(
                ErrorCode.E_INVALID_ARG,
                "skill_macro_exec 不接受未声明字段：${unknownTop.joinToString(",")}",
                channel = "macro",
                retryable = false,
            )
        }
        val name = (args.opt("name") as? String)?.trim().orEmpty()
        if (name.isEmpty()) {
            throw GatewayError(
                ErrorCode.E_INVALID_ARG,
                "skill_macro_exec 缺少必填参数 name",
                channel = "macro",
                retryable = false,
            )
        }
        val spec = catalog.find(name) ?: throw GatewayError(
            ErrorCode.E_INVALID_ARG,
            "未注册的生产宏：$name",
            channel = "macro",
            retryable = false,
            fallback = "先调用 skill_macro_list 查看已注册宏名称与参数",
        )
        if (isBlockedApp(spec.expectPackage)) {
            throw GatewayError(
                ErrorCode.E_BLOCKED,
                "宏目标应用（${spec.expectPackage}）属于敏感黑名单，拒绝执行",
                channel = "safety",
                retryable = false,
            )
        }
        val rawParams = args.opt("params")
        val paramsObj = when (rawParams) {
            null, JSONObject.NULL -> JSONObject()
            is JSONObject -> rawParams
            else -> throw GatewayError(
                ErrorCode.E_INVALID_ARG,
                "skill_macro_exec params 必须为 JSON 对象",
                channel = "macro",
                retryable = false,
            )
        }
        val boundParams = bindAndValidateParams(spec, paramsObj)

        val completedSteps = ArrayList<String>()
        val skippedSteps = ArrayList<String>()
        val savedRefs = LinkedHashMap<String, String>()
        var finalSnapshot: JSONObject? = null
        var stepsExecuted = 0

        for (step in spec.steps) {
            val resolvedArgs = MacroContract.renderArgs(step.argsTemplate, boundParams, savedRefs)
            val envelope = try {
                stepsExecuted += 1
                stepExecutor(step.tool, resolvedArgs)
            } finally {
                if (step.tool in MacroContract.MUTATING_STEP_TOOLS) {
                    savedRefs.clear()
                }
            }

            val ctx = envelope.optJSONObject("ctx") ?: JSONObject()
            if (envelope.opt("ok") != true) {
                val err = envelope.optJSONObject("error") ?: JSONObject()
                val errCode = err.optString("code", ErrorCode.E_INTERNAL.name)
                val errMsg = err.optString("message", "步骤执行失败")
                val errChannel = err.optString("channel", "macro")
                val errFallback = err.optString("fallback")
                val errExtra = err.optJSONObject("extra")

                if (errCode in MacroContract.SAFETY_TERMINAL_ERROR_CODES) {
                    val codeEnum = runCatching { ErrorCode.valueOf(errCode) }.getOrDefault(ErrorCode.E_BLOCKED)
                    val extra = JSONObject()
                        .put("macro_id", spec.id)
                        .put("failed_step", step.id)
                        .put("completed_steps", JSONArray(completedSteps))
                        .put("handoff_allowed", false)
                    throw GatewayError(
                        code = codeEnum,
                        message = "宏 ${spec.id} 在步骤 ${step.id} 触发安全终态（$errCode）：$errMsg",
                        channel = errChannel.ifEmpty { "safety" },
                        retryable = false,
                        fallback = errFallback.ifEmpty { "按站规立即停下并报告失败，不得重试或换路" },
                        extra = extra,
                    )
                }

                if (step.optional && errCode == ErrorCode.E_NOT_FOUND.name) {
                    skippedSteps.add(step.id)
                    continue
                }

                val actualPkg = errExtra?.optString("actual_package").orEmpty()
                    .ifEmpty { ctx.optString("app") }
                val blockerDetected = actualPkg == SYSTEM_APPFILTER_PACKAGE ||
                    ctx.optString("app") == SYSTEM_APPFILTER_PACKAGE
                val hint = if (blockerDetected) {
                    "当前命中系统拦截弹窗（$SYSTEM_APPFILTER_PACKAGE），请立即停止并交现场用户处理"
                } else {
                    errFallback.ifEmpty { "请由大脑从当前页面断点接管继续操作" }
                }
                return handoffResponse(
                    macroId = spec.id,
                    completedSteps = completedSteps,
                    skippedSteps = skippedSteps,
                    stepsExecuted = stepsExecuted,
                    failedStep = step.id,
                    failureCode = errCode,
                    failureReason = errMsg,
                    blockerDetected = blockerDetected,
                    nextHint = hint,
                    contextSummary = buildContextSummary(ctx, actualPkg, null),
                )
            }

            val data = envelope.optJSONObject("data") ?: JSONObject()
            val observedPkg = resolveObservedPackage(data, ctx)

            step.handoffIfForegroundIs?.let { targetFg ->
                if (observedPkg == targetFg) {
                    val reason = step.handoffReason
                        ?: "当前前台已在 $targetFg，交由大脑按目标页站内入口接管"
                    return handoffResponse(
                        macroId = spec.id,
                        completedSteps = completedSteps,
                        skippedSteps = skippedSteps,
                        stepsExecuted = stepsExecuted,
                        failedStep = step.id,
                        failureCode = "HANDOFF_PRECONDITION",
                        failureReason = reason,
                        blockerDetected = false,
                        nextHint = reason,
                        contextSummary = buildContextSummary(ctx, observedPkg, data),
                    )
                }
            }

            step.assertions?.let { assertions ->
                val violation = checkAssertions(
                    spec = spec,
                    step = step,
                    assertions = assertions,
                    data = data,
                    ctx = ctx,
                    observedPkg = observedPkg,
                )
                if (violation != null) {
                    return handoffResponse(
                        macroId = spec.id,
                        completedSteps = completedSteps,
                        skippedSteps = skippedSteps,
                        stepsExecuted = stepsExecuted,
                        failedStep = step.id,
                        failureCode = violation.code,
                        failureReason = violation.reason,
                        blockerDetected = violation.blockerDetected,
                        nextHint = violation.nextHint,
                        contextSummary = buildContextSummary(ctx, observedPkg, data),
                    )
                }
            }

            step.saveRef?.let { slot ->
                val matches = data.optJSONArray("matches")
                if (matches != null && matches.length() == 1) {
                    val ref = matches.getJSONObject(0).optString("ref").trim()
                    if (ref.isNotEmpty()) savedRefs[slot] = ref
                }
            }

            if (step.captureAsFinalSnapshot) {
                finalSnapshot = JSONObject(data.toString())
            }
            completedSteps.add(step.id)
        }

        return JSONObject()
            .put("status", "completed")
            .put("macro_id", spec.id)
            .put("app", spec.app)
            .put("expect_package", spec.expectPackage)
            .put("steps_executed", stepsExecuted)
            .put("completed_steps", JSONArray(completedSteps))
            .put("skipped_steps", JSONArray(skippedSteps))
            .put("summary", "宏 ${spec.id} 已完成全部前置步骤（跳过 ${skippedSteps.size} 步）")
            .apply {
                finalSnapshot?.let { put("final_snapshot", it) }
            }
    }

    private fun bindAndValidateParams(
        spec: MacroSpec,
        paramsObj: JSONObject,
    ): Map<String, String> {
        val providedKeys = paramsObj.keys().asSequence().toSet()
        val extraKeys = providedKeys - spec.params.keys
        if (extraKeys.isNotEmpty()) {
            throw GatewayError(
                ErrorCode.E_INVALID_ARG,
                "宏 ${spec.id} 不接受未声明参数：${extraKeys.sorted().joinToString(",")}",
                channel = "macro",
                retryable = false,
            )
        }
        val bound = LinkedHashMap<String, String>()
        for ((name, rule) in spec.params) {
            val raw = paramsObj.opt(name)
            if (raw == null || raw == JSONObject.NULL) {
                if (rule.required) {
                    throw GatewayError(
                        ErrorCode.E_INVALID_ARG,
                        "宏 ${spec.id} 缺少必填参数：$name",
                        channel = "macro",
                        retryable = false,
                    )
                }
                continue
            }
            if (raw !is String) {
                throw GatewayError(
                    ErrorCode.E_INVALID_ARG,
                    "宏 ${spec.id} 参数 $name 必须为字符串",
                    channel = "macro",
                    retryable = false,
                )
            }
            val value = raw.trim()
            if (value.length < rule.minLength || value.length > rule.maxLength) {
                throw GatewayError(
                    ErrorCode.E_INVALID_ARG,
                    "宏 ${spec.id} 参数 $name 长度需在 ${rule.minLength}..${rule.maxLength} 之间",
                    channel = "macro",
                    retryable = false,
                )
            }
            bound[name] = value
        }
        return bound
    }

    private data class AssertionViolation(
        val code: String,
        val reason: String,
        val blockerDetected: Boolean,
        val nextHint: String,
    )

    private fun checkAssertions(
        spec: MacroSpec,
        step: MacroStepSpec,
        assertions: MacroAssertions,
        data: JSONObject,
        ctx: JSONObject,
        observedPkg: String,
    ): AssertionViolation? {
        if (observedPkg in assertions.notPackages) {
            val blocker = observedPkg == SYSTEM_APPFILTER_PACKAGE
            return AssertionViolation(
                code = if (blocker) "SYSTEM_BLOCKER" else "ASSERTION_FAILED",
                reason = "步骤 ${step.id} 前台落入受阻包名：$observedPkg",
                blockerDetected = blocker,
                nextHint = if (blocker) {
                    "当前停在系统拦截弹窗（$SYSTEM_APPFILTER_PACKAGE），请立即停止并交现场用户处理"
                } else {
                    "请检查当前前台包名 $observedPkg 后由大脑接管"
                },
            )
        }
        assertions.packageEquals?.let { expectedPkg ->
            if (observedPkg != expectedPkg) {
                val blocker = observedPkg == SYSTEM_APPFILTER_PACKAGE
                return AssertionViolation(
                    code = "PACKAGE_MISMATCH",
                    reason = "步骤 ${step.id} 预期前台 $expectedPkg，实际为 ${observedPkg.ifEmpty { "<unknown>" }}",
                    blockerDetected = blocker,
                    nextHint = if (blocker) {
                        "当前停在系统拦截弹窗（$SYSTEM_APPFILTER_PACKAGE），请立即停止并交现场用户处理"
                    } else {
                        "请先核对当前前台状态后由大脑接管"
                    },
                )
            }
        }
        if (assertions.blockingOverlayFalse && data.optBoolean("blocking_overlay", false)) {
            return AssertionViolation(
                code = "BLOCKING_OVERLAY",
                reason = "步骤 ${step.id} 检测到页面存在遮挡弹窗（blocking_overlay=true）",
                blockerDetected = true,
                nextHint = "出现页面遮挡，请立即停止或由大脑按站规核对处理",
            )
        }
        if (assertions.noLoginWall) {
            val keywords = loginWallKeywordsForPackage(spec.expectPackage)
            if (keywords.isNotEmpty()) {
                val hit = findLoginWallKeyword(data, keywords)
                if (hit != null) {
                    return AssertionViolation(
                        code = "LOGIN_WALL",
                        reason = "步骤 ${step.id} 检测到登录墙关键词「$hit」",
                        blockerDetected = true,
                        nextHint = "命中账号登录墙，请立即停止并报告（绝不代登录或处理验证码）",
                    )
                }
            }
        }
        assertions.minMatches?.let { min ->
            val count = data.optJSONArray("matches")?.length() ?: 0
            if (count < min) {
                return AssertionViolation(
                    code = "ASSERTION_FAILED",
                    reason = "步骤 ${step.id} 匹配元素数 $count < $min",
                    blockerDetected = false,
                    nextHint = "目标元素未匹配足够数量，交由大脑接管",
                )
            }
        }
        return null
    }

    private fun findLoginWallKeyword(data: JSONObject, keywords: List<String>): String? {
        val elements = data.optJSONArray("elements") ?: return null
        for (i in 0 until elements.length()) {
            val el = elements.optJSONObject(i) ?: continue
            val text = el.optString("text")
            val desc = el.optString("desc")
            for (kw in keywords) {
                if (kw.isNotBlank() && (text.contains(kw) || desc.contains(kw))) return kw
            }
        }
        return null
    }

    private fun resolveObservedPackage(data: JSONObject, ctx: JSONObject): String =
        data.optString("actual_package").trim()
            .ifEmpty { data.optString("package").trim() }
            .ifEmpty { ctx.optString("app").trim() }

    private fun buildContextSummary(
        ctx: JSONObject,
        observedPkg: String,
        data: JSONObject?,
    ): JSONObject = JSONObject()
        .put("package", observedPkg.ifEmpty { ctx.optString("app") })
        .put("activity", ctx.optString("activity"))
        .put("foreground_known", ctx.optBoolean("foreground_known", false))
        .put("window_topology", ctx.optString("window_topology"))
        .apply {
            data?.takeIf { it.has("blocking_overlay") }?.let {
                put("blocking_overlay", it.optBoolean("blocking_overlay", false))
            }
            data?.takeIf { it.has("count") }?.let {
                put("element_count", it.optInt("count", 0))
            }
        }

    private fun handoffResponse(
        macroId: String,
        completedSteps: List<String>,
        skippedSteps: List<String>,
        stepsExecuted: Int,
        failedStep: String,
        failureCode: String,
        failureReason: String,
        blockerDetected: Boolean,
        nextHint: String,
        contextSummary: JSONObject,
    ): JSONObject = JSONObject()
        .put("status", "handoff_required")
        .put("handoff_allowed", true)
        .put("macro_id", macroId)
        .put("steps_executed", stepsExecuted)
        .put("completed_steps", JSONArray(completedSteps))
        .put("skipped_steps", JSONArray(skippedSteps))
        .put("failed_step", failedStep)
        .put("failure_code", failureCode)
        .put("failure_reason", failureReason)
        .put("blocker_detected", blockerDetected)
        .put("next_hint", nextHint)
        .put("context_summary", contextSummary)

    private companion object {
        const val SYSTEM_APPFILTER_PACKAGE = "com.vivo.appfilter"
    }
}

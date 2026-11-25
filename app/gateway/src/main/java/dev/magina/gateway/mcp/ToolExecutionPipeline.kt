package dev.magina.gateway.mcp

import android.graphics.Bitmap
import android.graphics.Rect
import android.os.Process
import android.os.SystemClock
import dev.magina.gateway.BuildConfig
import dev.magina.gateway.Gateway
import dev.magina.gateway.a11y.GatewayA11yService
import dev.magina.gateway.a11y.isExactNavLabelEligible
import dev.magina.gateway.core.ApprovalChannel
import dev.magina.gateway.core.Envelope
import dev.magina.gateway.core.ErrorCode
import dev.magina.gateway.core.GatewayError
import dev.magina.gateway.core.Level
import dev.magina.gateway.core.PreparedTargetEvidence
import dev.magina.gateway.core.SafetyContext
import dev.magina.gateway.core.SafetyDecision
import dev.magina.gateway.core.SafetyGate
import dev.magina.gateway.core.SafetyPolicy
import dev.magina.gateway.core.SafetyTarget
import dev.magina.gateway.core.StaleReconfirmGuard
import dev.magina.gateway.core.guardPreparedTargetTypeTextArgs
import dev.magina.gateway.core.invalidateInputEvidenceForMutation
import dev.magina.gateway.core.invalidatePreparedTargetForMutation
import dev.magina.gateway.core.preparedTargetSurvivesTypeText
import dev.magina.gateway.core.sanitizeAuditArgs
import dev.magina.gateway.core.shouldSerializeUiCall
import dev.magina.gateway.overlay.ConfirmCardTarget
import dev.magina.gateway.overlay.ConfirmNotificationRequest
import dev.magina.gateway.overlay.ConfirmOverlay
import dev.magina.gateway.overlay.ConfirmOverlayWindowHost
import dev.magina.gateway.overlay.confirmCardVisibleInCapture
import dev.magina.gateway.core.ConfirmApprovalArbiter
import dev.magina.gateway.testing.ConfirmationIdGenerator
import dev.magina.gateway.testing.TestConfirmationAttempt
import dev.magina.gateway.testing.TestConfirmationCapture
import dev.magina.gateway.testing.TestForeground
import dev.magina.gateway.tools.IntentTools
import dev.magina.gateway.tools.UiTools
import dev.magina.gateway.tools.createIntentSendObservation
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.util.UUID

internal enum class CallOrigin(val wireName: String) {
    MODEL("model"),
    MACRO("macro"),
}

/**
 * 统一工具执行与安全门管线（MODEL 与 MACRO 共用同一道黑名单、SafetyGate、ConfirmOverlay 与 Audit）。
 */
internal class ToolExecutionPipeline(
    private val byNameProvider: () -> Map<String, ToolSpec>,
) {
    private val intentObservationProcessInstance by lazy { UUID.randomUUID().toString() }

    fun call(name: String, args: JSONObject, origin: CallOrigin = CallOrigin.MODEL): ToolResult {
        val spec = byNameProvider()[name]
        val mutatesUi = shouldSerializeUiCall(
            spec?.level,
            name,
            args.optBoolean("scroll_search", false),
        )
        return if (mutatesUi) {
            Gateway.uiMutationCoordinator.runExclusive { callInternal(name, args, origin) }
        } else {
            callInternal(name, args, origin)
        }
    }

    private fun confirmActionPhrase(decision: SafetyDecision.ConfirmationRequired): String = when {
        decision.toolName == "press_key" && decision.action.equals("enter", ignoreCase = true) -> "发送消息"
        decision.toolName == "press_key" -> "按键 ${decision.action}"
        decision.action.isNotBlank() -> "${decision.action} 危险目标"
        else -> decision.toolName
    }

    private fun currentSafetyPolicy(): SafetyPolicy = SafetyPolicy(
        // 技能包资产的 danger_words 即 I 级、send_words 即 II 级、action_confirm_words 为泛化确认词（I 级）。
        irreversibleWords = Gateway.skills.dangerWords,
        retractableWords = Gateway.skills.sendWords,
        sensitiveTargets = Gateway.skills.sensitiveTargets,
        actionConfirmWords = Gateway.skills.actionConfirmWords,
    )

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
    ): Boolean {
        if (action != "click" || !isOcrOnly) return false
        if (!isExactNavLabelEligible(label)) return false
        val probeContext = baseContext.copy(
            target = SafetyTarget(
                ref = args.optString("ref"),
                text = label,
                description = desc,
                bounds = bounds,
                source = source,
                windowPane = windowPane,
            ),
        )
        return policy.assess("ui_action", Level.W, args, probeContext) == SafetyDecision.Allowed
    }

    internal fun requireExactNavStillAllowed(
        policy: SafetyPolicy,
        args: JSONObject,
        resolvedContext: SafetyContext,
    ) {
        val recheck = policy.assess("ui_action", Level.W, args, resolvedContext)
        if (recheck != SafetyDecision.Allowed) {
            throw GatewayError(
                ErrorCode.E_BLOCKED,
                "OCR 精确导航兜底复核目标未通过免确认普通点击复验，已 fail-closed 拒绝",
                channel = "safety",
            )
        }
    }

    private fun newSafetyGate(call: ToolRegistry.CallScope, policy: SafetyPolicy): SafetyGate = SafetyGate(
        policy = policy,
        confirmer = { decision ->
            if (Gateway.staleReconfirmGuard.isExhausted(call.staleKey)) {
                Gateway.staleReconfirmGuard.clear(call.staleKey)
                call.appendSafetyNote("reconfirm=exhausted")
                throw GatewayError(
                    ErrorCode.E_CONFIRM_REQUIRED,
                    StaleReconfirmGuard.EXHAUSTED_MESSAGE,
                    channel = "safety",
                    fallback = StaleReconfirmGuard.EXHAUSTED_FALLBACK,
                )
            }
            call.appendSafetyNote("risk=confirmation_required;args_fp=${decision.argsFingerprint};confirmation=requested")
            val attempt = TestConfirmationAttempt(
                confirmationId = ConfirmationIdGenerator.next(),
                toolName = decision.toolName,
                action = decision.action,
                initialPackage = decision.initialPackage,
                inputLength = decision.inputLength,
                inputSha256 = decision.inputSha256,
            )
            call.testAttempt = attempt
            var decidedVia: ApprovalChannel? = null
            try {
                val overlayHost = GatewayA11yService.instance?.let { service ->
                    ConfirmOverlayWindowHost(context = service)
                }
                ConfirmOverlay.ask(
                    context = Gateway.appContext,
                    actionDesc = decision.cardText(attempt.confirmationId),
                    overlayHost = overlayHost,
                    onShownBeforeButtonsEnabled = { cardTarget ->
                        call.testSession = Gateway.testControl.onConfirmationShown(attempt) {
                            captureConfirmCardEvidence(cardTarget)
                        }
                    },
                    onDecisionObserved = { observed, channel ->
                        decidedVia = channel
                        Gateway.testControl.onConfirmationDecision(call.testSession, observed, channel)
                    },
                    notification = ConfirmNotificationRequest(
                        confirmationId = attempt.confirmationId,
                        nonce = ConfirmApprovalArbiter.newNonce(),
                        riskTier = decision.riskTier,
                        action = confirmActionPhrase(decision),
                        target = call.targetLabel.ifBlank { "${decision.initialPackage}（未绑定会话标题）" },
                        targetPackage = decision.initialPackage,
                        preview = call.inputPreview,
                    ),
                ).also { confirmed ->
                    call.appendSafetyNote("confirmation=${if (confirmed) "allowed" else "denied"}")
                    decidedVia?.let { call.appendSafetyNote("decided_via=${it.wireName}") }
                }
            } catch (error: Throwable) {
                call.appendSafetyNote("confirmation=error:${(error as? GatewayError)?.code ?: error.javaClass.simpleName}")
                throw error
            }
        },
        contextProvider = { frozenArgs ->
            call.readContext { safetyContext(call.toolName, frozenArgs, call, policy) }
        },
        onExecutionFailure = { error ->
            if (error !is GatewayError || error.code != ErrorCode.E_RETRY_EXHAUSTED) {
                Gateway.retryGuard.recordFailure(call.toolName, call.argsFingerprint)
            }
        },
        afterConfirmationAllowed = { _, _, _ ->
            val attempt = call.testAttempt ?: throw GatewayError(
                ErrorCode.E_INTERNAL,
                "确认完成但缺少同一次确认编号",
                channel = "safety",
            )
            val a11y = GatewayA11yService.require()
            Gateway.testControl.afterAllowed(
                session = call.testSession,
                attempt = attempt,
                performHome = { a11y.globalKey("home") },
                foreground = {
                    val current = a11y.ctx(Gateway.caps())
                    TestForeground(
                        known = current.optBoolean("foreground_known", false),
                        packageName = current.optString("app"),
                    )
                },
            )
        },
        afterExecutionSuccess = { executedTool, executedContext ->
            if (call.staleKey.isNotEmpty()) Gateway.staleReconfirmGuard.clear(call.staleKey)
            if (
                executedTool == "press_key" &&
                executedContext.target?.preparedTargetEvidence != null
            ) {
                Gateway.preparedTargetEvidence.clear()
            }
        },
        onStaleAfterApproval = { _, _ ->
            if (call.staleKey.isNotEmpty()) {
                Gateway.staleReconfirmGuard.recordStaleAfterApproval(call.staleKey)
                call.appendSafetyNote("reconfirm=${Gateway.staleReconfirmGuard.reconfirmCount(call.staleKey)}")
            }
        },
    )

    private fun ctxSnapshot(): JSONObject {
        val ctx = GatewayA11yService.instance?.ctx(Gateway.caps())
            ?: JSONObject().put("app", "").put("activity", "")
                .put("foreground_known", false).put("revision", -1)
                .put("keyboard", JSONObject().put("visible", false).put("height", 0))
                .put("caps", JSONArray(Gateway.caps()))
                .put("note", "a11y 未开启，ctx 降级")
        ctx.put("audit_write_failures", Gateway.audit.writeFailures)
        return ctx
    }

    private fun callInternal(name: String, args: JSONObject, origin: CallOrigin): ToolResult {
        val spec = byNameProvider()[name]
        invalidateInputEvidenceForMutation(
            store = Gateway.inputCommitEvidence,
            level = spec?.level,
            toolName = name,
            key = args.optString("key").ifEmpty { null },
            action = args.optString("action").ifEmpty { null },
            scrollSearch = args.optBoolean("scroll_search", false),
        )
        invalidatePreparedTargetForMutation(
            store = Gateway.preparedTargetEvidence,
            level = spec?.level,
            toolName = name,
            key = args.optString("key").ifEmpty { null },
            scrollSearch = args.optBoolean("scroll_search", false),
        )
        val auditId = Gateway.audit.nextId()
        val start = SystemClock.elapsedRealtime()
        val call = ToolRegistry.CallScope(toolName = name, argsFingerprint = SafetyPolicy.fingerprint(args))
        if (origin != CallOrigin.MODEL) {
            call.appendSafetyNote(originAuditToken(origin))
        }
        call.intentObservation = createIntentSendObservation(
            BuildConfig.DEBUG, name, auditId, Process::myPid,
            { intentObservationProcessInstance }, SystemClock::elapsedRealtime,
        )
        val auditArgs = sanitizeAuditArgs(name, args)

        fun finish(env: JSONObject, code: String, channel: String, image: String? = null): ToolResult {
            Gateway.audit.write(
                auditId, name, auditArgs, code, channel, SystemClock.elapsedRealtime() - start,
                note = call.safetyNote + call.intentObservation?.auditNote().orEmpty(),
            )
            return ToolResult(env, image)
        }

        if (spec == null) {
            val e = GatewayError(ErrorCode.E_INVALID_ARG, "未知工具：$name")
            return finish(Envelope.err(e, ctxSnapshot(), auditId), e.code.name, "")
        }

        return try {
            if (name == "type_text") {
                guardPreparedTargetTypeTextArgs(
                    args = args,
                    preparedStore = Gateway.preparedTargetEvidence,
                    inputStore = Gateway.inputCommitEvidence,
                )
            }
            val fg = GatewayA11yService.instance?.foregroundPackage()
            if (Gateway.skills.isBlockedApp(fg) && !ToolCatalog.blockedAppAllows(name, args)) {
                throw GatewayError(
                    ErrorCode.E_BLOCKED, "前台是敏感 app（$fg），默认拒绝一切读写",
                    fallback = "press_key(home) 离开后继续任务，并在报告中说明",
                )
            }
            val policy = currentSafetyPolicy()
            val gate = newSafetyGate(call, policy)
            val data = gate.execute(name, spec.level, args) { frozenArgs, validatedContext ->
                Gateway.retryGuard.checkAllowed(name, call.argsFingerprint)
                val result = executeValidated(spec, frozenArgs, validatedContext, call, policy)
                runCatching { Gateway.retryGuard.recordSuccess(name, call.argsFingerprint) }
                    .onFailure { error ->
                        call.appendSafetyNote("retry_success_record=error:${error.javaClass.simpleName}")
                    }
                result
            }

            var image: String? = null
            if (name == "screen_capture") {
                image = data.optString("base64").ifEmpty { null }
                data.remove("base64")
            }
            finish(Envelope.ok(data, ctxSnapshot(), auditId), "OK", ToolCatalog.channelOf(name), image)
        } catch (e: GatewayError) {
            if (name == "type_text") Gateway.preparedTargetEvidence.clear()
            finish(Envelope.err(e, runCatching { ctxSnapshot() }.getOrElse { JSONObject() }, auditId), e.code.name, e.channel)
        } catch (e: Exception) {
            if (name == "type_text") Gateway.preparedTargetEvidence.clear()
            val ge = GatewayError(ErrorCode.E_INTERNAL, "${e.javaClass.simpleName}: ${e.message}")
            finish(Envelope.err(ge, runCatching { ctxSnapshot() }.getOrElse { JSONObject() }, auditId), "E_INTERNAL", "")
        }
    }

    private fun captureConfirmCardEvidence(target: ConfirmCardTarget?): TestConfirmationCapture {
        val service = GatewayA11yService.require()
        var attempts = 0
        var latest: Bitmap? = null
        var visible = false
        while (attempts < CONFIRM_CARD_CAPTURE_ATTEMPTS) {
            attempts += 1
            if (attempts > 1) SystemClock.sleep(CONFIRM_CARD_RECAPTURE_DELAY_MS)
            val bitmap = try {
                service.captureBitmap()
            } catch (error: GatewayError) {
                if (error.code == ErrorCode.E_RATE_LIMITED && attempts < CONFIRM_CARD_CAPTURE_ATTEMPTS) {
                    SystemClock.sleep(CONFIRM_CARD_THROTTLE_BACKOFF_MS)
                    continue
                }
                if (latest == null) throw error
                break
            }
            latest?.recycle()
            latest = bitmap
            visible = target != null && confirmCardVisibleInCapture(
                target = target,
                width = bitmap.width,
                height = bitmap.height,
                pixelAt = bitmap::getPixel,
            )
            if (visible || target == null) break
        }
        val bitmap = latest ?: throw GatewayError(
            ErrorCode.E_CHANNEL_DOWN, "确认卡取证未取得任何截图", channel = "overlay",
        )
        val png = ByteArrayOutputStream().use { output ->
            if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)) {
                throw GatewayError(ErrorCode.E_CHANNEL_DOWN, "确认卡 PNG 编码失败", channel = "overlay")
            }
            output.toByteArray()
        }
        return TestConfirmationCapture(png = png, cardVisible = visible, attempts = attempts)
    }

    private fun safetyContext(
        name: String,
        args: JSONObject,
        call: ToolRegistry.CallScope,
        policy: SafetyPolicy,
    ): SafetyContext {
        val a11y = GatewayA11yService.instance
            ?: return SafetyContext("", "", -1, foregroundKnown = false)
        val ctx = a11y.ctx(Gateway.caps())
        val packageName = ctx.optString("app")
        val activityName = ctx.optString("activity")
        val revision = ctx.optLong("revision", -1)
        val foregroundKnown = ctx.optBoolean("foreground_known", false)
        val identityBootstrapped = ctx.optString("foreground_identity_source") == "bootstrap"
        val sameAppMulti = ctx.optString("window_topology") == "same_app_multi"
        if (!foregroundKnown) return SafetyContext(
            packageName = packageName,
            activityName = activityName,
            revision = revision,
            foregroundKnown = false,
            sameAppMultiWindow = sameAppMulti,
            target = null,
        )
        val baseContext = SafetyContext(
            packageName = packageName,
            activityName = activityName,
            revision = revision,
            foregroundKnown = true,
            identityBootstrapped = identityBootstrapped,
            sameAppMultiWindow = sameAppMulti,
        )
        val target = when {
            name == "ui_action" -> {
                val ref = args.getString("ref")
                val action = args.optString("action")
                val cached = a11y.peekCachedRef(ref)
                val allowExactNav = cached != null && isExactNavFallbackEligible(
                    policy = policy,
                    action = action,
                    isOcrOnly = cached.isOcrOnly,
                    label = cached.label,
                    desc = cached.desc,
                    bounds = boundsString(cached.bounds),
                    source = cached.source,
                    windowPane = cached.pane.takeIf { sameAppMulti },
                    baseContext = baseContext,
                    args = args,
                )
                val resolved = a11y.resolve(
                    ref = ref,
                    allowExactNavFallback = allowExactNav,
                    hasProtectedKeyword = policy::containsProtectedActionKeyword,
                )
                val resolvedTarget = SafetyTarget(
                    ref = ref,
                    text = resolved.text,
                    description = resolved.desc,
                    bounds = boundsString(resolved.bounds),
                    source = resolved.source,
                    windowPane = resolved.pane.takeIf { sameAppMulti },
                )
                if (resolved.usedExactNavFallback) {
                    requireExactNavStillAllowed(policy, args, baseContext.copy(target = resolvedTarget))
                    call.appendSafetyNote(OCR_REVERIFY_EXACT_NAV_NOTE)
                }
                resolvedTarget
            }
            name == "press_key" && args.optString("key").equals("enter", ignoreCase = true) ->
                UiTools.focusedInputSnapshot(a11y).let { focused ->
                    val bounds = focused.bounds?.let(::boundsString)
                    SafetyTarget(
                        focusIdentity = focused.identity,
                        focusedInputBounds = bounds,
                        inputCommitEvidence = Gateway.inputCommitEvidence.current(
                            focused.identity,
                            focused.readableText,
                        ),
                        preparedTargetEvidence = Gateway.preparedTargetEvidence.current(
                            packageName,
                            focused.identity,
                            bounds,
                        ),
                        windowPane = (focused.windowPane ?: a11y.paneForBounds(focused.bounds)).takeIf { sameAppMulti },
                    )
                }
            else -> null
        }
        return baseContext.copy(target = target)
    }

    private fun executeValidated(
        spec: ToolSpec,
        args: JSONObject,
        validatedContext: SafetyContext,
        call: ToolRegistry.CallScope,
        policy: SafetyPolicy,
    ): JSONObject = when (spec.name) {
        "intent_send" -> IntentTools.intentSend(
            args.getString("action"), args.optString("uri").ifEmpty { null },
            args.optJSONObject("extras"), args.optString("package").ifEmpty { null },
            args.optString("component").ifEmpty { null }, call.intentObservation,
        )
        "ui_action" -> {
            val ref = args.getString("ref")
            val action = args.getString("action")
            val params = JSONObject()
                .put("text", args.optString("text"))
                .put("direction", args.optString("direction", "forward"))
            val expected = validatedContext.target ?: throw GatewayError(
                ErrorCode.E_STALE_REF, "安全门未提供已复核的 UI 目标", channel = "safety",
            )
            val allowExactNav = isExactNavFallbackEligible(
                policy = policy,
                action = action,
                isOcrOnly = expected.source == "ocr",
                label = expected.text,
                desc = expected.description,
                bounds = expected.bounds,
                source = expected.source,
                windowPane = expected.windowPane,
                baseContext = validatedContext,
                args = args,
            )
            UiTools.uiAction(
                ref = ref,
                action = action,
                params = params,
                expected = expected,
                allowExactNavFallback = allowExactNav,
                hasProtectedKeyword = policy::containsProtectedActionKeyword,
                onExactNavUsed = { resolved ->
                    val resolvedTarget = SafetyTarget(
                        ref = ref,
                        text = resolved.text,
                        description = resolved.desc,
                        bounds = boundsString(resolved.bounds),
                        source = resolved.source,
                        windowPane = resolved.pane.takeIf { validatedContext.sameAppMultiWindow },
                    )
                    requireExactNavStillAllowed(policy, args, validatedContext.copy(target = resolvedTarget))
                    call.appendSafetyNote(OCR_REVERIFY_EXACT_NAV_NOTE)
                },
            )
        }
        "press_key" -> UiTools.pressKey(
            args.getString("key"),
            validatedContext.target?.focusIdentity,
            validatedContext.target?.inputCommitEvidence,
            validatedContext.target?.focusedInputBounds,
            validatedContext.target?.preparedTargetEvidence,
        )
        "type_text" -> executeTypeTextWithPreparedTargetValidation(spec, args)
        else -> spec.handler(args)
    }

    private fun executeTypeTextWithPreparedTargetValidation(
        spec: ToolSpec,
        args: JSONObject,
    ): JSONObject {
        val expected = Gateway.preparedTargetEvidence.peekActive()
        if (expected == null) return spec.handler(args)
        val before = currentPreparedTarget()
        if (before != expected) {
            val why = preparedTargetDrift(expected)
            Gateway.preparedTargetEvidence.clear()
            Gateway.inputCommitEvidence.clear()
            throw GatewayError(
                ErrorCode.E_STALE_REF,
                "type_text 前已准备目标已变化：$why",
                channel = "safety",
                retryable = false,
            )
        }
        return try {
            val result = spec.handler(args)
            val after = currentPreparedTarget()
            val input = after?.let { Gateway.inputCommitEvidence.current(it.identity) }
            if (!preparedTargetSurvivesTypeText(before, after, input, succeeded = true)) {
                val why = when {
                    after == null || after != before ->
                        "已准备目标在输入后变化：${preparedTargetDrift(before)}"
                    input == null && before.identity.degraded ->
                        "IME-only 降级链没有形成输入提交证据：输入栏 OCR 读回" +
                            "verified=${result.optBoolean("verified", false)}" +
                            "，实际读回「${result.optString("readback").take(24)}」" +
                            "，${result.optString("readback_geometry")}" +
                            "（读回不过就不记证据，见 design §3.5）"
                    input == null -> "输入后没有形成可用的输入提交证据"
                    else -> "输入证据身份与已准备目标不一致"
                }
                Gateway.preparedTargetEvidence.clear()
                Gateway.inputCommitEvidence.clear()
                throw GatewayError(
                    ErrorCode.E_STALE_REF,
                    "type_text 后复核失败：$why",
                    channel = "safety",
                    retryable = false,
                )
            }
            result
        } catch (error: Throwable) {
            Gateway.preparedTargetEvidence.clear()
            Gateway.inputCommitEvidence.clear()
            throw error
        }
    }

    private fun preparedTargetDrift(expected: PreparedTargetEvidence): String {
        val a11y = GatewayA11yService.instance ?: return "无障碍服务不可用"
        val ctx = runCatching { a11y.ctx(Gateway.caps()) }.getOrNull()
            ?: return "无法读取前台上下文"
        if (!ctx.optBoolean("foreground_known", false)) return "前台身份未知"
        val focused = UiTools.focusedInputSnapshot(a11y)
        val bounds = focused.bounds?.let(::boundsString)
        return buildList {
            val pkg = ctx.optString("app")
            if (pkg != expected.packageName) add("前台包 ${expected.packageName} → $pkg")
            val identity = focused.identity
            when {
                identity == null -> add("当前取不到任何焦点输入身份（IME 会话可能已结束）")
                identity.source != expected.identity.source ->
                    add("身份来源 ${expected.identity.source} → ${identity.source}")
                identity.imeSessionId != expected.identity.imeSessionId ->
                    add("IME 会话 ${expected.identity.imeSessionId} → ${identity.imeSessionId}")
                identity.a11yInputId != expected.identity.a11yInputId ->
                    add("a11y 节点 ${expected.identity.a11yInputId} → ${identity.a11yInputId}")
                identity.cursorAnchorWindowId != expected.identity.cursorAnchorWindowId ->
                    add("光标锚点窗口 ${expected.identity.cursorAnchorWindowId} → ${identity.cursorAnchorWindowId}")
            }
            if (bounds != expected.bounds) add("焦点位置 ${expected.bounds} → $bounds")
        }.ifEmpty { listOf("身份逐项一致但短时目标已过期（TTL）") }.joinToString("；")
    }

    private fun currentPreparedTarget(): PreparedTargetEvidence? {
        val a11y = GatewayA11yService.instance ?: run {
            Gateway.preparedTargetEvidence.clear()
            return null
        }
        val ctx = a11y.ctx(Gateway.caps())
        if (!ctx.optBoolean("foreground_known", false)) {
            Gateway.preparedTargetEvidence.clear()
            return null
        }
        val focused = UiTools.focusedInputSnapshot(a11y)
        val bounds = focused.bounds?.let(::boundsString)
        return Gateway.preparedTargetEvidence.current(
            ctx.optString("app"),
            focused.identity,
            bounds,
        )
    }

    private fun boundsString(bounds: Rect): String =
        "[${bounds.left},${bounds.top}][${bounds.right},${bounds.bottom}]"

    companion object {
        const val OCR_REVERIFY_EXACT_NAV_NOTE = "ocr_reverify=exact_nav"

        fun originAuditToken(origin: CallOrigin): String = "origin=${origin.wireName}"

        /** 合成落后一两个 vsync 是常态，多给几次机会；总延迟仍远小于人抬手看卡的时间。 */
        private const val CONFIRM_CARD_CAPTURE_ATTEMPTS = 4
        private const val CONFIRM_CARD_RECAPTURE_DELAY_MS = 400L
        private const val CONFIRM_CARD_THROTTLE_BACKOFF_MS = 900L
    }
}

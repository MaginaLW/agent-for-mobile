package dev.magina.gateway.tools

import android.os.SystemClock
import android.graphics.Rect
import dev.magina.gateway.Gateway
import dev.magina.gateway.a11y.GatewayA11yService
import dev.magina.gateway.a11y.FreshValidatedRef
import dev.magina.gateway.a11y.P0FocusProbe
import dev.magina.gateway.a11y.P0FocusProbeValidator
import dev.magina.gateway.a11y.P0ElementStage
import dev.magina.gateway.a11y.P0FixedQueryValidator
import dev.magina.gateway.a11y.P0_FIXED_FILE_TRANSFER_QUERY
import dev.magina.gateway.a11y.P0PreparedTargetFinalState
import dev.magina.gateway.a11y.P0PreparedTargetRecorderValidator
import dev.magina.gateway.a11y.P0PreparedTargetRecordTransaction
import dev.magina.gateway.a11y.P0MacroElement
import dev.magina.gateway.a11y.P0MacroFocus
import dev.magina.gateway.a11y.P0MacroForeground
import dev.magina.gateway.a11y.P0MacroRect
import dev.magina.gateway.a11y.P0MacroSnapshot
import dev.magina.gateway.a11y.P0RefStage
import dev.magina.gateway.a11y.P0StageRefAction
import dev.magina.gateway.a11y.P0StageRefActionValidator
import dev.magina.gateway.a11y.P0WeChatPrepareAdapter
import dev.magina.gateway.a11y.P0WeChatPrepareConfig
import dev.magina.gateway.a11y.P0WeChatPrepareMacro
import dev.magina.gateway.a11y.P0_PREPARE_MACRO_NAME
import dev.magina.gateway.a11y.P0_WECHAT_PACKAGE
import dev.magina.gateway.core.ErrorCode
import dev.magina.gateway.core.GatewayError
import dev.magina.gateway.ime.ImeBridge
import org.json.JSONObject

internal object MacroRunnerFactory {
    fun run(args: JSONObject): JSONObject {
        Gateway.preparedTargetEvidence.clear()
        val keys = args.keys().asSequence().toSet()
        val name = args.opt("name")
        if (keys != setOf("name") || name !is String) throw GatewayError(
            ErrorCode.E_INVALID_ARG,
            "macro_run 只接受唯一白名单 name，禁止额外文本、联系人或坐标参数",
            channel = "macro",
            retryable = false,
        )
        if (name != P0_PREPARE_MACRO_NAME) throw GatewayError(
            ErrorCode.E_INVALID_ARG,
            "debug 宏不在验收白名单",
            channel = "macro",
            retryable = false,
        )
        val sensitiveSurfaceWords = Gateway.skills.dangerWords + Gateway.skills.sensitiveTargets
        val service = GatewayA11yService.require()
        val adapter = AndroidP0WeChatPrepareAdapter(
            service = service,
            sensitiveSurfaceWords = sensitiveSurfaceWords,
        )
        val result = P0WeChatPrepareMacro(
            adapter = adapter,
            config = P0WeChatPrepareConfig(
                sensitiveSurfaceWords = sensitiveSurfaceWords,
            ),
        ).run()
        val output = result.toJson()
        return P0PreparedTargetRecordTransaction.run(
            rollback = Gateway.preparedTargetEvidence::clear,
        ) {
            service.withFreshPreparedTargetGuard(P0_WECHAT_PACKAGE) { rawFresh, serviceInputProof ->
                val fresh = adapter.decodeForRecorder(rawFresh)
                val foregroundJson = service.ctx(Gateway.caps())
                val focused = UiTools.focusedInputSnapshot(service)
                val proofBounds = P0MacroRect(
                    serviceInputProof.left,
                    serviceInputProof.top,
                    serviceInputProof.right,
                    serviceInputProof.bottom,
                )
                val finalState = P0PreparedTargetFinalState(
                    foreground = P0MacroForeground(
                        foregroundJson.optBoolean("foreground_known", false),
                        foregroundJson.optString("app"),
                    ),
                    snapshot = fresh,
                    focused = P0MacroFocus(
                        nodePresent = serviceInputProof.nodePresent,
                        focused = serviceInputProof.focused,
                        editable = serviceInputProof.editable,
                        imeActive = ImeBridge.active,
                        inputConnectionAvailable = ImeBridge.hasInputConnection(),
                        fingerprint = ImeBridge.focusedInputId,
                        stage = if (
                            serviceInputProof.nodePresent &&
                            (serviceInputProof.top + serviceInputProof.bottom) / 2 >=
                            service.resources.displayMetrics.heightPixels * 0.75
                        ) P0ElementStage.BOTTOM_INPUT else P0ElementStage.CONTENT,
                    ),
                    focusedBounds = proofBounds,
                    uiFocusedInputId = focused.id,
                    uiFocusedBounds = focused.bounds?.let {
                        P0MacroRect(it.left, it.top, it.right, it.bottom)
                    },
                    imeFocusedInputId = ImeBridge.focusedInputId,
                    inputProofRevision = serviceInputProof.captureRevision,
                    inputProofWindowId = serviceInputProof.foregroundWindowId,
                    inputProofNodeId = serviceInputProof.nodeId,
                    inputProofImeSessionId = serviceInputProof.imeSessionId,
                    inputProofBounds = proofBounds,
                )
                val validated = P0PreparedTargetRecorderValidator.validateAndRecord(
                    result,
                    finalState,
                    sensitiveSurfaceWords,
                ) { target ->
                    val bounds = "[${target.bounds.left},${target.bounds.top}]" +
                        "[${target.bounds.right},${target.bounds.bottom}]"
                    Gateway.preparedTargetEvidence.record(
                        label = target.label,
                        packageName = target.packageName,
                        focusedInputId = target.focusedInputId,
                        bounds = bounds,
                        imeSessionId = target.imeSessionId,
                    )
                }
                output
                    .put("focused_input_id", validated.focusedInputId)
                    .put(
                        "focused_input_bounds",
                        org.json.JSONArray(
                            listOf(
                                validated.bounds.left,
                                validated.bounds.top,
                                validated.bounds.right,
                                validated.bounds.bottom,
                            ),
                        ),
                    )
            }
        }
    }
}

/** Android 细节只存在于 debug source set；状态机本身只消费稳定的 adapter 契约。 */
private class AndroidP0WeChatPrepareAdapter(
    private val service: GatewayA11yService,
    private val sensitiveSurfaceWords: List<String>,
) : P0WeChatPrepareAdapter {
    override fun foreground(): P0MacroForeground {
        val ctx = service.ctx(Gateway.caps())
        return P0MacroForeground(
            known = ctx.optBoolean("foreground_known", false),
            packageName = ctx.optString("app"),
        )
    }

    override fun snapshot(): P0MacroSnapshot = decodeSnapshot(
        service.snapshot("interactive", maxElements = 400),
    )

    override fun forceFreshVision(): P0MacroSnapshot = decodeSnapshot(
        service.forceFreshVision("interactive", maxElements = 400),
    )

    private fun decodeSnapshot(raw: JSONObject): P0MacroSnapshot {
        val metrics = service.resources.displayMetrics
        val elements = raw.getJSONArray("elements")
        val revision = raw.getLong("revision")
        val captureRevision = raw.optLong("capture_revision", Long.MIN_VALUE)
        if (captureRevision != revision) throw GatewayError(
            ErrorCode.E_STALE_REF,
            "fresh snapshot 未绑定同一 capture revision",
            channel = "p0-wechat-prepare",
            retryable = true,
        )
        return P0MacroSnapshot(
            screenWidth = metrics.widthPixels,
            screenHeight = metrics.heightPixels,
            revision = revision,
            captureRevision = captureRevision,
            foregroundWindowId = raw.optInt("foreground_window_id", -1),
            visionGeneration = raw.optLong("vision_generation", 0),
            blockingOverlay = raw.optBoolean("blocking_overlay", true),
            imeVisible = raw.optBoolean("ime_visible", false),
            systemBottomInset = raw.optInt("system_bottom_inset", 0),
            elements = buildList {
                for (index in 0 until elements.length()) {
                    val item = elements.getJSONObject(index)
                    val bounds = item.optJSONArray("bounds") ?: continue
                    if (bounds.length() != 4) continue
                    add(
                        P0MacroElement(
                            ref = item.optString("ref"),
                            role = item.optString("role"),
                            text = item.optString("text"),
                            description = item.optString("desc"),
                            source = item.optString("source"),
                            confidence = item.takeIf { it.has("confidence") }
                                ?.optDouble("confidence")
                                ?.takeIf { it.isFinite() },
                            bounds = P0MacroRect(
                                bounds.getInt(0),
                                bounds.getInt(1),
                                bounds.getInt(2),
                                bounds.getInt(3),
                            ),
                            stage = stageOf(
                                role = item.optString("role"),
                                text = item.optString("text") + item.optString("desc"),
                                centerY = (bounds.getInt(1) + bounds.getInt(3)) / 2,
                                screenHeight = metrics.heightPixels,
                            ),
                        )
                    )
                }
            },
        )
    }

    fun decodeForRecorder(raw: JSONObject): P0MacroSnapshot = decodeSnapshot(raw)

    private fun stageOf(role: String, text: String, centerY: Int, screenHeight: Int): P0ElementStage {
        val normalized = text.replace(Regex("[\\s：:]+"), "")
        return when {
            (role == "input" && centerY <= screenHeight * 0.30) ||
                normalized == "搜索" || normalized == "取消" -> P0ElementStage.SEARCH
            centerY in (screenHeight * 0.02).toInt()..(screenHeight * 0.12).toInt() -> P0ElementStage.TOOLBAR
            centerY >= screenHeight * 0.75 -> P0ElementStage.BOTTOM_INPUT
            else -> P0ElementStage.CONTENT
        }
    }

    override fun enterFixedFileTransferQuery(): Boolean {
        val fresh = forceFreshVision()
        val focus = focusedInput()
        P0FixedQueryValidator.requireAllowed(
            snapshot = fresh,
            foreground = foreground(),
            focus = focus,
            sensitiveSurfaceWords = sensitiveSurfaceWords,
        )
        val expectedFocusedId = focus.fingerprint ?: return false
        Gateway.inputCommitEvidence.clear()
        return try {
            ImeBridge.commitIfCurrentSession(
                expectedFocusedId = expectedFocusedId,
                text = P0_FIXED_FILE_TRANSFER_QUERY,
            ) {
                ImeBridge.focusedInputId == expectedFocusedId &&
                    fresh.visionGeneration > 0 &&
                    service.isFreshSearchCommitStateCurrent(
                        expectedRevision = fresh.captureRevision,
                        expectedWindowId = fresh.foregroundWindowId,
                        expectedPackage = P0_WECHAT_PACKAGE,
                    )
            }
        } finally {
            Gateway.inputCommitEvidence.clear()
        }
    }

    override fun clickStage(action: P0StageRefAction): Boolean = runCatching {
        service.performFreshVisionClick(
            expectedPackage = P0_WECHAT_PACKAGE,
            imeMustBeHidden = action.stage in setOf(P0RefStage.SEARCH_ENTRY, P0RefStage.INPUT_FIELD),
        ) { raw ->
            val snapshot = decodeSnapshot(raw)
            val actual = P0StageRefActionValidator.revalidate(
                expected = action,
                fresh = snapshot,
                foreground = foreground(),
                sensitiveSurfaceWords = sensitiveSurfaceWords,
            )
            FreshValidatedRef(
                ref = actual.ref,
                captureRevision = snapshot.captureRevision,
                visionGeneration = snapshot.visionGeneration,
                foregroundWindowId = snapshot.foregroundWindowId,
            )
        }
    }.getOrElse { error ->
        if (error is GatewayError) throw error
        false
    }

    override fun probeFocus(probe: P0FocusProbe): Boolean {
        val actionProof = P0FocusProbeValidator.revalidateForAction(
            expected = probe,
            fresh = forceFreshVision(),
            foreground = foreground(),
            sensitiveSurfaceWords = sensitiveSurfaceWords,
        )
        return service.performValidatedFocusProbe(
            screenWidth = actionProof.screenWidth,
            screenHeight = actionProof.screenHeight,
            region = Rect(
                actionProof.region.left, actionProof.region.top,
                actionProof.region.right, actionProof.region.bottom,
            ),
            x = actionProof.x,
            y = actionProof.y,
            snapshotRevision = actionProof.snapshotRevision,
            captureRevision = actionProof.proof.captureRevision,
            expectedWindowId = actionProof.proof.foregroundWindowId,
            expectedPackage = P0_WECHAT_PACKAGE,
            titleBounds = Rect(
                actionProof.proof.titleBounds.left, actionProof.proof.titleBounds.top,
                actionProof.proof.titleBounds.right, actionProof.proof.titleBounds.bottom,
            ),
            titleConfidence = actionProof.proof.titleConfidence,
            visionGeneration = actionProof.proof.visionGeneration,
            proofSafe = actionProof.proof.title == P0_FIXED_FILE_TRANSFER_QUERY &&
                actionProof.proof.titleSource in setOf("ocr", "fused") &&
                actionProof.proof.sensitiveSurfaceAbsent && actionProof.proof.blockingOverlayAbsent,
        )
    }

    override fun focusedInput(): P0MacroFocus {
        val node = service.focusedEditable()
        val nodePresent = node?.let { it.refresh() } == true
        val metrics = service.resources.displayMetrics
        val bounds = node?.let { Rect().also(it::getBoundsInScreen) }
        val focusStage = bounds?.let {
            when {
                it.centerY() <= metrics.heightPixels * 0.30 -> P0ElementStage.SEARCH
                it.centerY() >= metrics.heightPixels * 0.75 -> P0ElementStage.BOTTOM_INPUT
                else -> P0ElementStage.CONTENT
            }
        }
        return P0MacroFocus(
            nodePresent = nodePresent,
            focused = nodePresent && node?.isFocused == true,
            editable = nodePresent && node?.isEditable == true,
            imeActive = ImeBridge.active,
            inputConnectionAvailable = ImeBridge.hasInputConnection(),
            fingerprint = ImeBridge.focusedInputId,
            stage = focusStage,
        )
    }

    override fun monotonicMs(): Long = SystemClock.elapsedRealtime()

    override fun sleep(ms: Long) = Thread.sleep(ms)
}

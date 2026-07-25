package dev.magina.gateway.a11y

import dev.magina.gateway.core.ErrorCode
import dev.magina.gateway.core.GatewayError

internal data class P0PreparedTargetFinalState(
    val foreground: P0MacroForeground,
    val snapshot: P0MacroSnapshot,
    val focused: P0MacroFocus,
    val focusedBounds: P0MacroRect,
    val uiFocusedInputId: String?,
    val uiFocusedBounds: P0MacroRect?,
    val imeFocusedInputId: String?,
    val inputProofRevision: Long,
    val inputProofWindowId: Int,
    val inputProofNodeId: String?,
    val inputProofImeSessionId: String?,
    val inputProofBounds: P0MacroRect,
)

internal data class P0ValidatedPreparedTarget(
    val label: String,
    val packageName: String,
    val focusedInputId: String,
    val imeSessionId: String,
    val bounds: P0MacroRect,
)

/** 宏状态机返回后、写入短时目标前的独立强 fresh 终验。 */
internal object P0PreparedTargetRecorderValidator {
    fun validate(
        result: P0WeChatPrepareResult,
        state: P0PreparedTargetFinalState,
        sensitiveSurfaceWords: List<String>,
    ): P0ValidatedPreparedTarget {
        val snapshot = state.snapshot
        val w = snapshot.screenWidth
        val h = snapshot.screenHeight
        // 同 P0FocusProbeValidator / GatewayA11yService.performValidatedFocusProbe：这里的标题
        // 只用于"证明身处文件传输助手会话"这一识别判断，不是点击目标，故用 contains + 识别级
        // 门槛。真机实锤两个毛病都会各自独立卡死本校验：OCR 把标题识别成"文件传输助手8"
        // （尾随多字符、置信度正常）使严格 == 永远不成立；置信度实测 0.59 亦过不了 0.65。
        // 属 knowledge #15 同类的"改动遗漏"（contains 与识别级门槛两项决定均已获同意，
        // 此处当时未同步），非新的设计取舍。目标身份的真正保障在于：确认卡向真人展示目标会话，
        // 且下方 stableFreshProof/focusValid 仍逐项强校验 revision/窗口/焦点/bounds。
        val exactTitle = snapshot.elements.any { element ->
            val exact = element.text.trim().contains(P0_FILE_TRANSFER_ASSISTANT) ||
                element.description.trim().contains(P0_FILE_TRANSFER_ASSISTANT)
            val trusted = element.source == "a11y" ||
                (element.source in setOf("ocr", "fused") &&
                    element.confidence?.let {
                        it.isFinite() && it >= MIN_RECOGNITION_OCR_CONFIDENCE
                    } == true)
            exact && trusted && element.stage == P0ElementStage.TOOLBAR &&
                validBounds(element.bounds, w, h) &&
                element.bounds.centerY in (h * 0.02).toInt()..(h * 0.12).toInt() &&
                element.bounds.centerX in (w * 0.30).toInt()..(w * 0.70).toInt()
        }
        val focusedId = state.uiFocusedInputId
        val imeSessionId = state.imeFocusedInputId
        val stableFreshProof = snapshot.captureRevision == snapshot.revision &&
            snapshot.captureRevision == state.inputProofRevision &&
            snapshot.foregroundWindowId >= 0 &&
            snapshot.foregroundWindowId == state.inputProofWindowId &&
            snapshot.visionGeneration > 0
        val focusValid = state.focused.ready &&
            state.focused.focused && state.focused.editable &&
            state.focused.stage == P0ElementStage.BOTTOM_INPUT &&
            validBounds(state.focusedBounds, w, h) &&
            state.focusedBounds.centerY >= h * 0.75 &&
            state.uiFocusedBounds == state.focusedBounds &&
            state.focusedBounds == state.inputProofBounds
        val identityValid = result.ready &&
            result.packageName == P0_WECHAT_PACKAGE &&
            result.conversation == P0_FILE_TRANSFER_ASSISTANT &&
            state.foreground.known && state.foreground.packageName == P0_WECHAT_PACKAGE &&
            !focusedId.isNullOrBlank() &&
            focusedId == state.inputProofNodeId &&
            focusedId.count { it == '|' } == 4 &&
            !imeSessionId.isNullOrBlank() &&
            imeSessionId.matches(Regex("^ime\\|[0-9a-f]{24}$")) &&
            imeSessionId == state.inputProofImeSessionId &&
            imeSessionId == state.focused.fingerprint &&
            imeSessionId == result.focusedInputFingerprint
        if (
            !stableFreshProof || !identityValid || !focusValid || !exactTitle ||
            snapshot.blockingOverlay || !snapshot.imeVisible ||
            P0FocusProbeValidator.hasSensitiveOrBlockingSurface(snapshot, sensitiveSurfaceWords)
        ) throw GatewayError(
            ErrorCode.E_STALE_REF,
            "准备宏返回后的强 fresh 会话、标题、焦点或窗口 proof 已变化",
            channel = "p0-wechat-prepare",
            retryable = false,
        )
        return P0ValidatedPreparedTarget(
            label = P0_FILE_TRANSFER_ASSISTANT,
            packageName = P0_WECHAT_PACKAGE,
            focusedInputId = focusedId,
            imeSessionId = imeSessionId,
            bounds = state.focusedBounds,
        )
    }

    fun validateAndRecord(
        result: P0WeChatPrepareResult,
        state: P0PreparedTargetFinalState,
        sensitiveSurfaceWords: List<String>,
        record: (P0ValidatedPreparedTarget) -> Unit,
    ): P0ValidatedPreparedTarget = validate(result, state, sensitiveSurfaceWords).also(record)

    private fun validBounds(bounds: P0MacroRect, width: Int, height: Int): Boolean =
        width > 0 && height > 0 &&
            bounds.left >= 0 && bounds.top >= 0 &&
            bounds.right <= width && bounds.bottom <= height &&
            bounds.width > 0 && bounds.height > 0
}

/** service 的 post-guard 失败时回滚刚写入的进程内目标，避免竞态证据残留。 */
internal object P0PreparedTargetRecordTransaction {
    fun <T> run(
        rollback: () -> Unit,
        guardedRecord: () -> T,
    ): T = try {
        guardedRecord()
    } catch (error: Throwable) {
        rollback()
        throw error
    }
}

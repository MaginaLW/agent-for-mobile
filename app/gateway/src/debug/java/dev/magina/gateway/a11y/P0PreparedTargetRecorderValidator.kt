package dev.magina.gateway.a11y

import dev.magina.gateway.core.ErrorCode
import dev.magina.gateway.core.FocusIdentity
import dev.magina.gateway.core.GatewayError
import dev.magina.gateway.core.IdentitySource

internal data class P0PreparedTargetFinalState(
    val foreground: P0MacroForeground,
    val snapshot: P0MacroSnapshot,
    val focused: P0MacroFocus,
    /** a11y 焦点几何；IME-only 降级链下必须为 null（与 [uiFocusedBounds] 一致地缺失）。 */
    val focusedBounds: P0MacroRect?,
    val uiFocusedInputId: String?,
    val uiFocusedBounds: P0MacroRect?,
    val imeFocusedInputId: String?,
    /** IME 会话所属包名；零 UI IME 下取代"键盘可见"作为会话归属证据。 */
    val imeSessionPackage: String?,
    val inputProofRevision: Long,
    val inputProofWindowId: Int,
    val inputProofNodeId: String?,
    val inputProofImeSessionId: String?,
    val inputProofBounds: P0MacroRect?,
)

internal data class P0ValidatedPreparedTarget(
    val label: String,
    val packageName: String,
    val identity: FocusIdentity,
    /** 严格链下是焦点几何；IME-only 降级链下一致地缺失。 */
    val bounds: P0MacroRect?,
)

/** 宏状态机返回后、写入短时目标前的独立强 fresh 终验。 */
internal object P0PreparedTargetRecorderValidator {
    fun validate(
        result: P0WeChatPrepareResult,
        state: P0PreparedTargetFinalState,
        sensitiveSurfaceWords: List<String>,
        expectedLabel: String = P0_FILE_TRANSFER_ASSISTANT,
    ): P0ValidatedPreparedTarget {
        val snapshot = state.snapshot
        val w = snapshot.screenWidth
        val h = snapshot.screenHeight
        // 持久化 prepared evidence 前不再另写 contains：与语义重建共用同一个 canonical label
        // 与归一后精确策略。尾噪和真实更长会话机械不可分，必须一并 fail-closed。
        val exactTitle = ConversationSurfacePolicy.conversationTitle(
            elements = snapshot.elements,
            frame = snapshot.frame,
            expectedLabel = expectedLabel,
        ) != null
        val focusedId = state.uiFocusedInputId
        val imeSessionId = state.imeFocusedInputId
        // 与 Release 重建共用 capture 判据：尤其是 blocking_overlay 不能在 debug/release
        // 两套源集里各写一份、以后只收紧一边。
        val capture = FreshEvidenceCapture(
            revision = snapshot.revision,
            captureRevision = snapshot.captureRevision,
            visionGeneration = snapshot.visionGeneration,
            foregroundWindowId = snapshot.foregroundWindowId,
            foregroundKnown = state.foreground.known,
            foregroundPackage = state.foreground.packageName,
            blockingOverlay = snapshot.blockingOverlay,
        )
        val stableFreshProof = FreshEvidenceRebuildGuard.captureProblems(
            capture,
            P0_WECHAT_PACKAGE,
        ).isEmpty() &&
            snapshot.captureRevision == state.inputProofRevision &&
            snapshot.foregroundWindowId == state.inputProofWindowId
        // 身份来源在这里一次定死：a11y 侧给得出节点身份就必须走严格链，不允许降级。
        val identity = FocusIdentity.of(focusedId, imeSessionId)
        val imeIdentityValid = identity != null &&
            imeSessionId == state.inputProofImeSessionId &&
            imeSessionId == state.focused.fingerprint &&
            imeSessionId == result.focusedInputFingerprint &&
            // 会话必须属于微信本身：零 UI IME 下 ime_visible 恒假，不能当活性/归属代理。
            state.imeSessionPackage == P0_WECHAT_PACKAGE
        val sourceValid = when (identity?.source) {
            IdentitySource.A11Y ->
                // 严格链：a11y 焦点、几何、input proof 三处节点身份必须逐项对齐。
                focusedId == state.inputProofNodeId &&
                    state.focused.strictReadyAt(P0ElementStage.BOTTOM_INPUT) &&
                    state.focusedBounds != null &&
                    validBounds(state.focusedBounds, w, h) &&
                    state.focusedBounds.centerY >= h * 0.75 &&
                    state.uiFocusedBounds == state.focusedBounds &&
                    state.focusedBounds == state.inputProofBounds &&
                    !result.imeOnlyIdentity
            IdentitySource.IME_ONLY ->
                // 降级链：a11y 侧必须**一致地**缺失，任何残留（节点 id、几何、
                // nodePresent/focused/editable）都算错配，一律拒绝。
                state.inputProofNodeId.isNullOrBlank() &&
                    state.uiFocusedBounds == null &&
                    state.focusedBounds == null && state.inputProofBounds == null &&
                    state.focused.degradedReadyAt(P0_WECHAT_PACKAGE) &&
                    result.imeOnlyIdentity
            null -> false
        }
        val identityValid = result.ready &&
            result.packageName == P0_WECHAT_PACKAGE &&
            result.conversation == expectedLabel &&
            state.foreground.known && state.foreground.packageName == P0_WECHAT_PACKAGE &&
            imeIdentityValid && sourceValid
        if (
            !stableFreshProof || !identityValid || !exactTitle ||
            P0FocusProbeValidator.hasSensitiveOrBlockingSurface(snapshot, sensitiveSurfaceWords)
        ) throw GatewayError(
            ErrorCode.E_STALE_REF,
            "准备宏返回后的强 fresh 会话、标题、焦点或窗口 proof 已变化",
            channel = "p0-wechat-prepare",
            retryable = false,
        )
        return P0ValidatedPreparedTarget(
            label = expectedLabel,
            packageName = P0_WECHAT_PACKAGE,
            identity = identity!!,
            bounds = state.focusedBounds.takeIf { identity.source == IdentitySource.A11Y },
        )
    }

    fun validateAndRecord(
        result: P0WeChatPrepareResult,
        state: P0PreparedTargetFinalState,
        sensitiveSurfaceWords: List<String>,
        expectedLabel: String = P0_FILE_TRANSFER_ASSISTANT,
        record: (P0ValidatedPreparedTarget) -> Unit,
    ): P0ValidatedPreparedTarget =
        validate(result, state, sensitiveSurfaceWords, expectedLabel).also(record)

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

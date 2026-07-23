package dev.magina.gateway.a11y

import dev.magina.gateway.core.ErrorCode
import dev.magina.gateway.core.GatewayError
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test

class P0PreparedTargetRecorderValidatorTest {
    private val nodeId = "7|com.tencent.mm:id/chat_input|android.widget.EditText|com.tencent.mm|100,1600,980,1760"
    private val imeSessionId = "ime|0123456789abcdef01234567"
    private val bounds = P0MacroRect(100, 1_600, 980, 1_760)
    private val result = P0WeChatPrepareResult(
        ready = true,
        packageName = P0_WECHAT_PACKAGE,
        conversation = P0_FILE_TRANSFER_ASSISTANT,
        focusedInputFingerprint = imeSessionId,
        stableSamples = 2,
        usedCoordinateFallback = false,
    )
    private val snapshot = P0MacroSnapshot(
        screenWidth = 1_080,
        screenHeight = 1_920,
        revision = 20,
        captureRevision = 20,
        foregroundWindowId = 7,
        visionGeneration = 9,
        blockingOverlay = false,
        imeVisible = true,
        elements = listOf(
            P0MacroElement(
                ref = "title",
                role = "text",
                text = P0_FILE_TRANSFER_ASSISTANT,
                description = "",
                bounds = P0MacroRect(350, 60, 730, 150),
                source = "ocr",
                confidence = 0.99,
                stage = P0ElementStage.TOOLBAR,
            ),
        ),
    )
    private val state = P0PreparedTargetFinalState(
        foreground = P0MacroForeground(true, P0_WECHAT_PACKAGE),
        snapshot = snapshot,
        focused = P0MacroFocus(
            nodePresent = true,
            imeActive = true,
            inputConnectionAvailable = true,
            fingerprint = imeSessionId,
            focused = true,
            editable = true,
            stage = P0ElementStage.BOTTOM_INPUT,
        ),
        focusedBounds = bounds,
        uiFocusedInputId = nodeId,
        uiFocusedBounds = bounds,
        imeFocusedInputId = imeSessionId,
        inputProofRevision = 20,
        inputProofWindowId = 7,
        inputProofNodeId = nodeId,
        inputProofImeSessionId = imeSessionId,
        inputProofBounds = bounds,
    )

    @Test
    fun `valid strong fresh proof records exactly once`() {
        var records = 0

        val validated = P0PreparedTargetRecorderValidator.validateAndRecord(
            result,
            state,
            sensitiveSurfaceWords = emptyList(),
        ) {
            records++
        }

        assertEquals(1, records)
        assertEquals(P0_FILE_TRANSFER_ASSISTANT, validated.label)
        assertEquals(nodeId, validated.focusedInputId)
        assertEquals(imeSessionId, validated.imeSessionId)
        assertEquals(bounds, validated.bounds)
    }

    @Test
    fun `same package conversation switch title fingerprint and revision drift record nothing`() {
        val cases = listOf(
            state.copy(
                snapshot = snapshot.copy(
                    elements = snapshot.elements.map {
                        it.copy(text = "其他会话")
                    },
                ),
            ),
            state.copy(
                snapshot = snapshot.copy(
                    elements = snapshot.elements.map {
                        it.copy(confidence = 0.40)
                    },
                ),
            ),
            state.copy(uiFocusedInputId = nodeId.replace("|100,", "|101,")),
            state.copy(inputProofNodeId = nodeId.replace("|100,", "|101,")),
            state.copy(imeFocusedInputId = "ime|fedcba9876543210fedcba98"),
            state.copy(inputProofImeSessionId = "ime|fedcba9876543210fedcba98"),
            state.copy(snapshot = snapshot.copy(captureRevision = 19)),
            state.copy(inputProofRevision = 19),
            state.copy(inputProofWindowId = 8),
        )

        cases.forEachIndexed { index, changed ->
            var records = 0
            try {
                P0PreparedTargetRecorderValidator.validateAndRecord(
                    result,
                    changed,
                    sensitiveSurfaceWords = emptyList(),
                ) { records++ }
                fail("case $index must fail closed")
            } catch (error: GatewayError) {
                assertEquals(ErrorCode.E_STALE_REF, error.code)
            }
            assertEquals("case $index", 0, records)
        }
    }

    @Test
    fun `invalid focus bounds overlay ime and sensitive surface record nothing`() {
        val sensitiveSnapshot = snapshot.copy(
            elements = snapshot.elements + P0MacroElement(
                ref = "danger",
                role = "text",
                text = "确认支付",
                description = "",
                bounds = P0MacroRect(10, 500, 400, 580),
                source = "a11y",
                stage = P0ElementStage.CONTENT,
            ),
        )
        val cases = listOf(
            state.copy(focused = state.focused.copy(focused = false)),
            state.copy(focusedBounds = P0MacroRect(-1, 1_600, 980, 1_760)),
            state.copy(snapshot = snapshot.copy(blockingOverlay = true)),
            state.copy(snapshot = snapshot.copy(imeVisible = false)),
            state.copy(snapshot = sensitiveSnapshot),
        )
        cases.forEachIndexed { index, changed ->
            var records = 0
            try {
                P0PreparedTargetRecorderValidator.validateAndRecord(
                    result,
                    changed,
                    sensitiveSurfaceWords = listOf("支付"),
                ) { records++ }
                fail("case $index must fail closed")
            } catch (error: GatewayError) {
                assertEquals(ErrorCode.E_STALE_REF, error.code)
            }
            assertEquals("case $index", 0, records)
        }
    }
}

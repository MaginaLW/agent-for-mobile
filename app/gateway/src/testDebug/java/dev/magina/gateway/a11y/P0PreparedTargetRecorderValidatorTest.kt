package dev.magina.gateway.a11y

import dev.magina.gateway.core.ErrorCode
import dev.magina.gateway.core.GatewayError
import dev.magina.gateway.core.IdentitySource
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
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
                windowId = 7,
                foregroundWindow = true,
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
        imeSessionPackage = P0_WECHAT_PACKAGE,
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
        assertEquals(IdentitySource.A11Y, validated.identity.source)
        assertEquals(nodeId, validated.identity.a11yInputId)
        assertEquals(imeSessionId, validated.identity.imeSessionId)
        assertEquals(bounds, validated.bounds)
    }

    /** IME-only 降级链：a11y 侧一致缺失时可成链，但几何必须一并缺失。 */
    @Test
    fun `ime only state records a degraded identity without bounds`() {
        var records = 0

        val validated = P0PreparedTargetRecorderValidator.validateAndRecord(
            result.copy(imeOnlyIdentity = true),
            imeOnlyState,
            sensitiveSurfaceWords = emptyList(),
        ) { records++ }

        assertEquals(1, records)
        assertEquals(IdentitySource.IME_ONLY, validated.identity.source)
        assertNull(validated.identity.a11yInputId)
        assertEquals(imeSessionId, validated.identity.imeSessionId)
        assertNull(validated.bounds)
    }

    /** design §3.2/§3.3：a11y 侧有任何**可用**身份残留就不算缺失，一律拒绝降级。 */
    @Test
    fun `partial a11y evidence never degrades`() {
        val cases = listOf(
            imeOnlyState.copy(inputProofNodeId = nodeId),
            imeOnlyState.copy(uiFocusedBounds = bounds),
            imeOnlyState.copy(focusedBounds = bounds),
            imeOnlyState.copy(inputProofBounds = bounds),
            // 焦点落在非输入控件上：真错配，不是"没有输入节点"
            imeOnlyState.copy(
                focused = imeOnlyState.focused.copy(nodePresent = true, focused = true),
            ),
            imeOnlyState.copy(
                focused = imeOnlyState.focused.copy(nodePresent = true, editable = true),
            ),
            // 注：stage 不参与"有没有可用身份"的判定——它由 bounds 推出，没有可用节点时
            // 本就不该有 stage；真机残留节点反而会带着 stage=SEARCH，见下一条用例。
            // 宏说走了严格链，终验却只剩 IME 身份：两边必须一致
            imeOnlyState.copy(uiFocusedInputId = null).let { it },
        )

        cases.forEachIndexed { index, changed ->
            var records = 0
            try {
                P0PreparedTargetRecorderValidator.validateAndRecord(
                    result.copy(imeOnlyIdentity = index != cases.lastIndex),
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

    /**
     * 真机形态：a11y 侧残留一个既不 focused 也不 editable 的节点，且它不产出任何
     * 节点 id 与几何（`FreshPreparedInputProof`/`focusedInputSnapshot` 同判据）。
     * 这不是"部分证据"，是没有可用输入身份，允许降级。
     */
    @Test
    fun `residual non-input node still records a degraded identity`() {
        var records = 0

        val validated = P0PreparedTargetRecorderValidator.validateAndRecord(
            result.copy(imeOnlyIdentity = true),
            imeOnlyState.copy(focused = imeOnlyState.focused.copy(nodePresent = true)),
            sensitiveSurfaceWords = emptyList(),
        ) { records++ }

        assertEquals(1, records)
        assertEquals(IdentitySource.IME_ONLY, validated.identity.source)
        assertNull(validated.bounds)
    }

    /** design §3.2：a11y 可得时宏不得声称降级，声称了就是错配。 */
    @Test
    fun `available a11y identity with degraded claim is rejected`() {
        var records = 0
        try {
            P0PreparedTargetRecorderValidator.validateAndRecord(
                result.copy(imeOnlyIdentity = true),
                state,
                sensitiveSurfaceWords = emptyList(),
            ) { records++ }
            fail("a11y 可得却声称降级必须失败")
        } catch (error: GatewayError) {
            assertEquals(ErrorCode.E_STALE_REF, error.code)
        }
        assertEquals(0, records)
    }

    private val imeOnlyState = state.copy(
        focused = P0MacroFocus(
            nodePresent = false,
            imeActive = true,
            inputConnectionAvailable = true,
            fingerprint = imeSessionId,
            sessionPackage = P0_WECHAT_PACKAGE,
            focused = false,
            editable = false,
            stage = null,
        ),
        focusedBounds = null,
        uiFocusedInputId = null,
        uiFocusedBounds = null,
        inputProofNodeId = null,
        inputProofBounds = null,
    )

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

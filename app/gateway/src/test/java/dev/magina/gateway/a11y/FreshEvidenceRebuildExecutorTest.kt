package dev.magina.gateway.a11y

import dev.magina.gateway.core.EvidenceRebuild
import dev.magina.gateway.core.ErrorCode
import dev.magina.gateway.core.FocusIdentity
import dev.magina.gateway.core.GatewayError
import dev.magina.gateway.core.InputCommitEvidence
import dev.magina.gateway.core.InputCommitEvidenceStore
import dev.magina.gateway.core.PreparedTargetEvidenceStore
import dev.magina.gateway.core.TextNorm
import dev.magina.gateway.ime.ImeSessionIdentity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class FreshEvidenceRebuildExecutorTest {
    private val packageName = "com.tencent.mm"
    private val sessionId = "ime|0123456789abcdef01234567"
    private val nodeId = "9|chat_input|EditText|com.tencent.mm|100,1600,980,1760"
    private val initialCapture = FreshEvidenceCapture(
        revision = 41,
        captureRevision = 41,
        visionGeneration = 7,
        foregroundWindowId = 9,
        foregroundKnown = true,
        foregroundPackage = packageName,
        blockingOverlay = false,
    )
    private val initialSurface = FreshEvidenceSurface(initialCapture, "张三", "ocr")
    private val initialCurrent = FreshClickCurrent(
        revision = 41,
        foregroundKnown = true,
        windowId = 9,
        packageName = packageName,
        blockingOverlay = false,
        imeVisible = false,
    )
    private val session = ImeSessionIdentity(sessionId, packageName, connected = true)

    @Test
    fun `revision window package generation or conversation drift stays unverified with zero evidence`() {
        val cases = listOf<(MutableState) -> Unit>(
            { state -> state.current = state.current.copy(revision = 42) },
            { state -> state.current = state.current.copy(windowId = 10) },
            { state -> state.current = state.current.copy(packageName = "com.example.other") },
            { state -> state.finalGeneration = 7 },
            { state -> state.finalLabel = "李四" },
        )

        cases.forEachIndexed { index, drift ->
            val state = MutableState(initialCurrent)
            val prepared = PreparedTargetEvidenceStore()
            val input = InputCommitEvidenceStore()
            val identity = requireNotNull(FocusIdentity.of(nodeId, sessionId))

            val result = execute(
                state = state,
                prepared = prepared,
                input = input,
                beforeFinalSurface = { drift(state) },
            )

            assertTrue("case $index must be unverified: $result", result is EvidenceRebuild.Unverified)
            assertNull("case $index must not persist prepared evidence", prepared.peekActive())
            assertNull("case $index must not persist input evidence", input.current(identity))
        }
    }

    @Test
    fun `blocking overlay appearing after title read stays unverified with zero evidence`() {
        val state = MutableState(initialCurrent)
        val prepared = PreparedTargetEvidenceStore()
        val input = InputCommitEvidenceStore()
        val identity = requireNotNull(FocusIdentity.of(nodeId, sessionId))

        val result = execute(
            state = state,
            prepared = prepared,
            input = input,
            beforeFinalSurface = {
                state.current = state.current.copy(blockingOverlay = true)
            },
        )

        assertTrue(result.toString(), result is EvidenceRebuild.Unverified)
        assertNull(prepared.peekActive())
        assertNull(input.current(identity))
    }

    @Test
    fun `focused input identity drift after content read stays unverified with zero evidence`() {
        val state = MutableState(initialCurrent)
        val prepared = PreparedTargetEvidenceStore()
        val input = InputCommitEvidenceStore()
        val identity = requireNotNull(FocusIdentity.of(nodeId, sessionId))

        val result = execute(
            state = state,
            prepared = prepared,
            input = input,
            afterEvidenceRead = { state.inputNodeId = "$nodeId|switched" },
        )

        assertTrue(result.toString(), result is EvidenceRebuild.Unverified)
        assertNull(prepared.peekActive())
        assertNull(input.current(identity))
    }

    @Test
    fun `stable second capture and input proof publish both evidence records`() {
        val state = MutableState(initialCurrent)
        val prepared = PreparedTargetEvidenceStore()
        val input = InputCommitEvidenceStore()
        val identity = requireNotNull(FocusIdentity.of(nodeId, sessionId))

        val result = execute(state, prepared, input)

        assertTrue(result.toString(), result is EvidenceRebuild.Rebuilt)
        assertTrue(prepared.peekActive() != null)
        assertTrue(input.current(identity) != null)
    }

    @Test
    fun `second evidence write failure rolls back the first evidence`() {
        val state = MutableState(initialCurrent)
        val prepared = PreparedTargetEvidenceStore()
        val input = InputCommitEvidenceStore()
        val identity = requireNotNull(FocusIdentity.of(nodeId, sessionId))

        val result = execute(
            state = state,
            prepared = prepared,
            input = input,
            publish = { proof ->
                prepared.record("张三", packageName, identity, proof.boundsString())
                throw IllegalStateException("second store rejected the write")
            },
        )

        assertTrue(result.toString(), result is EvidenceRebuild.Unverified)
        assertNull("the first write must be rolled back", prepared.peekActive())
        assertNull("the second store must also be empty", input.current(identity))
    }

    @Test
    fun `normal mismatch or unverified result clears preexisting evidence`() {
        val verdicts = listOf<EvidenceRebuild>(
            EvidenceRebuild.Mismatch("approved content changed"),
            EvidenceRebuild.Unverified("content unreadable"),
        )

        verdicts.forEach { verdict ->
            val state = MutableState(initialCurrent)
            val prepared = PreparedTargetEvidenceStore()
            val input = InputCommitEvidenceStore()
            val identity = requireNotNull(FocusIdentity.of(nodeId, sessionId))
            prepared.record("旧会话", packageName, identity, "[100,1600][980,1760]")
            input.record("old content", identity, readbackVerified = true)

            val result = execute(state, prepared, input, verdict = verdict)

            assertTrue("the original non-Rebuilt verdict must survive", result == verdict)
            assertNull("$verdict must clear old prepared evidence", prepared.peekActive())
            assertNull("$verdict must clear old input evidence", input.current(identity))
        }
    }

    @Test
    fun `same package title drift after publish rolls back both evidence records`() {
        val state = MutableState(initialCurrent)
        val prepared = PreparedTargetEvidenceStore()
        val input = InputCommitEvidenceStore()
        val identity = requireNotNull(FocusIdentity.of(nodeId, sessionId))

        val result = execute(
            state = state,
            prepared = prepared,
            input = input,
            afterPublish = { state.finalLabel = "李四" },
        )

        assertTrue(result.toString(), result is EvidenceRebuild.Unverified)
        assertNull(prepared.peekActive())
        assertNull(input.current(identity))
    }

    @Test
    fun `IME only OCR content drift after publish rolls back both evidence records`() {
        val state = MutableState(initialCurrent)
        val prepared = PreparedTargetEvidenceStore()
        val input = InputCommitEvidenceStore()
        val identity = requireNotNull(FocusIdentity.of(null, sessionId))

        val result = execute(
            state = state,
            prepared = prepared,
            input = input,
            imeOnly = true,
            afterPublish = { state.inputOcrReadback = "different content" },
        )

        assertTrue(result.toString(), result is EvidenceRebuild.Unverified)
        assertNull(prepared.peekActive())
        assertNull(input.current(identity))
    }

    @Test
    fun `same app conversation switch after third frame must not reach enter`() {
        val drifts = listOf(
            "recipient title" to { state: MutableState -> state.finalLabel = "李四" },
            "same bitmap input OCR" to { state: MutableState -> state.inputOcrReadback = "other draft" },
        )
        drifts.forEach { (caseName, drift) ->
            val state = MutableState(initialCurrent)
            val prepared = PreparedTargetEvidenceStore()
            val input = InputCommitEvidenceStore()
            val identity = requireNotNull(FocusIdentity.of(null, sessionId))
            val rebuilt = execute(
                state = state,
                prepared = prepared,
                input = input,
                imeOnly = true,
            )
            assertTrue(rebuilt.toString(), rebuilt is EvidenceRebuild.Rebuilt)
            val approvedTarget = requireNotNull(prepared.peekActive())
            val approvedInput = requireNotNull(input.current(identity))

            // 第三张 fresh 图已经验完，SafetyGate/context 与 IME 最终门之间切到同 App 的另一个会话。
            // 微信可能不发内容事件，故 revision/window/session/input identity 全部原样；只有下一张
            // 真实 Bitmap 的标题或同图输入栏 OCR 能看出 surface 已经漂移。
            drift(state)
            var enterCalls = 0
            try {
                FreshEnterActionExecutor.execute(
                    expectedFocusIdentity = identity,
                    expectedFocusedInputBounds = null,
                    expectedPrepared = approvedTarget,
                    expectedInput = approvedInput,
                    readFreshBundle = {
                        val capture = initialCapture.copy(visionGeneration = 10)
                        FreshEvidenceReadBundle(
                            surface = FreshEvidenceSurface(capture, state.finalLabel, "ocr"),
                            input = inputProof(capture, state.inputNodeId, imeOnly = true),
                            inputOcrReadback = state.inputOcrReadback,
                        )
                    },
                    readCurrent = { state.current },
                    readSession = { session },
                    prepareAction = { capture ->
                        FreshEnterPreparedAction(
                            input = inputProof(capture, state.inputNodeId, imeOnly = true),
                            performOnce = { enterCalls += 1; true },
                        )
                    },
                    rollback = {
                        prepared.clear()
                        input.clear()
                    },
                )
                fail("$caseName drift must fail closed")
            } catch (error: GatewayError) {
                assertTrue(
                    "$caseName must map to a terminal safety failure: ${error.code}",
                    error.code == ErrorCode.E_STALE_REF || error.code == ErrorCode.E_VERIFY_FAIL,
                )
                assertTrue("$caseName must be non-retryable", !error.retryable)
            }

            assertEquals("$caseName must be rejected before the only Enter", 0, enterCalls)
            assertNull("$caseName must clear prepared evidence", prepared.peekActive())
            assertNull("$caseName must clear input evidence", input.current(identity))
        }
    }

    @Test
    fun `stable final fresh bundle performs exactly one enter`() {
        val state = MutableState(initialCurrent)
        val prepared = PreparedTargetEvidenceStore()
        val input = InputCommitEvidenceStore()
        val identity = requireNotNull(FocusIdentity.of(null, sessionId))
        assertTrue(execute(state, prepared, input, imeOnly = true) is EvidenceRebuild.Rebuilt)
        val approvedTarget = requireNotNull(prepared.peekActive())
        val approvedInput = requireNotNull(input.current(identity))
        var enterCalls = 0

        val entered = FreshEnterActionExecutor.execute(
            expectedFocusIdentity = identity,
            expectedFocusedInputBounds = null,
            expectedPrepared = approvedTarget,
            expectedInput = approvedInput,
            readFreshBundle = {
                val capture = initialCapture.copy(visionGeneration = 10)
                FreshEvidenceReadBundle(
                    surface = FreshEvidenceSurface(capture, "张三", "ocr"),
                    input = inputProof(capture, state.inputNodeId, imeOnly = true),
                    inputOcrReadback = "hello",
                )
            },
            readCurrent = { state.current },
            readSession = { session },
            prepareAction = { capture ->
                FreshEnterPreparedAction(
                    input = inputProof(capture, state.inputNodeId, imeOnly = true),
                    performOnce = { enterCalls += 1; true },
                )
            },
            rollback = {
                prepared.clear()
                input.clear()
            },
        )

        assertTrue(entered)
        assertEquals(1, enterCalls)
        assertTrue("accepted action keeps evidence until send post-verification", prepared.peekActive() != null)
        assertTrue(input.current(identity) != null)
    }

    @Test
    fun `false exception or fatal Error from the only enter action clears both evidence records`() {
        listOf("false", "exception", "error").forEach { mode ->
            val state = MutableState(initialCurrent)
            val prepared = PreparedTargetEvidenceStore()
            val input = InputCommitEvidenceStore()
            val identity = requireNotNull(FocusIdentity.of(null, sessionId))
            assertTrue(execute(state, prepared, input, imeOnly = true) is EvidenceRebuild.Rebuilt)
            val approvedTarget = requireNotNull(prepared.peekActive())
            val approvedInput = requireNotNull(input.current(identity))
            var enterCalls = 0

            try {
                val entered = FreshEnterActionExecutor.execute(
                    expectedFocusIdentity = identity,
                    expectedFocusedInputBounds = null,
                    expectedPrepared = approvedTarget,
                    expectedInput = approvedInput,
                    readFreshBundle = {
                        val capture = initialCapture.copy(visionGeneration = 10)
                        FreshEvidenceReadBundle(
                            surface = FreshEvidenceSurface(capture, "张三", "ocr"),
                            input = inputProof(capture, state.inputNodeId, imeOnly = true),
                            inputOcrReadback = "hello",
                        )
                    },
                    readCurrent = { state.current },
                    readSession = { session },
                    prepareAction = { capture ->
                        FreshEnterPreparedAction(
                            input = inputProof(capture, state.inputNodeId, imeOnly = true),
                            performOnce = {
                                enterCalls += 1
                                when (mode) {
                                    "exception" -> throw IllegalStateException("result unavailable")
                                    "error" -> throw AssertionError("fatal VM condition")
                                    else -> false
                                }
                            },
                        )
                    },
                    rollback = {
                        prepared.clear()
                        input.clear()
                    },
                )
                assertEquals("false", mode)
                assertFalse(entered)
            } catch (error: GatewayError) {
                assertEquals("exception", mode)
                assertEquals(ErrorCode.E_VERIFY_FAIL, error.code)
                assertFalse(error.retryable)
            } catch (_: AssertionError) {
                assertEquals("fatal Error must propagate instead of becoming E_VERIFY_FAIL", "error", mode)
            }

            assertEquals("$mode may invoke only the selected channel once", 1, enterCalls)
            assertNull(prepared.peekActive())
            assertNull(input.current(identity))
        }
    }

    private fun execute(
        state: MutableState,
        prepared: PreparedTargetEvidenceStore,
        input: InputCommitEvidenceStore,
        beforeFinalSurface: () -> Unit = {},
        afterEvidenceRead: () -> Unit = {},
        afterPublish: () -> Unit = {},
        imeOnly: Boolean = false,
        verdict: EvidenceRebuild = EvidenceRebuild.Rebuilt(InputCommitEvidence.sha256("hello"), 5),
        publish: (FreshPreparedInputProof) -> Unit = { proof ->
            val identity = requireNotNull(FreshEvidenceRebuildGuard.identityOf(proof))
            prepared.record("张三", packageName, identity, proof.boundsString())
            input.rebindApproved(
                sha256 = InputCommitEvidence.sha256("hello"),
                length = 5,
                preview = "hello",
                normalizedText = TextNorm.ocr("hello"),
                identity = identity,
            )
        },
    ): EvidenceRebuild = FreshEvidenceRebuildExecutor.execute(
        initialBundle = FreshEvidenceReadBundle(
            surface = initialSurface,
            input = inputProof(initialCapture, state.inputNodeId, imeOnly),
            inputOcrReadback = state.inputOcrReadback.takeIf { imeOnly },
        ),
        expectedPackage = packageName,
        expectedSessionId = sessionId,
        readCurrent = { state.current },
        readSession = { session },
        readCurrentInput = { capture -> inputProof(capture, state.inputNodeId, imeOnly) },
        readFreshBundle = {
            state.freshReads++
            if (state.freshReads == 1L) beforeFinalSurface()
            val finalCapture = initialCapture.copy(
                revision = state.current.revision,
                captureRevision = state.current.revision,
                visionGeneration = state.finalGeneration + state.freshReads - 1,
                foregroundWindowId = state.current.windowId,
                blockingOverlay = state.current.blockingOverlay,
            )
            FreshEvidenceReadBundle(
                surface = FreshEvidenceSurface(finalCapture, state.finalLabel, "ocr"),
                input = inputProof(finalCapture, state.inputNodeId, imeOnly),
                inputOcrReadback = state.inputOcrReadback.takeIf { imeOnly },
            )
        },
        readEvidence = { _ ->
            afterEvidenceRead()
            verdict
        },
        publish = { _, proof ->
            publish(proof)
            afterPublish()
        },
        rollback = {
            prepared.clear()
            input.clear()
        },
    )

    private fun inputProof(
        capture: FreshEvidenceCapture,
        currentNodeId: String,
        imeOnly: Boolean = false,
    ) = FreshPreparedInputProof(
        captureRevision = capture.captureRevision,
        foregroundWindowId = capture.foregroundWindowId,
        visionGeneration = capture.visionGeneration,
        nodePresent = !imeOnly,
        nodeId = currentNodeId.takeUnless { imeOnly },
        imeSessionId = sessionId,
        focused = !imeOnly,
        editable = !imeOnly,
        left = if (imeOnly) 0 else 100,
        top = if (imeOnly) 0 else 1_600,
        right = if (imeOnly) 0 else 980,
        bottom = if (imeOnly) 0 else 1_760,
        readableText = "hello".takeUnless { imeOnly },
    )

    private data class MutableState(
        var current: FreshClickCurrent,
        var finalLabel: String = "张三",
        var inputNodeId: String = "9|chat_input|EditText|com.tencent.mm|100,1600,980,1760",
        var finalGeneration: Long = 8,
        var freshReads: Long = 0,
        var inputOcrReadback: String = "hello",
    )

    private fun FreshPreparedInputProof.boundsString(): String? =
        FreshEvidenceRebuildGuard.boundsStringOf(this)
}

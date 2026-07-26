package dev.magina.gateway.core

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ReleasePreparedTargetSafetyTest {
    private val imeSessionId = "ime|0123456789abcdef01234567"
    private val nodeId =
        "7|com.tencent.mm:id/chat_input|android.widget.EditText|com.tencent.mm|10,20,100,80"
    private val strict = FocusIdentity(IdentitySource.A11Y, nodeId, imeSessionId)
    private val degraded = FocusIdentity(IdentitySource.IME_ONLY, null, imeSessionId)

    @Test
    fun `release enter without debug prepared target fails closed`() {
        val text = "P0 安全硬门测试"
        val input = InputCommitEvidence(
            commitId = 1,
            preview = text,
            length = text.length,
            sha256 = InputCommitEvidence.sha256(text),
            identity = strict,
            readbackVerified = true,
            committedAtMs = 1_000,
            expiresAtMs = 61_000,
        )

        val decision = SafetyPolicy().assess(
            toolName = "press_key",
            level = Level.W,
            args = JSONObject().put("key", "enter"),
            context = SafetyContext(
                packageName = "com.tencent.mm",
                activityName = ".ui.LauncherUI",
                revision = 1,
                target = SafetyTarget(
                    focusIdentity = strict,
                    focusedInputBounds = "[10,20][100,80]",
                    inputCommitEvidence = input,
                    preparedTargetEvidence = null,
                ),
            ),
        )

        assertTrue(decision is SafetyDecision.Blocked)
        assertEquals(ErrorCode.E_BLOCKED, (decision as SafetyDecision.Blocked).code)
    }

    /** release 下没有准备宏，降级链同样不得成为绕过已准备目标的新口子。 */
    @Test
    fun `release enter on the degraded chain without prepared target fails closed`() {
        val text = "P0 安全硬门测试"
        val input = InputCommitEvidence(
            commitId = 1,
            preview = text,
            length = text.length,
            sha256 = InputCommitEvidence.sha256(text),
            identity = degraded,
            readbackVerified = true,
            committedAtMs = 1_000,
            expiresAtMs = 61_000,
        )

        val decision = SafetyPolicy().assess(
            toolName = "press_key",
            level = Level.W,
            args = JSONObject().put("key", "enter"),
            context = SafetyContext(
                packageName = "com.tencent.mm",
                activityName = ".ui.LauncherUI",
                revision = 1,
                target = SafetyTarget(
                    focusIdentity = degraded,
                    focusedInputBounds = null,
                    inputCommitEvidence = input,
                    preparedTargetEvidence = null,
                ),
            ),
        )

        assertTrue(decision is SafetyDecision.Blocked)
        assertEquals(ErrorCode.E_BLOCKED, (decision as SafetyDecision.Blocked).code)
    }
}

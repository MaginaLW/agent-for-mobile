package dev.magina.gateway.core

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ReleasePreparedTargetSafetyTest {
    @Test
    fun `release enter without debug prepared target fails closed`() {
        val text = "P0 安全硬门测试"
        val input = InputCommitEvidence(
            commitId = 1,
            preview = text,
            length = text.length,
            sha256 = InputCommitEvidence.sha256(text),
            focusedInputId = "chat-input",
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
                    focusedInputId = "chat-input",
                    focusedInputBounds = "[10,20][100,80]",
                    inputCommitEvidence = input,
                    preparedTargetEvidence = null,
                ),
            ),
        )

        assertTrue(decision is SafetyDecision.Blocked)
        assertEquals(ErrorCode.E_BLOCKED, (decision as SafetyDecision.Blocked).code)
    }
}

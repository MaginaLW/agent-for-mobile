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
    fun `release enter with valid input commit and no prepared target opens confirmation card with explicit unverified label`() {
        val text = "常规生产回车测试"
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
                packageName = "com.xingin.xhs",
                activityName = ".SearchActivity",
                revision = 1,
                target = SafetyTarget(
                    focusIdentity = strict,
                    focusedInputBounds = "[10,20][100,80]",
                    inputCommitEvidence = input,
                    preparedTargetEvidence = null,
                ),
            ),
        )

        assertTrue(decision is SafetyDecision.ConfirmationRequired)
        val card = (decision as SafetyDecision.ConfirmationRequired).cardText("c-1")
        assertTrue(card.contains("目标会话：未绑定会话标题，请核对屏幕"))
        assertTrue(card.contains("实际输入预览：$text"))
    }

    @Test
    fun `release enter on degraded chain with verified readback and no prepared target opens confirmation card in single window`() {
        val text = "常规降级回车测试"
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

        assertTrue(decision is SafetyDecision.ConfirmationRequired)
        val card = (decision as SafetyDecision.ConfirmationRequired).cardText("c-2")
        assertTrue(card.contains("目标会话：未绑定会话标题，请核对屏幕"))
        assertTrue(card.contains("已降级为 IME 单命名空间"))
    }

    @Test
    fun `release enter without input commit evidence or with mismatched prepared target fails closed`() {
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
        val mismatchedPrepared = PreparedTargetEvidence(
            preparedId = 9,
            label = "文件传输助手",
            packageName = "com.other.app",
            identity = strict,
            bounds = "[10,20][100,80]",
            preparedAtMs = 1_000,
            expiresAtMs = 61_000,
        )

        val noInput = SafetyPolicy().assess(
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
                    inputCommitEvidence = null,
                    preparedTargetEvidence = null,
                ),
            ),
        )
        assertTrue(noInput is SafetyDecision.Blocked)
        assertEquals(ErrorCode.E_BLOCKED, (noInput as SafetyDecision.Blocked).code)

        val mismatched = SafetyPolicy().assess(
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
                    preparedTargetEvidence = mismatchedPrepared,
                ),
            ),
        )
        assertTrue(mismatched is SafetyDecision.Blocked)
        assertEquals(ErrorCode.E_BLOCKED, (mismatched as SafetyDecision.Blocked).code)
    }
}

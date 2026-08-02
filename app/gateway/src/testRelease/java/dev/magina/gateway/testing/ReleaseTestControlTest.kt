package dev.magina.gateway.testing

import dev.magina.gateway.core.ApprovalChannel
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

class ReleaseTestControlTest {
    @Test
    fun `release remains inert even when input digest is present`() {
        var captured = false
        var home = false
        val control = ReleaseTestControl()
        val attempt = TestConfirmationAttempt(
            confirmationId = "abc123def456",
            toolName = "press_key",
            action = "enter",
            initialPackage = "com.tencent.mm",
            inputLength = 19,
            inputSha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        )

        val session = control.onConfirmationShown(attempt) {
            captured = true
            TestConfirmationCapture(byteArrayOf(1), cardVisible = true, attempts = 1)
        }
        control.onConfirmationDecision(session, TestConfirmationDecision.ALLOWED, ApprovalChannel.OVERLAY)
        control.afterAllowed(session, attempt, { home = true; true }) {
            TestForeground(known = true, packageName = "launcher")
        }

        assertFalse(session.armed)
        assertNull(session.confirmId)
        assertFalse(captured)
        assertFalse(home)
    }
}

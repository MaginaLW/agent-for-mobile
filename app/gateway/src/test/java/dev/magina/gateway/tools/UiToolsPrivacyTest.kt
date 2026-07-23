package dev.magina.gateway.tools

import dev.magina.gateway.core.InputCommitEvidence
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UiToolsPrivacyTest {
    @Test
    fun `readback mismatch error contains only lengths and hashes`() {
        val expected = "预期秘密输入-9bd2"
        val actual = "App 改写后的秘密输入-4ca1"

        val message = inputVerificationMismatchMessage(expected, actual)

        assertFalse(message.contains(expected))
        assertFalse(message.contains(actual))
        assertTrue(message.contains("期望长度=${expected.length}"))
        assertTrue(message.contains("实际长度=${actual.length}"))
        assertTrue(message.contains(InputCommitEvidence.sha256(expected)))
        assertTrue(message.contains(InputCommitEvidence.sha256(actual)))
    }
}

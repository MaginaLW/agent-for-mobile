package dev.magina.gateway.a11y

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FocusedInputIdentityTest {
    @Test
    fun `node producer uses window namespace distinct from ime session`() {
        val nodeId = FocusedInputIdentity.compose(
            windowId = 7,
            viewId = "com.tencent.mm:id/chat_input",
            className = "android.widget.EditText",
            packageName = "com.tencent.mm",
            left = 100,
            top = 1_600,
            right = 980,
            bottom = 1_760,
        )
        val imeSessionId = "ime|0123456789abcdef01234567"

        assertEquals(
            "7|com.tencent.mm:id/chat_input|android.widget.EditText|com.tencent.mm|100,1600,980,1760",
            nodeId,
        )
        assertTrue(imeSessionId.matches(Regex("^ime\\|[0-9a-f]{24}$")))
        assertFalse(nodeId == imeSessionId)
    }
}

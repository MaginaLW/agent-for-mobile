package dev.magina.gateway.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FocusIdentityTest {
    private val imeSessionId = "ime|0123456789abcdef01234567"
    private val nodeId =
        "7|com.tencent.mm:id/chat_input|android.widget.EditText|com.tencent.mm|10,20,100,80"

    /** design §3.2：a11y 侧一旦拿得到身份就必须走严格链，不允许滑到最松的一档。 */
    @Test
    fun `available a11y identity must never degrade`() {
        val identity = FocusIdentity.of(nodeId, imeSessionId)

        assertEquals(IdentitySource.A11Y, identity?.source)
        assertEquals(nodeId, identity?.a11yInputId)
        assertFalse(identity!!.degraded)
    }

    /** design §3.1：降级只允许来自 a11y 侧结构性缺失，且必须显式标记来源。 */
    @Test
    fun `structurally absent a11y identity degrades explicitly`() {
        listOf(null, "", "   ").forEach { absent ->
            val identity = FocusIdentity.of(absent, imeSessionId)
            assertEquals(IdentitySource.IME_ONLY, identity?.source)
            assertNull(identity?.a11yInputId)
            assertTrue(identity!!.degraded)
        }
    }

    /** knowledge #43 / design §3.4：IME 会话 id 被塞进 a11y 位一律 fail-closed。 */
    @Test
    fun `ime session id in the a11y slot is rejected instead of accepted or degraded`() {
        assertNull(FocusIdentity.of(imeSessionId, imeSessionId))
        assertNull(FocusIdentity.of("chat-input", imeSessionId))
    }

    @Test
    fun `missing or malformed ime session fails closed in both modes`() {
        assertNull(FocusIdentity.of(nodeId, null))
        assertNull(FocusIdentity.of(nodeId, ""))
        assertNull(FocusIdentity.of(nodeId, "ime|not-hex"))
        assertNull(FocusIdentity.of(null, null))
    }

    /** design §3.1：两边都空不得"平凡通过"——空值组合根本产不出身份。 */
    @Test
    fun `blank everything produces no identity at all`() {
        assertNull(FocusIdentity.of(null, null))
        assertNull(FocusIdentity.of("", ""))
    }

    @Test
    fun `constructor rejects mismatched source and fields`() {
        listOf(
            { FocusIdentity(IdentitySource.A11Y, null, imeSessionId) },
            { FocusIdentity(IdentitySource.A11Y, "chat-input", imeSessionId) },
            { FocusIdentity(IdentitySource.IME_ONLY, nodeId, imeSessionId) },
            { FocusIdentity(IdentitySource.IME_ONLY, null, "not-an-ime-session") },
        ).forEach { build ->
            try {
                build()
                throw AssertionError("错配的身份组合必须构造失败")
            } catch (expected: IllegalArgumentException) {
                assertTrue(expected.message!!.isNotBlank())
            }
        }
    }

    /** design §3.3：几何证据必须与来源一致地存在或一致地缺失。 */
    @Test
    fun `bounds must be consistently present or consistently absent`() {
        assertTrue(FocusIdentity.boundsConsistent(IdentitySource.A11Y, "[10,20][100,80]"))
        assertFalse(FocusIdentity.boundsConsistent(IdentitySource.A11Y, null))
        assertFalse(FocusIdentity.boundsConsistent(IdentitySource.A11Y, ""))
        assertTrue(FocusIdentity.boundsConsistent(IdentitySource.IME_ONLY, null))
        assertFalse(FocusIdentity.boundsConsistent(IdentitySource.IME_ONLY, "[10,20][100,80]"))
        assertFalse("空串不是合法的一致缺失", FocusIdentity.boundsConsistent(IdentitySource.IME_ONLY, ""))
    }
}

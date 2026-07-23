package dev.magina.gateway.ime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ImeFocusedInputIdTest {
    @Test
    fun `same editor metadata receives a new id for every input session`() {
        val sessions = ImeSessionIdGenerator()
        val first = sessions.next("com.tencent.mm", 17, "chat_input", 1, 4)
        val second = sessions.next("com.tencent.mm", 17, "chat_input", 1, 4)

        assertNotEquals(first, second)
        assertTrue(first!!.startsWith("ime|"))
        assertTrue(!first.contains("chat_input"))
    }

    @Test
    fun `different editor metadata produces a different fingerprint and missing package fails closed`() {
        val sessions = ImeSessionIdGenerator()
        assertNotEquals(
            sessions.next("com.tencent.mm", 17, "chat_input", 1, 4),
            sessions.next("com.tencent.mm", 18, "search_input", 1, 4),
        )
        assertNull(sessions.next(null, 17, "chat_input", 1, 4))
    }
}

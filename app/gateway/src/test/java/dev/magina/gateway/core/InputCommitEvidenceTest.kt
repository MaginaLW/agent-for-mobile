package dev.magina.gateway.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class InputCommitEvidenceTest {
    private var now = 1_000L
    private val store = InputCommitEvidenceStore(ttlMs = 500L, clock = { now })

    @Test
    fun `record stores bounded preview length hash focus and ttl without full plaintext`() {
        val text = "这是需要由真人确认的实际输入内容".repeat(8)

        val evidence = store.record(text, "wechat-chat-input")

        assertEquals(text.length, evidence.length)
        assertEquals(InputCommitEvidence.sha256(text), evidence.sha256)
        assertEquals("wechat-chat-input", evidence.focusedInputId)
        assertEquals(1_500L, evidence.expiresAtMs)
        assertTrue(text.startsWith(evidence.preview.removeSuffix("…")))
        assertFalse("长输入不得把完整明文留在证据对象", evidence.preview == text)
    }

    @Test
    fun `matching focus returns evidence only before ttl expires`() {
        val evidence = store.record("P0 安全硬门测试", "wechat-chat-input")

        now = 1_499L
        assertEquals(evidence, store.current("wechat-chat-input", "P0 安全硬门测试"))

        now = 1_500L
        assertNull(store.current("wechat-chat-input"))
    }

    @Test
    fun `same focus with externally changed readable text fails closed`() {
        val evidence = store.record("原始输入", "wechat-chat-input")

        assertEquals(evidence, store.current("wechat-chat-input", "原始输入"))
        assertNull(store.current("wechat-chat-input", "用户改写后的输入"))
        assertNull(store.current("wechat-chat-input", ""))
        assertEquals(
            "文本不可读时只依赖焦点与 TTL",
            evidence,
            store.current("wechat-chat-input", readableText = null),
        )
        assertFalse(evidence.copy(preview = "伪造预览").matchesReadableText("原始输入"))
    }

    @Test
    fun `blank or mismatching focused input fails closed`() {
        store.record("P0 安全硬门测试", "wechat-chat-input")

        assertNull(store.current(null))
        assertNull(store.current(""))
        assertNull(store.current("search-input"))
    }

    @Test
    fun `new commit invalidates previous commit even when text is identical`() {
        val first = store.record("相同文本", "wechat-chat-input")
        now += 1
        val second = store.record("相同文本", "wechat-chat-input")

        assertTrue(first.sha256 == second.sha256)
        assertTrue(first.commitId != second.commitId)
        assertEquals(second, store.current("wechat-chat-input"))
    }
}

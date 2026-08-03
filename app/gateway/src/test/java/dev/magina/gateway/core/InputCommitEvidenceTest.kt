package dev.magina.gateway.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class InputCommitEvidenceTest {
    private var now = 1_000L
    private val store = InputCommitEvidenceStore(ttlMs = 500L, clock = { now })
    private val imeSessionId = "ime|0123456789abcdef01234567"
    private val nodeId =
        "7|com.tencent.mm:id/chat_input|android.widget.EditText|com.tencent.mm|10,20,100,80"
    private val strict = FocusIdentity(IdentitySource.A11Y, nodeId, imeSessionId)
    private val degraded = FocusIdentity(IdentitySource.IME_ONLY, null, imeSessionId)

    @Test
    fun `record stores bounded preview length hash focus and ttl without full plaintext`() {
        val text = "这是需要由真人确认的实际输入内容".repeat(8)

        val evidence = store.record(text, strict, readbackVerified = true)

        assertEquals(text.length, evidence.length)
        assertEquals(InputCommitEvidence.sha256(text), evidence.sha256)
        assertEquals(strict, evidence.identity)
        assertTrue(evidence.readbackVerified)
        assertEquals(1_500L, evidence.expiresAtMs)
        assertTrue(text.startsWith(evidence.preview.removeSuffix("…")))
        assertFalse("长输入不得把完整明文留在证据对象", evidence.preview == text)
    }

    @Test
    fun `matching focus returns evidence only before ttl expires`() {
        val evidence = store.record("P0 安全硬门测试", strict, readbackVerified = true)

        now = 1_499L
        assertEquals(evidence, store.current(strict, "P0 安全硬门测试"))

        now = 1_500L
        assertNull(store.current(strict))
    }

    @Test
    fun `same focus with externally changed readable text fails closed`() {
        val evidence = store.record("原始输入", strict, readbackVerified = true)

        assertEquals(evidence, store.current(strict, "原始输入"))
        assertNull(store.current(strict, "用户改写后的输入"))
        assertNull(store.current(strict, ""))
        assertEquals(
            "文本不可读时只依赖焦点与 TTL",
            evidence,
            store.current(strict, readableText = null),
        )
        assertFalse(evidence.copy(preview = "伪造预览").matchesReadableText("原始输入"))
    }

    @Test
    fun `blank or mismatching focused input fails closed`() {
        store.record("P0 安全硬门测试", strict, readbackVerified = true)

        assertNull(store.current(null))
        assertNull(
            store.current(
                FocusIdentity(IdentitySource.A11Y, nodeId.replace("chat_input", "search"), imeSessionId),
            ),
        )
        assertNull(
            store.current(FocusIdentity(IdentitySource.A11Y, nodeId, "ime|fedcba9876543210fedcba98")),
        )
    }

    /** 降级链与严格链是两条独立的链：同一 IME 会话也不得互相顶替（design §3.4）。 */
    @Test
    fun `strict and degraded identities never satisfy each other`() {
        store.record("P0 安全硬门测试", strict, readbackVerified = true)
        assertNull("a11y 证据不得被 IME-only 身份读出", store.current(degraded))

        store.clear()
        store.record("P0 安全硬门测试", degraded, readbackVerified = true)
        assertNull("IME-only 证据不得被 a11y 身份读出", store.current(strict))
        assertEquals(degraded, store.current(degraded)?.identity)
    }

    @Test
    fun `readback verification result is persisted on the evidence`() {
        assertFalse(store.record("未读回", degraded, readbackVerified = false).readbackVerified)
        assertTrue(store.record("已读回", degraded, readbackVerified = true).readbackVerified)
    }

    // —— 批准后重建（spec §2.4 选项 C）：归一明文与按当前身份落回 ——

    @Test
    fun `record keeps the normalized plaintext in memory for later ocr comparison`() {
        // 只有 preview 的话，**超过 64 字的内容即使一个字没改也必然判不匹配**——
        // 发送后验正是栽在同一个坑里，而 18 字的测试 marker 恰好绕过它。
        val long = "这是一条足够长的消息".repeat(10)

        val evidence = store.record(long, strict, readbackVerified = true)

        assertEquals(TextNorm.ocr(long), evidence.normalizedText)
        assertTrue("归一明文必须是全文，不是被 preview 截断的那份", evidence.normalizedText.length > 64)
    }

    @Test
    fun `evidence toString redacts both preview and normalized plaintext`() {
        val rendered = store.record("不该出现在日志里的内容", strict, readbackVerified = true).toString()

        assertFalse(rendered, rendered.contains("不该出现在日志里"))
        assertTrue(rendered, rendered.contains("字符>"))
    }

    @Test
    fun `rebindApproved re-issues the approved content under the current identity`() {
        val approved = store.record("已批准的内容", strict, readbackVerified = true)
        // 切走再回来：IME 会话 id 每次 onStartInput 重新生成，旧身份取不出证据了。
        val newIdentity = FocusIdentity(IdentitySource.IME_ONLY, null, "ime|89abcdef0123456789abcdef")
        assertNull(store.current(newIdentity))

        now += 400
        val rebuilt = store.rebindApproved(
            sha256 = approved.sha256,
            length = approved.length,
            preview = approved.preview,
            normalizedText = approved.normalizedText,
            identity = newIdentity,
        )

        // 内容事实一律来自已批准的那份，只有身份与新鲜度换掉了。
        assertEquals(approved.sha256, rebuilt.sha256)
        assertEquals(approved.length, rebuilt.length)
        assertEquals(approved.preview, rebuilt.preview)
        assertEquals(approved.normalizedText, rebuilt.normalizedText)
        assertEquals(newIdentity, rebuilt.identity)
        assertTrue(rebuilt.readbackVerified)
        assertEquals(now + 500L, rebuilt.expiresAtMs)
        assertTrue(approved.commitId != rebuilt.commitId)
        assertEquals(rebuilt, store.current(newIdentity))
        // 旧身份再也取不到——重建换的是身份，不是"两份证据同时有效"。
        assertNull(store.current(strict))
    }

    @Test
    fun `new commit invalidates previous commit even when text is identical`() {
        val first = store.record("相同文本", strict, readbackVerified = true)
        now += 1
        val second = store.record("相同文本", strict, readbackVerified = true)

        assertTrue(first.sha256 == second.sha256)
        assertTrue(first.commitId != second.commitId)
        assertEquals(second, store.current(strict))
    }
}

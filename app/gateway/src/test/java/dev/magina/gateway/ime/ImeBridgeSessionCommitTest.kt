package dev.magina.gateway.ime

import android.view.inputmethod.ExtractedText
import android.view.inputmethod.InputConnection
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.lang.reflect.Proxy

class ImeBridgeSessionCommitTest {
    private var commits = 0

    @After
    fun cleanup() = ImeBridge.finishSession()

    @Test
    fun `commit is zero when focus switches finishes or fast precondition fails`() {
        val connection = fakeConnection()
        ImeBridge.startSession("session-a", "com.tencent.mm", null) { connection }
        assertFalse(ImeBridge.commitIfCurrentSession("wrong", "fixed") { true })
        assertFalse(ImeBridge.commitIfCurrentSession("session-a", "fixed") { false })

        ImeBridge.startSession("session-b", "com.tencent.mm", null) { connection }
        assertFalse(ImeBridge.commitIfCurrentSession("session-a", "fixed") { true })
        ImeBridge.finishSession()
        assertFalse(ImeBridge.commitIfCurrentSession("session-b", "fixed") { true })
        assertEquals(0, commits)
    }

    @Test
    fun `matching current session commits once while lock owns final precondition`() {
        val connection = fakeConnection()
        ImeBridge.startSession("session-a", "com.tencent.mm", null) { connection }

        assertTrue(ImeBridge.commitIfCurrentSession("session-a", "fixed") {
            ImeBridge.focusedInputId == "session-a"
        })

        assertEquals(1, commits)
    }

    @Test
    fun `foreground change or invalid SEARCH proof produces zero commit`() {
        val connection = fakeConnection()
        var foregroundIsWechat = true
        var searchProofValid = true
        ImeBridge.startSession("session-a", "com.tencent.mm", null) { connection }

        foregroundIsWechat = false
        assertFalse(ImeBridge.commitIfCurrentSession("session-a", "fixed") {
            foregroundIsWechat && searchProofValid
        })
        foregroundIsWechat = true
        searchProofValid = false
        assertFalse(ImeBridge.commitIfCurrentSession("session-a", "fixed") {
            foregroundIsWechat && searchProofValid
        })

        assertEquals(0, commits)
    }

    @Test
    fun `editor readback needs exact full text in the original session`() {
        val expected = "东京三日游"
        val field = ExtractedText().apply {
            text = expected
            startOffset = 0
            partialStartOffset = -1
            partialEndOffset = -1
            selectionStart = expected.length
            selectionEnd = expected.length
        }
        val connection = fakeConnection(field)
        ImeBridge.startSession("search", "com.xingin.xhs", null) { connection }
        val session = requireNotNull(ImeBridge.session())
        assertTrue(ImeBridge.matchesCommittedText(session, expected))
        field.text = "搜索, $expected"
        assertFalse(ImeBridge.matchesCommittedText(session, expected))
        field.text = expected
        field.startOffset = 4
        assertFalse(ImeBridge.matchesCommittedText(session, expected))
        field.startOffset = 0
        field.partialEndOffset = expected.length
        assertFalse(ImeBridge.matchesCommittedText(session, expected))
        field.partialEndOffset = -1
        val clipped = fakeConnection(field, afterCursor = "余")
        ImeBridge.startSession("clipped", "com.xingin.xhs", null) { clipped }
        assertFalse(ImeBridge.matchesCommittedText(requireNotNull(ImeBridge.session()), expected))
        ImeBridge.startSession("other-field", "com.xingin.xhs", null) { connection }
        assertFalse(ImeBridge.matchesCommittedText(session, expected))
    }

    private fun fakeConnection(field: ExtractedText? = null, afterCursor: String = ""): InputConnection = Proxy.newProxyInstance(
        InputConnection::class.java.classLoader,
        arrayOf(InputConnection::class.java),
    ) { _, method, _ ->
        when (method.name) {
            "getExtractedText" -> field
            "getTextAfterCursor" -> afterCursor
            "commitText" -> { commits++; true }
            "beginBatchEdit", "endBatchEdit", "performContextMenuAction" -> true
            else -> when (method.returnType) {
                java.lang.Boolean.TYPE -> false
                java.lang.Integer.TYPE -> 0
                else -> null
            }
        }
    } as InputConnection
}

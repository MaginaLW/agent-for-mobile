package dev.magina.gateway.ime

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
        ImeBridge.startSession("session-a", "com.tencent.mm") { connection }
        assertFalse(ImeBridge.commitIfCurrentSession("wrong", "fixed") { true })
        assertFalse(ImeBridge.commitIfCurrentSession("session-a", "fixed") { false })

        ImeBridge.startSession("session-b", "com.tencent.mm") { connection }
        assertFalse(ImeBridge.commitIfCurrentSession("session-a", "fixed") { true })
        ImeBridge.finishSession()
        assertFalse(ImeBridge.commitIfCurrentSession("session-b", "fixed") { true })
        assertEquals(0, commits)
    }

    @Test
    fun `matching current session commits once while lock owns final precondition`() {
        val connection = fakeConnection()
        ImeBridge.startSession("session-a", "com.tencent.mm") { connection }

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
        ImeBridge.startSession("session-a", "com.tencent.mm") { connection }

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

    private fun fakeConnection(): InputConnection = Proxy.newProxyInstance(
        InputConnection::class.java.classLoader,
        arrayOf(InputConnection::class.java),
    ) { _, method, _ ->
        when (method.name) {
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

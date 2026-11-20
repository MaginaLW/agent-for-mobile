package dev.magina.gateway.ime

import android.text.InputType
import android.view.inputmethod.InputConnection
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.lang.reflect.Proxy
import java.util.concurrent.Executor

class ImeBridgeEditorBoundsTest {
    private val direct = Executor { it.run() }
    private val calls = mutableListOf<List<Any?>>()
    private fun connection(accept: Boolean = true): InputConnection = Proxy.newProxyInstance(
        InputConnection::class.java.classLoader, arrayOf(InputConnection::class.java),
    ) { _, method, args ->
        check(method.name == "requestCursorUpdates") { "Unexpected input connection call: ${method.name}" }
        calls.add(requireNotNull(args).toList())
        accept
    } as InputConnection

    private fun start(id: String, connection: InputConnection): ImeSessionIdentity {
        val contract = ImeEditorContract(InputType.TYPE_CLASS_TEXT, 0, 0, null, fieldId = 42)
        ImeBridge.startSession(id, "fixture.app", contract) { connection }
        return requireNotNull(ImeBridge.session())
    }

    @After fun cleanup() = ImeBridge.finishSession()

    @Test fun `timeout and concurrent callers cannot reuse a pending update`() {
        val connection = connection()
        val session = start("first", connection)
        val pending = ImeBridge.requestEditorBounds(session, direct)
        assertFalse(pending.isDone)
        val concurrent = ImeBridge.requestEditorBounds(session, direct)
        assertTrue(concurrent.isDone)
        assertNull(concurrent.join())
        pending.cancel(false)
        val afterTimeout = ImeBridge.requestEditorBounds(session, direct)
        assertTrue(afterTimeout.isDone)
        assertNull(afterTimeout.join())
        assertEquals(listOf(listOf(InputConnection.CURSOR_UPDATE_IMMEDIATE,
            InputConnection.CURSOR_UPDATE_FILTER_EDITOR_BOUNDS)), calls)

        ImeBridge.observeEditorBounds(connection, null)
        assertTrue(pending.isCancelled)
        val next = ImeBridge.requestEditorBounds(session, direct)
        assertFalse(next.isDone)
        assertEquals(2, calls.size)
        ImeBridge.finishSession()
        assertTrue(next.isDone)
        assertNull(next.join())
    }

    @Test fun `refocusing the same connection discards pending and queued work from the old session`() {
        val connection = connection()
        val session = start("old", connection)
        lateinit var task: Runnable
        val queued = ImeBridge.requestEditorBounds(session, Executor { task = it })
        val pending = ImeBridge.requestEditorBounds(session, direct)
        start("new", connection)
        task.run()
        assertTrue(queued.isDone)
        assertNull(queued.join())
        assertTrue(pending.isDone)
        assertNull(pending.join())
        assertEquals(1, calls.size)
    }

    @Test fun `declined filter returns empty and releases the request`() {
        val session = start("declined", connection(accept = false))
        repeat(2) {
            val result = ImeBridge.requestEditorBounds(session, direct)
            assertTrue(result.isDone)
            assertNull(result.join())
        }
        assertEquals(2, calls.size)
    }
}

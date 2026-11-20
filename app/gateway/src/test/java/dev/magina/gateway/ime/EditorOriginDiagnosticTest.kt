package dev.magina.gateway.ime

import android.graphics.PointF
import dev.magina.gateway.tools.SystemTools
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CompletableFuture
import java.util.concurrent.Executor

class EditorOriginDiagnosticTest {
    @After
    fun resetIme() = ImeBridge.finishSession()

    @Test
    fun `missing input target and expired session stop before reading geometry`() {
        val direct = Executor { it.run() }
        ImeBridge.startSession("old", "fixture", null) { null }
        val original = requireNotNull(ImeBridge.session())
        assertEquals(EditorOriginResult.Unavailable.NO_INPUT_TARGET, ImeBridge.requestEditorOrigin(original, direct).get())
        ImeBridge.startSession("next", "fixture", null) { null }
        assertEquals(EditorOriginResult.Unavailable.CONTEXT_CHANGED, ImeBridge.requestEditorOrigin(original, direct).get())
    }

    @Test
    fun `empty geometry timeout and exception preserve null with distinct content free reasons`() {
        val pending = CompletableFuture<EditorOriginResult>()
        val failed = CompletableFuture<EditorOriginResult>().apply {
            completeExceptionally(IllegalStateException("private-fixture"))
        }
        for ((request, reason) in listOf(
            CompletableFuture.completedFuture<EditorOriginResult>(EditorOriginResult.Unavailable.NO_VERIFIED_GEOMETRY) to "no_verified_geometry",
            pending to "timeout",
            failed to "request_failed",
        )) {
            val reply = finish(request, true)
            assertTrue(reply.has("ime_editor_origin") && reply.isNull("ime_editor_origin"))
            assertEquals(reason, reply.getString("ime_editor_origin_reason"))
            assertFalse(reply.toString().contains("private-fixture"))
        }
        assertTrue(pending.isCancelled)
    }

    @Test
    fun `only the current session receives the measured point`() {
        val point = PointF().apply { x = 17f; y = 9f }
        val request = CompletableFuture.completedFuture<EditorOriginResult>(EditorOriginResult.Available(point))
        val stale = finish(request, false)
        assertTrue(stale.isNull("ime_editor_origin"))
        assertEquals("context_changed", stale.getString("ime_editor_origin_reason"))
        val success = finish(request, true)
        assertFalse(success.has("ime_editor_origin_reason"))
        val origin = success.getJSONObject("ime_editor_origin")
        assertEquals("fixture-session", origin.getString("session_id"))
        assertEquals(17.0, origin.getDouble("x"), 0.0)
        assertEquals(9.0, origin.getDouble("y"), 0.0)
    }

    private fun finish(request: CompletableFuture<EditorOriginResult>, current: Boolean) =
        SystemTools.finishEditorOriginRead(JSONObject(), request, "fixture-session") { current }
}

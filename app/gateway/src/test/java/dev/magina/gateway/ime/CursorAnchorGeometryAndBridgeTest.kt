package dev.magina.gateway.ime

import android.text.InputType
import android.view.inputmethod.InputConnection
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.lang.reflect.Proxy
import java.util.concurrent.Executor

class CursorAnchorGeometryAndBridgeTest {
    private val direct = Executor { it.run() }

    @After
    fun cleanup() = ImeBridge.finishSession()

    private fun startSession(
        id: String = "sess-1",
        pkg: String = "com.tencent.mm",
        inputType: Int = InputType.TYPE_CLASS_TEXT,
        fieldId: Int = 0x7f090042,
        connection: InputConnection?,
    ): ImeSessionIdentity {
        val contract = ImeEditorContract(inputType = inputType, imeOptions = 0x04, actionId = 0, actionLabel = null, fieldId = fieldId)
        ImeBridge.startSession(id, pkg, contract) { connection }
        return requireNotNull(ImeBridge.session())
    }

    private fun fakeConnection(
        onFiltered: (mode: Int, filter: Int) -> Boolean = { _, _ -> true },
        onLegacy: (mode: Int) -> Boolean = { true },
    ): Pair<InputConnection, MutableList<List<Int>>> {
        val calls = mutableListOf<List<Int>>()
        val proxy = Proxy.newProxyInstance(
            InputConnection::class.java.classLoader,
            arrayOf(InputConnection::class.java),
        ) { _, method, args ->
            check(method.name == "requestCursorUpdates") { "Unexpected InputConnection call: ${method.name}" }
            val intArgs = requireNotNull(args).map { it as Int }
            calls += intArgs
            if (intArgs.size == 2) onFiltered(intArgs[0], intArgs[1]) else onLegacy(intArgs[0])
        } as InputConnection
        return proxy to calls
    }

    // ---- AffineMatrix2D & CursorAnchorInfo 坐标变换 ----

    @Test
    fun `translation and scale matrices map editorBounds insertionMarker visibleLines and origin accurately`() {
        val translated = RawCursorAnchorData(
            matrixValues = AffineMatrix2D.translation(989f, 1780f).values,
            localEditorBounds = FloatRect(51f, 10f, 1511f, 120f),
            insertionMarkerHorizontal = 68f,
            insertionMarkerTop = 24f,
            insertionMarkerBaseline = 66f,
            insertionMarkerBottom = 80f,
            insertionMarkerFlags = ScreenInsertionMarker.FLAG_HAS_VISIBLE_REGION,
            localVisibleLineBounds = listOf(FloatRect(55f, 24f, 400f, 80f)),
        )
        val geom = requireNotNull(transformCursorAnchor(translated, 42, CursorUpdateRequestMode.FILTERED_2ARG))
        assertFalse(geom.matrixIsIdentity)
        assertEquals(FloatPoint(989f, 1780f), geom.matrixOrigin)
        assertEquals(FloatRect(1040f, 1790f, 2500f, 1900f), geom.editorBounds)
        val marker = requireNotNull(geom.insertionMarker)
        assertEquals(FloatPoint(1057f, 1804f), marker.top)
        assertEquals(FloatPoint(1057f, 1846f), marker.baseline)
        assertEquals(FloatPoint(1057f, 1860f), marker.bottom)
        assertEquals("visible", marker.visibility)
        assertEquals(listOf(FloatRect(1044f, 1804f, 1389f, 1860f)), geom.visibleLineBounds)
        assertEquals(1, geom.visibleLineTotalCount)

        // Scale + translation
        val scaled = RawCursorAnchorData(
            matrixValues = AffineMatrix2D.scaleAndTranslate(1.5f, 2f, 100f, 200f).values,
            localEditorBounds = FloatRect(10f, 20f, 110f, 70f),
            insertionMarkerHorizontal = 20f,
            insertionMarkerTop = 25f,
            insertionMarkerBaseline = Float.NaN,
            insertionMarkerBottom = 45f,
            insertionMarkerFlags = ScreenInsertionMarker.FLAG_HAS_VISIBLE_REGION or ScreenInsertionMarker.FLAG_HAS_INVISIBLE_REGION,
        )
        val scaledGeom = requireNotNull(transformCursorAnchor(scaled, 42, CursorUpdateRequestMode.FILTERED_2ARG))
        assertEquals(FloatPoint(100f, 200f), scaledGeom.matrixOrigin)
        assertEquals(FloatRect(115f, 240f, 265f, 340f), scaledGeom.editorBounds)
        val scaledMarker = requireNotNull(scaledGeom.insertionMarker)
        assertEquals(FloatPoint(130f, 250f), scaledMarker.top)
        assertNull(scaledMarker.baseline)
        assertEquals(FloatPoint(130f, 290f), scaledMarker.bottom)
        assertEquals("partially_visible", scaledMarker.visibility)

        // 90° rotation + translation (maps 4 corners to AABB)
        val rotated = RawCursorAnchorData(
            matrixValues = floatArrayOf(0f, -1f, 1000f, 1f, 0f, 500f, 0f, 0f, 1f),
            localEditorBounds = FloatRect(0f, 0f, 100f, 40f),
        )
        val rotatedGeom = requireNotNull(transformCursorAnchor(rotated, 42, CursorUpdateRequestMode.FILTERED_2ARG))
        assertEquals(FloatRect(960f, 500f, 1000f, 600f), rotatedGeom.editorBounds)
    }

    @Test
    fun `malformed non-affine singular or NaN matrices fail closed and NaN marker is omitted`() {
        val invalidMatrices = listOf(
            // Non-affine perspective row
            floatArrayOf(1f, 0f, 100f, 0f, 1f, 100f, 0.001f, 0f, 1f),
            floatArrayOf(1f, 0f, 100f, 0f, 1f, 100f, 0f, 0f, 2f),
            // Singular (det == 0)
            floatArrayOf(0f, 0f, 100f, 0f, 1f, 100f, 0f, 0f, 1f),
            // NaN entry
            floatArrayOf(1f, 0f, Float.NaN, 0f, 1f, 100f, 0f, 0f, 1f),
        )
        for (m in invalidMatrices) {
            assertNull(transformCursorAnchor(RawCursorAnchorData(matrixValues = m), 42, CursorUpdateRequestMode.FILTERED_2ARG))
        }
        assertNull(
            transformCursorAnchor(
                RawCursorAnchorData(matrixValues = AffineMatrix2D.identity().values, hasMatrix = false),
                42,
                CursorUpdateRequestMode.FILTERED_2ARG,
            ),
        )

        // Valid matrix with NaN marker and invisible marker classification
        val noMarker = requireNotNull(
            transformCursorAnchor(
                RawCursorAnchorData(
                    matrixValues = AffineMatrix2D.translation(500f, 600f).values,
                    insertionMarkerHorizontal = Float.NaN,
                    insertionMarkerTop = 10f,
                    insertionMarkerBottom = 50f,
                ),
                42,
                CursorUpdateRequestMode.LEGACY_1ARG,
            ),
        )
        assertNull(noMarker.insertionMarker)
        assertFalse(noMarker.hasPrimaryGeometry)

        val invisibleMarker = requireNotNull(
            transformCursorAnchor(
                RawCursorAnchorData(
                    matrixValues = AffineMatrix2D.translation(500f, 600f).values,
                    insertionMarkerHorizontal = 10f,
                    insertionMarkerTop = 10f,
                    insertionMarkerBottom = 50f,
                    insertionMarkerFlags = ScreenInsertionMarker.FLAG_HAS_INVISIBLE_REGION,
                ),
                42,
                CursorUpdateRequestMode.LEGACY_1ARG,
            ),
        )
        assertEquals("invisible", invisibleMarker.insertionMarker?.visibility)
        assertNull(invisibleMarker.usableInsertionMarker)
        assertFalse(invisibleMarker.hasPrimaryGeometry)
    }

    // ---- ImeBridge.requestCursorAnchor 2参/1参兜底与会话世代校验 ----

    @Test
    fun `API 34 filtered request uses combined 3-filter mask and receives transformed geometry`() {
        val (conn, calls) = fakeConnection(onFiltered = { _, _ -> true })
        val session = startSession(connection = conn)
        val future = ImeBridge.requestCursorAnchor(session, direct, sdkInt = 34)
        assertFalse(future.isDone)
        assertEquals(
            listOf(
                listOf(
                    InputConnection.CURSOR_UPDATE_IMMEDIATE,
                    InputConnection.CURSOR_UPDATE_FILTER_EDITOR_BOUNDS or
                        InputConnection.CURSOR_UPDATE_FILTER_INSERTION_MARKER or
                        InputConnection.CURSOR_UPDATE_FILTER_VISIBLE_LINE_BOUNDS,
                ),
            ),
            calls,
        )

        ImeBridge.observeCursorAnchorRaw(
            conn,
            RawCursorAnchorData(
                matrixValues = AffineMatrix2D.translation(1000f, 1800f).values,
                localEditorBounds = FloatRect(0f, 0f, 800f, 100f),
            ),
        )
        val outcome = future.join() as CursorAnchorProbeResult.Received
        assertEquals(CursorUpdateRequestMode.FILTERED_2ARG, outcome.requestMode)
        assertEquals(true, outcome.filteredAccepted)
        assertNull(outcome.legacyAccepted)
        assertEquals(FloatRect(1000f, 1800f, 1800f, 1900f), outcome.geometry?.editorBounds)
    }

    @Test
    fun `declined 2-arg filtered request falls back cleanly to 1-arg CURSOR_UPDATE_IMMEDIATE`() {
        val (conn, calls) = fakeConnection(
            onFiltered = { _, _ -> false },
            onLegacy = { true },
        )
        val session = startSession(connection = conn)
        val future = ImeBridge.requestCursorAnchor(session, direct, sdkInt = 35)
        assertFalse(future.isDone)
        assertEquals(2, calls.size)
        assertEquals(2, calls[0].size)
        assertEquals(listOf(InputConnection.CURSOR_UPDATE_IMMEDIATE), calls[1])

        ImeBridge.observeCursorAnchorRaw(
            conn,
            RawCursorAnchorData(
                matrixValues = AffineMatrix2D.translation(1040f, 1820f).values,
                insertionMarkerHorizontal = 12f,
                insertionMarkerTop = 10f,
                insertionMarkerBaseline = 42f,
                insertionMarkerBottom = 52f,
                insertionMarkerFlags = ScreenInsertionMarker.FLAG_HAS_VISIBLE_REGION,
            ),
        )
        val outcome = future.join() as CursorAnchorProbeResult.Received
        assertEquals(CursorUpdateRequestMode.LEGACY_1ARG, outcome.requestMode)
        assertEquals(false, outcome.filteredAccepted)
        assertEquals(true, outcome.legacyAccepted)
        assertNotNull(outcome.geometry?.usableInsertionMarker)
    }

    @Test
    fun `declining both 2-arg and 1-arg returns Declined and frees pending slot`() {
        val (conn, calls) = fakeConnection(onFiltered = { _, _ -> false }, onLegacy = { false })
        val session = startSession(connection = conn)
        repeat(2) {
            val outcome = ImeBridge.requestCursorAnchor(session, direct, sdkInt = 35).join()
            assertEquals(CursorAnchorProbeResult.Declined(filteredAccepted = false, legacyAccepted = false), outcome)
        }
        assertEquals(4, calls.size)
    }

    @Test
    fun `TYPE_NULL password session generation churn and wrong connection fail closed`() {
        val (conn, calls) = fakeConnection()

        // TYPE_NULL -> zero IC calls
        val typeNullSession = startSession(id = "null-sess", inputType = InputType.TYPE_NULL, connection = conn)
        assertEquals(
            CursorAnchorProbeResult.Rejected.INPUT_TYPE_NULL,
            ImeBridge.requestCursorAnchor(typeNullSession, direct, sdkInt = 35).join(),
        )
        assertEquals(0, calls.size)

        // Password -> zero IC calls
        val pwdSession = startSession(
            id = "pwd-sess",
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD,
            connection = conn,
        )
        assertEquals(
            CursorAnchorProbeResult.Rejected.SENSITIVE_FIELD,
            ImeBridge.requestCursorAnchor(pwdSession, direct, sdkInt = 35).join(),
        )
        assertEquals(0, calls.size)

        // Session generation change (even with same focusedInputId!) invalidates pending request
        val firstGen = startSession(id = "same-id", connection = conn)
        val pending = ImeBridge.requestCursorAnchor(firstGen, direct, sdkInt = 35)
        assertFalse(pending.isDone)
        val secondGen = startSession(id = "same-id", connection = conn)
        assertTrue(secondGen.generation > firstGen.generation)
        assertTrue(pending.isDone)
        assertEquals(CursorAnchorProbeResult.Rejected.CONTEXT_CHANGED, pending.join())

        // Wrong connection callback fails closed
        val (otherConn, _) = fakeConnection()
        val live = ImeBridge.requestCursorAnchor(secondGen, direct, sdkInt = 35)
        ImeBridge.observeCursorAnchorRaw(otherConn, RawCursorAnchorData(AffineMatrix2D.translation(10f, 10f).values))
        assertEquals(CursorAnchorProbeResult.Rejected.CONTEXT_CHANGED, live.join())

        // Concurrent active request fails closed with BUSY while first is still pending
        val active = ImeBridge.requestCursorAnchor(secondGen, direct, sdkInt = 35)
        assertFalse(active.isDone)
        assertEquals(
            CursorAnchorProbeResult.Rejected.BUSY,
            ImeBridge.requestCursorAnchor(secondGen, direct, sdkInt = 35).join(),
        )
        // Cancelling a timed-out request releases the slot immediately (never permanently stuck in BUSY)
        active.cancel(false)
        assertTrue(active.isCancelled)
        // Late callback after cancellation is ignored harmlessly when idle
        ImeBridge.observeCursorAnchorRaw(conn, RawCursorAnchorData(AffineMatrix2D.translation(10f, 10f).values))
        // Subsequent cursor-anchor probe succeeds without BUSY
        val fresh = ImeBridge.requestCursorAnchor(secondGen, direct, sdkInt = 35)
        assertFalse(fresh.isDone)
        ImeBridge.observeCursorAnchorRaw(
            conn,
            RawCursorAnchorData(
                matrixValues = AffineMatrix2D.translation(1040f, 1800f).values,
                localEditorBounds = FloatRect(0f, 0f, 400f, 100f),
            ),
        )
        val freshOutcome = fresh.join() as CursorAnchorProbeResult.Received
        assertEquals(FloatRect(1040f, 1800f, 1440f, 1900f), freshOutcome.geometry?.editorBounds)
        // And subsequent requestEditorBounds is not blocked either
        val boundsAfter = ImeBridge.requestEditorBounds(secondGen, direct)
        assertFalse(boundsAfter.isDone)
        boundsAfter.cancel(false)
    }
}

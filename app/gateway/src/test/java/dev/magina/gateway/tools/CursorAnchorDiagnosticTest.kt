package dev.magina.gateway.tools

import android.text.InputType
import dev.magina.gateway.ime.AffineMatrix2D
import dev.magina.gateway.ime.CursorAnchorProbeResult
import dev.magina.gateway.ime.CursorUpdateRequestMode
import dev.magina.gateway.ime.FloatRect
import dev.magina.gateway.ime.ImeEditorContract
import dev.magina.gateway.ime.ImeSessionIdentity
import dev.magina.gateway.ime.RawCursorAnchorData
import dev.magina.gateway.ime.ScreenCursorAnchorGeometry
import dev.magina.gateway.ime.ScreenInsertionMarker
import dev.magina.gateway.ime.transformCursorAnchor
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import dev.magina.gateway.core.ErrorCode
import dev.magina.gateway.core.GatewayError
import java.util.concurrent.TimeoutException

class CursorAnchorDiagnosticTest {
    private val pkg = "com.tencent.mm"
    private val fieldId = 0x7f090042
    private val fieldName = "$pkg:id/chat_input"
    private val chatInputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE

    // PA2553 平行视界实测窗口坐标（tablet.md L289）：左窗 [0,0,985,1968]，右窗 [989,0,2800,1968]
    private val pa2553LeftWindow = VisibleAppWindow(10, pkg, isActive = false, isFocused = false, bounds = IntBounds(0, 0, 985, 1968))
    private val pa2553RightWindow = VisibleAppWindow(20, pkg, isActive = true, isFocused = true, bounds = IntBounds(989, 0, 2800, 1968))
    private val pa2553Windows = listOf(pa2553LeftWindow, pa2553RightWindow)

    private fun sampleGeometry(
        dx: Float,
        dy: Float,
        localBounds: FloatRect? = FloatRect(0f, 0f, 1200f, 120f),
        markerX: Float = 24f,
        markerTop: Float = 16f,
        markerBaseline: Float = 60f,
        markerBottom: Float = 76f,
        markerFlags: Int = ScreenInsertionMarker.FLAG_HAS_VISIBLE_REGION,
        localLines: List<FloatRect> = emptyList(),
        mode: CursorUpdateRequestMode = CursorUpdateRequestMode.FILTERED_2ARG,
    ): ScreenCursorAnchorGeometry = requireNotNull(
        transformCursorAnchor(
            RawCursorAnchorData(
                matrixValues = AffineMatrix2D.translation(dx, dy).values,
                localEditorBounds = localBounds,
                insertionMarkerHorizontal = markerX,
                insertionMarkerTop = markerTop,
                insertionMarkerBaseline = markerBaseline,
                insertionMarkerBottom = markerBottom,
                insertionMarkerFlags = markerFlags,
                localVisibleLineBounds = localLines,
            ),
            fieldId = fieldId,
            requestMode = mode,
        ),
    )

    private class FakeCursorEnv(
        override var sdkInt: Int = 35,
        var session: ImeSessionIdentity? = ImeSessionIdentity("ime|0123456789abcdef01234567", "com.tencent.mm", connected = true, generation = 7L),
        var contract: ImeEditorContract? = ImeEditorContract(
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE,
            imeOptions = 0x04,
            actionId = 0,
            actionLabel = null,
            fieldId = 0x7f090042,
            autofillIdPresent = true,
            autofillIdVirtual = false,
            hasSupportedHandwritingGestures = true,
        ),
        var foregroundPackage: String = "com.tencent.mm",
        var gatewayImeSelected: Boolean = true,
        var windows: List<VisibleAppWindow> = emptyList(),
        var resourceResults: MutableMap<Int, ResourceNameResult> = mutableMapOf(
            0x7f090042 to ResourceNameResult.Found("com.tencent.mm:id/chat_input"),
        ),
        var a11yDiagResult: A11yNodeDiagnosticResult = A11yNodeDiagnosticResult.Unavailable("active_root_missing"),
        var onRequest: (FakeCursorEnv, Boolean) -> CursorAnchorProbeResult = { _, _ ->
            CursorAnchorProbeResult.Declined(false, false)
        },
        var throwTimeoutOnRequest: Boolean = false,
        var onMainThread: Boolean = false,
        var packageBlocked: Boolean = false,
        var focusedNodeSensitive: Boolean = false,
    ) : CursorAnchorEnvironment {
        var requestCalls = 0
        var cancelCalls = 0
        val legacyFlags = mutableListOf<Boolean>()

        override fun session(): ImeSessionIdentity? = session
        override fun editorContract(): ImeEditorContract? = contract
        override fun foregroundPackage(): String = foregroundPackage
        override fun ensurePackageAllowed(pkg: String) {
            if (packageBlocked) throw GatewayError(ErrorCode.E_BLOCKED, "blocked: $pkg")
        }
        override fun checkNotMainThread() {
            if (onMainThread) throw IllegalStateException("main thread")
        }
        override fun isGatewayImeSelected(): Boolean = gatewayImeSelected
        override fun visibleAppWindows(): List<VisibleAppWindow> = windows
        override fun resourceName(pkg: String, resId: Int): ResourceNameResult =
            resourceResults[resId] ?: ResourceNameResult.Missing
        override fun isFocusedNodeSensitive(): Boolean = focusedNodeSensitive

        override fun requestCursorAnchor(session: ImeSessionIdentity, preferLegacyOnly: Boolean): CursorAnchorRequest {
            requestCalls++
            legacyFlags += preferLegacyOnly
            return object : CursorAnchorRequest {
                override fun await(timeoutMs: Long): CursorAnchorProbeResult {
                    if (throwTimeoutOnRequest) throw TimeoutException("timeout")
                    return onRequest(this@FakeCursorEnv, preferLegacyOnly)
                }
                override fun cancel() {
                    cancelCalls++
                }
            }
        }

        override fun inspectA11yNodes(pkg: String, contract: ImeEditorContract?): A11yNodeDiagnosticResult = a11yDiagResult
    }

    @Test
    fun `disjoint PA2553 right-pane passes even when a11y before_sample is completely opaque`() {
        val rightGeometry = sampleGeometry(
            dx = 1040f,
            dy = 1780f,
            localBounds = FloatRect(0f, 0f, 1500f, 120f),
            localLines = listOf(FloatRect(12f, 16f, 600f, 76f)),
        )
        val env = FakeCursorEnv(
            windows = pa2553Windows,
            // 模拟 PA2553 微信：两个无名节点都是 [0,0,0,0] 死路，传统 before_sample 必败，但 4A 直接成功
            a11yDiagResult = A11yNodeDiagnosticResult.Ready(
                NodeTelemetrySnapshot(
                    serviceFocus = NodeTelemetryRow(
                        sameAsService = true, refreshed = true, sameWindow = true, samePackage = true,
                        focused = false, visible = false, editable = false, viewIdState = "missing",
                        boundsState = NodeBoundsState.EMPTY, bounds = null, inputType = 0,
                        matchesContractInputType = false, className = "android.view.View",
                    ),
                    fieldMatchSummary = FieldMatchTelemetrySummary(
                        totalMatches = 2, inspectedMatches = 2, unnamedMatches = 2,
                        boundsInWindowMatches = 0, emptyBoundsMatches = 2, outsideWindowMatches = 0,
                        visibleMatches = 0, focusedMatches = 0, editableMatches = 0,
                        inputTypeMatches = 0, sameAsServiceMatches = 1,
                    ),
                    fieldMatches = listOf(
                        NodeTelemetryRow(
                            sameAsService = true, refreshed = true, sameWindow = true, samePackage = true,
                            focused = false, visible = false, editable = false, viewIdState = "missing",
                            boundsState = NodeBoundsState.EMPTY, bounds = null, inputType = 0,
                            matchesContractInputType = false, className = "android.view.View",
                        ),
                        NodeTelemetryRow(
                            sameAsService = false, refreshed = true, sameWindow = true, samePackage = true,
                            focused = false, visible = false, editable = false, viewIdState = "missing",
                            boundsState = NodeBoundsState.EMPTY, bounds = null, inputType = 0,
                            matchesContractInputType = false, className = "android.view.View",
                        ),
                    ),
                ),
            ),
            onRequest = { _, _ ->
                CursorAnchorProbeResult.Received(rightGeometry, CursorUpdateRequestMode.FILTERED_2ARG, true, null)
            },
        )

        val reply = readCursorAnchor(env, JSONObject())
        assertFalse(reply.has("ime_cursor_anchor_reason"))
        assertEquals(1, env.requestCalls)

        val anchor = reply.getJSONObject("ime_cursor_anchor")
        assertEquals(20, anchor.getInt("window_id"))
        assertEquals("right", anchor.getString("pane"))
        assertEquals("editor_bounds+insertion_marker+visible_lines", anchor.getString("geometry_source"))
        assertEquals("filtered_2arg", anchor.getString("request_mode"))
        assertEquals(7L, anchor.getLong("session_generation"))
        assertEquals(2, anchor.getInt("same_package_window_count"))

        val eb = anchor.getJSONObject("editor_bounds")
        assertEquals(1040.0, eb.getDouble("left"), 0.001)
        assertEquals(1780.0, eb.getDouble("top"), 0.001)
        assertEquals(2540.0, eb.getDouble("right"), 0.001)
        assertEquals(1900.0, eb.getDouble("bottom"), 0.001)

        val crossCheck = anchor.getJSONObject("a11y_cross_check")
        assertEquals(0, crossCheck.getInt("input_type_and_geometry_matches"))
        assertEquals(2, reply.getJSONObject("ime_editor_node_telemetry").getJSONObject("field_matches_summary").getInt("empty_bounds_matches"))
    }

    @Test
    fun `disjoint PA2553 left-pane passes and 4B cross-check reports exact bounds plus inputType agreement`() {
        val leftGeometry = sampleGeometry(
            dx = 60f,
            dy = 160f,
            localBounds = FloatRect(0f, 0f, 800f, 100f),
        )
        val env = FakeCursorEnv(
            windows = pa2553Windows,
            a11yDiagResult = A11yNodeDiagnosticResult.Ready(
                NodeTelemetrySnapshot(
                    serviceFocus = null,
                    fieldMatchSummary = FieldMatchTelemetrySummary(
                        totalMatches = 2, inspectedMatches = 2, unnamedMatches = 2,
                        boundsInWindowMatches = 1, emptyBoundsMatches = 1, outsideWindowMatches = 0,
                        visibleMatches = 0, focusedMatches = 0, editableMatches = 1,
                        inputTypeMatches = 1, sameAsServiceMatches = 0,
                    ),
                    fieldMatches = listOf(
                        NodeTelemetryRow(
                            sameAsService = false, refreshed = true, sameWindow = true, samePackage = true,
                            focused = false, visible = false, editable = true, viewIdState = "missing",
                            boundsState = NodeBoundsState.IN_WINDOW, bounds = IntBounds(60, 160, 860, 260),
                            inputType = chatInputType, matchesContractInputType = true, className = "android.widget.EditText",
                        ),
                    ),
                ),
            ),
            onRequest = { _, _ ->
                CursorAnchorProbeResult.Received(leftGeometry, CursorUpdateRequestMode.FILTERED_2ARG, true, null)
            },
        )

        val reply = readCursorAnchor(env, JSONObject())
        val anchor = reply.getJSONObject("ime_cursor_anchor")
        assertEquals(10, anchor.getInt("window_id"))
        assertEquals("left", anchor.getString("pane"))
        val crossCheck = anchor.getJSONObject("a11y_cross_check")
        assertEquals(1, crossCheck.getInt("exact_editor_bounds_matches"))
        assertEquals(1, crossCheck.getInt("marker_inside_node_matches"))
        assertEquals(1, crossCheck.getInt("input_type_and_geometry_matches"))
    }

    @Test
    fun `insertionMarker-only 1-arg fallback and empty-filtered retry both pass on disjoint right pane`() {
        // 2-arg returns empty identity matrix -> automatic bounded 1-arg retry succeeds with insertion_marker only
        val emptyFiltered = requireNotNull(
            transformCursorAnchor(
                RawCursorAnchorData(matrixValues = AffineMatrix2D.identity().values),
                fieldId = fieldId,
                requestMode = CursorUpdateRequestMode.FILTERED_2ARG,
            ),
        )
        val legacyMarkerOnly = sampleGeometry(
            dx = 1040f,
            dy = 1780f,
            localBounds = null,
            mode = CursorUpdateRequestMode.LEGACY_1ARG,
        )
        val env = FakeCursorEnv(
            windows = pa2553Windows,
            onRequest = { _, preferLegacy ->
                if (!preferLegacy) {
                    CursorAnchorProbeResult.Received(emptyFiltered, CursorUpdateRequestMode.FILTERED_2ARG, true, null)
                } else {
                    CursorAnchorProbeResult.Received(legacyMarkerOnly, CursorUpdateRequestMode.LEGACY_1ARG, null, true)
                }
            },
        )

        val reply = readCursorAnchor(env, JSONObject())
        assertEquals(2, env.requestCalls)
        assertEquals(listOf(false, true), env.legacyFlags)
        val anchor = reply.getJSONObject("ime_cursor_anchor")
        assertEquals(20, anchor.getInt("window_id"))
        assertEquals("right", anchor.getString("pane"))
        assertEquals("insertion_marker", anchor.getString("geometry_source"))
        assertEquals("legacy_1arg_after_empty_filtered", anchor.getString("request_mode"))
        assertTrue(anchor.isNull("editor_bounds"))
    }

    @Test
    fun `overlapping windows and seam-boundary carets fail closed as ambiguous_window_overlap`() {
        // 1) Overlapping same-package windows at editor geometry
        val overlapWindows = listOf(
            VisibleAppWindow(10, pkg, isActive = false, isFocused = false, bounds = IntBounds(0, 0, 1400, 1000)),
            VisibleAppWindow(20, pkg, isActive = true, isFocused = true, bounds = IntBounds(400, 100, 1800, 1000)),
        )
        val overlapGeometry = sampleGeometry(dx = 500f, dy = 600f, localBounds = FloatRect(0f, 0f, 600f, 100f))
        val overlapEnv = FakeCursorEnv(
            windows = overlapWindows,
            onRequest = { _, _ ->
                CursorAnchorProbeResult.Received(overlapGeometry, CursorUpdateRequestMode.FILTERED_2ARG, true, null)
            },
        )
        val overlapReply = readCursorAnchor(overlapEnv, JSONObject())
        assertTrue(overlapReply.isNull("ime_cursor_anchor"))
        assertEquals("ambiguous_window_overlap", overlapReply.getString("ime_cursor_anchor_reason"))

        // 2) Editor contained in window 10 but partially intersecting window 20 -> fail closed
        val partialOverlap = sampleGeometry(dx = 200f, dy = 600f, localBounds = FloatRect(0f, 0f, 500f, 100f))
        val partialAttr = attributeCursorAnchorToDisjointWindow(partialOverlap, pkg, overlapWindows)
        assertTrue(partialAttr is WindowAttributionOutcome.Rejected && partialAttr.reason == "ambiguous_window_overlap")

        // 3) Foreign-package or unknown-package TYPE_APPLICATION window (overlapping OR non-overlapping!) -> fail closed cross_app_or_unknown_window
        val foreignOverlay = VisibleAppWindow(99, "com.other.floating", isActive = false, isFocused = false, bounds = IntBounds(1200, 1700, 1600, 1950))
        val foreignDisjoint = VisibleAppWindow(100, "com.android.launcher", isActive = false, isFocused = false, bounds = IntBounds(0, 0, 200, 200))
        val unknownDisjoint = VisibleAppWindow(101, null, isActive = false, isFocused = false, bounds = IntBounds(0, 0, 200, 200))
        val rightEditor = sampleGeometry(dx = 1040f, dy = 1780f, localBounds = FloatRect(0f, 0f, 1000f, 120f))
        for (extraWin in listOf(foreignOverlay, foreignDisjoint, unknownDisjoint)) {
            val attr = attributeCursorAnchorToDisjointWindow(rightEditor, pkg, pa2553Windows + extraWin)
            assertTrue(
                "expected cross_app_or_unknown_window for $extraWin, got $attr",
                attr is WindowAttributionOutcome.Rejected && attr.reason == "cross_app_or_unknown_window",
            )
        }
        val crossAppEnv = FakeCursorEnv(
            windows = pa2553Windows + foreignDisjoint,
            onRequest = { _, _ ->
                CursorAnchorProbeResult.Received(rightEditor, CursorUpdateRequestMode.FILTERED_2ARG, true, null)
            },
        )
        val crossAppReply = readCursorAnchor(crossAppEnv, JSONObject())
        assertTrue(crossAppReply.isNull("ime_cursor_anchor"))
        assertEquals("cross_app_or_unknown_window", crossAppReply.getString("ime_cursor_anchor_reason"))

        // 4) Zero-gap adjacent windows: full-width right rect passes, but caret literally on seam x=985 fails closed
        val touchingWindows = listOf(
            VisibleAppWindow(10, pkg, false, false, IntBounds(0, 0, 985, 1968)),
            VisibleAppWindow(20, pkg, true, true, IntBounds(985, 0, 2800, 1968)),
        )
        val fullRightRect = sampleGeometry(dx = 985f, dy = 1780f, localBounds = FloatRect(0f, 0f, 1815f, 120f), markerX = 20f)
        val fullRightAttr = attributeCursorAnchorToDisjointWindow(fullRightRect, pkg, touchingWindows)
        assertTrue(fullRightAttr is WindowAttributionOutcome.Attributed && fullRightAttr.windowId == 20)

        val seamCaret = sampleGeometry(dx = 985f, dy = 1780f, localBounds = null, markerX = 0f)
        val seamAttr = attributeCursorAnchorToDisjointWindow(seamCaret, pkg, touchingWindows)
        assertTrue(seamAttr is WindowAttributionOutcome.Rejected && seamAttr.reason == "ambiguous_window_overlap")
    }

    @Test
    fun `identity-only matrix geometry conflict invisible marker stale session TYPE_NULL and sensitive fail closed`() {
        // 1) Bare identity matrix (0,0) must NEVER attribute to top-left window [0,0,985,1968]
        val bareIdentity = requireNotNull(
            transformCursorAnchor(RawCursorAnchorData(AffineMatrix2D.identity().values), fieldId, CursorUpdateRequestMode.LEGACY_1ARG),
        )
        val idAttr = attributeCursorAnchorToDisjointWindow(bareIdentity, pkg, pa2553Windows)
        assertTrue(idAttr is WindowAttributionOutcome.Rejected && idAttr.reason == "no_verified_geometry")

        // 2) Geometry conflict: editorBounds in right window, insertionMarker in left window
        val conflicting = sampleGeometry(
            dx = 1040f,
            dy = 1780f,
            localBounds = FloatRect(0f, 0f, 1000f, 120f),
            markerX = -500f, // maps to x=540 (left window!)
        )
        val conflictAttr = attributeCursorAnchorToDisjointWindow(conflicting, pkg, pa2553Windows)
        assertTrue(conflictAttr is WindowAttributionOutcome.Rejected && conflictAttr.reason == "geometry_conflict")

        // 3) Explicitly invisible insertion marker with no editorBounds -> marker_invisible
        val invisible = sampleGeometry(
            dx = 1040f,
            dy = 1780f,
            localBounds = null,
            markerFlags = ScreenInsertionMarker.FLAG_HAS_INVISIBLE_REGION,
        )
        val invisAttr = attributeCursorAnchorToDisjointWindow(invisible, pkg, pa2553Windows)
        assertTrue(invisAttr is WindowAttributionOutcome.Rejected && invisAttr.reason == "marker_invisible")

        // 4) Stale session generation changed during callback -> context_changed
        val rightGeom = sampleGeometry(dx = 1040f, dy = 1780f)
        val staleSessionEnv = FakeCursorEnv(
            windows = pa2553Windows,
            onRequest = { e, _ ->
                e.session = e.session!!.copy(generation = e.session!!.generation + 1)
                CursorAnchorProbeResult.Received(rightGeom, CursorUpdateRequestMode.FILTERED_2ARG, true, null)
            },
        )
        val staleReply = readCursorAnchor(staleSessionEnv, JSONObject())
        assertTrue(staleReply.isNull("ime_cursor_anchor"))
        assertEquals("context_changed", staleReply.getString("ime_cursor_anchor_reason"))

        // 5) Window bounds changed during callback -> context_changed
        val windowDriftEnv = FakeCursorEnv(
            windows = pa2553Windows,
            onRequest = { e, _ ->
                e.windows = listOf(pa2553LeftWindow, pa2553RightWindow.copy(bounds = IntBounds(990, 0, 2800, 1968)))
                CursorAnchorProbeResult.Received(rightGeom, CursorUpdateRequestMode.FILTERED_2ARG, true, null)
            },
        )
        val driftReply = readCursorAnchor(windowDriftEnv, JSONObject())
        assertTrue(driftReply.isNull("ime_cursor_anchor"))
        assertEquals("context_changed", driftReply.getString("ime_cursor_anchor_reason"))

        // 6) TYPE_NULL -> input_type_null with zero IME requests and sanitized contract diag
        val typeNullEnv = FakeCursorEnv(
            windows = pa2553Windows,
            contract = ImeEditorContract(InputType.TYPE_NULL, 0, 0, null, fieldId = 0),
        )
        val nullReply = readCursorAnchor(typeNullEnv, JSONObject())
        assertTrue(nullReply.isNull("ime_cursor_anchor"))
        assertEquals("input_type_null", nullReply.getString("ime_cursor_anchor_reason"))
        assertEquals(0, typeNullEnv.requestCalls)
        assertTrue(nullReply.getJSONObject("ime_editor_contract_diag").getBoolean("input_type_is_null"))

        // 7) Password contract OR a11y sensitive -> sensitive_field with ZERO telemetry/geometry
        val pwdEnv = FakeCursorEnv(
            windows = pa2553Windows,
            contract = ImeEditorContract(InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD, 0, 0, null, fieldId = fieldId),
        )
        val pwdReply = readCursorAnchor(pwdEnv, JSONObject())
        assertTrue(pwdReply.isNull("ime_cursor_anchor"))
        assertEquals("sensitive_field", pwdReply.getString("ime_cursor_anchor_reason"))
        assertEquals(0, pwdEnv.requestCalls)
        assertFalse(pwdReply.has("ime_cursor_anchor_diag"))
        assertFalse(pwdReply.has("ime_editor_contract_diag"))
        assertFalse(pwdReply.has("ime_editor_node_telemetry"))

        val a11ySensitiveEnv = FakeCursorEnv(
            windows = pa2553Windows,
            a11yDiagResult = A11yNodeDiagnosticResult.SensitiveField,
            onRequest = { _, _ ->
                CursorAnchorProbeResult.Received(rightGeom, CursorUpdateRequestMode.FILTERED_2ARG, true, null)
            },
        )
        val sensReply = readCursorAnchor(a11ySensitiveEnv, JSONObject())
        assertTrue(sensReply.isNull("ime_cursor_anchor"))
        assertEquals("sensitive_field", sensReply.getString("ime_cursor_anchor_reason"))
        assertFalse(sensReply.has("ime_cursor_anchor_diag"))
        assertFalse(sensReply.has("ime_editor_contract_diag"))
        assertFalse(sensReply.has("ime_editor_node_telemetry"))
    }

    @Test
    fun `resolveCursorAnchorFocusBounds resolves PA2553 right pane, left pane, legacy fallback, and never caches`() {
        // PA2553 微信横屏实测几何：[1048,1834,2578,1946] 落于右窗 [927,0,2800,1968]
        val liveLeft = VisibleAppWindow(10, pkg, isActive = false, isFocused = false, bounds = IntBounds(0, 0, 923, 1968))
        val liveRight = VisibleAppWindow(20, pkg, isActive = true, isFocused = true, bounds = IntBounds(927, 0, 2800, 1968))
        val liveWindows = listOf(liveLeft, liveRight)

        var height = 112f
        val env = FakeCursorEnv(
            windows = liveWindows,
            onRequest = { _, _ ->
                val geom = sampleGeometry(
                    dx = 1048f,
                    dy = 1834f,
                    localBounds = FloatRect(0f, 0f, 1530f, height),
                )
                CursorAnchorProbeResult.Received(geom, CursorUpdateRequestMode.FILTERED_2ARG, true, null)
            },
        )
        val first = resolveCursorAnchorFocusBounds(env)
        assertNotNull(first)
        assertEquals("ime|0123456789abcdef01234567", first!!.sessionId)
        assertEquals(20, first.windowId)
        assertEquals("right", first.pane)
        assertEquals(IntBounds(1048, 1834, 2578, 1946), first.editorBounds)

        // 零缓存：第二次调用必须重新发请求并反映最新几何（如输入多行增高）
        height = 124f
        val second = resolveCursorAnchorFocusBounds(env)
        assertNotNull(second)
        assertEquals(2, env.requestCalls)
        assertEquals(IntBounds(1048, 1834, 2578, 1958), second!!.editorBounds)

        // 左窗互不重叠归属
        val leftEnv = FakeCursorEnv(
            windows = liveWindows,
            onRequest = { _, _ ->
                val geom = sampleGeometry(dx = 40f, dy = 1800f, localBounds = FloatRect(0f, 0f, 800f, 100f))
                CursorAnchorProbeResult.Received(geom, CursorUpdateRequestMode.FILTERED_2ARG, true, null)
            },
        )
        val leftRes = resolveCursorAnchorFocusBounds(leftEnv)
        assertEquals(10, leftRes?.windowId)
        assertEquals("left", leftRes?.pane)
        assertEquals(IntBounds(40, 1800, 840, 1900), leftRes?.editorBounds)

        // 2 参返回空 editorBounds 时自动 1 参兜底成功
        val fallbackEnv = FakeCursorEnv(
            windows = liveWindows,
            onRequest = { _, preferLegacy ->
                if (!preferLegacy) {
                    val markerOnly = sampleGeometry(dx = 1048f, dy = 1834f, localBounds = null)
                    CursorAnchorProbeResult.Received(markerOnly, CursorUpdateRequestMode.FILTERED_2ARG, true, null)
                } else {
                    val full = sampleGeometry(dx = 1048f, dy = 1834f, localBounds = FloatRect(0f, 0f, 1530f, 112f))
                    CursorAnchorProbeResult.Received(full, CursorUpdateRequestMode.LEGACY_1ARG, true, true)
                }
            },
        )
        val fallbackRes = resolveCursorAnchorFocusBounds(fallbackEnv)
        assertNotNull(fallbackRes)
        assertEquals(listOf(false, true), fallbackEnv.legacyFlags)
        assertEquals(20, fallbackRes!!.windowId)
        assertEquals("right", fallbackRes.pane)
        assertEquals(IntBounds(1048, 1834, 2578, 1946), fallbackRes.editorBounds)
    }

    @Test
    fun `resolveCursorAnchorFocusBounds fails closed on single-window, cross-app, main-thread, blocked, TYPE_NULL, password, sensitive, overlap, marker-only, drift, and timeout`() {
        val validGeom = sampleGeometry(dx = 1048f, dy = 1834f, localBounds = FloatRect(0f, 0f, 1500f, 100f))
        val validReply: (FakeCursorEnv, Boolean) -> CursorAnchorProbeResult = { _, _ ->
            CursorAnchorProbeResult.Received(validGeom, CursorUpdateRequestMode.FILTERED_2ARG, true, null)
        }

        // 1) 单窗竖屏：零 IPC、立刻返回 null 保持 IME_ONLY
        val singleEnv = FakeCursorEnv(windows = listOf(pa2553RightWindow), onRequest = validReply)
        assertNull(resolveCursorAnchorFocusBounds(singleEnv))
        assertEquals(0, singleEnv.requestCalls)

        // 2) 跨包或未知包多窗：零 IPC、立刻返回 null
        val crossEnv = FakeCursorEnv(
            windows = listOf(
                pa2553RightWindow,
                VisibleAppWindow(99, "com.other.app", false, false, IntBounds(0, 0, 900, 1968)),
            ),
            onRequest = validReply,
        )
        assertNull(resolveCursorAnchorFocusBounds(crossEnv))
        assertEquals(0, crossEnv.requestCalls)

        // 3) 主线程 / 受阻包 / TYPE_NULL / 密码 / 敏感焦点节点：零 IPC、全部返回 null
        val mainThreadEnv = FakeCursorEnv(windows = pa2553Windows, onMainThread = true, onRequest = validReply)
        assertNull(resolveCursorAnchorFocusBounds(mainThreadEnv))
        assertEquals(0, mainThreadEnv.requestCalls)

        val blockedEnv = FakeCursorEnv(windows = pa2553Windows, packageBlocked = true, onRequest = validReply)
        assertNull(resolveCursorAnchorFocusBounds(blockedEnv))
        assertEquals(0, blockedEnv.requestCalls)

        val typeNullEnv = FakeCursorEnv(
            windows = pa2553Windows,
            contract = ImeEditorContract(InputType.TYPE_NULL, 0, 0, null, fieldId = 0),
            onRequest = validReply,
        )
        assertNull(resolveCursorAnchorFocusBounds(typeNullEnv))
        assertEquals(0, typeNullEnv.requestCalls)

        val pwdEnv = FakeCursorEnv(
            windows = pa2553Windows,
            contract = ImeEditorContract(InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD, 0, 0, null, fieldId = fieldId),
            onRequest = validReply,
        )
        assertNull(resolveCursorAnchorFocusBounds(pwdEnv))
        assertEquals(0, pwdEnv.requestCalls)

        val sensitiveBeforeEnv = FakeCursorEnv(windows = pa2553Windows, focusedNodeSensitive = true, onRequest = validReply)
        assertNull(resolveCursorAnchorFocusBounds(sensitiveBeforeEnv))
        assertEquals(0, sensitiveBeforeEnv.requestCalls)

        val sensitiveAfterEnv = FakeCursorEnv(
            windows = pa2553Windows,
            onRequest = { env, _ ->
                env.focusedNodeSensitive = true
                validReply(env, false)
            },
        )
        assertNull(resolveCursorAnchorFocusBounds(sensitiveAfterEnv))

        // 4) 重叠双窗：fail-closed 返回 null
        val overlapEnv = FakeCursorEnv(
            windows = listOf(
                VisibleAppWindow(10, pkg, false, false, IntBounds(0, 0, 1800, 1968)),
                VisibleAppWindow(20, pkg, true, true, IntBounds(800, 0, 2800, 1968)),
            ),
            onRequest = validReply,
        )
        assertNull(resolveCursorAnchorFocusBounds(overlapEnv))

        // 5) 仅有 insertionMarker / matrixOrigin 但 editorBounds == null：绝不提升为 IME_CURSOR_ANCHOR
        val markerOnlyGeom = sampleGeometry(dx = 1048f, dy = 1834f, localBounds = null)
        val markerOnlyEnv = FakeCursorEnv(
            windows = pa2553Windows,
            onRequest = { _, preferLegacy ->
                CursorAnchorProbeResult.Received(
                    markerOnlyGeom,
                    if (preferLegacy) CursorUpdateRequestMode.LEGACY_1ARG else CursorUpdateRequestMode.FILTERED_2ARG,
                    true,
                    if (preferLegacy) true else null,
                )
            },
        )
        assertNull(resolveCursorAnchorFocusBounds(markerOnlyEnv))

        // 6) 回调期间会话世代或窗口变化 -> fail-closed
        val driftSessionEnv = FakeCursorEnv(
            windows = pa2553Windows,
            onRequest = { env, _ ->
                env.session = env.session!!.copy(generation = env.session!!.generation + 1)
                validReply(env, false)
            },
        )
        assertNull(resolveCursorAnchorFocusBounds(driftSessionEnv))

        val driftWindowEnv = FakeCursorEnv(
            windows = pa2553Windows,
            onRequest = { env, _ ->
                env.windows = listOf(
                    pa2553LeftWindow,
                    pa2553RightWindow.copy(bounds = IntBounds(990, 0, 2800, 1968)),
                )
                validReply(env, false)
            },
        )
        assertNull(resolveCursorAnchorFocusBounds(driftWindowEnv))

        // 7) 超时取消请求并返回 null
        val timeoutEnv = FakeCursorEnv(windows = pa2553Windows, throwTimeoutOnRequest = true)
        assertNull(resolveCursorAnchorFocusBounds(timeoutEnv))
        assertEquals(1, timeoutEnv.cancelCalls)
    }
}

package dev.magina.gateway.tools

import android.content.ComponentName
import android.content.pm.PackageManager
import android.content.res.Resources
import android.graphics.Rect
import android.os.Build
import android.os.Looper
import android.provider.Settings
import android.text.InputType
import android.view.accessibility.AccessibilityWindowInfo
import dev.magina.gateway.Gateway
import dev.magina.gateway.a11y.AppWindowSlice
import dev.magina.gateway.a11y.GatewayA11yService
import dev.magina.gateway.a11y.assignWindowPanes
import dev.magina.gateway.core.ensureTargetPackageAllowed
import dev.magina.gateway.ime.CursorAnchorProbeResult
import dev.magina.gateway.ime.CursorUpdateRequestMode
import dev.magina.gateway.ime.FloatPoint
import dev.magina.gateway.ime.FloatRect
import dev.magina.gateway.ime.GatewayIme
import dev.magina.gateway.ime.ImeBridge
import dev.magina.gateway.ime.ImeEditorContract
import dev.magina.gateway.ime.ImeSessionIdentity
import dev.magina.gateway.ime.ScreenCursorAnchorGeometry
import dev.magina.gateway.ime.ScreenInsertionMarker
import dev.magina.gateway.ime.isPasswordInputType
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.ExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

internal data class VisibleAppWindow(
    val id: Int,
    val packageName: String?,
    val isActive: Boolean,
    val isFocused: Boolean,
    val bounds: IntBounds,
)

internal sealed interface WindowAttributionOutcome {
    data class Attributed(
        val windowId: Int,
        val pane: String,
        val windowBounds: IntBounds,
        val geometrySource: String,
        val samePackageWindowCount: Int,
        val totalAppWindowCount: Int,
    ) : WindowAttributionOutcome

    data class Rejected(
        val reason: String,
        val containingWindowIds: List<Int>,
        val overlappingWindowIds: List<Int>,
        val samePackageWindowCount: Int,
        val totalAppWindowCount: Int,
    ) : WindowAttributionOutcome
}

private sealed interface PrimitiveAttribution {
    data class Matched(val window: VisibleAppWindow) : PrimitiveAttribution
    data class Failed(
        val reason: String,
        val containingWindowIds: List<Int>,
        val overlappingWindowIds: List<Int>,
    ) : PrimitiveAttribution
}

internal fun attributeCursorAnchorToDisjointWindow(
    geometry: ScreenCursorAnchorGeometry,
    targetPkg: String,
    appWindows: List<VisibleAppWindow>,
): WindowAttributionOutcome {
    val positive = appWindows.filter { !it.bounds.isEmpty }
    val samePkg = positive.filter { it.packageName == targetPkg }
    val totalCount = positive.size
    val samePkgCount = samePkg.size
    if (samePkg.isEmpty()) {
        return WindowAttributionOutcome.Rejected(
            reason = "no_target_window",
            containingWindowIds = emptyList(),
            overlappingWindowIds = emptyList(),
            samePackageWindowCount = 0,
            totalAppWindowCount = totalCount,
        )
    }

    fun rectContainedIn(rect: FloatRect, window: VisibleAppWindow): Boolean =
        rect.left >= window.bounds.left && rect.top >= window.bounds.top &&
            rect.right <= window.bounds.right && rect.bottom <= window.bounds.bottom

    /** 正面积矩形采用开区间内部相交：相邻零间隙平行视窗不误判重叠，但任何真实重叠立即拦截。 */
    fun rectIntersects(rect: FloatRect, window: VisibleAppWindow): Boolean =
        rect.left < window.bounds.right && window.bounds.left < rect.right &&
            rect.top < window.bounds.bottom && window.bounds.top < rect.bottom

    fun attributeRect(rect: FloatRect): PrimitiveAttribution {
        val containing = samePkg.filter { rectContainedIn(rect, it) }
        if (containing.isEmpty()) {
            val overlapping = positive.filter { rectIntersects(rect, it) }
            val reason = if (overlapping.size >= 2) "ambiguous_window_overlap" else "outside_windows"
            return PrimitiveAttribution.Failed(reason, emptyList(), overlapping.map { it.id })
        }
        if (containing.size >= 2) {
            val overlapping = positive.filter { rectIntersects(rect, it) }
            return PrimitiveAttribution.Failed(
                reason = "ambiguous_window_overlap",
                containingWindowIds = containing.map { it.id },
                overlappingWindowIds = overlapping.map { it.id },
            )
        }
        val winner = containing.single()
        val othersIntersecting = positive.filter { it.id != winner.id && rectIntersects(rect, it) }
        if (othersIntersecting.isNotEmpty()) {
            return PrimitiveAttribution.Failed(
                reason = "ambiguous_window_overlap",
                containingWindowIds = listOf(winner.id),
                overlappingWindowIds = (listOf(winner.id) + othersIntersecting.map { it.id }).distinct(),
            )
        }
        return PrimitiveAttribution.Matched(winner)
    }

    fun segmentInside(seg: FloatRect, window: VisibleAppWindow): Boolean {
        val midX = (seg.left + seg.right) / 2f
        val midY = (seg.top + seg.bottom) / 2f
        return seg.left >= window.bounds.left && seg.right <= window.bounds.right &&
            seg.top >= window.bounds.top && seg.bottom <= window.bounds.bottom &&
            midX < window.bounds.right && midY < window.bounds.bottom
    }

    /** 线段/点对其它窗口采用闭区间相交，保证恰好落在双窗接缝线上的光标一律 fail-closed 判歧义。 */
    fun segmentTouchesOrIntersects(seg: FloatRect, window: VisibleAppWindow): Boolean =
        seg.right >= window.bounds.left && seg.left <= window.bounds.right &&
            seg.bottom >= window.bounds.top && seg.top <= window.bounds.bottom

    fun attributeSegment(marker: ScreenInsertionMarker): PrimitiveAttribution {
        val seg = marker.segmentBounds()
        val containing = samePkg.filter { segmentInside(seg, it) }
        if (containing.isEmpty()) {
            val overlapping = positive.filter { segmentTouchesOrIntersects(seg, it) }
            val reason = if (overlapping.size >= 2) "ambiguous_window_overlap" else "outside_windows"
            return PrimitiveAttribution.Failed(reason, emptyList(), overlapping.map { it.id })
        }
        if (containing.size >= 2) {
            val overlapping = positive.filter { segmentTouchesOrIntersects(seg, it) }
            return PrimitiveAttribution.Failed(
                reason = "ambiguous_window_overlap",
                containingWindowIds = containing.map { it.id },
                overlappingWindowIds = overlapping.map { it.id },
            )
        }
        val winner = containing.single()
        val othersTouching = positive.filter { it.id != winner.id && segmentTouchesOrIntersects(seg, it) }
        if (othersTouching.isNotEmpty()) {
            return PrimitiveAttribution.Failed(
                reason = "ambiguous_window_overlap",
                containingWindowIds = listOf(winner.id),
                overlappingWindowIds = (listOf(winner.id) + othersTouching.map { it.id }).distinct(),
            )
        }
        return PrimitiveAttribution.Matched(winner)
    }

    fun attributePoint(pt: FloatPoint): PrimitiveAttribution {
        val containing = samePkg.filter {
            pt.x >= it.bounds.left && pt.x < it.bounds.right &&
                pt.y >= it.bounds.top && pt.y < it.bounds.bottom
        }
        fun touches(w: VisibleAppWindow): Boolean =
            pt.x >= w.bounds.left && pt.x <= w.bounds.right &&
                pt.y >= w.bounds.top && pt.y <= w.bounds.bottom
        if (containing.isEmpty()) {
            val overlapping = positive.filter(::touches)
            val reason = if (overlapping.size >= 2) "ambiguous_window_overlap" else "outside_windows"
            return PrimitiveAttribution.Failed(reason, emptyList(), overlapping.map { it.id })
        }
        if (containing.size >= 2) {
            val overlapping = positive.filter(::touches)
            return PrimitiveAttribution.Failed(
                reason = "ambiguous_window_overlap",
                containingWindowIds = containing.map { it.id },
                overlappingWindowIds = overlapping.map { it.id },
            )
        }
        val winner = containing.single()
        val othersTouching = positive.filter { it.id != winner.id && touches(it) }
        if (othersTouching.isNotEmpty()) {
            return PrimitiveAttribution.Failed(
                reason = "ambiguous_window_overlap",
                containingWindowIds = listOf(winner.id),
                overlappingWindowIds = (listOf(winner.id) + othersTouching.map { it.id }).distinct(),
            )
        }
        return PrimitiveAttribution.Matched(winner)
    }

    val checks = mutableListOf<Pair<String, PrimitiveAttribution>>()
    geometry.editorBounds?.let { checks += "editor_bounds" to attributeRect(it) }
    geometry.usableInsertionMarker?.let { checks += "insertion_marker" to attributeSegment(it) }
    if (geometry.visibleLineBounds.isNotEmpty()) {
        val lineResults = geometry.visibleLineBounds.map(::attributeRect)
        val firstFailure = lineResults.filterIsInstance<PrimitiveAttribution.Failed>().firstOrNull()
        val lineAttr = if (firstFailure != null) {
            firstFailure
        } else {
            val lineWinners = lineResults.filterIsInstance<PrimitiveAttribution.Matched>().map { it.window }.distinctBy { it.id }
            if (lineWinners.size == 1) {
                PrimitiveAttribution.Matched(lineWinners.single())
            } else {
                PrimitiveAttribution.Failed(
                    reason = "geometry_conflict",
                    containingWindowIds = lineWinners.map { it.id },
                    overlappingWindowIds = lineWinners.map { it.id },
                )
            }
        }
        checks += "visible_lines" to lineAttr
    }

    if (checks.isEmpty()) {
        if (geometry.insertionMarker != null && geometry.insertionMarker.visibility == "invisible") {
            return WindowAttributionOutcome.Rejected(
                reason = "marker_invisible",
                containingWindowIds = emptyList(),
                overlappingWindowIds = emptyList(),
                samePackageWindowCount = samePkgCount,
                totalAppWindowCount = totalCount,
            )
        }
        if (geometry.matrixIsIdentity || (geometry.matrixOrigin.x == 0f && geometry.matrixOrigin.y == 0f)) {
            return WindowAttributionOutcome.Rejected(
                reason = "no_verified_geometry",
                containingWindowIds = emptyList(),
                overlappingWindowIds = emptyList(),
                samePackageWindowCount = samePkgCount,
                totalAppWindowCount = totalCount,
            )
        }
        checks += "matrix_origin" to attributePoint(geometry.matrixOrigin)
    }

    val failures = checks.mapNotNull { it.second as? PrimitiveAttribution.Failed }
    if (failures.isNotEmpty()) {
        val prioritized = failures.firstOrNull { it.reason == "ambiguous_window_overlap" }
            ?: failures.firstOrNull { it.reason == "geometry_conflict" }
            ?: failures.first()
        return WindowAttributionOutcome.Rejected(
            reason = prioritized.reason,
            containingWindowIds = prioritized.containingWindowIds,
            overlappingWindowIds = prioritized.overlappingWindowIds,
            samePackageWindowCount = samePkgCount,
            totalAppWindowCount = totalCount,
        )
    }

    val matchedWindows = checks.map { (it.second as PrimitiveAttribution.Matched).window }.distinctBy { it.id }
    if (matchedWindows.size != 1) {
        return WindowAttributionOutcome.Rejected(
            reason = "geometry_conflict",
            containingWindowIds = matchedWindows.map { it.id },
            overlappingWindowIds = matchedWindows.map { it.id },
            samePackageWindowCount = samePkgCount,
            totalAppWindowCount = totalCount,
        )
    }

    val winner = matchedWindows.single()
    val paneMap = assignWindowPanes(
        samePkg.map {
            AppWindowSlice(it.id, it.packageName, it.bounds.left, it.bounds.top, it.bounds.right, it.bounds.bottom)
        },
    )
    return WindowAttributionOutcome.Attributed(
        windowId = winner.id,
        pane = paneMap[winner.id] ?: "full",
        windowBounds = winner.bounds,
        geometrySource = checks.joinToString("+") { it.first },
        samePackageWindowCount = samePkgCount,
        totalAppWindowCount = totalCount,
    )
}

internal interface CursorAnchorRequest {
    fun await(timeoutMs: Long): CursorAnchorProbeResult
    fun cancel()
}

internal interface CursorAnchorEnvironment {
    val sdkInt: Int
    fun session(): ImeSessionIdentity?
    fun editorContract(): ImeEditorContract?
    fun foregroundPackage(): String
    fun ensurePackageAllowed(pkg: String)
    fun checkNotMainThread()
    fun isGatewayImeSelected(): Boolean
    fun visibleAppWindows(): List<VisibleAppWindow>
    fun resourceName(pkg: String, resId: Int): ResourceNameResult
    fun requestCursorAnchor(session: ImeSessionIdentity, preferLegacyOnly: Boolean = false): CursorAnchorRequest
    fun inspectA11yNodes(pkg: String, contract: ImeEditorContract?): A11yNodeDiagnosticResult
}

private fun FloatRect.toJson(): JSONObject = JSONObject()
    .put("left", left.toDouble())
    .put("top", top.toDouble())
    .put("right", right.toDouble())
    .put("bottom", bottom.toDouble())

private fun ScreenInsertionMarker.toJson(): JSONObject = JSONObject()
    .put("top_x", top.x.toDouble())
    .put("top_y", top.y.toDouble())
    .put("baseline_x", baseline?.x?.toDouble() ?: JSONObject.NULL)
    .put("baseline_y", baseline?.y?.toDouble() ?: JSONObject.NULL)
    .put("bottom_x", bottom.x.toDouble())
    .put("bottom_y", bottom.y.toDouble())
    .put("flags", flags)
    .put("visibility", visibility)

private fun geometryToJson(geometry: ScreenCursorAnchorGeometry): JSONObject {
    val lines = JSONArray()
    for (line in geometry.visibleLineBounds) {
        lines.put(line.toJson())
    }
    return JSONObject()
        .put("request_mode", geometry.requestMode.wireName)
        .put("matrix_origin", JSONObject().put("x", geometry.matrixOrigin.x.toDouble()).put("y", geometry.matrixOrigin.y.toDouble()))
        .put("matrix_is_identity", geometry.matrixIsIdentity)
        .put("editor_bounds", geometry.editorBounds?.toJson() ?: JSONObject.NULL)
        .put("insertion_marker", geometry.insertionMarker?.toJson() ?: JSONObject.NULL)
        .put("visible_line_bounds_count", geometry.visibleLineTotalCount)
        .put("visible_line_bounds", lines)
}

private fun buildA11yCrossCheck(
    geometry: ScreenCursorAnchorGeometry,
    telemetry: NodeTelemetrySnapshot?,
): JSONObject? {
    telemetry ?: return null
    var exactEditorBoundsMatches = 0
    var markerInsideNodeMatches = 0
    var inputTypeAndGeometryMatches = 0
    val eb = geometry.editorBounds
    val markerSeg = geometry.usableInsertionMarker?.segmentBounds()
    for (row in telemetry.fieldMatches) {
        val b = row.bounds ?: continue
        if (row.boundsState != NodeBoundsState.IN_WINDOW) continue
        val ebMatch = eb != null && b.matchesFloat(FloatBounds(eb.left, eb.top, eb.right, eb.bottom))
        val markerInside = markerSeg != null &&
            markerSeg.left >= b.left && markerSeg.right <= b.right &&
            markerSeg.top >= b.top && markerSeg.bottom <= b.bottom
        if (ebMatch) exactEditorBoundsMatches++
        if (markerInside) markerInsideNodeMatches++
        if (row.matchesContractInputType == true && (ebMatch || markerInside)) {
            inputTypeAndGeometryMatches++
        }
    }
    return JSONObject()
        .put("exact_editor_bounds_matches", exactEditorBoundsMatches)
        .put("marker_inside_node_matches", markerInsideNodeMatches)
        .put("input_type_and_geometry_matches", inputTypeAndGeometryMatches)
}

private fun normalizeWindowsForStability(windows: List<VisibleAppWindow>): List<VisibleAppWindow> =
    windows.filter { !it.bounds.isEmpty }.sortedBy { it.id }

/**
 * Pathway 4A + 4B 组合只读诊断入口：
 * - 不以无障碍前置焦点闸门为前提，直接调用 `InputConnection.requestCursorUpdates`；
 * - 严格按屏幕空间与同包/它包可见应用窗口做互不重叠归属；
 * - 同步附带脱敏契约与无短路无障碍节点遥测（密码/无障碍敏感一律 fail-closed 零泄露）；
 * - 绝不生成操作引用（ref）或输入身份。
 */
internal fun readCursorAnchor(service: GatewayA11yService, state: JSONObject): JSONObject =
    readCursorAnchor(AndroidCursorAnchorEnvironment(service), state)

internal fun readCursorAnchor(
    env: CursorAnchorEnvironment,
    state: JSONObject,
    timeoutMs: Long = 2_000L,
): JSONObject {
    fun unavailable(reason: String) =
        state.put("ime_cursor_anchor", JSONObject.NULL).put("ime_cursor_anchor_reason", reason)

    val session = env.session() ?: return unavailable("no_input_target")
    val pkg = env.foregroundPackage()
    if (pkg.isBlank() || !session.belongsTo(pkg)) return unavailable("no_input_target")
    env.ensurePackageAllowed(pkg)
    env.checkNotMainThread()

    return try {
        if (!env.isGatewayImeSelected()) return unavailable("no_input_target")
        val contractBefore = env.editorContract()
        if (contractBefore == null) {
            return unavailable("no_input_target")
                .put("ime_editor_contract_diag", buildContractDiag(env::resourceName, pkg, null))
        }
        if (isPasswordInputType(contractBefore.inputType)) {
            return unavailable("sensitive_field")
        }
        if (contractBefore.inputType == InputType.TYPE_NULL) {
            return unavailable("input_type_null")
                .put("ime_editor_contract_diag", buildContractDiag(env::resourceName, pkg, contractBefore))
        }

        val windowsBefore = normalizeWindowsForStability(env.visibleAppWindows())

        fun executeRequest(preferLegacyOnly: Boolean): CursorAnchorProbeResult {
            val request = env.requestCursorAnchor(session, preferLegacyOnly)
            return try {
                request.await(timeoutMs)
            } catch (e: TimeoutException) {
                request.cancel()
                throw e
            } catch (e: InterruptedException) {
                request.cancel()
                Thread.currentThread().interrupt()
                throw e
            }
        }

        var probeResult = try {
            executeRequest(preferLegacyOnly = false)
        } catch (_: TimeoutException) {
            return unavailable("timeout")
                .put("ime_editor_contract_diag", buildContractDiag(env::resourceName, pkg, contractBefore))
        } catch (_: InterruptedException) {
            return unavailable("interrupted")
        }

        // 若 2 参过滤请求被受理却返回空几何/单位矩阵，且仍在同一会话世代内，允许一次 1 参有界兜底。
        if (probeResult is CursorAnchorProbeResult.Received &&
            probeResult.requestMode == CursorUpdateRequestMode.FILTERED_2ARG &&
            (probeResult.geometry == null || (!probeResult.geometry.hasPrimaryGeometry && probeResult.geometry.matrixIsIdentity))
        ) {
            val midContract = env.editorContract()
            if (midContract != null && isPasswordInputType(midContract.inputType)) {
                return unavailable("sensitive_field")
            }
            if (env.session() == session && env.foregroundPackage() == pkg &&
                env.isGatewayImeSelected() && midContract == contractBefore
            ) {
                val fallback = try {
                    executeRequest(preferLegacyOnly = true)
                } catch (_: TimeoutException) {
                    null
                } catch (_: InterruptedException) {
                    return unavailable("interrupted")
                }
                if (fallback is CursorAnchorProbeResult.Received && fallback.geometry != null) {
                    probeResult = fallback.copy(
                        geometry = fallback.geometry.copy(
                            requestMode = CursorUpdateRequestMode.LEGACY_1ARG_AFTER_EMPTY_FILTERED,
                        ),
                        requestMode = CursorUpdateRequestMode.LEGACY_1ARG_AFTER_EMPTY_FILTERED,
                        filteredAccepted = true,
                        legacyAccepted = true,
                    )
                }
            }
        }

        val contractAfter = env.editorContract()
        if (contractAfter != null && isPasswordInputType(contractAfter.inputType)) {
            return unavailable("sensitive_field")
        }
        val windowsAfter = normalizeWindowsForStability(env.visibleAppWindows())
        if (env.session() != session || env.foregroundPackage() != pkg ||
            !env.isGatewayImeSelected() || contractAfter != contractBefore ||
            windowsBefore != windowsAfter
        ) {
            return unavailable("context_changed")
        }

        // 4B 同步无短路节点遥测：若无障碍侧发现密码/敏感节点，立即 fail-closed 且零几何泄露。
        val a11yDiag = env.inspectA11yNodes(pkg, contractBefore)
        if (a11yDiag is A11yNodeDiagnosticResult.SensitiveField) {
            return unavailable("sensitive_field")
        }
        val nodeTelemetry = (a11yDiag as? A11yNodeDiagnosticResult.Ready)?.telemetry
        val contractDiag = buildContractDiag(env::resourceName, pkg, contractBefore)

        fun attachNonSensitiveTelemetry(target: JSONObject): JSONObject {
            target.put("ime_editor_contract_diag", contractDiag)
            if (nodeTelemetry != null) {
                target.put("ime_editor_node_telemetry", nodeTelemetry.toJson())
            } else if (a11yDiag is A11yNodeDiagnosticResult.Unavailable) {
                target.put("ime_editor_node_telemetry_reason", a11yDiag.reason)
            }
            return target
        }

        when (val outcome = probeResult) {
            is CursorAnchorProbeResult.Rejected -> {
                val reason = when (outcome) {
                    CursorAnchorProbeResult.Rejected.SENSITIVE_FIELD -> return unavailable("sensitive_field")
                    CursorAnchorProbeResult.Rejected.INPUT_TYPE_NULL -> "input_type_null"
                    CursorAnchorProbeResult.Rejected.NO_INPUT_TARGET -> "no_input_target"
                    CursorAnchorProbeResult.Rejected.CONTEXT_CHANGED -> "context_changed"
                    CursorAnchorProbeResult.Rejected.BUSY -> "busy"
                }
                attachNonSensitiveTelemetry(unavailable(reason))
            }
            is CursorAnchorProbeResult.Declined -> {
                val diag = JSONObject()
                    .put("filtered_accepted", outcome.filteredAccepted ?: JSONObject.NULL)
                    .put("legacy_accepted", outcome.legacyAccepted)
                attachNonSensitiveTelemetry(unavailable("request_declined").put("ime_cursor_anchor_diag", diag))
            }
            is CursorAnchorProbeResult.Received -> {
                val geometry = outcome.geometry
                if (geometry == null) {
                    val diag = JSONObject()
                        .put("request_mode", outcome.requestMode.wireName)
                        .put("filtered_accepted", outcome.filteredAccepted ?: JSONObject.NULL)
                        .put("legacy_accepted", outcome.legacyAccepted ?: JSONObject.NULL)
                        .put("geometry_present", false)
                    return attachNonSensitiveTelemetry(
                        unavailable("no_verified_geometry").put("ime_cursor_anchor_diag", diag),
                    )
                }

                val crossCheck = buildA11yCrossCheck(geometry, nodeTelemetry)
                when (val attr = attributeCursorAnchorToDisjointWindow(geometry, pkg, windowsAfter)) {
                    is WindowAttributionOutcome.Rejected -> {
                        val diag = geometryToJson(geometry)
                            .put("filtered_accepted", outcome.filteredAccepted ?: JSONObject.NULL)
                            .put("legacy_accepted", outcome.legacyAccepted ?: JSONObject.NULL)
                            .put("same_package_window_count", attr.samePackageWindowCount)
                            .put("total_app_window_count", attr.totalAppWindowCount)
                            .put("containing_window_ids", JSONArray(attr.containingWindowIds))
                            .put("overlapping_window_ids", JSONArray(attr.overlappingWindowIds))
                            .put("a11y_cross_check", crossCheck ?: JSONObject.NULL)
                        attachNonSensitiveTelemetry(unavailable(attr.reason).put("ime_cursor_anchor_diag", diag))
                    }
                    is WindowAttributionOutcome.Attributed -> {
                        val anchor = geometryToJson(geometry)
                            .put("window_id", attr.windowId)
                            .put("pane", attr.pane)
                            .put(
                                "window_bounds",
                                JSONArray(
                                    listOf(
                                        attr.windowBounds.left,
                                        attr.windowBounds.top,
                                        attr.windowBounds.right,
                                        attr.windowBounds.bottom,
                                    ),
                                ),
                            )
                            .put("session_id", session.id)
                            .put("session_generation", session.generation)
                            .put("geometry_source", attr.geometrySource)
                            .put("filtered_accepted", outcome.filteredAccepted ?: JSONObject.NULL)
                            .put("legacy_accepted", outcome.legacyAccepted ?: JSONObject.NULL)
                            .put("same_package_window_count", attr.samePackageWindowCount)
                            .put("total_app_window_count", attr.totalAppWindowCount)
                            .put("a11y_cross_check", crossCheck ?: JSONObject.NULL)
                        attachNonSensitiveTelemetry(state.put("ime_cursor_anchor", anchor))
                    }
                }
            }
        }
    } catch (_: SecurityException) {
        unavailable("access_denied")
    } catch (_: ExecutionException) {
        unavailable("request_failed")
    }
}

private class AndroidCursorAnchorEnvironment(
    private val service: GatewayA11yService,
) : CursorAnchorEnvironment {
    private val gatewayIme by lazy(LazyThreadSafetyMode.NONE) { ComponentName(service, GatewayIme::class.java) }

    override val sdkInt: Int get() = Build.VERSION.SDK_INT
    override fun session(): ImeSessionIdentity? = ImeBridge.session()
    override fun editorContract(): ImeEditorContract? = ImeBridge.editorContract
    override fun foregroundPackage(): String = service.foregroundPackage()
    override fun ensurePackageAllowed(pkg: String) = ensureTargetPackageAllowed(pkg, Gateway.skills::isBlockedApp)
    override fun checkNotMainThread() = check(Looper.myLooper() != Looper.getMainLooper())

    override fun isGatewayImeSelected(): Boolean =
        Settings.Secure.getString(service.contentResolver, Settings.Secure.DEFAULT_INPUT_METHOD)
            ?.let(ComponentName::unflattenFromString) == gatewayIme

    override fun visibleAppWindows(): List<VisibleAppWindow> = service.windows.mapNotNull { w ->
        if (w.type != AccessibilityWindowInfo.TYPE_APPLICATION) return@mapNotNull null
        val rect = Rect().also(w::getBoundsInScreen)
        val bounds = IntBounds(rect.left, rect.top, rect.right, rect.bottom)
        if (bounds.isEmpty) return@mapNotNull null
        val rootPkg = runCatching { w.root?.packageName?.toString() }.getOrNull()
        VisibleAppWindow(
            id = w.id,
            packageName = rootPkg,
            isActive = w.isActive,
            isFocused = w.isFocused,
            bounds = bounds,
        )
    }

    override fun resourceName(pkg: String, resId: Int): ResourceNameResult = try {
        ResourceNameResult.Found(service.packageManager.getResourcesForApplication(pkg).getResourceName(resId))
    } catch (_: PackageManager.NameNotFoundException) {
        ResourceNameResult.ResourcesUnavailable
    } catch (_: Resources.NotFoundException) {
        ResourceNameResult.Missing
    }

    override fun requestCursorAnchor(
        session: ImeSessionIdentity,
        preferLegacyOnly: Boolean,
    ): CursorAnchorRequest {
        val raw = ImeBridge.requestCursorAnchor(
            expected = session,
            executor = service.mainExecutor,
            sdkInt = Build.VERSION.SDK_INT,
            preferLegacyOnly = preferLegacyOnly,
        )
        return object : CursorAnchorRequest {
            override fun await(timeoutMs: Long): CursorAnchorProbeResult = raw.get(timeoutMs, TimeUnit.MILLISECONDS)
            override fun cancel() {
                raw.cancel(false)
            }
        }
    }

    override fun inspectA11yNodes(pkg: String, contract: ImeEditorContract?): A11yNodeDiagnosticResult =
        inspectA11yNodesForDiagnostic(
            clearCache = { if (Build.VERSION.SDK_INT >= 33) service.clearCache() else true },
            activeRoot = {
                val root = if (Build.VERSION.SDK_INT >= 33) service.getRootInActiveWindow(0) else service.rootInActiveWindow
                root?.let(::AndroidFocusRoot)
            },
            serviceFocus = { service.focusedEditable()?.let(::AndroidFocusNode) },
            resourceName = ::resourceName,
            pkg = pkg,
            contract = contract,
        )
}

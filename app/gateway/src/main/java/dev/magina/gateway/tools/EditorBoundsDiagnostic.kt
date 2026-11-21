package dev.magina.gateway.tools

import android.accessibilityservice.AccessibilityServiceInfo
import android.content.ComponentName
import android.content.pm.PackageManager
import android.content.res.Resources
import android.graphics.Rect
import android.os.Build
import android.os.Looper
import android.provider.Settings
import android.text.InputType
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import androidx.annotation.RequiresApi
import dev.magina.gateway.Gateway
import dev.magina.gateway.a11y.GatewayA11yService
import dev.magina.gateway.core.ensureTargetPackageAllowed
import dev.magina.gateway.ime.GatewayIme
import dev.magina.gateway.ime.ImeBridge
import dev.magina.gateway.ime.ImeEditorContract
import dev.magina.gateway.ime.ImeSessionIdentity
import org.json.JSONObject
import java.util.concurrent.ExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

internal data class IntBounds(val left: Int, val top: Int, val right: Int, val bottom: Int) {
    val isEmpty: Boolean get() = left >= right || top >= bottom

    /** 与 `android.graphics.Rect.contains(Rect)` 对齐：空窗口一律不含任何矩形。 */
    fun contains(other: IntBounds): Boolean =
        !isEmpty && left <= other.left && top <= other.top && right >= other.right && bottom >= other.bottom

    /** 与 `RectF(after.bounds) == sample.bounds` 对齐：按 Float 逐边精确比较，不截断小数。 */
    fun matchesFloat(other: FloatBounds): Boolean =
        left.toFloat() == other.left && top.toFloat() == other.top &&
            right.toFloat() == other.right && bottom.toFloat() == other.bottom
}

internal data class FloatBounds(val left: Float, val top: Float, val right: Float, val bottom: Float)

internal data class EditorBoundsMeasurement(val fieldId: Int, val bounds: FloatBounds)

internal interface EditorBoundsRequest {
    fun await(timeoutMs: Long): EditorBoundsMeasurement?
    fun cancel()
}

internal sealed interface ResourceNameResult {
    data class Found(val name: String) : ResourceNameResult
    data object Missing : ResourceNameResult
    data object ResourcesUnavailable : ResourceNameResult
}

internal interface EditorFocusNode {
    val isFocused: Boolean
    val isVisibleToUser: Boolean
    val windowId: Int
    val packageName: String?
    val isPassword: Boolean
    val isAccessibilityDataSensitive: Boolean
    val viewIdResourceName: String?
    val isEditable: Boolean
    fun refresh(): Boolean
    fun boundsInScreen(): IntBounds
}

internal interface EditorFocusWindow {
    val id: Int
    val isApplicationType: Boolean
    val isActive: Boolean
    val isFocused: Boolean
    fun boundsInScreen(): IntBounds
}

internal interface EditorFocusRoot {
    val packageName: String?
    fun window(): EditorFocusWindow?
    fun findNodesByViewId(viewId: String): List<EditorFocusNode>
    fun findInputFocus(): EditorFocusNode?
}

internal interface EditorBoundsEnvironment {
    val sdkInt: Int
    fun session(): ImeSessionIdentity?
    fun editorContract(): ImeEditorContract?
    fun foregroundPackage(): String
    fun ensurePackageAllowed(pkg: String)
    fun checkNotMainThread()
    fun isGatewayImeSelected(): Boolean
    fun clearCache(): Boolean
    fun activeRoot(): EditorFocusRoot?
    fun serviceFocus(): EditorFocusNode?
    fun reportViewIds(): Boolean?
    fun resourceName(pkg: String, resId: Int): ResourceNameResult
    fun requestEditorBounds(session: ImeSessionIdentity): EditorBoundsRequest
}

private data class EditorFocus(
    val node: EditorFocusNode,
    val windowId: Int,
    val resourceName: String,
    val bounds: IntBounds,
    val editable: Boolean,
    val focused: Boolean,
)

private data class ResolvedFocus(
    val focus: EditorFocus,
    val usedWindowField: Boolean,
    val filteredAmbiguous: Boolean,
)

private data class FilteredFieldMatch(
    val node: EditorFocusNode,
    val bounds: IntBounds,
    val focused: Boolean,
    val editable: Boolean,
)

private data class MultiMatchScan(
    val totalMatches: Int,
    val boundsInWindowMatches: Int,
    val refreshFailedMatches: Int,
    val wrongWindowOrPackageMatches: Int,
    val idMismatchMatches: Int,
    val missingNameMatches: Int,
    val emptyBoundsMatches: Int,
    val outsideWindowMatches: Int,
    val visibleMatches: Int,
    val usable: List<FilteredFieldMatch>,
)

private class Unavailable(val reason: String) : Exception(reason)
private class FocusUnavailable(
    val phase: String,
    val check: String,
    val diag: JSONObject? = null,
    val missingNameMatches: Int? = null,
) : Exception()

private sealed interface WindowFieldNameResult {
    data class Found(val name: String) : WindowFieldNameResult
    data object NoContract : WindowFieldNameResult
    data object MissingId : WindowFieldNameResult
    data object ResourcesUnavailable : WindowFieldNameResult
}

private class ServiceFocusSnapshot(
    val node: EditorFocusNode?,
    val refreshed: Boolean?,
    val focused: Boolean?,
    val visible: Boolean?,
    val sameWindow: Boolean?,
    val samePackage: Boolean?,
    val sensitive: Boolean,
    val viewId: String?,
) {
    val valid: Boolean
        get() = node != null && refreshed == true && visible == true && sameWindow == true && samePackage == true

    val unavailableCheck: String?
        get() = when {
            node == null -> null
            refreshed != true -> "node_refresh_failed"
            visible != true -> "node_not_visible"
            sameWindow != true -> "node_window_mismatch"
            samePackage != true -> "node_package_mismatch"
            else -> null
        }
}

private class WindowFieldSnapshot(
    val lookup: String,
    val fieldName: String? = null,
    val candidate: EditorFocusNode? = null,
    val visible: Boolean? = null,
    val focused: Boolean? = null,
    val sameWindow: Boolean? = null,
    val boundsInWindow: Boolean? = null,
    val totalMatches: Int? = null,
    val visibleInWindowMatches: Int? = null,
    val boundsInWindowMatches: Int? = null,
    val refreshFailedMatches: Int? = null,
    val wrongWindowOrPackageMatches: Int? = null,
    val idMismatchMatches: Int? = null,
    val missingNameMatches: Int = 0,
    val emptyBoundsMatches: Int? = null,
    val outsideWindowMatches: Int? = null,
    val visibleMatches: Int? = null,
)

/** 只读回执。即使两份独立测量一致，也不生成操作引用或输入身份。 */
internal fun readEditorBounds(service: GatewayA11yService, state: JSONObject): JSONObject {
    if (Build.VERSION.SDK_INT < 34) {
        return state.put("ime_editor_bounds", JSONObject.NULL).put("ime_editor_bounds_reason", "unsupported_api")
    }
    return readEditorBounds(AndroidEditorBoundsEnvironment(service), state)
}

internal fun readEditorBounds(
    env: EditorBoundsEnvironment,
    state: JSONObject,
    timeoutMs: Long = 2_000L,
): JSONObject {
    fun unavailable(reason: String) =
        state.put("ime_editor_bounds", JSONObject.NULL).put("ime_editor_bounds_reason", reason)

    if (env.sdkInt < 34) return unavailable("unsupported_api")
    val session = env.session() ?: return unavailable("no_input_target")
    val pkg = env.foregroundPackage()
    if (pkg.isBlank() || !session.belongsTo(pkg)) return unavailable("no_input_target")
    env.ensurePackageAllowed(pkg)
    env.checkNotMainThread()
    return try {
        if (!env.isGatewayImeSelected()) return unavailable("no_input_target")
        val beforeResolved = currentFocus(env, pkg, "before_sample")
        val before = beforeResolved.focus
        val request = env.requestEditorBounds(session)
        val sample = try {
            request.await(timeoutMs)
        } catch (_: TimeoutException) {
            request.cancel()
            return unavailable("timeout")
        } catch (_: InterruptedException) {
            request.cancel()
            Thread.currentThread().interrupt()
            return unavailable("interrupted")
        }
        if (env.session() != session || env.foregroundPackage() != pkg) return unavailable("context_changed")
        if (sample == null) return unavailable("no_ime_bounds")
        val imeName = requireResourceName(env, pkg, sample.fieldId)
        val afterResolved = currentFocus(env, pkg, "after_sample")
        val after = afterResolved.focus
        if (before != after || env.foregroundPackage() != pkg || !env.isGatewayImeSelected() || env.session() != session) {
            return unavailable("context_changed")
        }
        if (imeName != after.resourceName) return unavailable("different_id")
        if (!after.bounds.matchesFloat(sample.bounds)) return unavailable("different_bounds")
        val bounds = JSONObject().put("window_id", after.windowId)
            .put("session_id", session.id).put("editable", after.editable)
            .put("left", after.bounds.left).put("top", after.bounds.top)
            .put("right", after.bounds.right).put("bottom", after.bounds.bottom)
        if (beforeResolved.usedWindowField || afterResolved.usedWindowField) {
            bounds.put("window_field_phase", when {
                !afterResolved.usedWindowField -> "before_sample"
                !beforeResolved.usedWindowField -> "after_sample"
                else -> "both"
            })
        }
        if (beforeResolved.filteredAmbiguous || afterResolved.filteredAmbiguous) {
            bounds.put("filtered_visible_field", true)
        }
        if (!after.focused) {
            bounds.put("node_focused", false)
        }
        state.put("ime_editor_bounds", bounds)
    } catch (e: FocusUnavailable) {
        unavailable("focus_unavailable")
            .put("ime_editor_focus_phase", e.phase)
            .put("ime_editor_focus_check", e.check)
            .also { if (e.diag != null) it.put("ime_editor_focus_diag", e.diag) }
            .putOpt("ime_editor_field_missing_name_matches", e.missingNameMatches)
        if ((e.missingNameMatches ?: 0) > 0) {
            val reportViewIds = try {
                env.reportViewIds()
            } catch (_: RuntimeException) {
                null
            }
            state.put("ime_editor_report_view_ids", reportViewIds ?: JSONObject.NULL)
        }
        state
    } catch (e: Unavailable) {
        unavailable(e.reason)
    } catch (_: SecurityException) {
        unavailable("access_denied")
    } catch (_: ExecutionException) {
        unavailable("request_failed")
    }
}

private fun requireResourceName(env: EditorBoundsEnvironment, pkg: String, resId: Int): String =
    when (val result = env.resourceName(pkg, resId)) {
        is ResourceNameResult.Found -> result.name
        ResourceNameResult.Missing -> throw Unavailable("missing_id")
        ResourceNameResult.ResourcesUnavailable -> throw Unavailable("resources_unavailable")
    }

private fun isPasswordInputType(inputType: Int): Boolean =
    when (inputType and (InputType.TYPE_MASK_CLASS or InputType.TYPE_MASK_VARIATION)) {
        InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD,
        InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD,
        InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD,
        InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_VARIATION_PASSWORD -> true
        else -> false
    }

private fun resolveWindowFieldNameResult(env: EditorBoundsEnvironment, pkg: String): WindowFieldNameResult {
    val contract = env.editorContract() ?: return WindowFieldNameResult.NoContract
    if (isPasswordInputType(contract.inputType)) throw Unavailable("sensitive_field")
    val id = contract.fieldId
    if (id == 0 || id == -1) return WindowFieldNameResult.MissingId
    return when (val result = env.resourceName(pkg, id)) {
        is ResourceNameResult.Found ->
            if (result.name.substringAfter(':', "").startsWith("id/")) WindowFieldNameResult.Found(result.name)
            else WindowFieldNameResult.MissingId
        ResourceNameResult.Missing -> WindowFieldNameResult.MissingId
        ResourceNameResult.ResourcesUnavailable -> WindowFieldNameResult.ResourcesUnavailable
    }
}

private fun resolveWindowFieldName(env: EditorBoundsEnvironment, pkg: String): String =
    when (val result = resolveWindowFieldNameResult(env, pkg)) {
        is WindowFieldNameResult.Found -> result.name
        WindowFieldNameResult.NoContract, WindowFieldNameResult.MissingId -> throw Unavailable("missing_id")
        WindowFieldNameResult.ResourcesUnavailable -> throw Unavailable("resources_unavailable")
    }

/** 仅输出固定 23 键脱敏状态（布尔、非负整数、null 或固定小写枚举），不含文本、包名、资源名、坐标或窗口号。 */
private fun buildFocusDiag(
    sf: ServiceFocusSnapshot,
    rootFocus: EditorFocusNode?,
    wf: WindowFieldSnapshot,
): JSONObject {
    val matchesService = rootFocus != null && sf.node != null && rootFocus == sf.node
    val matchesWindowField = rootFocus != null && wf.candidate != null && rootFocus == wf.candidate
    val rootFocusState = when {
        rootFocus == null -> "missing"
        matchesService && matchesWindowField -> "matches_both"
        matchesService -> "matches_service"
        matchesWindowField -> "matches_window_field"
        else -> "other"
    }
    val serviceMatchesField = if (sf.refreshed == true && !sf.sensitive && sf.viewId != null && wf.fieldName != null) {
        sf.viewId == wf.fieldName
    } else {
        null
    }
    val sameAsService = if (wf.candidate != null && sf.node != null) {
        wf.candidate == sf.node
    } else {
        null
    }
    return JSONObject()
        .put("service_focus_present", sf.node != null)
        .put("service_focus_refreshed", sf.refreshed ?: JSONObject.NULL)
        .put("service_focus_focused", sf.focused ?: JSONObject.NULL)
        .put("service_focus_visible", sf.visible ?: JSONObject.NULL)
        .put("service_focus_same_window", sf.sameWindow ?: JSONObject.NULL)
        .put("service_focus_same_package", sf.samePackage ?: JSONObject.NULL)
        .put("service_focus_matches_field", serviceMatchesField ?: JSONObject.NULL)
        .put("root_focus_state", rootFocusState)
        .put("window_field_lookup", wf.lookup)
        .put("window_field_same_as_service", sameAsService ?: JSONObject.NULL)
        .put("window_field_visible", wf.visible ?: JSONObject.NULL)
        .put("window_field_focused", wf.focused ?: JSONObject.NULL)
        .put("window_field_same_window", wf.sameWindow ?: JSONObject.NULL)
        .put("window_field_bounds_in_window", wf.boundsInWindow ?: JSONObject.NULL)
        .put("window_field_total_matches", wf.totalMatches ?: JSONObject.NULL)
        .put("window_field_visible_in_window_matches", wf.visibleInWindowMatches ?: JSONObject.NULL)
        .put("window_field_bounds_in_window_matches", wf.boundsInWindowMatches ?: JSONObject.NULL)
        .put("window_field_refresh_failed_matches", wf.refreshFailedMatches ?: JSONObject.NULL)
        .put("window_field_wrong_window_or_package_matches", wf.wrongWindowOrPackageMatches ?: JSONObject.NULL)
        .put("window_field_id_mismatch_matches", wf.idMismatchMatches ?: JSONObject.NULL)
        .put("window_field_empty_bounds_matches", wf.emptyBoundsMatches ?: JSONObject.NULL)
        .put("window_field_outside_window_matches", wf.outsideWindowMatches ?: JSONObject.NULL)
        .put("window_field_visible_matches", wf.visibleMatches ?: JSONObject.NULL)
}

/**
 * 兜底路径的根焦点放行条件：
 * 1) 根焦点缺失；
 * 2) 根焦点就是兜底候选；
 * 3) PA2553 已证实的退化形态：根焦点与服务焦点同指一个不同于候选、已刷新、未聚焦、不可见、匿名且非敏感节点。
 */
private fun isFallbackRootFocusAllowed(
    sf: ServiceFocusSnapshot,
    candidate: EditorFocusNode,
    rootFocus: EditorFocusNode?,
): Boolean {
    if (rootFocus == null || rootFocus == candidate) return true
    return sf.node != null &&
        candidate != sf.node &&
        rootFocus == sf.node &&
        sf.refreshed == true &&
        sf.focused == false &&
        sf.visible == false &&
        sf.viewId == null &&
        !sf.sensitive
}

/**
 * 对多命中（或过滤后二次复核）列表按统一严格口径逐项刷新、扫描：
 * 任一刷新成功的同窗同包节点为密码/无障碍敏感时立即 fail-closed 抛 sensitive_field。
 */
private fun scanMultiMatches(
    nodes: List<EditorFocusNode>,
    windowId: Int,
    pkg: String,
    fieldName: String,
    windowBounds: IntBounds,
): MultiMatchScan {
    var boundsInWindowCount = 0
    var refreshFailedCount = 0
    var wrongWindowOrPackageCount = 0
    var idMismatchCount = 0
    var missingNameCount = 0
    var emptyBoundsCount = 0
    var outsideWindowCount = 0
    var visibleCount = 0
    val usable = mutableListOf<FilteredFieldMatch>()
    for (m in nodes) {
        if (!m.refresh()) {
            refreshFailedCount++
            continue
        }
        if (m.windowId != windowId || m.packageName != pkg) {
            wrongWindowOrPackageCount++
            continue
        }
        if (m.isPassword || m.isAccessibilityDataSensitive) throw Unavailable("sensitive_field")
        val name = m.viewIdResourceName
        if (name != fieldName) {
            idMismatchCount++
            if (name.isNullOrBlank()) missingNameCount++
            continue
        }
        val visible = m.isVisibleToUser
        if (visible) visibleCount++
        val bounds = m.boundsInScreen()
        if (bounds.isEmpty) {
            emptyBoundsCount++
            continue
        }
        if (!windowBounds.contains(bounds)) {
            outsideWindowCount++
            continue
        }
        boundsInWindowCount++
        if (visible) {
            usable += FilteredFieldMatch(
                node = m,
                bounds = bounds,
                focused = m.isFocused,
                editable = m.isEditable,
            )
        }
    }
    return MultiMatchScan(
        totalMatches = nodes.size,
        boundsInWindowMatches = boundsInWindowCount,
        refreshFailedMatches = refreshFailedCount,
        wrongWindowOrPackageMatches = wrongWindowOrPackageCount,
        idMismatchMatches = idMismatchCount,
        missingNameMatches = missingNameCount,
        emptyBoundsMatches = emptyBoundsCount,
        outsideWindowMatches = outsideWindowCount,
        visibleMatches = visibleCount,
        usable = usable,
    )
}

private fun currentFocus(env: EditorBoundsEnvironment, pkg: String, phase: String): ResolvedFocus {
    fun missing(check: String): Nothing = throw FocusUnavailable(phase, check)
    if (!env.clearCache()) missing("cache_clear_failed")
    val root = env.activeRoot() ?: missing("active_root_missing")
    val window = root.window() ?: missing("active_window_missing")
    if (!window.isApplicationType || !window.isActive || !window.isFocused || root.packageName != pkg) {
        throw Unavailable("window_mismatch")
    }

    var rootFocusLoaded = false
    var cachedRootFocus: EditorFocusNode? = null
    fun getRootFocus(): EditorFocusNode? {
        if (!rootFocusLoaded) {
            cachedRootFocus = root.findInputFocus()
            rootFocusLoaded = true
        }
        return cachedRootFocus
    }

    val sfNode = env.serviceFocus()
    val sf = if (sfNode == null) {
        ServiceFocusSnapshot(null, null, null, null, null, null, sensitive = false, viewId = null)
    } else if (!sfNode.refresh()) {
        ServiceFocusSnapshot(sfNode, false, null, null, null, null, sensitive = false, viewId = null)
    } else {
        val sameWindow = sfNode.windowId == window.id
        val samePackage = sfNode.packageName == pkg
        val sensitive = sfNode.isPassword || sfNode.isAccessibilityDataSensitive
        if (sameWindow && samePackage && sensitive) throw Unavailable("sensitive_field")
        ServiceFocusSnapshot(
            node = sfNode,
            refreshed = true,
            focused = sfNode.isFocused,
            visible = sfNode.isVisibleToUser,
            sameWindow = sameWindow,
            samePackage = samePackage,
            sensitive = sensitive,
            viewId = if (sensitive) null else sfNode.viewIdResourceName?.takeIf { it.isNotBlank() },
        )
    }

    fun missingField(check: String, field: WindowFieldSnapshot): Nothing {
        val missingNames = field.missingNameMatches.takeIf { (field.idMismatchMatches ?: 0) > 0 }
        throw FocusUnavailable(phase, check, buildFocusDiag(sf, getRootFocus(), field), missingNames)
    }

    // 有效服务焦点严格沿用原路径，禁止因 root_focus_mismatch 或 different_id 绕过兜底。
    if (sf.valid) {
        val node = checkNotNull(sf.node)
        val focused = checkNotNull(sf.focused)
        val rootFocus = getRootFocus()
        if (rootFocus != node) {
            missingField("root_focus_mismatch", WindowFieldSnapshot("not_attempted"))
        }
        val expectedFieldName = if (!focused) resolveWindowFieldName(env, pkg) else null
        val name = sf.viewId ?: throw Unavailable("missing_id")
        if (expectedFieldName != null && expectedFieldName != name) throw Unavailable("different_id")
        if (root.findNodesByViewId(name).singleOrNull() != node) throw Unavailable("ambiguous_id")
        val bounds = node.boundsInScreen()
        if (bounds.isEmpty || !window.boundsInScreen().contains(bounds)) throw Unavailable("invalid_bounds")
        return ResolvedFocus(
            focus = EditorFocus(node, window.id, name, bounds, node.isEditable, focused),
            usedWindowField = false,
            filteredAmbiguous = false,
        )
    }

    // 服务焦点缺失或未通过活动窗可用性检查时，尝试按活动窗内 EditorInfo.fieldId 定向查找。
    val sfFailureCheck = sf.unavailableCheck
    val fieldName = when (val result = resolveWindowFieldNameResult(env, pkg)) {
        is WindowFieldNameResult.Found -> result.name
        WindowFieldNameResult.NoContract -> {
            if (sfFailureCheck == null) throw Unavailable("missing_id")
            missingField(sfFailureCheck, WindowFieldSnapshot("no_contract"))
        }
        WindowFieldNameResult.MissingId -> {
            if (sfFailureCheck == null) throw Unavailable("missing_id")
            missingField(sfFailureCheck, WindowFieldSnapshot("missing_id"))
        }
        WindowFieldNameResult.ResourcesUnavailable -> {
            if (sfFailureCheck == null) throw Unavailable("resources_unavailable")
            missingField(sfFailureCheck, WindowFieldSnapshot("resources_unavailable"))
        }
    }

    val matches = root.findNodesByViewId(fieldName)
    if (matches.isEmpty()) {
        val check = sfFailureCheck ?: "input_focus_missing"
        missingField(
            check,
            WindowFieldSnapshot(
                lookup = "zero_matches",
                fieldName = fieldName,
                totalMatches = 0,
                visibleInWindowMatches = 0,
                boundsInWindowMatches = 0,
                refreshFailedMatches = 0,
                wrongWindowOrPackageMatches = 0,
                idMismatchMatches = 0,
                emptyBoundsMatches = 0,
                outsideWindowMatches = 0,
                visibleMatches = 0,
            ),
        )
    }

    val windowBounds = window.boundsInScreen()
    if (matches.size == 1) {
        val candidate = matches[0]
        val sameAsService = sf.node != null && candidate == sf.node
        if (!candidate.refresh()) {
            val wf = WindowFieldSnapshot(
                lookup = "unique",
                fieldName = fieldName,
                candidate = candidate,
                totalMatches = 1,
                visibleInWindowMatches = 0,
                boundsInWindowMatches = 0,
                refreshFailedMatches = 1,
                wrongWindowOrPackageMatches = 0,
                idMismatchMatches = 0,
                emptyBoundsMatches = 0,
                outsideWindowMatches = 0,
                visibleMatches = 0,
            )
            val check = if (sameAsService) checkNotNull(sfFailureCheck) else "node_refresh_failed"
            missingField(check, wf)
        }
        if (candidate.isPassword || candidate.isAccessibilityDataSensitive) throw Unavailable("sensitive_field")
        val candFocused = candidate.isFocused
        val candVisible = candidate.isVisibleToUser
        val candSameWindow = candidate.windowId == window.id
        val candSamePackage = candidate.packageName == pkg
        val candBounds = candidate.boundsInScreen()
        val candBoundsInWindow = !candBounds.isEmpty && windowBounds.contains(candBounds)
        val candViewId = candidate.viewIdResourceName?.takeIf { it.isNotBlank() }
        val sameWindowAndPkg = candSameWindow && candSamePackage
        val idMatched = sameWindowAndPkg && candViewId == fieldName
        val inWindowQualified = idMatched && candBoundsInWindow
        val wf = WindowFieldSnapshot(
            lookup = "unique",
            fieldName = fieldName,
            candidate = candidate,
            visible = candVisible,
            focused = candFocused,
            sameWindow = candSameWindow,
            boundsInWindow = candBoundsInWindow,
            totalMatches = 1,
            visibleInWindowMatches = if (inWindowQualified && candVisible) 1 else 0,
            boundsInWindowMatches = if (inWindowQualified) 1 else 0,
            refreshFailedMatches = 0,
            wrongWindowOrPackageMatches = if (!sameWindowAndPkg) 1 else 0,
            idMismatchMatches = if (sameWindowAndPkg && !idMatched) 1 else 0,
            missingNameMatches = if (candViewId == null) 1 else 0,
            emptyBoundsMatches = if (idMatched && candBounds.isEmpty) 1 else 0,
            outsideWindowMatches = if (idMatched && !candBounds.isEmpty && !windowBounds.contains(candBounds)) 1 else 0,
            visibleMatches = if (idMatched && candVisible) 1 else 0,
        )
        val candidateFocusCheck = when {
            !candVisible -> "node_not_visible"
            !candSameWindow -> "node_window_mismatch"
            !candSamePackage -> "node_package_mismatch"
            else -> null
        }
        if (candidateFocusCheck != null) {
            val check = if (sameAsService) checkNotNull(sfFailureCheck) else candidateFocusCheck
            missingField(check, wf)
        }
        val rootFocus = getRootFocus()
        if (!isFallbackRootFocusAllowed(sf, candidate, rootFocus)) {
            val check = if (sameAsService) checkNotNull(sfFailureCheck) else "root_focus_mismatch"
            missingField(check, wf)
        }
        val name = candViewId ?: throw Unavailable("missing_id")
        if (name != fieldName) throw Unavailable("different_id")
        if (root.findNodesByViewId(name).singleOrNull() != candidate) throw Unavailable("ambiguous_id")
        if (!candBoundsInWindow) throw Unavailable("invalid_bounds")
        return ResolvedFocus(
            focus = EditorFocus(candidate, window.id, name, candBounds, candidate.isEditable, candFocused),
            usedWindowField = true,
            filteredAmbiguous = false,
        )
    }

    // 多命中（matches.size >= 2）：全量刷新并优先做同窗同包敏感 fail-closed 检查，再按可见且窗内有效子集筛选。
    val scan = scanMultiMatches(matches, window.id, pkg, fieldName, windowBounds)
    if (scan.usable.size != 1) {
        val wf = WindowFieldSnapshot(
            lookup = "ambiguous",
            fieldName = fieldName,
            totalMatches = scan.totalMatches,
            visibleInWindowMatches = scan.usable.size,
            boundsInWindowMatches = scan.boundsInWindowMatches,
            refreshFailedMatches = scan.refreshFailedMatches,
            wrongWindowOrPackageMatches = scan.wrongWindowOrPackageMatches,
            idMismatchMatches = scan.idMismatchMatches,
            missingNameMatches = scan.missingNameMatches,
            emptyBoundsMatches = scan.emptyBoundsMatches,
            outsideWindowMatches = scan.outsideWindowMatches,
            visibleMatches = scan.visibleMatches,
        )
        if (sfFailureCheck != null) {
            missingField(sfFailureCheck, wf)
        }
        if (scan.usable.size >= 2) throw Unavailable("ambiguous_id")
        missingField("node_not_visible", wf)
    }

    val picked = scan.usable.single()
    val candidate = picked.node
    val sameAsService = sf.node != null && candidate == sf.node
    val wf = WindowFieldSnapshot(
        lookup = "filtered_unique",
        fieldName = fieldName,
        candidate = candidate,
        visible = true,
        focused = picked.focused,
        sameWindow = true,
        boundsInWindow = true,
        totalMatches = scan.totalMatches,
        visibleInWindowMatches = 1,
        boundsInWindowMatches = scan.boundsInWindowMatches,
        refreshFailedMatches = scan.refreshFailedMatches,
        wrongWindowOrPackageMatches = scan.wrongWindowOrPackageMatches,
        idMismatchMatches = scan.idMismatchMatches,
        missingNameMatches = scan.missingNameMatches,
        emptyBoundsMatches = scan.emptyBoundsMatches,
        outsideWindowMatches = scan.outsideWindowMatches,
        visibleMatches = scan.visibleMatches,
    )
    val rootFocus = getRootFocus()
    if (!isFallbackRootFocusAllowed(sf, candidate, rootFocus)) {
        val check = if (sameAsService) checkNotNull(sfFailureCheck) else "root_focus_mismatch"
        missingField(check, wf)
    }
    val secondScan = scanMultiMatches(root.findNodesByViewId(fieldName), window.id, pkg, fieldName, windowBounds)
    if (secondScan.usable.singleOrNull()?.node != candidate) throw Unavailable("ambiguous_id")
    return ResolvedFocus(
        focus = EditorFocus(candidate, window.id, fieldName, picked.bounds, picked.editable, picked.focused),
        usedWindowField = true,
        filteredAmbiguous = true,
    )
}

/** 必须用 data class 把 equals/hashCode 委托给底层 AccessibilityNodeInfo，避免跨次 Binder 对象引用不等。 */
@RequiresApi(34)
private data class AndroidFocusNode(private val raw: AccessibilityNodeInfo) : EditorFocusNode {
    override val isFocused: Boolean get() = raw.isFocused
    override val isVisibleToUser: Boolean get() = raw.isVisibleToUser
    override val windowId: Int get() = raw.windowId
    override val packageName: String? get() = raw.packageName?.toString()
    override val isPassword: Boolean get() = raw.isPassword
    override val isAccessibilityDataSensitive: Boolean get() = raw.isAccessibilityDataSensitive
    override val viewIdResourceName: String? get() = raw.viewIdResourceName
    override val isEditable: Boolean get() = raw.isEditable
    override fun refresh(): Boolean = raw.refresh()
    override fun boundsInScreen(): IntBounds = Rect().also(raw::getBoundsInScreen).let {
        IntBounds(it.left, it.top, it.right, it.bottom)
    }
}

@RequiresApi(34)
private class AndroidFocusWindow(private val raw: AccessibilityWindowInfo) : EditorFocusWindow {
    override val id: Int get() = raw.id
    override val isApplicationType: Boolean get() = raw.type == AccessibilityWindowInfo.TYPE_APPLICATION
    override val isActive: Boolean get() = raw.isActive
    override val isFocused: Boolean get() = raw.isFocused
    override fun boundsInScreen(): IntBounds = Rect().also(raw::getBoundsInScreen).let {
        IntBounds(it.left, it.top, it.right, it.bottom)
    }
}

@RequiresApi(34)
private class AndroidFocusRoot(private val raw: AccessibilityNodeInfo) : EditorFocusRoot {
    override val packageName: String? get() = raw.packageName?.toString()
    override fun window(): EditorFocusWindow? = raw.window?.let(::AndroidFocusWindow)
    override fun findNodesByViewId(viewId: String): List<EditorFocusNode> =
        raw.findAccessibilityNodeInfosByViewId(viewId).orEmpty().map(::AndroidFocusNode)
    override fun findInputFocus(): EditorFocusNode? =
        raw.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)?.let(::AndroidFocusNode)
}

@RequiresApi(34)
private class AndroidEditorBoundsEnvironment(private val service: GatewayA11yService) : EditorBoundsEnvironment {
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

    override fun clearCache(): Boolean = service.clearCache()
    override fun activeRoot(): EditorFocusRoot? = service.getRootInActiveWindow(0)?.let(::AndroidFocusRoot)
    override fun serviceFocus(): EditorFocusNode? = service.focusedEditable()?.let(::AndroidFocusNode)

    override fun reportViewIds(): Boolean? {
        if (GatewayA11yService.instance !== service) return null
        val flags = service.serviceInfo?.flags ?: return null
        if (GatewayA11yService.instance !== service) return null
        return (flags and AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS) != 0
    }

    override fun resourceName(pkg: String, resId: Int): ResourceNameResult = try {
        ResourceNameResult.Found(service.packageManager.getResourcesForApplication(pkg).getResourceName(resId))
    } catch (_: PackageManager.NameNotFoundException) {
        ResourceNameResult.ResourcesUnavailable
    } catch (_: Resources.NotFoundException) {
        ResourceNameResult.Missing
    }

    override fun requestEditorBounds(session: ImeSessionIdentity): EditorBoundsRequest {
        val raw = ImeBridge.requestEditorBounds(session, service.mainExecutor)
        return object : EditorBoundsRequest {
            override fun await(timeoutMs: Long): EditorBoundsMeasurement? =
                raw.get(timeoutMs, TimeUnit.MILLISECONDS)?.let {
                    EditorBoundsMeasurement(
                        it.fieldId,
                        FloatBounds(it.bounds.left, it.bounds.top, it.bounds.right, it.bounds.bottom),
                    )
                }

            override fun cancel() {
                raw.cancel(false)
            }
        }
    }
}

package dev.magina.gateway.tools

import android.accessibilityservice.AccessibilityServiceInfo
import android.content.ComponentName
import android.content.pm.PackageManager
import android.content.res.Configuration
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
import dev.magina.gateway.ime.isPasswordInputType
import org.json.JSONArray
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
    val inputType: Int get() = InputType.TYPE_NULL
    val className: String? get() = null
    fun refresh(): Boolean
    fun boundsInScreen(): IntBounds
}

internal enum class NodeBoundsState(val wireName: String) {
    EMPTY("empty"),
    OUTSIDE_WINDOW("outside_window"),
    IN_WINDOW("in_window"),
}

internal fun sanitizeClassName(raw: String?): String? {
    val trimmed = raw?.trim().orEmpty()
    if (trimmed.isEmpty()) return null
    if (trimmed.length > 160) return "other"
    return if (trimmed.all { it.isLetterOrDigit() || it == '.' || it == '_' || it == '$' }) trimmed else "other"
}

/** 单个无障碍节点的无短路脱敏遥测行（零文本、零包名、零资源名明文）。 */
internal data class NodeTelemetryRow(
    val sameAsService: Boolean,
    val refreshed: Boolean,
    val sameWindow: Boolean,
    val samePackage: Boolean,
    val focused: Boolean,
    val visible: Boolean,
    val editable: Boolean,
    val viewIdState: String,
    val boundsState: NodeBoundsState,
    val bounds: IntBounds?,
    val inputType: Int,
    val matchesContractInputType: Boolean?,
    val className: String?,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("same_as_service", sameAsService)
        .put("refreshed", refreshed)
        .put("same_window", sameWindow)
        .put("same_package", samePackage)
        .put("focused", focused)
        .put("visible", visible)
        .put("editable", editable)
        .put("view_id_state", viewIdState)
        .put("bounds_state", boundsState.wireName)
        .put("bounds", bounds?.let { JSONArray(listOf(it.left, it.top, it.right, it.bottom)) } ?: JSONObject.NULL)
        .put("input_type", inputType)
        .put("matches_contract_input_type", matchesContractInputType ?: JSONObject.NULL)
        .put("class_name", className ?: JSONObject.NULL)
}

internal data class FieldMatchTelemetrySummary(
    val totalMatches: Int,
    val inspectedMatches: Int,
    val unnamedMatches: Int,
    val boundsInWindowMatches: Int,
    val emptyBoundsMatches: Int,
    val outsideWindowMatches: Int,
    val visibleMatches: Int,
    val focusedMatches: Int,
    val editableMatches: Int,
    val inputTypeMatches: Int,
    val sameAsServiceMatches: Int,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("total_matches", totalMatches)
        .put("inspected_matches", inspectedMatches)
        .put("unnamed_matches", unnamedMatches)
        .put("bounds_in_window_matches", boundsInWindowMatches)
        .put("empty_bounds_matches", emptyBoundsMatches)
        .put("outside_window_matches", outsideWindowMatches)
        .put("visible_matches", visibleMatches)
        .put("focused_matches", focusedMatches)
        .put("editable_matches", editableMatches)
        .put("input_type_matches", inputTypeMatches)
        .put("same_as_service_matches", sameAsServiceMatches)
}

private const val MAX_TELEMETRY_MATCH_ROWS = 16

internal data class NodeTelemetrySnapshot(
    val serviceFocus: NodeTelemetryRow?,
    val fieldMatchSummary: FieldMatchTelemetrySummary?,
    val fieldMatches: List<NodeTelemetryRow>,
) {
    fun toJson(): JSONObject {
        val rows = JSONArray()
        for (row in fieldMatches.take(MAX_TELEMETRY_MATCH_ROWS)) {
            rows.put(row.toJson())
        }
        return JSONObject()
            .put("service_focus", serviceFocus?.toJson() ?: JSONObject.NULL)
            .put("field_matches_summary", fieldMatchSummary?.toJson() ?: JSONObject.NULL)
            .put("field_matches", rows)
    }
}

internal sealed interface A11yNodeDiagnosticResult {
    data class Ready(val telemetry: NodeTelemetrySnapshot) : A11yNodeDiagnosticResult
    data object SensitiveField : A11yNodeDiagnosticResult
    data class Unavailable(val reason: String) : A11yNodeDiagnosticResult
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
    val isLandscape: Boolean
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
    val anonymousPair: AnonymousEditorPair? = null,
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
    val anonymous: List<AnonymousEditor>,
    val telemetrySummary: FieldMatchTelemetrySummary,
    val inspectedNodes: List<NodeTelemetryRow>,
)

private class Unavailable(val reason: String) : Exception(reason)
private class MissingIdUnavailable(
    val phase: String,
    val source: String,
    val contractDiag: JSONObject? = null,
    val nodeTelemetry: NodeTelemetrySnapshot? = null,
) : Exception("missing_id")

private class AnonymousPairStopped(
    val pair: AnonymousEditorPair,
    val phase: String,
    val reason: String,
    val contractDiag: JSONObject? = null,
    val nodeTelemetry: NodeTelemetrySnapshot? = null,
) : Exception(reason)

private class FocusUnavailable(
    val phase: String,
    val check: String,
    val diag: JSONObject? = null,
    val missingNameMatches: Int? = null,
    val contractDiag: JSONObject? = null,
    val nodeTelemetry: NodeTelemetrySnapshot? = null,
) : Exception()

internal sealed interface WindowFieldNameResult {
    data class Found(val name: String, val id: Int) : WindowFieldNameResult
    data object NoContract : WindowFieldNameResult
    data object MissingId : WindowFieldNameResult
    data object ResourcesUnavailable : WindowFieldNameResult
}

internal data class ClassifiedContractField(
    val fieldIdClass: String,
    val lookupResult: WindowFieldNameResult,
)

internal fun classifyContractField(
    resourceName: (String, Int) -> ResourceNameResult,
    pkg: String,
    contract: ImeEditorContract?,
): ClassifiedContractField {
    if (contract == null) return ClassifiedContractField("no_contract", WindowFieldNameResult.NoContract)
    val id = contract.fieldId
    if (id == 0) return ClassifiedContractField("zero", WindowFieldNameResult.MissingId)
    if (id == -1) return ClassifiedContractField("no_id", WindowFieldNameResult.MissingId)
    return when (val result = resourceName(pkg, id)) {
        is ResourceNameResult.Found ->
            if (result.name.substringAfter(':', "").startsWith("id/")) {
                ClassifiedContractField("id", WindowFieldNameResult.Found(result.name, id))
            } else {
                ClassifiedContractField("non_id", WindowFieldNameResult.MissingId)
            }
        ResourceNameResult.Missing -> ClassifiedContractField("unresolved", WindowFieldNameResult.MissingId)
        ResourceNameResult.ResourcesUnavailable ->
            ClassifiedContractField("resources_unavailable", WindowFieldNameResult.ResourcesUnavailable)
    }
}

/** 固定 8 键脱敏契约诊断（零文本、零包名、零资源名、零 AutofillId 明文）。密码字段必须提前拦截，不得进入此函数。 */
internal fun buildContractDiag(
    resourceName: (String, Int) -> ResourceNameResult,
    pkg: String,
    contract: ImeEditorContract?,
    preclassifiedFieldClass: String? = null,
): JSONObject {
    val fieldIdClass = preclassifiedFieldClass ?: try {
        classifyContractField(resourceName, pkg, contract).fieldIdClass
    } catch (_: SecurityException) {
        "access_denied"
    }
    return JSONObject()
        .put("contract_present", contract != null)
        .put("input_type_is_null", contract?.let { it.inputType == InputType.TYPE_NULL } ?: JSONObject.NULL)
        .put("input_type", contract?.inputType ?: JSONObject.NULL)
        .put("ime_options", contract?.imeOptions ?: JSONObject.NULL)
        .put("field_id_class", fieldIdClass)
        .put("autofill_id_present", contract?.autofillIdPresent ?: JSONObject.NULL)
        .put("autofill_id_virtual", contract?.autofillIdVirtual ?: JSONObject.NULL)
        .put("supported_handwriting_gestures", contract?.hasSupportedHandwritingGestures ?: JSONObject.NULL)
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
    val telemetry: NodeTelemetryRow? = null,
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
    val telemetrySummary: FieldMatchTelemetrySummary? = null,
    val inspectedNodes: List<NodeTelemetryRow> = emptyList(),
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
    var beforePair: AnonymousEditorPair? = null
    return try {
        if (!env.isGatewayImeSelected()) return unavailable("no_input_target")
        // Pathway 4B：在进入 currentFocus() 前先分类密码与 TYPE_NULL 兜底连接，绝不把 DecorView TYPE_NULL 误报为 field_id_unresolved。
        val beforeContract = env.editorContract()
        if (beforeContract != null && isPasswordInputType(beforeContract.inputType)) {
            return unavailable("sensitive_field")
        }
        if (beforeContract != null && beforeContract.inputType == InputType.TYPE_NULL) {
            return unavailable("input_type_null")
                .put("ime_editor_contract_diag", buildContractDiag(env::resourceName, pkg, beforeContract))
        }
        val beforeResolved = currentFocus(env, pkg, "before_sample", beforeContract)
        beforePair = beforeResolved.anonymousPair
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
        val afterContract = env.editorContract()
        if (afterContract != null && isPasswordInputType(afterContract.inputType)) {
            return unavailable("sensitive_field")
        }
        if (afterContract != null && afterContract.inputType == InputType.TYPE_NULL) {
            return unavailable("context_changed")
        }
        val imeName = requireResourceName(env, pkg, sample.fieldId, afterContract)
        val afterResolved = currentFocus(env, pkg, "after_sample", afterContract)
        val after = afterResolved.focus
        val pair = afterResolved.anonymousPair
        if (before != after || beforePair != pair || env.foregroundPackage() != pkg ||
            !env.isGatewayImeSelected() || env.session() != session || (pair != null && !env.isLandscape)) {
            return unavailable("context_changed")
        }
        if (imeName != after.resourceName || (pair != null && pair.fieldId != sample.fieldId)) return unavailable("different_id")
        if (pair != null) {
            val matched = pair.candidates.singleOrNull { it.bounds.matchesFloat(sample.bounds) }
            val reason = when {
                matched == null -> "geometry_unverified"
                !matched.focused -> "focus_conflict"
                else -> null
            }
            if (reason != null) return unavailable(reason)
                .put("ime_editor_anonymous_pair", pair.receipt("after_sample", reason, sample.bounds))
        } else if (!after.bounds.matchesFloat(sample.bounds)) {
            return unavailable("different_bounds")
        }
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
        if (pair != null) state.put("ime_editor_anonymous_pair", pair.receipt("after_sample", "selected", sample.bounds))
        state.put("ime_editor_bounds", bounds)
    } catch (e: AnonymousPairStopped) {
        try {
            if (env.session() != session || env.foregroundPackage() != pkg || !env.isGatewayImeSelected() ||
                !env.isLandscape || (e.phase == "after_sample" && beforePair?.hasSameScope(e.pair) != true)) {
                unavailable("context_changed")
            } else {
                unavailable(e.reason)
                    .put("ime_editor_anonymous_pair", e.pair.receipt(e.phase, e.reason))
                    .also { if (e.contractDiag != null) it.put("ime_editor_contract_diag", e.contractDiag) }
                    .also { if (e.nodeTelemetry != null) it.put("ime_editor_node_telemetry", e.nodeTelemetry.toJson()) }
            }
        } catch (_: SecurityException) {
            unavailable("access_denied")
        }
    } catch (e: FocusUnavailable) {
        unavailable("focus_unavailable")
            .put("ime_editor_focus_phase", e.phase)
            .put("ime_editor_focus_check", e.check)
            .also { if (e.diag != null) it.put("ime_editor_focus_diag", e.diag) }
            .also { if (e.contractDiag != null) it.put("ime_editor_contract_diag", e.contractDiag) }
            .also { if (e.nodeTelemetry != null) it.put("ime_editor_node_telemetry", e.nodeTelemetry.toJson()) }
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
    } catch (e: MissingIdUnavailable) {
        unavailable("missing_id")
            .put("ime_editor_missing_id_phase", e.phase)
            .put("ime_editor_missing_id_source", e.source)
            .also { if (e.contractDiag != null) it.put("ime_editor_contract_diag", e.contractDiag) }
            .also { if (e.nodeTelemetry != null) it.put("ime_editor_node_telemetry", e.nodeTelemetry.toJson()) }
    } catch (e: Unavailable) {
        unavailable(e.reason)
    } catch (_: SecurityException) {
        unavailable("access_denied")
    } catch (_: ExecutionException) {
        unavailable("request_failed")
    }
}

private fun requireResourceName(
    env: EditorBoundsEnvironment,
    pkg: String,
    resId: Int,
    contract: ImeEditorContract?,
): String =
    when (val result = env.resourceName(pkg, resId)) {
        is ResourceNameResult.Found -> result.name
        ResourceNameResult.Missing -> throw MissingIdUnavailable(
            phase = "after_sample",
            source = "ime_sample_field_unresolved",
            contractDiag = buildContractDiag(env::resourceName, pkg, contract),
        )
        ResourceNameResult.ResourcesUnavailable -> throw Unavailable("resources_unavailable")
    }

private fun resolveWindowFieldNameResult(
    env: EditorBoundsEnvironment,
    pkg: String,
    contract: ImeEditorContract?,
): ClassifiedContractField {
    if (contract != null && isPasswordInputType(contract.inputType)) throw Unavailable("sensitive_field")
    return classifyContractField(env::resourceName, pkg, contract)
}

private fun resolveWindowFieldName(
    env: EditorBoundsEnvironment,
    pkg: String,
    phase: String,
    contract: ImeEditorContract?,
    sfTelemetry: NodeTelemetryRow?,
): String {
    val classified = resolveWindowFieldNameResult(env, pkg, contract)
    return when (val result = classified.lookupResult) {
        is WindowFieldNameResult.Found -> result.name
        WindowFieldNameResult.NoContract -> throw MissingIdUnavailable(
            phase = phase,
            source = "field_contract_absent",
            contractDiag = buildContractDiag(env::resourceName, pkg, contract, classified.fieldIdClass),
            nodeTelemetry = sfTelemetry?.let { NodeTelemetrySnapshot(it, null, emptyList()) },
        )
        WindowFieldNameResult.MissingId -> throw MissingIdUnavailable(
            phase = phase,
            source = "field_id_unresolved",
            contractDiag = buildContractDiag(env::resourceName, pkg, contract, classified.fieldIdClass),
            nodeTelemetry = sfTelemetry?.let { NodeTelemetrySnapshot(it, null, emptyList()) },
        )
        WindowFieldNameResult.ResourcesUnavailable -> throw Unavailable("resources_unavailable")
    }
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

private fun inspectNodeTelemetryRow(
    node: EditorFocusNode,
    windowBounds: IntBounds,
    sameAsService: Boolean,
    sameWindow: Boolean,
    samePackage: Boolean,
    fieldName: String?,
    contractInputType: Int?,
): NodeTelemetryRow {
    val name = node.viewIdResourceName
    val viewIdState = when {
        name.isNullOrBlank() -> "missing"
        fieldName == null -> "unchecked"
        name == fieldName -> "matches_field"
        else -> "other"
    }
    val bounds = node.boundsInScreen()
    val boundsState = when {
        bounds.isEmpty -> NodeBoundsState.EMPTY
        !windowBounds.contains(bounds) -> NodeBoundsState.OUTSIDE_WINDOW
        else -> NodeBoundsState.IN_WINDOW
    }
    val nodeInputType = node.inputType
    val matchesContractType = contractInputType
        ?.takeIf { it != InputType.TYPE_NULL }
        ?.let { nodeInputType == it }
    return NodeTelemetryRow(
        sameAsService = sameAsService,
        refreshed = true,
        sameWindow = sameWindow,
        samePackage = samePackage,
        focused = node.isFocused,
        visible = node.isVisibleToUser,
        editable = node.isEditable,
        viewIdState = viewIdState,
        boundsState = boundsState,
        bounds = bounds.takeUnless { it.isEmpty },
        inputType = nodeInputType,
        matchesContractInputType = matchesContractType,
        className = sanitizeClassName(node.className),
    )
}

/**
 * 对多命中（或过滤后二次复核）列表按统一严格口径逐项刷新、扫描：
 * 任一刷新成功的同窗同包节点为密码/无障碍敏感时立即 fail-closed 抛 sensitive_field。
 * Pathway 4B：在判断 `viewIdResourceName != fieldName` 之前先采集无短路脱敏节点遥测，
 * 确保即使节点被剥离 `viewIdResourceName == null` 也能观测到真实 bounds/visible/focused/editable/inputType/className/same_as_service。
 */
private fun scanMultiMatches(
    nodes: List<EditorFocusNode>,
    windowId: Int,
    pkg: String,
    fieldName: String,
    windowBounds: IntBounds,
    readAnonymousPair: Boolean = false,
    sfNode: EditorFocusNode? = null,
    contractInputType: Int? = null,
): MultiMatchScan {
    var boundsInWindowCount = 0
    var refreshFailedCount = 0
    var wrongWindowOrPackageCount = 0
    var idMismatchCount = 0
    var missingNameCount = 0
    var emptyBoundsCount = 0
    var outsideWindowCount = 0
    var visibleCount = 0
    var anyBoundsInWindowCount = 0
    var anyEmptyBoundsCount = 0
    var anyOutsideWindowCount = 0
    var anyVisibleCount = 0
    var anyFocusedCount = 0
    var anyEditableCount = 0
    var anyInputTypeMatchesCount = 0
    var anySameAsServiceCount = 0
    val usable = mutableListOf<FilteredFieldMatch>()
    val anonymous = mutableListOf<AnonymousEditor>()
    val inspectedNodes = mutableListOf<NodeTelemetryRow>()
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
        val row = inspectNodeTelemetryRow(
            node = m,
            windowBounds = windowBounds,
            sameAsService = sfNode != null && m == sfNode,
            sameWindow = true,
            samePackage = true,
            fieldName = fieldName,
            contractInputType = contractInputType,
        )
        inspectedNodes += row
        when (row.boundsState) {
            NodeBoundsState.IN_WINDOW -> anyBoundsInWindowCount++
            NodeBoundsState.EMPTY -> anyEmptyBoundsCount++
            NodeBoundsState.OUTSIDE_WINDOW -> anyOutsideWindowCount++
        }
        if (row.visible) anyVisibleCount++
        if (row.focused) anyFocusedCount++
        if (row.editable) anyEditableCount++
        if (row.matchesContractInputType == true) anyInputTypeMatchesCount++
        if (row.sameAsService) anySameAsServiceCount++

        val name = m.viewIdResourceName
        if (name != fieldName) {
            idMismatchCount++
            if (name.isNullOrBlank()) {
                missingNameCount++
                if (readAnonymousPair) {
                    anonymous += AnonymousEditor(
                        m,
                        row.bounds ?: IntBounds(0, 0, 0, 0),
                        row.focused,
                        row.visible,
                        row.editable,
                    )
                }
            }
            continue
        }
        if (row.visible) visibleCount++
        val bounds = row.bounds
        if (bounds == null) {
            emptyBoundsCount++
            continue
        }
        if (row.boundsState != NodeBoundsState.IN_WINDOW) {
            outsideWindowCount++
            continue
        }
        boundsInWindowCount++
        if (row.visible) {
            usable += FilteredFieldMatch(
                node = m,
                bounds = bounds,
                focused = row.focused,
                editable = row.editable,
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
        anonymous = anonymous,
        telemetrySummary = FieldMatchTelemetrySummary(
            totalMatches = nodes.size,
            inspectedMatches = inspectedNodes.size,
            unnamedMatches = missingNameCount,
            boundsInWindowMatches = anyBoundsInWindowCount,
            emptyBoundsMatches = anyEmptyBoundsCount,
            outsideWindowMatches = anyOutsideWindowCount,
            visibleMatches = anyVisibleCount,
            focusedMatches = anyFocusedCount,
            editableMatches = anyEditableCount,
            inputTypeMatches = anyInputTypeMatchesCount,
            sameAsServiceMatches = anySameAsServiceCount,
        ),
        inspectedNodes = inspectedNodes,
    )
}

private fun currentFocus(
    env: EditorBoundsEnvironment,
    pkg: String,
    phase: String,
    contract: ImeEditorContract?,
): ResolvedFocus {
    fun missing(check: String): Nothing = throw FocusUnavailable(
        phase = phase,
        check = check,
        contractDiag = buildContractDiag(env::resourceName, pkg, contract),
    )
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

    fun focusReading(node: EditorFocusNode?): InputFocusReading {
        if (node == null || node.windowId != window.id || node.packageName != pkg) return InputFocusReading(null, null, null)
        if (node.isPassword || node.isAccessibilityDataSensitive) throw Unavailable("sensitive_field")
        return InputFocusReading(node, node.isFocused, node.isVisibleToUser)
    }

    val landscape = env.isLandscape
    val windowBounds by lazy(LazyThreadSafetyMode.NONE) { window.boundsInScreen() }
    val contractInputType = contract?.inputType
    val sfNode = env.serviceFocus()
    // 在 refresh 或字段枚举改变缓存前，分别保存服务和窗口根两次焦点查询的原始属性。
    val serviceReading = if (landscape) focusReading(sfNode) else null
    val rootReading = if (landscape) focusReading(getRootFocus()) else null
    val sf = if (sfNode == null) {
        ServiceFocusSnapshot(null, null, null, null, null, null, sensitive = false, viewId = null)
    } else if (!sfNode.refresh()) {
        ServiceFocusSnapshot(sfNode, false, null, null, null, null, sensitive = false, viewId = null)
    } else {
        val sameWindow = sfNode.windowId == window.id
        val samePackage = sfNode.packageName == pkg
        val sensitive = sfNode.isPassword || sfNode.isAccessibilityDataSensitive
        if (sameWindow && samePackage && sensitive) throw Unavailable("sensitive_field")
        val sfTelemetry = if (!sensitive) {
            inspectNodeTelemetryRow(
                node = sfNode,
                windowBounds = windowBounds,
                sameAsService = true,
                sameWindow = sameWindow,
                samePackage = samePackage,
                fieldName = null,
                contractInputType = contractInputType,
            )
        } else {
            null
        }
        ServiceFocusSnapshot(
            node = sfNode,
            refreshed = true,
            focused = sfNode.isFocused,
            visible = sfNode.isVisibleToUser,
            sameWindow = sameWindow,
            samePackage = samePackage,
            sensitive = sensitive,
            viewId = if (sensitive) null else sfNode.viewIdResourceName?.takeIf { it.isNotBlank() },
            telemetry = sfTelemetry,
        )
    }

    val classifiedLookup = if (landscape || !sf.valid) resolveWindowFieldNameResult(env, pkg, contract) else null
    val lookup = classifiedLookup?.lookupResult
    val field = lookup as? WindowFieldNameResult.Found
    val sfTelemetryWithField = sf.telemetry?.let { row ->
        if (field == null) row
        else row.copy(
            viewIdState = when {
                sf.viewId == null -> "missing"
                sf.viewId == field.name -> "matches_field"
                else -> "other"
            },
        )
    }

    fun contractDiag(): JSONObject = buildContractDiag(env::resourceName, pkg, contract, classifiedLookup?.fieldIdClass)

    fun missingField(check: String, wf: WindowFieldSnapshot): Nothing {
        val missingNames = wf.missingNameMatches.takeIf { (wf.idMismatchMatches ?: 0) > 0 }
        val nodeTelemetry = NodeTelemetrySnapshot(
            serviceFocus = sfTelemetryWithField,
            fieldMatchSummary = wf.telemetrySummary,
            fieldMatches = wf.inspectedNodes,
        )
        throw FocusUnavailable(
            phase = phase,
            check = check,
            diag = buildFocusDiag(sf, getRootFocus(), wf),
            missingNameMatches = missingNames,
            contractDiag = contractDiag(),
            nodeTelemetry = nodeTelemetry,
        )
    }

    val fieldMatches = field?.let { root.findNodesByViewId(it.name) }.orEmpty()
    val fieldScan = if (field != null && fieldMatches.size >= 2 && (!sf.valid || fieldMatches.size == 2)) {
        scanMultiMatches(
            nodes = fieldMatches,
            windowId = window.id,
            pkg = pkg,
            fieldName = field.name,
            windowBounds = windowBounds,
            readAnonymousPair = landscape && fieldMatches.size == 2,
            sfNode = sf.node,
            contractInputType = contractInputType,
        )
    } else null
    if (field != null && fieldScan?.anonymous?.size == 2) {
        val candidates = fieldScan.anonymous
        if (candidates[0].node == candidates[1].node) throw Unavailable("ambiguous_id")
        val pair = AnonymousEditorPair(field.id, window.id, windowBounds, checkNotNull(serviceReading),
            checkNotNull(rootReading), candidates.toSet())
        val reason = pair.stopReason() ?: if (!sf.valid || sf.focused != true ||
            (sf.viewId != null && sf.viewId != field.name)) "focus_conflict" else null
        if (reason != null) throw AnonymousPairStopped(
            pair = pair,
            phase = phase,
            reason = reason,
            contractDiag = contractDiag(),
            nodeTelemetry = NodeTelemetrySnapshot(
                serviceFocus = sfTelemetryWithField,
                fieldMatchSummary = fieldScan.telemetrySummary,
                fieldMatches = fieldScan.inspectedNodes,
            ),
        )
        val target = checkNotNull(pair.focused)
        return ResolvedFocus(EditorFocus(target.node, window.id, field.name, target.bounds,
            target.editable, target.focused), usedWindowField = true, filteredAmbiguous = false, anonymousPair = pair)
    }

    // 有效服务焦点严格沿用原路径，禁止因 root_focus_mismatch 或 different_id 绕过兜底。
    if (sf.valid) {
        val node = checkNotNull(sf.node)
        val focused = checkNotNull(sf.focused)
        val rootFocus = getRootFocus()
        if (rootFocus != node) {
            missingField("root_focus_mismatch", WindowFieldSnapshot("not_attempted"))
        }
        val expectedFieldName = if (!focused) {
            resolveWindowFieldName(env, pkg, phase, contract, sfTelemetryWithField)
        } else {
            null
        }
        val name = sf.viewId ?: throw MissingIdUnavailable(
            phase = phase,
            source = "service_node_unnamed",
            contractDiag = contractDiag(),
            nodeTelemetry = sfTelemetryWithField?.let { NodeTelemetrySnapshot(it, null, emptyList()) },
        )
        if (expectedFieldName != null && expectedFieldName != name) throw Unavailable("different_id")
        val byName = if (landscape && field?.name == name) fieldMatches else root.findNodesByViewId(name)
        if (byName.singleOrNull() != node) throw Unavailable("ambiguous_id")
        val bounds = sf.telemetry?.bounds ?: node.boundsInScreen()
        if (bounds.isEmpty || !windowBounds.contains(bounds)) throw Unavailable("invalid_bounds")
        return ResolvedFocus(
            focus = EditorFocus(node, window.id, name, bounds, sf.telemetry?.editable ?: node.isEditable, focused),
            usedWindowField = false,
            filteredAmbiguous = false,
        )
    }

    // 服务焦点缺失或未通过活动窗可用性检查时，尝试按活动窗内 EditorInfo.fieldId 定向查找。
    val sfFailureCheck = sf.unavailableCheck
    val fieldName = when (val result = checkNotNull(lookup)) {
        is WindowFieldNameResult.Found -> result.name
        WindowFieldNameResult.NoContract -> {
            if (sfFailureCheck == null) throw MissingIdUnavailable(
                phase = phase,
                source = "field_contract_absent",
                contractDiag = contractDiag(),
                nodeTelemetry = NodeTelemetrySnapshot(sfTelemetryWithField, null, emptyList()),
            )
            missingField(sfFailureCheck, WindowFieldSnapshot("no_contract"))
        }
        WindowFieldNameResult.MissingId -> {
            if (sfFailureCheck == null) throw MissingIdUnavailable(
                phase = phase,
                source = "field_id_unresolved",
                contractDiag = contractDiag(),
                nodeTelemetry = NodeTelemetrySnapshot(sfTelemetryWithField, null, emptyList()),
            )
            missingField(sfFailureCheck, WindowFieldSnapshot("missing_id"))
        }
        WindowFieldNameResult.ResourcesUnavailable -> {
            if (sfFailureCheck == null) throw Unavailable("resources_unavailable")
            missingField(sfFailureCheck, WindowFieldSnapshot("resources_unavailable"))
        }
    }

    val matches = fieldMatches
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
                telemetrySummary = FieldMatchTelemetrySummary(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0),
                inspectedNodes = emptyList(),
            ),
        )
    }

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
                telemetrySummary = FieldMatchTelemetrySummary(1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0),
                inspectedNodes = emptyList(),
            )
            val check = if (sameAsService) checkNotNull(sfFailureCheck) else "node_refresh_failed"
            missingField(check, wf)
        }
        if (candidate.isPassword || candidate.isAccessibilityDataSensitive) throw Unavailable("sensitive_field")
        val candSameWindow = candidate.windowId == window.id
        val candSamePackage = candidate.packageName == pkg
        val candRow = inspectNodeTelemetryRow(
            node = candidate,
            windowBounds = windowBounds,
            sameAsService = sameAsService,
            sameWindow = candSameWindow,
            samePackage = candSamePackage,
            fieldName = fieldName,
            contractInputType = contractInputType,
        )
        val candFocused = candRow.focused
        val candVisible = candRow.visible
        val candBounds = candRow.bounds ?: IntBounds(0, 0, 0, 0)
        val candBoundsInWindow = candRow.boundsState == NodeBoundsState.IN_WINDOW
        val candViewId = candidate.viewIdResourceName?.takeIf { it.isNotBlank() }
        val sameWindowAndPkg = candSameWindow && candSamePackage
        val idMatched = sameWindowAndPkg && candViewId == fieldName
        val inWindowQualified = idMatched && candBoundsInWindow
        val singleSummary = FieldMatchTelemetrySummary(
            totalMatches = 1,
            inspectedMatches = 1,
            unnamedMatches = if (candViewId == null) 1 else 0,
            boundsInWindowMatches = if (candBoundsInWindow) 1 else 0,
            emptyBoundsMatches = if (candRow.boundsState == NodeBoundsState.EMPTY) 1 else 0,
            outsideWindowMatches = if (candRow.boundsState == NodeBoundsState.OUTSIDE_WINDOW) 1 else 0,
            visibleMatches = if (candVisible) 1 else 0,
            focusedMatches = if (candFocused) 1 else 0,
            editableMatches = if (candRow.editable) 1 else 0,
            inputTypeMatches = if (candRow.matchesContractInputType == true) 1 else 0,
            sameAsServiceMatches = if (sameAsService) 1 else 0,
        )
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
            telemetrySummary = singleSummary,
            inspectedNodes = listOf(candRow),
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
        val name = candViewId ?: throw MissingIdUnavailable(
            phase = phase,
            source = "candidate_node_unnamed",
            contractDiag = contractDiag(),
            nodeTelemetry = NodeTelemetrySnapshot(sfTelemetryWithField, singleSummary, listOf(candRow)),
        )
        if (name != fieldName) throw Unavailable("different_id")
        if (root.findNodesByViewId(name).singleOrNull() != candidate) throw Unavailable("ambiguous_id")
        if (!candBoundsInWindow) throw Unavailable("invalid_bounds")
        return ResolvedFocus(
            focus = EditorFocus(candidate, window.id, name, candBounds, candRow.editable, candFocused),
            usedWindowField = true,
            filteredAmbiguous = false,
        )
    }

    // 多命中（matches.size >= 2）：全量刷新并优先做同窗同包敏感 fail-closed 检查，再按可见且窗内有效子集筛选。
    val scan = checkNotNull(fieldScan)
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
            telemetrySummary = scan.telemetrySummary,
            inspectedNodes = scan.inspectedNodes,
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
        telemetrySummary = scan.telemetrySummary,
        inspectedNodes = scan.inspectedNodes,
    )
    val rootFocus = getRootFocus()
    if (!isFallbackRootFocusAllowed(sf, candidate, rootFocus)) {
        val check = if (sameAsService) checkNotNull(sfFailureCheck) else "root_focus_mismatch"
        missingField(check, wf)
    }
    val secondScan = scanMultiMatches(
        nodes = root.findNodesByViewId(fieldName),
        windowId = window.id,
        pkg = pkg,
        fieldName = fieldName,
        windowBounds = windowBounds,
        sfNode = sf.node,
        contractInputType = contractInputType,
    )
    if (secondScan.usable.singleOrNull()?.node != candidate) throw Unavailable("ambiguous_id")
    return ResolvedFocus(
        focus = EditorFocus(candidate, window.id, fieldName, picked.bounds, picked.editable, picked.focused),
        usedWindowField = true,
        filteredAmbiguous = true,
    )
}

/**
 * Pathway 4B 独立只读节点扫描（供 Pathway 4A 组合探针复用）：
 * 不以无障碍焦点可用为前提，直接采集 `sfNode` 与 `findNodesByViewId(fieldName)` 全量无短路遥测；
 * 遇到密码或无障碍敏感节点立即返回 [A11yNodeDiagnosticResult.SensitiveField]（fail-closed）。
 */
internal fun inspectA11yNodesForDiagnostic(
    clearCache: () -> Boolean,
    activeRoot: () -> EditorFocusRoot?,
    serviceFocus: () -> EditorFocusNode?,
    resourceName: (String, Int) -> ResourceNameResult,
    pkg: String,
    contract: ImeEditorContract?,
): A11yNodeDiagnosticResult {
    return try {
        if (!clearCache()) return A11yNodeDiagnosticResult.Unavailable("cache_clear_failed")
        val root = activeRoot() ?: return A11yNodeDiagnosticResult.Unavailable("active_root_missing")
        val window = root.window() ?: return A11yNodeDiagnosticResult.Unavailable("active_window_missing")
        if (!window.isApplicationType || root.packageName != pkg) {
            return A11yNodeDiagnosticResult.Unavailable("window_mismatch")
        }
        val windowBounds = window.boundsInScreen()
        val contractInputType = contract?.inputType
        val classified = classifyContractField(resourceName, pkg, contract)
        val fieldName = (classified.lookupResult as? WindowFieldNameResult.Found)?.name

        val sfNode = serviceFocus()
        val sfRow = if (sfNode != null && sfNode.refresh()) {
            val sameWindow = sfNode.windowId == window.id
            val samePackage = sfNode.packageName == pkg
            val sensitive = sfNode.isPassword || sfNode.isAccessibilityDataSensitive
            if (sameWindow && samePackage && sensitive) return A11yNodeDiagnosticResult.SensitiveField
            if (!sensitive) {
                inspectNodeTelemetryRow(
                    node = sfNode,
                    windowBounds = windowBounds,
                    sameAsService = true,
                    sameWindow = sameWindow,
                    samePackage = samePackage,
                    fieldName = fieldName,
                    contractInputType = contractInputType,
                )
            } else {
                null
            }
        } else {
            null
        }

        if (fieldName == null) {
            return A11yNodeDiagnosticResult.Ready(NodeTelemetrySnapshot(sfRow, null, emptyList()))
        }
        val matches = root.findNodesByViewId(fieldName)
        val scan = scanMultiMatches(
            nodes = matches,
            windowId = window.id,
            pkg = pkg,
            fieldName = fieldName,
            windowBounds = windowBounds,
            readAnonymousPair = false,
            sfNode = sfNode,
            contractInputType = contractInputType,
        )
        A11yNodeDiagnosticResult.Ready(
            NodeTelemetrySnapshot(
                serviceFocus = sfRow,
                fieldMatchSummary = scan.telemetrySummary,
                fieldMatches = scan.inspectedNodes,
            ),
        )
    } catch (e: Unavailable) {
        if (e.reason == "sensitive_field") A11yNodeDiagnosticResult.SensitiveField
        else A11yNodeDiagnosticResult.Unavailable(e.reason)
    } catch (_: SecurityException) {
        A11yNodeDiagnosticResult.Unavailable("access_denied")
    }
}

/** 必须用 data class 把 equals/hashCode 委托给底层 AccessibilityNodeInfo，避免跨次 Binder 对象引用不等。 */
internal data class AndroidFocusNode(private val raw: AccessibilityNodeInfo) : EditorFocusNode {
    override val isFocused: Boolean get() = raw.isFocused
    override val isVisibleToUser: Boolean get() = raw.isVisibleToUser
    override val windowId: Int get() = raw.windowId
    override val packageName: String? get() = raw.packageName?.toString()
    override val isPassword: Boolean get() = raw.isPassword
    override val isAccessibilityDataSensitive: Boolean
        get() = Build.VERSION.SDK_INT >= 34 && raw.isAccessibilityDataSensitive
    override val viewIdResourceName: String? get() = raw.viewIdResourceName
    override val isEditable: Boolean get() = raw.isEditable
    override val inputType: Int get() = raw.inputType
    override val className: String? get() = raw.className?.toString()
    override fun refresh(): Boolean = raw.refresh()
    override fun boundsInScreen(): IntBounds = Rect().also(raw::getBoundsInScreen).let {
        IntBounds(it.left, it.top, it.right, it.bottom)
    }
}

internal class AndroidFocusWindow(private val raw: AccessibilityWindowInfo) : EditorFocusWindow {
    override val id: Int get() = raw.id
    override val isApplicationType: Boolean get() = raw.type == AccessibilityWindowInfo.TYPE_APPLICATION
    override val isActive: Boolean get() = raw.isActive
    override val isFocused: Boolean get() = raw.isFocused
    override fun boundsInScreen(): IntBounds = Rect().also(raw::getBoundsInScreen).let {
        IntBounds(it.left, it.top, it.right, it.bottom)
    }
}

internal class AndroidFocusRoot(private val raw: AccessibilityNodeInfo) : EditorFocusRoot {
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
    override val isLandscape: Boolean get() = service.resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE
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

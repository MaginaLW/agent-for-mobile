package dev.magina.gateway.tools

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

private class Unavailable(val reason: String) : Exception(reason)
private class FocusUnavailable(val phase: String, val check: String) : Exception()

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
        val (before, usedFieldBefore) = currentFocus(env, pkg, "before_sample")
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
        val (after, usedFieldAfter) = currentFocus(env, pkg, "after_sample")
        if (before != after || env.foregroundPackage() != pkg || !env.isGatewayImeSelected() || env.session() != session) {
            return unavailable("context_changed")
        }
        if (imeName != after.resourceName) return unavailable("different_id")
        if (!after.bounds.matchesFloat(sample.bounds)) return unavailable("different_bounds")
        val bounds = JSONObject().put("window_id", after.windowId)
            .put("session_id", session.id).put("editable", after.editable)
            .put("left", after.bounds.left).put("top", after.bounds.top)
            .put("right", after.bounds.right).put("bottom", after.bounds.bottom)
        if (usedFieldBefore || usedFieldAfter) {
            bounds.put("window_field_phase", when {
                !usedFieldAfter -> "before_sample"
                !usedFieldBefore -> "after_sample"
                else -> "both"
            })
        }
        if (!after.focused) {
            bounds.put("node_focused", false)
        }
        state.put("ime_editor_bounds", bounds)
    } catch (e: FocusUnavailable) {
        unavailable("focus_unavailable")
            .put("ime_editor_focus_phase", e.phase)
            .put("ime_editor_focus_check", e.check)
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

private fun resolveWindowFieldName(env: EditorBoundsEnvironment, pkg: String): String {
    val contract = env.editorContract() ?: throw Unavailable("missing_id")
    when (contract.inputType and (InputType.TYPE_MASK_CLASS or InputType.TYPE_MASK_VARIATION)) {
        InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD,
        InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD,
        InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD,
        InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_VARIATION_PASSWORD -> throw Unavailable("sensitive_field")
    }
    val id = contract.fieldId
    if (id == 0 || id == -1) throw Unavailable("missing_id")
    val name = requireResourceName(env, pkg, id)
    if (!name.substringAfter(':', "").startsWith("id/")) throw Unavailable("missing_id")
    return name
}

private fun currentFocus(env: EditorBoundsEnvironment, pkg: String, phase: String): Pair<EditorFocus, Boolean> {
    fun missing(check: String): Nothing = throw FocusUnavailable(phase, check)
    if (!env.clearCache()) missing("cache_clear_failed")
    val root = env.activeRoot() ?: missing("active_root_missing")
    val window = root.window() ?: missing("active_window_missing")
    if (!window.isApplicationType || !window.isActive || !window.isFocused || root.packageName != pkg) {
        throw Unavailable("window_mismatch")
    }
    val serviceFocus = env.serviceFocus()
    val fieldName = if (serviceFocus == null) resolveWindowFieldName(env, pkg) else null
    val node = serviceFocus ?: run {
        val matches = root.findNodesByViewId(checkNotNull(fieldName))
        if (matches.isEmpty()) missing("input_focus_missing")
        matches.singleOrNull() ?: throw Unavailable("ambiguous_id")
    }
    if (!node.refresh()) missing("node_refresh_failed")
    val focused = node.isFocused
    if (!node.isVisibleToUser) missing("node_not_visible")
    if (node.windowId != window.id) missing("node_window_mismatch")
    if (node.packageName != pkg) missing("node_package_mismatch")
    val rootFocus = root.findInputFocus()
    // 服务级焦点非空时要求活动根焦点指向同一节点；按窗口字段查找时允许根焦点为空或指向本节点，指向他节点一律拒绝。
    if (rootFocus != node && (serviceFocus != null || rootFocus != null)) missing("root_focus_mismatch")
    if (node.isPassword || node.isAccessibilityDataSensitive) throw Unavailable("sensitive_field")
    val expectedFieldName = fieldName ?: if (!focused) resolveWindowFieldName(env, pkg) else null
    val name = node.viewIdResourceName?.takeIf { it.isNotBlank() } ?: throw Unavailable("missing_id")
    if (expectedFieldName != null && expectedFieldName != name) throw Unavailable("different_id")
    if (root.findNodesByViewId(name).singleOrNull() != node) throw Unavailable("ambiguous_id")
    val bounds = node.boundsInScreen()
    if (bounds.isEmpty || !window.boundsInScreen().contains(bounds)) throw Unavailable("invalid_bounds")
    return EditorFocus(node, window.id, name, bounds, node.isEditable, focused) to (serviceFocus == null)
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

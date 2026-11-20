package dev.magina.gateway.tools

import android.content.ComponentName
import android.content.pm.PackageManager
import android.content.res.Resources
import android.graphics.Rect
import android.graphics.RectF
import android.os.Build
import android.os.Looper
import android.provider.Settings
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import androidx.annotation.RequiresApi
import dev.magina.gateway.Gateway
import dev.magina.gateway.a11y.GatewayA11yService
import dev.magina.gateway.core.ensureTargetPackageAllowed
import dev.magina.gateway.ime.GatewayIme
import dev.magina.gateway.ime.ImeBridge
import org.json.JSONObject
import java.util.concurrent.ExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

private data class EditorFocus(
    val node: AccessibilityNodeInfo,
    val windowId: Int,
    val resourceName: String,
    val bounds: Rect,
    val editable: Boolean,
)

private class Unavailable(val reason: String) : Exception(reason)
private class FocusUnavailable(val phase: String, val check: String) : Exception()

/** 只读回执。即使两份独立测量一致，也不生成操作引用或输入身份。 */
internal fun readEditorBounds(service: GatewayA11yService, state: JSONObject): JSONObject {
    fun unavailable(reason: String) =
        state.put("ime_editor_bounds", JSONObject.NULL).put("ime_editor_bounds_reason", reason)

    if (Build.VERSION.SDK_INT < 34) return unavailable("unsupported_api")
    val session = ImeBridge.session() ?: return unavailable("no_input_target")
    val pkg = service.foregroundPackage()
    if (pkg.isBlank() || !session.belongsTo(pkg)) return unavailable("no_input_target")
    ensureTargetPackageAllowed(pkg, Gateway.skills::isBlockedApp)
    check(Looper.myLooper() != Looper.getMainLooper())
    val gatewayIme = ComponentName(service, GatewayIme::class.java)
    fun selectedIme() = Settings.Secure.getString(service.contentResolver, Settings.Secure.DEFAULT_INPUT_METHOD)
        ?.let(ComponentName::unflattenFromString)
    return try {
        if (selectedIme() != gatewayIme) return unavailable("no_input_target")
        val before = currentFocus(service, pkg, "before_sample")
        val request = ImeBridge.requestEditorBounds(session, service.mainExecutor)
        val sample = try {
            request.get(2, TimeUnit.SECONDS)
        } catch (_: TimeoutException) {
            request.cancel(false)
            return unavailable("timeout")
        } catch (_: InterruptedException) {
            request.cancel(false)
            Thread.currentThread().interrupt()
            return unavailable("interrupted")
        }
        if (ImeBridge.session() != session || service.foregroundPackage() != pkg) return unavailable("context_changed")
        if (sample == null) return unavailable("no_ime_bounds")
        val imeName = service.packageManager.getResourcesForApplication(pkg).getResourceName(sample.fieldId)
        val after = currentFocus(service, pkg, "after_sample")
        if (before != after || service.foregroundPackage() != pkg || selectedIme() != gatewayIme || ImeBridge.session() != session) {
            return unavailable("context_changed")
        }
        if (imeName != after.resourceName) return unavailable("different_id")
        if (RectF(after.bounds) != sample.bounds) return unavailable("different_bounds")
        state.put("ime_editor_bounds", JSONObject().put("window_id", after.windowId)
            .put("session_id", session.id).put("editable", after.editable)
            .put("left", after.bounds.left).put("top", after.bounds.top)
            .put("right", after.bounds.right).put("bottom", after.bounds.bottom))
    } catch (e: FocusUnavailable) {
        unavailable("focus_unavailable")
            .put("ime_editor_focus_phase", e.phase)
            .put("ime_editor_focus_check", e.check)
    } catch (e: Unavailable) {
        unavailable(e.reason)
    } catch (_: PackageManager.NameNotFoundException) {
        unavailable("resources_unavailable")
    } catch (_: Resources.NotFoundException) {
        unavailable("missing_id")
    } catch (_: SecurityException) {
        unavailable("access_denied")
    } catch (_: ExecutionException) {
        unavailable("request_failed")
    }
}

@RequiresApi(34)
private fun currentFocus(service: GatewayA11yService, pkg: String, phase: String): EditorFocus {
    fun missing(check: String): Nothing = throw FocusUnavailable(phase, check)
    if (!service.clearCache()) missing("cache_clear_failed")
    val root = service.getRootInActiveWindow(0) ?: missing("active_root_missing")
    val window = root.window ?: missing("active_window_missing")
    if (window.type != AccessibilityWindowInfo.TYPE_APPLICATION || !window.isActive ||
        !window.isFocused || root.packageName?.toString() != pkg) throw Unavailable("window_mismatch")
    val node = service.focusedEditable() ?: missing("input_focus_missing")
    if (!node.refresh()) missing("node_refresh_failed")
    if (!node.isFocused) missing("node_not_focused")
    if (!node.isVisibleToUser) missing("node_not_visible")
    if (node.windowId != window.id) missing("node_window_mismatch")
    if (node.packageName?.toString() != pkg) missing("node_package_mismatch")
    if (root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT) != node) missing("root_focus_mismatch")
    if (node.isPassword || node.isAccessibilityDataSensitive) throw Unavailable("sensitive_field")
    val name = node.viewIdResourceName?.takeIf { it.isNotBlank() } ?: throw Unavailable("missing_id")
    if (root.findAccessibilityNodeInfosByViewId(name).singleOrNull() != node) throw Unavailable("ambiguous_id")
    val bounds = Rect().also(node::getBoundsInScreen)
    if (bounds.isEmpty || !Rect().also(window::getBoundsInScreen).contains(bounds)) throw Unavailable("invalid_bounds")
    return EditorFocus(node, window.id, name, bounds, node.isEditable)
}

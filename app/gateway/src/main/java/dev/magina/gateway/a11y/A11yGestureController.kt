package dev.magina.gateway.a11y

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.graphics.Rect
import android.view.accessibility.AccessibilityNodeInfo
import dev.magina.gateway.core.ErrorCode
import dev.magina.gateway.core.GatewayError
import org.json.JSONObject
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit

/**
 * 无障碍坐标手势与节点动作辅助（拆自 GatewayA11yService）。
 */
internal class A11yGestureController(
    private val service: AccessibilityService,
    private val onGestureCompleted: () -> Unit,
) {

    fun performOcrGesture(
        target: GatewayA11yService.Target,
        action: String,
        params: JSONObject,
        gestureScrollBounds: () -> Rect,
        currentRevision: () -> Long,
    ): JSONObject {
        val ok = when (action) {
            "click" -> tapGesture(target.bounds.exactCenterX(), target.bounds.exactCenterY())
            "long_click" -> tapGesture(target.bounds.exactCenterX(), target.bounds.exactCenterY(), 700L)
            "scroll" -> gestureScroll(gestureScrollBounds(), params.optString("direction", "forward") != "backward")
            else -> throw GatewayError(
                ErrorCode.E_INVALID_ARG, "OCR 元素仅支持 click/long_click/scroll（无 a11y 节点通道）",
                fallback = "输入用 type_text(ref=本元素)；其余动作先 ui_snapshot 找 a11y 元素",
            )
        }
        if (!ok) throw GatewayError(
            ErrorCode.E_VERIFY_FAIL, "坐标手势 $action 派发失败", channel = "vision", retryable = true,
            fallback = "重试一次；仍失败 screen_capture(reason=layout_changed) 复核",
        )
        return JSONObject().put("done", true).put("revision_after", currentRevision())
    }

    /**
     * 点击：
     * - 开关/勾选类（isCheckable，如 vivo 系统设置的蓝牙/WiFi Switch）用坐标手势点 bounds 中心。
     * - 其余节点自身不可点时向上找最近可点祖先 → ACTION_CLICK。
     */
    fun clickNode(node: AccessibilityNodeInfo, bounds: Rect): Boolean {
        if (node.isCheckable) {
            val x = if (bounds.width() > bounds.height() * 2) {
                bounds.right - bounds.height() / 2f
            } else {
                bounds.exactCenterX()
            }
            return tapGesture(x, bounds.exactCenterY())
        }
        var n: AccessibilityNodeInfo? = node
        var hops = 0
        while (n != null && hops < 5) {
            if (n.isClickable) return n.performAction(AccessibilityNodeInfo.ACTION_CLICK)
            n = n.parent; hops++
        }
        return node.performAction(AccessibilityNodeInfo.ACTION_CLICK)
    }

    fun tapGesture(
        cx: Float,
        cy: Float,
        durationMs: Long = 60L,
        preDispatch: () -> Unit = {},
    ): Boolean {
        val path = Path().apply { moveTo(cx, cy) }
        return dispatchStroke(path, durationMs, preDispatch)
    }

    fun gestureScroll(bounds: Rect, forward: Boolean): Boolean {
        val cx = bounds.exactCenterX()
        val y1 = bounds.top + bounds.height() * (if (forward) 0.62f else 0.38f)
        val y2 = bounds.top + bounds.height() * (if (forward) 0.38f else 0.62f)
        val path = Path().apply { moveTo(cx, y1); lineTo(cx, y2) }
        return dispatchStroke(path, 400L)
    }

    private fun dispatchStroke(path: Path, durationMs: Long, preDispatch: () -> Unit = {}): Boolean {
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0L, durationMs))
            .build()
        val done = CompletableFuture<Boolean>()
        preDispatch()
        val dispatched = service.dispatchGesture(
            gesture,
            object : AccessibilityService.GestureResultCallback() {
                override fun onCompleted(d: GestureDescription?) { done.complete(true) }
                override fun onCancelled(d: GestureDescription?) { done.complete(false) }
            },
            null,
        )
        if (!dispatched) return false
        val ok = runCatching { done.get(2, TimeUnit.SECONDS) }.getOrDefault(false)
        if (ok) onGestureCompleted()
        return ok
    }

    fun scrollable(node: AccessibilityNodeInfo): AccessibilityNodeInfo {
        var n: AccessibilityNodeInfo? = node
        var hops = 0
        while (n != null && hops < 8) {
            if (n.isScrollable) return n
            n = n.parent; hops++
        }
        return node
    }
}

package dev.magina.gateway.a11y

import android.graphics.Rect
import android.view.accessibility.AccessibilityNodeInfo

/** Accessibility node 身份 producer；与 IME session id 是两个独立命名空间。 */
internal object FocusedInputIdentity {
    fun fromRefreshedNode(node: AccessibilityNodeInfo): String {
        val bounds = Rect().also { node.getBoundsInScreen(it) }
        return compose(
            windowId = node.windowId,
            viewId = node.viewIdResourceName.orEmpty(),
            className = node.className?.toString().orEmpty(),
            packageName = node.packageName?.toString().orEmpty(),
            left = bounds.left,
            top = bounds.top,
            right = bounds.right,
            bottom = bounds.bottom,
        )
    }

    fun compose(
        windowId: Int,
        viewId: String,
        className: String,
        packageName: String,
        left: Int,
        top: Int,
        right: Int,
        bottom: Int,
    ): String = listOf(
        windowId.toString(),
        viewId,
        className,
        packageName,
        "$left,$top,$right,$bottom",
    ).joinToString("|")
}

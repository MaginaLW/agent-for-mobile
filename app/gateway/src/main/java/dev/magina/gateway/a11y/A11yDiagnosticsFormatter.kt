package dev.magina.gateway.a11y

import android.graphics.Rect
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import org.json.JSONArray
import org.json.JSONObject

/**
 * 无障碍窗口/节点诊断格式化与节点语义属性映射（拆自 GatewayA11yService）。
 */
internal object A11yDiagnosticsFormatter {

    fun identitySourceName(resolved: ResolvedForeground): String = when {
        !resolved.known -> "unknown"
        resolved.bootstrapped -> "bootstrap"
        else -> "event"
    }

    fun windowTypeName(type: Int): String = when (type) {
        AccessibilityWindowInfo.TYPE_APPLICATION -> "application"
        AccessibilityWindowInfo.TYPE_INPUT_METHOD -> "input_method"
        AccessibilityWindowInfo.TYPE_SYSTEM -> "system"
        AccessibilityWindowInfo.TYPE_ACCESSIBILITY_OVERLAY -> "a11y_overlay"
        AccessibilityWindowInfo.TYPE_SPLIT_SCREEN_DIVIDER -> "split_divider"
        else -> "other_$type"
    }

    fun roleOf(n: AccessibilityNodeInfo): String {
        val cls = n.className?.toString().orEmpty()
        return when {
            n.isEditable -> "input"
            n.isCheckable -> "switch"
            n.isScrollable -> "list"
            n.isClickable && cls.contains("Image") -> "icon_button"
            n.isClickable -> "button"
            cls.contains("TextView") -> "text"
            else -> cls.substringAfterLast('.').ifEmpty { "node" }
        }
    }

    fun flagsOf(n: AccessibilityNodeInfo): String = buildString {
        if (n.isClickable) append("C")
        if (n.isLongClickable) append("L")
        if (n.isEditable) append("E")
        if (n.isScrollable) append("S")
        if (n.isCheckable) append("K")
        if (n.isChecked) append("k")
        if (n.isFocused) append("F")
        if (!n.isEnabled) append("x")
    }

    fun buildForegroundDiagnosticsJson(
        currentWindows: List<AccessibilityWindowInfo>,
        selected: AccessibilityWindowInfo?,
        topology: WindowTopology,
        resolved: ResolvedForeground,
        identity: ForegroundIdentity,
        recentEvents: List<ForegroundEventRecord>,
        revision: Long,
        nowMs: Long = System.currentTimeMillis(),
    ): JSONObject {
        val windowsJson = JSONArray()
        for (window in currentWindows) {
            val b = Rect().also(window::getBoundsInScreen)
            windowsJson.put(
                JSONObject()
                    .put("id", window.id)
                    .put("type", windowTypeName(window.type))
                    .put("active", window.isActive)
                    .put("focused", window.isFocused)
                    .put("root_package", runCatching { window.root?.packageName?.toString() }.getOrNull() ?: JSONObject.NULL)
                    .put("title", window.title?.toString().orEmpty())
                    .put("bounds", JSONArray(listOf(b.left, b.top, b.right, b.bottom))),
            )
        }
        val eventsJson = JSONArray()
        for (record in recentEvents) {
            eventsJson.put(
                JSONObject()
                    .put("seq", record.seq)
                    .put("at_ms", record.atMillis)
                    .put("kind", record.kind)
                    .put("window_id", record.eventWindowId)
                    .put("package", record.packageName)
                    .put("activity", record.activityName)
                    .put("decision", record.decision.name.lowercase())
                    .put("selected_window_id", record.selectedApplicationWindowId ?: JSONObject.NULL)
                    .put(
                        "windows",
                        record.windows.joinToString(",") {
                            "${it.id}:${it.type.name}:${if (it.isActive) "a" else "-"}${if (it.isFocused) "f" else "-"}"
                        },
                    ),
            )
        }
        return JSONObject()
            .put("package", resolved.packageName)
            .put("activity", resolved.activityName)
            .put("foreground_known", resolved.known)
            .put("foreground_reason", resolved.reason.name.lowercase())
            .put("foreground_identity_source", identitySourceName(resolved))
            .put("window_topology", topology.wireName)
            .put("selected_window_id", selected?.id ?: JSONObject.NULL)
            .put(
                "tracked_identity",
                (identity as? ForegroundIdentity.Known)?.let {
                    JSONObject()
                        .put("window_id", it.windowId)
                        .put("package", it.packageName)
                        .put("activity", it.activityName)
                        .put("bootstrapped", it.bootstrapped)
                } ?: JSONObject.NULL,
            )
            .put("now_ms", nowMs)
            .put("revision", revision)
            .put("windows", windowsJson)
            .put("recent_events", eventsJson)
    }
}

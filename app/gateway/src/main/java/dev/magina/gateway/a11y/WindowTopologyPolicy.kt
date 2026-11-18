package dev.magina.gateway.a11y

/** 参与窗口拓扑判定的 TYPE_APPLICATION 窗口摘要；纯值类型以支撑 JVM 离线单测。 */
internal data class AppWindowSlice(
    val windowId: Int,
    val rootPackage: String?,
    val left: Int,
    val top: Int,
    val right: Int,
    val bottom: Int,
) {
    val width: Int get() = (right - left).coerceAtLeast(0)
    val height: Int get() = (bottom - top).coerceAtLeast(0)
    val hasPositiveArea: Boolean get() = width > 0 && height > 0
    val centerX: Int get() = left + (right - left) / 2
    val centerY: Int get() = top + (bottom - top) / 2

    fun contains(x: Int, y: Int): Boolean =
        hasPositiveArea && x in left until right && y in top until bottom
}

internal enum class WindowTopology(val wireName: String) {
    NONE("none"),
    SINGLE("single"),
    SAME_APP_MULTI("same_app_multi"),
    CROSS_OR_UNKNOWN_MULTI("cross_or_unknown_multi"),
}

private const val MULTI_PANE_CENTER_SPREAD_THRESHOLD_PX = 80

internal fun classifyWindowTopology(slices: List<AppWindowSlice>): WindowTopology {
    val visible = slices.filter { it.hasPositiveArea }
    if (visible.isEmpty()) return WindowTopology.NONE
    if (visible.size == 1) return WindowTopology.SINGLE

    val packages = visible.map { it.rootPackage?.trim().orEmpty() }
    if (packages.any { it.isEmpty() }) return WindowTopology.CROSS_OR_UNKNOWN_MULTI
    return if (packages.distinct().size == 1) {
        WindowTopology.SAME_APP_MULTI
    } else {
        WindowTopology.CROSS_OR_UNKNOWN_MULTI
    }
}

internal fun assignWindowPanes(slices: List<AppWindowSlice>): Map<Int, String> {
    val visible = slices.filter { it.hasPositiveArea }
    if (visible.isEmpty()) return emptyMap()
    if (visible.size == 1) return mapOf(visible.single().windowId to "full")

    val xSpread = visible.maxOf { it.centerX } - visible.minOf { it.centerX }
    val ySpread = visible.maxOf { it.centerY } - visible.minOf { it.centerY }
    if (maxOf(xSpread, ySpread) < MULTI_PANE_CENTER_SPREAD_THRESHOLD_PX) {
        return visible.associate { it.windowId to "full" }
    }

    val horizontal = xSpread >= ySpread
    val sorted = if (horizontal) {
        visible.sortedWith(compareBy<AppWindowSlice> { it.centerX }.thenBy { it.windowId })
    } else {
        visible.sortedWith(compareBy<AppWindowSlice> { it.centerY }.thenBy { it.windowId })
    }
    val last = sorted.lastIndex
    return sorted.mapIndexed { index, slice ->
        val pane = when {
            index == 0 -> if (horizontal) "left" else "top"
            index == last -> if (horizontal) "right" else "bottom"
            else -> "middle"
        }
        slice.windowId to pane
    }.toMap()
}

internal fun matchSliceForPoint(
    slices: List<AppWindowSlice>,
    x: Int,
    y: Int,
): AppWindowSlice? = slices
    .filter { it.contains(x, y) }
    .minWithOrNull(
        compareBy<AppWindowSlice> { it.width.toLong() * it.height.toLong() }
            .thenBy { it.windowId },
    )

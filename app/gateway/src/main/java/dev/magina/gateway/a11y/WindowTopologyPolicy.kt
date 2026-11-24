package dev.magina.gateway.a11y

import dev.magina.gateway.core.ErrorCode
import dev.magina.gateway.core.GatewayError

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
internal const val TRANSIENT_MULTI_WINDOW_MAX_REREADS = 4
internal const val TRANSIENT_MULTI_WINDOW_REREAD_INTERVAL_MS = 80L

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

/**
 * 仅当拓扑为 [WindowTopology.CROSS_OR_UNKNOWN_MULTI]、至少一个可见窗口切片 `rootPackage` 为空/空白，
 * 且所有非空 `rootPackage` 全部属于同一个应用时返回 true。
 * 一旦出现两个及以上不同非空包名（或全为空白），立即返回 false（零等待 fail-closed）。
 */
internal fun isTransientUnknownMultiWindow(slices: List<AppWindowSlice>): Boolean {
    if (classifyWindowTopology(slices) != WindowTopology.CROSS_OR_UNKNOWN_MULTI) return false
    val visiblePackages = slices
        .filter { it.hasPositiveArea }
        .map { it.rootPackage?.trim().orEmpty() }
    if (visiblePackages.none { it.isEmpty() }) return false
    return visiblePackages.filter { it.isNotEmpty() }.distinct().size == 1
}

internal data class SettledSnapshotWindows<W>(
    val windows: List<W>,
    val slices: List<AppWindowSlice>,
    val topology: WindowTopology,
)

/**
 * 仅针对 [isTransientUnknownMultiWindow] 做有限短重读（只重读、不放宽任何多窗安全判据）；
 * 重读后若仍为 [WindowTopology.CROSS_OR_UNKNOWN_MULTI] 仍严格抛出原 [ErrorCode.E_BLOCKED]。
 */
internal fun <W> settleSnapshotWindows(
    readWindows: () -> List<W>,
    extractSlices: (List<W>) -> List<AppWindowSlice>,
    sleep: (Long) -> Unit,
    maxRereads: Int = TRANSIENT_MULTI_WINDOW_MAX_REREADS,
    intervalMs: Long = TRANSIENT_MULTI_WINDOW_REREAD_INTERVAL_MS,
): SettledSnapshotWindows<W> {
    var currentWindows = readWindows()
    var appSlices = extractSlices(currentWindows)
    var rereads = 0
    while (isTransientUnknownMultiWindow(appSlices) && rereads < maxRereads) {
        sleep(intervalMs)
        rereads += 1
        currentWindows = readWindows()
        appSlices = extractSlices(currentWindows)
    }
    val topology = classifyWindowTopology(appSlices)
    if (topology == WindowTopology.CROSS_OR_UNKNOWN_MULTI) {
        throw GatewayError(
            ErrorCode.E_BLOCKED,
            "检测到跨应用或归属未知的多窗口（分屏/悬浮窗），已拒绝混采快照",
            channel = "a11y",
            fallback = "关闭无关分屏或悬浮小窗，保留单应用全屏或同应用平行视界后重试",
        )
    }
    return SettledSnapshotWindows(currentWindows, appSlices, topology)
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

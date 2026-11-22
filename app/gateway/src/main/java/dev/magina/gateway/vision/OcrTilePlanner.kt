package dev.magina.gateway.vision

import dev.magina.gateway.a11y.AppWindowSlice
import dev.magina.gateway.a11y.WindowTopology

/** 大屏多窗触发分窗切片 OCR 的长边阈值；小屏/普通手机 ≤1600px 保持原整屏路径。 */
internal const val TILED_OCR_MIN_LONG_EDGE_PX = 1600

/** 单窗有效高度超过该值（如隐键盘 1968px）时沿垂直中线对半切两片，确保每片处于 ML Kit 原生分辨率带。 */
internal const val TILED_OCR_MAX_TILE_HEIGHT_PX = 1400

/** 垂直切缝处的上下重叠余量，避免文字行被腰斩；归属带严格互不相交，杜绝缝间重复。 */
internal const val TILED_OCR_OVERLAP_PX = 80

/** 供 ML Kit 处理的切片最小边长（低于 32px ML Kit 会抛异常）。 */
internal const val TILED_OCR_MIN_EDGE_PX = 32

internal data class TileRect(
    val left: Int,
    val top: Int,
    val right: Int,
    val bottom: Int,
) {
    val width: Int get() = (right - left).coerceAtLeast(0)
    val height: Int get() = (bottom - top).coerceAtLeast(0)
    val centerX: Int get() = (left + right) / 2
    val centerY: Int get() = (top + bottom) / 2
}

internal data class OcrTile(
    val windowId: Int,
    val crop: TileRect,
    val ownTop: Int,
    val ownBottom: Int,
    val ownBottomInclusive: Boolean,
) {
    fun ownsCenterY(screenCenterY: Int): Boolean =
        if (ownBottomInclusive) screenCenterY in ownTop..ownBottom
        else screenCenterY >= ownTop && screenCenterY < ownBottom
}

internal data class TileOcrLine(
    val text: String,
    val conf: Float,
    val bounds: TileRect,
)

/**
 * 逐窗判定稀疏性：在 `SAME_APP_MULTI` 下返回前景可读节点数 `< threshold` 的应用窗口 ID 集合，
 * 避免右窗（如 Flutter 页面 ≥5 节点）把左侧稀疏 `LauncherUI` 窗格的 OCR 融合抑制掉。
 */
internal fun sparseWindowIds(
    slices: List<AppWindowSlice>,
    fgCountByWin: Map<Int, Int>,
    threshold: Int,
): Set<Int> = slices
    .filter { it.hasPositiveArea && (fgCountByWin[it.windowId] ?: 0) < threshold }
    .map { it.windowId }
    .toSet()

/**
 * 为大屏 `SAME_APP_MULTI`（如 PA2553 2800×1968 平行视界）生成分窗切片计划：
 * - 单窗（`SINGLE`）或小屏（`max(fullWidth, fullHeight) <= 1600`）返回空列表，100% 沿用既有整屏路径；
 * - 每个稀疏窗格先裁剪到 `[0, 0, fullWidth, min(fullHeight, imeTop)]`：
 *   - 裁后高度 `<= 1400`：单窗 1 片（`ownBottomInclusive = true`）；
 *   - 裁后高度 `> 1400`：以 `midY = top + height / 2` 上下各留 `80px` 重叠切为上下 2 片，
 *     归属带严格不相交：`[top, midY)` 与 `[midY, bottom]`。
 */
internal fun planOcrTiles(
    topology: WindowTopology,
    sparseSlices: List<AppWindowSlice>,
    fullWidth: Int,
    fullHeight: Int,
    imeTop: Int,
): List<OcrTile> {
    if (topology != WindowTopology.SAME_APP_MULTI) return emptyList()
    if (fullWidth <= 0 || fullHeight <= 0) return emptyList()
    if (maxOf(fullWidth, fullHeight) <= TILED_OCR_MIN_LONG_EDGE_PX) return emptyList()
    val visibleBottom = if (imeTop in 1 until fullHeight) imeTop else fullHeight
    if (visibleBottom < TILED_OCR_MIN_EDGE_PX) return emptyList()

    val out = ArrayList<OcrTile>()
    val ordered = sparseSlices
        .filter { it.hasPositiveArea }
        .sortedWith(compareBy<AppWindowSlice> { it.left }.thenBy { it.top }.thenBy { it.windowId })
    for (slice in ordered) {
        val left = slice.left.coerceIn(0, fullWidth)
        val top = slice.top.coerceIn(0, visibleBottom)
        val right = slice.right.coerceIn(left, fullWidth)
        val bottom = slice.bottom.coerceIn(top, visibleBottom)
        val clipped = TileRect(left, top, right, bottom)
        if (clipped.width < TILED_OCR_MIN_EDGE_PX || clipped.height < TILED_OCR_MIN_EDGE_PX) continue

        if (clipped.height <= TILED_OCR_MAX_TILE_HEIGHT_PX) {
            out += OcrTile(
                windowId = slice.windowId,
                crop = clipped,
                ownTop = clipped.top,
                ownBottom = clipped.bottom,
                ownBottomInclusive = true,
            )
        } else {
            val midY = clipped.top + clipped.height / 2
            val topCrop = TileRect(
                left = clipped.left,
                top = clipped.top,
                right = clipped.right,
                bottom = (midY + TILED_OCR_OVERLAP_PX).coerceAtMost(clipped.bottom),
            )
            val bottomCrop = TileRect(
                left = clipped.left,
                top = (midY - TILED_OCR_OVERLAP_PX).coerceAtLeast(clipped.top),
                right = clipped.right,
                bottom = clipped.bottom,
            )
            if (topCrop.height >= TILED_OCR_MIN_EDGE_PX) {
                out += OcrTile(
                    windowId = slice.windowId,
                    crop = topCrop,
                    ownTop = clipped.top,
                    ownBottom = midY,
                    ownBottomInclusive = false,
                )
            }
            if (bottomCrop.height >= TILED_OCR_MIN_EDGE_PX) {
                out += OcrTile(
                    windowId = slice.windowId,
                    crop = bottomCrop,
                    ownTop = midY,
                    ownBottom = clipped.bottom,
                    ownBottomInclusive = true,
                )
            }
        }
    }
    return out
}

/**
 * 将单片识别框以纯整数 `(+crop.left, +crop.top)` 偏移回整屏坐标（零缩放、0px 误差），
 * 并仅保留屏幕 `centerY` 落入本片互不相交归属带内的行，杜绝 `midY` 接缝重复。
 */
internal fun offsetAndFilterTileLines(
    tile: OcrTile,
    tileLines: List<TileOcrLine>,
): List<TileOcrLine> = tileLines.mapNotNull { line ->
    val screenBox = TileRect(
        left = line.bounds.left + tile.crop.left,
        top = line.bounds.top + tile.crop.top,
        right = line.bounds.right + tile.crop.left,
        bottom = line.bounds.bottom + tile.crop.top,
    )
    if (!tile.ownsCenterY(screenBox.centerY)) return@mapNotNull null
    line.copy(bounds = screenBox)
}

/** 供 `ocrCache` 复用的稳定切片签名：拓扑、键盘顶边或稀疏窗格几何任一变化即失效缓存。 */
internal fun buildOcrCacheSignature(
    topology: WindowTopology,
    sparseSlices: List<AppWindowSlice>,
    imeTop: Int,
): String {
    val slicePart = sparseSlices
        .filter { it.hasPositiveArea }
        .sortedWith(compareBy<AppWindowSlice> { it.left }.thenBy { it.top }.thenBy { it.windowId })
        .joinToString(";") { "${it.windowId}:${it.left},${it.top},${it.right},${it.bottom}" }
    return "${topology.wireName}|ime=$imeTop|$slicePart"
}

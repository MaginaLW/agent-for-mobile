package dev.magina.gateway.a11y

import android.graphics.Bitmap
import android.graphics.Rect
import android.os.SystemClock
import android.util.Base64
import dev.magina.gateway.core.ErrorCode
import dev.magina.gateway.core.GatewayError
import dev.magina.gateway.ocr.OcrEngine
import dev.magina.gateway.vision.TileOcrLine
import dev.magina.gateway.vision.TileRect
import dev.magina.gateway.vision.buildOcrCacheSignature
import dev.magina.gateway.vision.offsetAndFilterTileLines
import dev.magina.gateway.vision.planOcrTiles
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream

/**
 * L5 整屏切片 OCR 缓存、区域直读与受控截图编码（拆自 GatewayA11yService）。
 */
internal class A11yOcrCoordinator(
    private val freshVisionSession: FreshVisionSession<Bitmap>,
    private val captureRawBitmap: () -> Bitmap,
    private val captureRetriedBitmap: () -> Bitmap,
    private val currentRevision: () -> Long,
    private val currentImeTop: () -> Int,
    private val currentBottomInset: () -> Int,
    private val displayMetrics: () -> android.util.DisplayMetrics,
) {

    data class OcrShot(
        val revision: Long,
        val at: Long,
        val generation: Long,
        val signature: String,
        val lines: List<OcrEngine.OcrLine>,
    )

    private val ocrCache = FreshVisionCache<OcrShot>()
    @Volatile var forceFreshOcrOnce = false

    fun invalidateCache() {
        ocrCache.invalidate()
    }

    fun conf2(c: Float): Double = Math.round(c * 100.0) / 100.0

    @Synchronized
    fun ocrScreen(
        topology: WindowTopology = WindowTopology.SINGLE,
        sparseSlices: List<AppWindowSlice> = emptyList(),
    ): OcrShot {
        val r = currentRevision()
        val imeTop = currentImeTop()
        val cacheSignature = buildOcrCacheSignature(topology, sparseSlices, imeTop)
        return ocrCache.getOrLoad(
            forceFresh = forceFreshOcrOnce,
            reusable = {
                it.revision == r &&
                    it.signature == cacheSignature &&
                    SystemClock.elapsedRealtime() - it.at < 2_000
            },
            loader = {
                val capture = freshVisionSession.captureForOcr()
                if (capture.revision != r) throw GatewayError(
                    ErrorCode.E_STALE_REF,
                    "OCR 截图与请求 revision 不一致",
                    channel = "vision",
                    retryable = true,
                )
                val full = capture.payload
                val tiles = planOcrTiles(topology, sparseSlices, full.width, full.height, imeTop)
                val lines = if (tiles.isNotEmpty()) {
                    val combined = ArrayList<OcrEngine.OcrLine>()
                    for (tile in tiles) {
                        val tileBmp = Bitmap.createBitmap(
                            full, tile.crop.left, tile.crop.top, tile.crop.width, tile.crop.height,
                        )
                        val rawLines = try {
                            OcrEngine.recognize(tileBmp, OcrEngine.MIN_CONF).map { l ->
                                TileOcrLine(
                                    l.text,
                                    l.conf,
                                    TileRect(l.bounds.left, l.bounds.top, l.bounds.right, l.bounds.bottom),
                                )
                            }
                        } finally {
                            if (tileBmp !== full && !tileBmp.isRecycled) tileBmp.recycle()
                        }
                        offsetAndFilterTileLines(tile, rawLines).forEach { mapped ->
                            combined += OcrEngine.OcrLine(
                                mapped.text,
                                mapped.conf,
                                Rect(mapped.bounds.left, mapped.bounds.top, mapped.bounds.right, mapped.bounds.bottom),
                            )
                        }
                    }
                    combined
                } else {
                    val page = if (imeTop in 1 until full.height)
                        Bitmap.createBitmap(full, 0, 0, full.width, imeTop) else full
                    try {
                        OcrEngine.recognize(page, OcrEngine.MIN_CONF)
                    } finally {
                        if (page !== full && !page.isRecycled) page.recycle()
                    }
                }
                OcrShot(capture.revision, SystemClock.elapsedRealtime(), capture.generation, cacheSignature, lines)
            },
        )
    }

    private fun ocrReadRegionOf(full: Bitmap, r: Rect): String? {
        if (r.width() <= 0 || r.height() <= 0) return null
        val clipped = Rect(
            r.left.coerceAtLeast(0), r.top.coerceAtLeast(0),
            r.right.coerceAtMost(full.width), r.bottom.coerceAtMost(full.height),
        )
        if (clipped.width() <= 0 || clipped.height() <= 0) return null
        val piece = Bitmap.createBitmap(full, clipped.left, clipped.top, clipped.width(), clipped.height())
        val lines = OcrEngine.recognize(piece, 0.25f)
        if (lines.isEmpty()) return null
        return lines.sortedWith(compareBy({ it.bounds.top }, { it.bounds.left }))
            .joinToString(" ") { it.text }
    }

    fun ocrReadRegion(bounds: Rect): String? {
        val full = captureRetriedBitmap()
        val m = bounds.height().coerceAtLeast(16)
        val r = Rect(
            (bounds.left - m).coerceAtLeast(0),
            (bounds.top - m).coerceAtLeast(0),
            (bounds.right + m).coerceAtMost(full.width),
            (bounds.bottom + m).coerceAtMost(full.height),
        )
        if (r.width() <= 0 || r.height() <= 0) return null
        val piece = Bitmap.createBitmap(full, r.left, r.top, r.width(), r.height())
        val lines = OcrEngine.recognize(piece, 0.25f)
        if (lines.isEmpty()) return null
        return lines.sortedWith(compareBy({ it.bounds.top }, { it.bounds.left }))
            .joinToString(" ") { it.text }
    }

    fun ocrReadInputBarRegion(preferredBounds: Rect? = null): GatewayA11yService.InputBarReadback {
        val metrics = displayMetrics()
        val inset = currentBottomInset()
        val full = captureRetriedBitmap()
        val preferred = preferredBounds?.let { wanted ->
            Rect(
                wanted.left.coerceIn(0, full.width - 1),
                wanted.top.coerceIn(0, full.height - 1),
                wanted.right.coerceIn(1, full.width),
                wanted.bottom.coerceIn(1, full.height),
            ).takeIf { it.width() >= MIN_OCR_EDGE_PX && it.height() >= MIN_OCR_EDGE_PX }
        }
        val bottom = full.height
        val top = (bottom - INPUT_BAR_READBACK_HEIGHT_PX).coerceAtLeast(0)
        val region = preferred ?: Rect(
            (full.width * 0.06).toInt(),
            top,
            (full.width * 0.94).toInt(),
            bottom,
        )
        val text = runCatching { ocrReadRegionOf(full, region) }.getOrNull()
        return GatewayA11yService.InputBarReadback(
            text = text,
            region = region,
            screenWidth = full.width,
            screenHeight = full.height,
            metricsWidth = metrics.widthPixels,
            metricsHeight = metrics.heightPixels,
            bottomInset = inset,
            regionSource = if (preferred != null) "focused_bounds" else "bottom_band",
        )
    }

    fun screenshotPngBase64(region: Rect?): JSONObject {
        val full = captureRawBitmap()
        val cropped = if (region != null) {
            val r = Rect(
                region.left.coerceIn(0, full.width - 1),
                region.top.coerceIn(0, full.height - 1),
                region.right.coerceIn(1, full.width),
                region.bottom.coerceIn(1, full.height),
            )
            Bitmap.createBitmap(full, r.left, r.top, r.width(), r.height())
        } else full

        val bos = ByteArrayOutputStream()
        cropped.compress(Bitmap.CompressFormat.PNG, 90, bos)
        return JSONObject()
            .put("mime", "image/png")
            .put("base64", Base64.encodeToString(bos.toByteArray(), Base64.NO_WRAP))
            .put("width", cropped.width)
            .put("height", cropped.height)
            .put("offset", JSONArray(listOf(region?.left ?: 0, region?.top ?: 0)))
            .put("scale", 1.0)
            .put("revision", currentRevision())
    }
}

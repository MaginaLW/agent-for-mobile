package dev.magina.gateway.ocr

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.ColorMatrix
import android.graphics.ColorMatrixColorFilter
import android.graphics.Paint
import android.graphics.Rect
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
import dev.magina.gateway.core.ErrorCode
import dev.magina.gateway.core.GatewayError
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

/**
 * L5 视觉通道 OCR 端（spec §9）：ML Kit 中文 bundled 版（vivo 国行无 GMS，必须 bundled）。
 * client 常驻进程保持模型热加载（Spike S3：冷 736ms → 稳定态整屏 ~450ms，小裁剪更快）。
 */
object OcrEngine {

    /** 单行识别结果；bounds 为传入位图坐标系（整屏图即物理像素）。 */
    data class OcrLine(val text: String, val conf: Float, val bounds: Rect)

    /** Spike S3 实锤：conf<0.5 基本是图片内嵌文字的二次识别乱码，默认过滤。 */
    const val MIN_CONF = 0.5f

    /**
     * 灰度化+对比度拉伸的强度：2026-07-24 真机实锤深色模式灰底灰字漏识（部分实例置信度
     * 跌破 [MIN_CONF]，连候选都不存在，不是单纯阈值问题）。数值取自常见对比度增强经验值，
     * 未做设备专项调参——如后续真机验证效果不足或误伤正常对比度文字，优先调这个常量。
     */
    private const val CONTRAST_BOOST = 1.8f

    /** 同一段文字被两遍识别都命中时，判定为"同一处"所需的最小重叠占比（并集面积计）。 */
    private const val SAME_REGION_IOU = 0.5

    private val client by lazy {
        TextRecognition.getClient(ChineseTextRecognizerOptions.Builder().build())
    }

    /**
     * 原图识别一遍 + 对比度增强图再识别一遍，取每处文字置信度更高的结果合并返回。
     * 双跑而非替换：避免对比度变换对本来就清晰的文字产生回退（该变换未必对所有场景都是
     * 增益，保留原图结果做兜底）。两遍都是同一张位图的独立 ML Kit 调用，互不影响彼此结果。
     */
    fun recognize(bmp: Bitmap, minConf: Float = MIN_CONF): List<OcrLine> {
        val base = recognizeOnce(bmp, minConf)
        val enhanced = recognizeOnce(contrastEnhanced(bmp), minConf)
        return mergeByBestConfidence(base, enhanced)
    }

    private fun recognizeOnce(bmp: Bitmap, minConf: Float): List<OcrLine> {
        val fut = CompletableFuture<List<OcrLine>>()
        client.process(InputImage.fromBitmap(bmp, 0))
            .addOnSuccessListener { text ->
                val out = ArrayList<OcrLine>()
                for (block in text.textBlocks) for (line in block.lines) {
                    val b = line.boundingBox ?: continue
                    val t = line.text.trim()
                    if (t.isEmpty() || line.confidence < minConf) continue
                    out.add(OcrLine(t, line.confidence, Rect(b)))
                }
                fut.complete(out)
            }
            .addOnFailureListener { fut.completeExceptionally(it) }
        return try {
            fut.get(10, TimeUnit.SECONDS)
        } catch (e: ExecutionException) {
            throw GatewayError(
                ErrorCode.E_INTERNAL, "OCR 识别失败：${e.cause?.message}", channel = "vision",
                fallback = "screen_capture(reason=low_confidence) 交大脑目检",
            )
        } catch (e: TimeoutException) {
            throw GatewayError(ErrorCode.E_TIMEOUT, "OCR 10s 未返回", channel = "vision", retryable = true)
        }
    }

    /** 灰度化（文字可读性本质是亮度对比，色相无关）+ 围绕中灰点做对比度拉伸。 */
    private fun contrastEnhanced(bmp: Bitmap): Bitmap {
        val grayscale = ColorMatrix().apply { setSaturation(0f) }
        val translate = (1 - CONTRAST_BOOST) * 128f
        val contrast = ColorMatrix(
            floatArrayOf(
                CONTRAST_BOOST, 0f, 0f, 0f, translate,
                0f, CONTRAST_BOOST, 0f, 0f, translate,
                0f, 0f, CONTRAST_BOOST, 0f, translate,
                0f, 0f, 0f, 1f, 0f,
            ),
        )
        grayscale.postConcat(contrast)
        val out = Bitmap.createBitmap(bmp.width, bmp.height, Bitmap.Config.ARGB_8888)
        Canvas(out).drawBitmap(bmp, 0f, 0f, Paint().apply { colorFilter = ColorMatrixColorFilter(grayscale) })
        return out
    }

    /**
     * 同一段文字（原文相同且位置重叠占比达 [SAME_REGION_IOU]）只保留置信度更高的一条；
     * 只在其中一遍出现的行原样保留。纯几何/字符串比较，不依赖 ML Kit。
     */
    internal fun mergeByBestConfidence(base: List<OcrLine>, extra: List<OcrLine>): List<OcrLine> {
        val merged = base.toMutableList()
        for (candidate in extra) {
            val matchIndex = merged.indexOfFirst { sameRegion(it, candidate) }
            when {
                matchIndex < 0 -> merged.add(candidate)
                candidate.conf > merged[matchIndex].conf -> merged[matchIndex] = candidate
            }
        }
        return merged
    }

    private fun sameRegion(a: OcrLine, b: OcrLine): Boolean =
        a.text == b.text && overlapRatio(
            a.bounds.left, a.bounds.top, a.bounds.right, a.bounds.bottom,
            b.bounds.left, b.bounds.top, b.bounds.right, b.bounds.bottom,
        ) >= SAME_REGION_IOU

    /**
     * 交并比（IoU），只吃 Int 坐标、不碰 [Rect]——纯 JVM 单测就能覆盖，不需要真机或
     * Robolectric（这个仓库统一走"几何计算用普通数值、不依赖 android.graphics.*"的路子，
     * 见 `P0MacroRect` 同类做法）。
     */
    internal fun overlapRatio(
        aLeft: Int,
        aTop: Int,
        aRight: Int,
        aBottom: Int,
        bLeft: Int,
        bTop: Int,
        bRight: Int,
        bBottom: Int,
    ): Double {
        val interWidth = (minOf(aRight, bRight) - maxOf(aLeft, bLeft)).coerceAtLeast(0)
        val interHeight = (minOf(aBottom, bBottom) - maxOf(aTop, bTop)).coerceAtLeast(0)
        val interArea = interWidth.toLong() * interHeight
        val aArea = (aRight - aLeft).toLong() * (aBottom - aTop)
        val bArea = (bRight - bLeft).toLong() * (bBottom - bTop)
        val unionArea = aArea + bArea - interArea
        return if (unionArea > 0) interArea.toDouble() / unionArea else 0.0
    }

    /**
     * 匹配归一（仅用于比对，不改动展示原文）：去空白、全角→半角、小写化、o→0
     * （Spike S3 实锤：ML Kit 中文模型把数字 0 识成字母 O）。
     */
    fun norm(s: String): String {
        val sb = StringBuilder(s.length)
        for (raw in s) {
            var c = raw
            if (c in '！'..'～') c -= 0xFEE0
            if (c == '　' || c.isWhitespace()) continue
            c = c.lowercaseChar()
            if (c == 'o') c = '0'
            sb.append(c)
        }
        return sb.toString()
    }
}

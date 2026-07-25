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
import kotlin.math.pow
import kotlin.math.roundToInt

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
     * 灰度化+伽马校正+对比度拉伸的强度：2026-07-24 真机实锤深色模式灰底灰字漏识（部分实例
     * 置信度跌破 [MIN_CONF]，连候选都不存在，不是单纯阈值问题）。数值取自常见图像增强经验值，
     * 未做设备专项调参——如后续真机验证效果不足或误伤正常对比度文字，优先调这两个常量。
     */
    private const val CONTRAST_BOOST = 1.8f

    /**
     * 2026-07-25 网络调研（Appium OCR 插件真实预处理链：灰度→归一化→锐化→伽马校正→
     * 中值降噪→二值化）参照加入的一步：伽马 <1 会非线性拉亮中间调，专门放大临界灰阶
     * （深色模式灰底灰字）之间原本很小的亮度差异，和线性对比度拉伸互补，不是重复。
     * 没有照抄锐化/中值降噪/二值化——二值化对小号 CJK 字符的抗锯齿边缘信息破坏较大，
     * 中值降噪主要对付传感器噪声（这里是纯数字截屏，不适用）；如果这版效果仍不够，
     * 下一步再考虑锐化。
     */
    private const val GAMMA = 0.6f

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

    /** i/255 → 伽马校正 → 围绕中灰点做线性对比度拉伸，预计算成查找表，逐像素只做一次数组查表。 */
    private val enhancementLut: IntArray by lazy {
        IntArray(256) { i ->
            val gammaCorrected = 255.0 * (i / 255.0).pow(GAMMA.toDouble())
            val contrasted = (gammaCorrected - 128.0) * CONTRAST_BOOST + 128.0
            contrasted.roundToInt().coerceIn(0, 255)
        }
    }

    /**
     * 灰度化（文字可读性本质是亮度对比，色相无关）+ 伽马校正 + 对比度拉伸。灰度化用
     * `ColorMatrix`（Android 原生、GPU 路径），伽马+对比度用查找表逐像素应用（`ColorMatrix`
     * 只能表达线性变换，伽马是非线性幂函数，做不到）。
     */
    private fun contrastEnhanced(bmp: Bitmap): Bitmap {
        val grayscale = Bitmap.createBitmap(bmp.width, bmp.height, Bitmap.Config.ARGB_8888)
        Canvas(grayscale).drawBitmap(
            bmp, 0f, 0f,
            Paint().apply { colorFilter = ColorMatrixColorFilter(ColorMatrix().apply { setSaturation(0f) }) },
        )
        val pixels = IntArray(grayscale.width * grayscale.height)
        grayscale.getPixels(pixels, 0, grayscale.width, 0, 0, grayscale.width, grayscale.height)
        for (i in pixels.indices) {
            // 灰度化后 R=G=B，任取一个通道查表即可；alpha 原样保留。
            val level = enhancementLut[(pixels[i] ushr 16) and 0xFF]
            pixels[i] = (pixels[i] and 0xFF000000.toInt()) or (level shl 16) or (level shl 8) or level
        }
        grayscale.setPixels(pixels, 0, grayscale.width, 0, 0, grayscale.width, grayscale.height)
        return grayscale
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

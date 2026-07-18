package dev.magina.gateway.ocr

import android.graphics.Bitmap
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

    private val client by lazy {
        TextRecognition.getClient(ChineseTextRecognizerOptions.Builder().build())
    }

    fun recognize(bmp: Bitmap, minConf: Float = MIN_CONF): List<OcrLine> {
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

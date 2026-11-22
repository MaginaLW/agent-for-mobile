package dev.magina.gateway.a11y

import dev.magina.gateway.core.TextNorm
import kotlin.math.hypot

/** 仅当初始目标行高严格小于该阈值且 1x 二次校验零命中时，才触发 2x 上采样兜底。 */
internal const val SMALL_TEXT_UPSAMPLE_MAX_HEIGHT_PX = 60

/** 纯整数裁剪区坐标框（零 android.graphics.* 依赖，供 JVM 单测直接覆盖）。 */
internal data class OcrCropBox(
    val left: Int,
    val top: Int,
    val right: Int,
    val bottom: Int,
) {
    val centerX: Int get() = (left + right) / 2
    val centerY: Int get() = (top + bottom) / 2
}

internal data class OcrCandidateLine(
    val text: String,
    val conf: Float,
    val box: OcrCropBox,
)

internal data class OcrReverifyOutcome(
    val hit: OcrCandidateLine?,
    val observedLines: List<OcrCandidateLine>,
    val usedUpsample2x: Boolean,
)

/**
 * 仅对小字号目标（`0 < height < 60px`，如 PA2553 左窗 43px 会话行）允许 2x 上采样二次兜底；
 * 常规高度目标或 1x 已命中的按钮（如 38px「发送」1x 置信度 0.71）绝不进入 2x 分支。
 */
internal fun shouldTrySmallTextUpsample2x(expectedHeightPx: Int): Boolean =
    expectedHeightPx in 1 until SMALL_TEXT_UPSAMPLE_MAX_HEIGHT_PX

/**
 * 将 2x 上采样位图上的识别框确定性地映射回 1x `piece` 坐标系，并钳制在 `[0, pieceWidth]` / `[0, pieceHeight]`。
 * 采用整数 `left / 2`、`top / 2`、`(right + 1) / 2`、`(bottom + 1) / 2`，固定裁区下跨帧零漂移。
 */
internal fun mapUpsampled2xBoxToPiece(
    scaled: OcrCropBox,
    pieceWidth: Int,
    pieceHeight: Int,
): OcrCropBox {
    val maxX = pieceWidth.coerceAtLeast(0)
    val maxY = pieceHeight.coerceAtLeast(0)
    val left = (scaled.left / 2).coerceIn(0, maxX)
    val top = (scaled.top / 2).coerceIn(0, maxY)
    val right = ((scaled.right + 1) / 2).coerceIn(left, maxX)
    val bottom = ((scaled.bottom + 1) / 2).coerceIn(top, maxY)
    return OcrCropBox(left, top, right, bottom)
}

/** 字符袋相似度（0~1）：多重集交集 ×2 / 总长。短文本 OCR 抖动下比编辑距离更稳。 */
internal fun ocrCharBagSim(a: String, b: String): Float {
    if (a.isEmpty() || b.isEmpty()) return 0f
    val bag = HashMap<Char, Int>()
    for (c in a) bag[c] = (bag[c] ?: 0) + 1
    var common = 0
    for (c in b) {
        val n = bag[c] ?: 0
        if (n > 0) {
            bag[c] = n - 1
            common++
        }
    }
    return 2f * common / (a.length + b.length)
}

/**
 * 动作前 OCR 二次校验匹配：
 * ① 归一 contains（任意位置）；
 * ② 位置稳定（中心漂移 ≤ 1.2 行高）+ 字符袋相似度 ≥ 0.4（CJK 形近字抖动容错）。
 */
internal fun selectOcrReverifyHit(
    lines: List<OcrCandidateLine>,
    wantNorm: String,
    expectedCenterXInPiece: Int,
    expectedCenterYInPiece: Int,
    expectedHeightPx: Int,
): OcrCandidateLine? {
    val tol = 1.2f * expectedHeightPx
    return lines
        .map { l ->
            val got = TextNorm.ocr(l.text)
            val contains = got.contains(wantNorm) || (wantNorm.contains(got) && got.length >= 2)
            val drift = hypot(
                (l.box.centerX - expectedCenterXInPiece).toDouble(),
                (l.box.centerY - expectedCenterYInPiece).toDouble(),
            ).toFloat()
            val s = ocrCharBagSim(wantNorm, got)
            Triple(l, if (contains) 2f + l.conf else s + l.conf * 0.1f, contains || (drift <= tol && s >= 0.4f))
        }
        .filter { it.third }
        .maxByOrNull { it.second }?.first
}

/**
 * `resolveOcr` 二阶段复核调度：
 * 1. 先执行既有 1x 识别（`MIN_ACTION_OCR_CONFIDENCE = 0.65f`）；
 * 2. 仅当 1x 零命中且 `0 < expectedHeightPx < 60` 时，才调用 2x 上采样识别（仍保持 `0.65f`）并将
 *    2x 框确定性映射回 1x `piece` 坐标后按同一匹配规则复核。
 */
internal fun resolveOcrWithSmallTextUpsample(
    wantNorm: String,
    expectedCenterXInPiece: Int,
    expectedCenterYInPiece: Int,
    expectedHeightPx: Int,
    pieceWidth: Int,
    pieceHeight: Int,
    recognize1x: () -> List<OcrCandidateLine>,
    recognize2x: () -> List<OcrCandidateLine>,
): OcrReverifyOutcome {
    val lines1x = recognize1x()
    val hit1x = selectOcrReverifyHit(
        lines = lines1x,
        wantNorm = wantNorm,
        expectedCenterXInPiece = expectedCenterXInPiece,
        expectedCenterYInPiece = expectedCenterYInPiece,
        expectedHeightPx = expectedHeightPx,
    )
    if (hit1x != null || !shouldTrySmallTextUpsample2x(expectedHeightPx)) {
        return OcrReverifyOutcome(
            hit = hit1x,
            observedLines = lines1x,
            usedUpsample2x = false,
        )
    }
    val mapped2x = recognize2x().map { line ->
        line.copy(box = mapUpsampled2xBoxToPiece(line.box, pieceWidth, pieceHeight))
    }
    val hit2x = selectOcrReverifyHit(
        lines = mapped2x,
        wantNorm = wantNorm,
        expectedCenterXInPiece = expectedCenterXInPiece,
        expectedCenterYInPiece = expectedCenterYInPiece,
        expectedHeightPx = expectedHeightPx,
    )
    return OcrReverifyOutcome(
        hit = hit2x,
        observedLines = if (hit2x != null || mapped2x.isNotEmpty()) mapped2x else lines1x,
        usedUpsample2x = true,
    )
}

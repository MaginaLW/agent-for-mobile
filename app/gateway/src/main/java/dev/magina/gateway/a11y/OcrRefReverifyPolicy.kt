package dev.magina.gateway.a11y

import dev.magina.gateway.core.TextNorm
import dev.magina.gateway.ocr.OcrEngine
import kotlin.math.hypot

/** 仅当初始目标行高严格小于该阈值且 1x 二次校验零命中时，才触发 2x 上采样兜底。 */
internal const val SMALL_TEXT_UPSAMPLE_MAX_HEIGHT_PX = 60

/** 方案 A 精确具名导航兜底的最小归一字长（物理排除 1–3 字按钮，如「发送」「删除」「支付」「确认」）。 */
internal const val EXACT_NAV_MIN_NORM_LENGTH = 4

/** 方案 A 精确具名导航兜底要求的最小两帧像素交并比（IoU）。 */
internal const val EXACT_NAV_MIN_IOU = 0.75

/** 方案 A 精确具名导航兜底允许的最大中心漂移（占预期目标行高比例）。 */
internal const val EXACT_NAV_MAX_CENTER_DRIFT_RATIO = 0.35f

/** 检查裁区内其他 OCR 行是否与命中框重叠（防止危险/发送/确认词贴边误触）的外扩边距（像素）。 */
internal const val EXACT_NAV_OVERLAP_MARGIN_PX = 4

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
    val usedExactNavFallback: Boolean = false,
)

internal data class ExactNavFallbackConfig(
    val expectedLabel: String,
    val expectedScreenBox: OcrCropBox,
    val cropLeft: Int,
    val cropTop: Int,
    val minConf: Float = OcrEngine.MIN_CONF,
    val hasProtectedKeyword: (String) -> Boolean,
)

/** 仅归一长度 >= 4 的具名标签才具备进入方案 A 精确具名导航兜底的资格。 */
internal fun isExactNavLabelEligible(label: String): Boolean =
    TextNorm.ocr(label).length >= EXACT_NAV_MIN_NORM_LENGTH

/** 判定两个屏幕坐标框在给定像素安全边距下是否相交。 */
internal fun boxesOverlapWithMargin(
    a: OcrCropBox,
    b: OcrCropBox,
    marginPx: Int = EXACT_NAV_OVERLAP_MARGIN_PX,
): Boolean =
    a.left - marginPx < b.right && b.left < a.right + marginPx &&
        a.top - marginPx < b.bottom && b.top < a.bottom + marginPx

/**
 * 方案 A 精确具名导航兜底匹配（仅在 1x/2x @ 0.65f 零命中、且调用方已证实普通 `click` + `SafetyDecision.Allowed` 时触发）：
 * 1. `wantNorm = TextNorm.ocr(expectedLabel)` 长度 `>= 4` 且本身不含保护词；
 * 2. 禁用 `charBagSim` 模糊匹配，强制 `TextNorm.ocr(line.text) == wantNorm` 且 `conf >= minConf`（`0.50f`）；
 * 3. 裁区内精确命中必须唯一（0 条或 `>= 2` 条一律返回 null）；
 * 4. 严格像素锁位：`IoU(expectedScreenBox, screenBox) >= 0.75` 且中心欧氏漂移 `<= 0.35 * expectedHeight`；
 * 5. 裁区内所有与命中框相交（含 4px 安全边距）的其他 OCR 行均不得命中 `SafetyPolicy` 保护词。
 */
internal fun selectExactNavMatch(
    lines: List<OcrCandidateLine>,
    expectedLabel: String,
    expectedScreenBox: OcrCropBox,
    cropLeft: Int,
    cropTop: Int,
    minConf: Float = OcrEngine.MIN_CONF,
    hasProtectedKeyword: (String) -> Boolean,
): OcrCandidateLine? {
    val wantNorm = TextNorm.ocr(expectedLabel)
    if (wantNorm.length < EXACT_NAV_MIN_NORM_LENGTH) return null
    val expectedHeight = expectedScreenBox.bottom - expectedScreenBox.top
    if (expectedHeight <= 0 || expectedScreenBox.right <= expectedScreenBox.left) return null
    if (hasProtectedKeyword(expectedLabel)) return null

    val exactMatches = lines.filter { line ->
        line.conf >= minConf && TextNorm.ocr(line.text) == wantNorm
    }
    if (exactMatches.size != 1) return null

    val winner = exactMatches.single()
    val winnerScreen = OcrCropBox(
        left = winner.box.left + cropLeft,
        top = winner.box.top + cropTop,
        right = winner.box.right + cropLeft,
        bottom = winner.box.bottom + cropTop,
    )
    val iou = OcrEngine.overlapRatio(
        expectedScreenBox.left, expectedScreenBox.top, expectedScreenBox.right, expectedScreenBox.bottom,
        winnerScreen.left, winnerScreen.top, winnerScreen.right, winnerScreen.bottom,
    )
    if (iou < EXACT_NAV_MIN_IOU) return null

    val drift = hypot(
        (winnerScreen.centerX - expectedScreenBox.centerX).toDouble(),
        (winnerScreen.centerY - expectedScreenBox.centerY).toDouble(),
    ).toFloat()
    if (drift > EXACT_NAV_MAX_CENTER_DRIFT_RATIO * expectedHeight) return null

    for (other in lines) {
        if (other === winner) continue
        val otherScreen = OcrCropBox(
            left = other.box.left + cropLeft,
            top = other.box.top + cropTop,
            right = other.box.right + cropLeft,
            bottom = other.box.bottom + cropTop,
        )
        if (boxesOverlapWithMargin(winnerScreen, otherScreen) && hasProtectedKeyword(other.text)) {
            return null
        }
    }
    return winner
}

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
 * `resolveOcr` 多阶段复核调度：
 * 1. 先执行既有 1x 识别（`MIN_ACTION_OCR_CONFIDENCE = 0.65f`）；高置信命中立即返回，不进后续兜底；
 * 2. 仅当 1x 零命中且 `0 < expectedHeightPx < 60` 时，执行 2x 上采样识别（仍保持 `0.65f`）并确定性映射回 1x 坐标；
 * 3. 仅当上述 `0.65f` 阶段均零命中、且调用方显式授权 `exactNavConfig`（普通 `click` + `SafetyDecision.Allowed` + `len >= 4`）时，
 *    对同一固定裁区跑 1x `OcrEngine.MIN_CONF (0.50f)` 并过 [selectExactNavMatch] 严锁五道护栏。
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
    exactNavConfig: ExactNavFallbackConfig? = null,
    recognize1xExactNav: (() -> List<OcrCandidateLine>)? = null,
): OcrReverifyOutcome {
    val lines1x = recognize1x()
    val hit1x = selectOcrReverifyHit(
        lines = lines1x,
        wantNorm = wantNorm,
        expectedCenterXInPiece = expectedCenterXInPiece,
        expectedCenterYInPiece = expectedCenterYInPiece,
        expectedHeightPx = expectedHeightPx,
    )
    if (hit1x != null) {
        return OcrReverifyOutcome(
            hit = hit1x,
            observedLines = lines1x,
            usedUpsample2x = false,
            usedExactNavFallback = false,
        )
    }

    var observed = lines1x
    var tried2x = false
    if (shouldTrySmallTextUpsample2x(expectedHeightPx)) {
        tried2x = true
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
        if (hit2x != null) {
            return OcrReverifyOutcome(
                hit = hit2x,
                observedLines = mapped2x,
                usedUpsample2x = true,
                usedExactNavFallback = false,
            )
        }
        if (mapped2x.isNotEmpty()) observed = mapped2x
    }

    if (exactNavConfig != null &&
        recognize1xExactNav != null &&
        isExactNavLabelEligible(exactNavConfig.expectedLabel) &&
        !exactNavConfig.hasProtectedKeyword(exactNavConfig.expectedLabel)
    ) {
        val linesNav = recognize1xExactNav()
        val hitNav = selectExactNavMatch(
            lines = linesNav,
            expectedLabel = exactNavConfig.expectedLabel,
            expectedScreenBox = exactNavConfig.expectedScreenBox,
            cropLeft = exactNavConfig.cropLeft,
            cropTop = exactNavConfig.cropTop,
            minConf = exactNavConfig.minConf,
            hasProtectedKeyword = exactNavConfig.hasProtectedKeyword,
        )
        if (hitNav != null) {
            return OcrReverifyOutcome(
                hit = hitNav,
                observedLines = linesNav,
                usedUpsample2x = false,
                usedExactNavFallback = true,
            )
        }
        if (linesNav.isNotEmpty()) observed = linesNav
    }

    return OcrReverifyOutcome(
        hit = null,
        observedLines = observed,
        usedUpsample2x = tried2x,
        usedExactNavFallback = false,
    )
}

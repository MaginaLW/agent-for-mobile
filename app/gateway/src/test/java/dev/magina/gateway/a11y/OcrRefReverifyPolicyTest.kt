package dev.magina.gateway.a11y

import dev.magina.gateway.core.TextNorm
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OcrRefReverifyPolicyTest {

    @Test
    fun `action ocr confidence threshold and upsample height gate remain unchanged`() {
        assertEquals(0.65f, MIN_ACTION_OCR_CONFIDENCE, 0f)
        assertEquals(60, SMALL_TEXT_UPSAMPLE_MAX_HEIGHT_PX)
        assertTrue(shouldTrySmallTextUpsample2x(43))
        assertTrue(shouldTrySmallTextUpsample2x(59))
        assertFalse(shouldTrySmallTextUpsample2x(60))
        assertFalse(shouldTrySmallTextUpsample2x(80))
        assertFalse(shouldTrySmallTextUpsample2x(0))
        assertFalse(shouldTrySmallTextUpsample2x(-4))
    }

    @Test
    fun `2x inverse mapping is exact on even coords, rounds deterministically on odd coords, and clamps cleanly`() {
        // PA2553 左窗「文件传输助手」[216,281,498,325] 在 620x220 裁区 [47,193,667,413] 内的局部坐标为 [169,88,451,132]
        val exact = mapUpsampled2xBoxToPiece(
            scaled = OcrCropBox(338, 176, 902, 264),
            pieceWidth = 620,
            pieceHeight = 220,
        )
        assertEquals(OcrCropBox(169, 88, 451, 132), exact)
        assertEquals(216, exact.left + 47)
        assertEquals(281, exact.top + 193)
        assertEquals(498, exact.right + 47)
        assertEquals(325, exact.bottom + 193)

        // 奇数 2x 边按 left/2, (right+1)/2 确定性取整，跨静态帧零漂移
        val odd1 = mapUpsampled2xBoxToPiece(OcrCropBox(339, 177, 903, 265), 620, 220)
        val odd2 = mapUpsampled2xBoxToPiece(OcrCropBox(339, 177, 903, 265), 620, 220)
        assertEquals(OcrCropBox(169, 88, 452, 133), odd1)
        assertEquals(odd1, odd2)

        // 越界与负值被严格钳制在 [0, pieceWidth] / [0, pieceHeight] 且满足 right>=left, bottom>=top
        val clamped = mapUpsampled2xBoxToPiece(OcrCropBox(-10, -5, 1300, 500), 620, 220)
        assertEquals(OcrCropBox(0, 0, 620, 220), clamped)

        val inverted = mapUpsampled2xBoxToPiece(OcrCropBox(400, 200, 300, 100), 620, 220)
        assertEquals(OcrCropBox(200, 100, 200, 100), inverted)
    }

    @Test
    fun `2x fallback triggers only when 1x misses and target height is below 60px`() {
        var calls1x = 0
        var calls2x = 0
        val outcome = resolveOcrWithSmallTextUpsample(
            wantNorm = TextNorm.ocr("文件传输助手"),
            expectedCenterXInPiece = 310,
            expectedCenterYInPiece = 110,
            expectedHeightPx = 43,
            pieceWidth = 620,
            pieceHeight = 220,
            recognize1x = {
                calls1x++
                // 复现 PA2553 a-000055：1x 仅高置信读到下方预览行，43px 标题行漏识
                listOf(OcrCandidateLine("PA2553橫屏确认卡验收-202", 0.82f, OcrCropBox(169, 157, 620, 190)))
            },
            recognize2x = {
                calls2x++
                listOf(
                    OcrCandidateLine("文件传输助手", 0.78f, OcrCropBox(338, 176, 902, 262)),
                    OcrCandidateLine("PA2553橫屏确认卡验收-202", 0.85f, OcrCropBox(338, 314, 1240, 380)),
                )
            },
        )
        assertEquals(1, calls1x)
        assertEquals(1, calls2x)
        assertTrue(outcome.usedUpsample2x)
        assertNotNull(outcome.hit)
        assertEquals("文件传输助手", outcome.hit!!.text)
        assertEquals(OcrCropBox(169, 88, 451, 131), outcome.hit!!.box)
    }

    @Test
    fun `2x fallback stays fail-closed when both 1x and 2x find zero matching candidates`() {
        var calls2x = 0
        val outcome = resolveOcrWithSmallTextUpsample(
            wantNorm = TextNorm.ocr("文件传输助手"),
            expectedCenterXInPiece = 310,
            expectedCenterYInPiece = 110,
            expectedHeightPx = 43,
            pieceWidth = 620,
            pieceHeight = 220,
            recognize1x = { listOf(OcrCandidateLine("公众号", 0.90f, OcrCropBox(160, 90, 300, 130))) },
            recognize2x = {
                calls2x++
                listOf(OcrCandidateLine("公众号", 0.92f, OcrCropBox(320, 180, 600, 260)))
            },
        )
        assertEquals(1, calls2x)
        assertTrue(outcome.usedUpsample2x)
        assertNull(outcome.hit)
        assertEquals(1, outcome.observedLines.size)
        assertEquals("公众号", outcome.observedLines.single().text)
    }

    @Test
    fun `2x fallback is skipped whenever 1x already succeeds on normal action buttons`() {
        var calls2x = 0
        // 复现 38px「发送」按钮 1x 已在 0.71 命中：绝不进入 2x 分支，保证确认卡前后固定裁区路径零变化
        val outcome = resolveOcrWithSmallTextUpsample(
            wantNorm = TextNorm.ocr("发送"),
            expectedCenterXInPiece = 310,
            expectedCenterYInPiece = 110,
            expectedHeightPx = 38,
            pieceWidth = 620,
            pieceHeight = 220,
            recognize1x = { listOf(OcrCandidateLine("发送", 0.71f, OcrCropBox(270, 91, 350, 129))) },
            recognize2x = {
                calls2x++
                emptyList()
            },
        )
        assertEquals(0, calls2x)
        assertFalse(outcome.usedUpsample2x)
        assertNotNull(outcome.hit)
        assertEquals(OcrCropBox(270, 91, 350, 129), outcome.hit!!.box)
    }

    @Test
    fun `2x fallback is skipped when target height is 60px or larger even on 1x miss`() {
        for (height in listOf(60, 72, 120)) {
            var calls2x = 0
            val outcome = resolveOcrWithSmallTextUpsample(
                wantNorm = TextNorm.ocr("文件传输助手"),
                expectedCenterXInPiece = 310,
                expectedCenterYInPiece = 110,
                expectedHeightPx = height,
                pieceWidth = 620,
                pieceHeight = 220,
                recognize1x = { emptyList() },
                recognize2x = {
                    calls2x++
                    listOf(OcrCandidateLine("文件传输助手", 0.85f, OcrCropBox(338, 176, 902, 296)))
                },
            )
            assertEquals("height=$height 不应触发 2x", 0, calls2x)
            assertFalse(outcome.usedUpsample2x)
            assertNull(outcome.hit)
        }
    }
}

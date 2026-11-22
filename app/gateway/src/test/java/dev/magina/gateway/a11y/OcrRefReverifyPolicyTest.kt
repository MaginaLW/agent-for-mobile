package dev.magina.gateway.a11y

import dev.magina.gateway.core.SafetyPolicy
import dev.magina.gateway.core.TextNorm
import dev.magina.gateway.ocr.OcrEngine
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

    @Test
    fun `exact_nav fallback succeeds on PA2553 44px left-pane File Transfer Assistant after 0_65f miss while keeping thresholds unchanged`() {
        assertEquals(0.65f, MIN_ACTION_OCR_CONFIDENCE, 0f)
        assertEquals(0.50f, OcrEngine.MIN_CONF, 0f)

        val policy = SafetyPolicy()
        // PA2553 实测左窗「文件传输助手」[216,282,498,326] (44px)，裁区 crop=[47,194,667,414]，
        // 局部坐标 [169,88,451,132]；下方预览「PA2553橫屏确认卡验收-202」[216,350,763,383]（含「确认」但间隔 24px >> 4px）
        val expectedScreen = OcrCropBox(216, 282, 498, 326)
        val cropLeft = 47
        val cropTop = 194
        val cfg = ExactNavFallbackConfig(
            expectedLabel = "文件传输助手",
            expectedScreenBox = expectedScreen,
            cropLeft = cropLeft,
            cropTop = cropTop,
            minConf = OcrEngine.MIN_CONF,
            hasProtectedKeyword = policy::containsProtectedActionKeyword,
        )

        var calls1x = 0
        var calls2x = 0
        var callsExactNav = 0
        val outcome = resolveOcrWithSmallTextUpsample(
            wantNorm = TextNorm.ocr("文件传输助手"),
            expectedCenterXInPiece = expectedScreen.centerX - cropLeft,
            expectedCenterYInPiece = expectedScreen.centerY - cropTop,
            expectedHeightPx = 44,
            pieceWidth = 620,
            pieceHeight = 220,
            recognize1x = {
                calls1x++
                listOf(OcrCandidateLine("PA2553橫屏确认卡验收-202", 0.82f, OcrCropBox(169, 156, 620, 189)))
            },
            recognize2x = {
                calls2x++
                listOf(OcrCandidateLine("PA2553橫屏确认卡验收-202", 0.85f, OcrCropBox(338, 312, 1240, 378)))
            },
            exactNavConfig = cfg,
            recognize1xExactNav = {
                callsExactNav++
                listOf(
                    OcrCandidateLine("文件传输助手", 0.54f, OcrCropBox(169, 88, 451, 132)),
                    OcrCandidateLine("PA2553橫屏确认卡验收-202", 0.82f, OcrCropBox(169, 156, 620, 189)),
                )
            },
        )
        assertEquals(1, calls1x)
        assertEquals(1, calls2x)
        assertEquals(1, callsExactNav)
        assertTrue(outcome.usedExactNavFallback)
        assertFalse(outcome.usedUpsample2x)
        assertNotNull(outcome.hit)
        assertEquals("文件传输助手", outcome.hit!!.text)
        assertEquals(OcrCropBox(169, 88, 451, 132), outcome.hit!!.box)

        // 高置信 1x 或 2x 命中时绝不进入 exact_nav 分支
        var skippedNavCalls = 0
        val hitOn1x = resolveOcrWithSmallTextUpsample(
            wantNorm = TextNorm.ocr("文件传输助手"),
            expectedCenterXInPiece = expectedScreen.centerX - cropLeft,
            expectedCenterYInPiece = expectedScreen.centerY - cropTop,
            expectedHeightPx = 44,
            pieceWidth = 620,
            pieceHeight = 220,
            recognize1x = { listOf(OcrCandidateLine("文件传输助手", 0.72f, OcrCropBox(169, 88, 451, 132))) },
            recognize2x = { error("1x 命中不应跑 2x") },
            exactNavConfig = cfg,
            recognize1xExactNav = { skippedNavCalls++; emptyList() },
        )
        assertEquals(0, skippedNavCalls)
        assertFalse(hitOn1x.usedExactNavFallback)
        assertNotNull(hitOn1x.hit)
    }

    @Test
    fun `exact_nav fallback fails closed on short labels, protected keywords, fuzzy text, low conf, low IoU, high drift, duplicates, and overlapping danger text`() {
        val policy = SafetyPolicy(sensitiveTargets = listOf("银行卡号"))
        val expected = OcrCropBox(216, 282, 498, 326) // 282x44
        val cropLeft = 47
        val cropTop = 194
        val localExact = OcrCropBox(169, 88, 451, 132)

        // 1) <4 字标签一律拒绝（含 1-3 字按钮与短普通词）
        for (shortLabel in listOf("发送", "删除", "支付", "确认", "123", "文件助", "")) {
            assertFalse(isExactNavLabelEligible(shortLabel))
            assertNull(
                "短标签「$shortLabel」不得进入 exact_nav",
                selectExactNavMatch(
                    lines = listOf(OcrCandidateLine(shortLabel, 0.58f, localExact)),
                    expectedLabel = shortLabel,
                    expectedScreenBox = expected,
                    cropLeft = cropLeft,
                    cropTop = cropTop,
                    hasProtectedKeyword = policy::containsProtectedActionKeyword,
                ),
            )
        }

        // 2) >=4 字含危险/发送/确认/敏感词标签一律拒绝
        for (protectedLabel in listOf("确认发送", "立即支付", "删除聊天", "转账给张三", "我的银行卡号")) {
            assertTrue(policy.containsProtectedActionKeyword(protectedLabel))
            assertNull(
                "受保护标签「$protectedLabel」不得走 exact_nav",
                selectExactNavMatch(
                    lines = listOf(OcrCandidateLine(protectedLabel, 0.60f, localExact)),
                    expectedLabel = protectedLabel,
                    expectedScreenBox = expected,
                    cropLeft = cropLeft,
                    cropTop = cropTop,
                    hasProtectedKeyword = policy::containsProtectedActionKeyword,
                ),
            )
        }

        // 3) 禁用 charBagSim 模糊匹配：少一字/多一字/形近字必须返回 null
        for (fuzzy in listOf("文件传输助", "文件传输助于", "文件传输入助手")) {
            assertNull(
                "模糊文本「$fuzzy」必须被拒绝",
                selectExactNavMatch(
                    lines = listOf(OcrCandidateLine(fuzzy, 0.62f, localExact)),
                    expectedLabel = "文件传输助手",
                    expectedScreenBox = expected,
                    cropLeft = cropLeft,
                    cropTop = cropTop,
                    hasProtectedKeyword = policy::containsProtectedActionKeyword,
                ),
            )
        }

        // 4) 置信度 < 0.50f 拒绝
        assertNull(
            selectExactNavMatch(
                lines = listOf(OcrCandidateLine("文件传输助手", 0.49f, localExact)),
                expectedLabel = "文件传输助手",
                expectedScreenBox = expected,
                cropLeft = cropLeft,
                cropTop = cropTop,
                hasProtectedKeyword = policy::containsProtectedActionKeyword,
            ),
        )

        // 5) IoU < 0.75 拒绝（高度缩水导致 IoU=0.68 即使中心零漂移）
        assertNull(
            selectExactNavMatch(
                lines = listOf(OcrCandidateLine("文件传输助手", 0.55f, OcrCropBox(169, 95, 451, 125))),
                expectedLabel = "文件传输助手",
                expectedScreenBox = expected,
                cropLeft = cropLeft,
                cropTop = cropTop,
                hasProtectedKeyword = policy::containsProtectedActionKeyword,
            ),
        )

        // 6) 中心漂移 > 0.35 * 44 (=15.4px) 拒绝（整体平移 16px）
        assertNull(
            selectExactNavMatch(
                lines = listOf(OcrCandidateLine("文件传输助手", 0.55f, OcrCropBox(169, 104, 451, 148))),
                expectedLabel = "文件传输助手",
                expectedScreenBox = expected,
                cropLeft = cropLeft,
                cropTop = cropTop,
                hasProtectedKeyword = policy::containsProtectedActionKeyword,
            ),
        )

        // 7) 裁区内重复精确命中（2 条同名）拒绝
        assertNull(
            selectExactNavMatch(
                lines = listOf(
                    OcrCandidateLine("文件传输助手", 0.54f, localExact),
                    OcrCandidateLine("文件传输助手", 0.56f, OcrCropBox(169, 150, 451, 194)),
                ),
                expectedLabel = "文件传输助手",
                expectedScreenBox = expected,
                cropLeft = cropLeft,
                cropTop = cropTop,
                hasProtectedKeyword = policy::containsProtectedActionKeyword,
            ),
        )

        // 8) 危险/发送/确认词与目标框相交（含 4px 安全边距，甚至带空格「发 送」）必须拒绝
        for (overlapText in listOf("删除", "发 送", "确认")) {
            assertNull(
                "重叠保护词「$overlapText」必须阻止 exact_nav",
                selectExactNavMatch(
                    lines = listOf(
                        OcrCandidateLine("文件传输助手", 0.54f, localExact),
                        // 屏幕 y=328，距离目标下沿 326 仅 2px（< 4px 边距）
                        OcrCandidateLine(overlapText, 0.70f, OcrCropBox(200, 134, 320, 170)),
                    ),
                    expectedLabel = "文件传输助手",
                    expectedScreenBox = expected,
                    cropLeft = cropLeft,
                    cropTop = cropTop,
                    hasProtectedKeyword = policy::containsProtectedActionKeyword,
                ),
            )
        }
    }

    @Test
    fun `traditional to simplified folding handles PA2553 flicker in exact_nav and blocks traditional protected keywords`() {
        val policy = SafetyPolicy()
        val expected = OcrCropBox(216, 282, 498, 326) // PA2553 左窗实测 282x44
        val cropLeft = 47
        val cropTop = 194
        val localExact = OcrCropBox(169, 88, 451, 132)

        // 1) 预期简体「文件传输助手」，实时帧 ML Kit 抖出繁体「文件传輸助手」(conf=0.51) → 精确命中
        val tradHit = selectExactNavMatch(
            lines = listOf(
                OcrCandidateLine("文件传輸助手", 0.51f, localExact),
                OcrCandidateLine("PA2553橫屏确认卡验收-20261122", 0.75f, OcrCropBox(169, 156, 620, 189)),
            ),
            expectedLabel = "文件传输助手",
            expectedScreenBox = expected,
            cropLeft = cropLeft,
            cropTop = cropTop,
            hasProtectedKeyword = policy::containsProtectedActionKeyword,
        )
        assertNotNull(tradHit)
        assertEquals("文件传輸助手", tradHit!!.text)

        // 2) 快照期出繁体「文件传輸助手」，复核帧出简体「文件传输助手」→ 同样精确命中
        val simpHit = selectExactNavMatch(
            lines = listOf(OcrCandidateLine("文件传输助手", 0.54f, localExact)),
            expectedLabel = "文件传輸助手",
            expectedScreenBox = expected,
            cropLeft = cropLeft,
            cropTop = cropTop,
            hasProtectedKeyword = policy::containsProtectedActionKeyword,
        )
        assertNotNull(simpHit)
        assertEquals("文件传输助手", simpHit!!.text)

        // 3) 繁体受保护关键词既不能作为 exact_nav 目标，也不能在 4px 重叠邻域内被绕过
        for (tradProtected in listOf("確認發送", "立即購買", "刪除聊天", "轉賬給張三", "提交訂單")) {
            assertTrue("containsProtectedActionKeyword 必须拦下繁体「$tradProtected」", policy.containsProtectedActionKeyword(tradProtected))
            assertNull(
                selectExactNavMatch(
                    lines = listOf(OcrCandidateLine(tradProtected, 0.58f, localExact)),
                    expectedLabel = tradProtected,
                    expectedScreenBox = expected,
                    cropLeft = cropLeft,
                    cropTop = cropTop,
                    hasProtectedKeyword = policy::containsProtectedActionKeyword,
                ),
            )
        }
        for (tradOverlap in listOf("發送", "刪除", "確認", "發 送")) {
            assertNull(
                "重叠繁体保护词「$tradOverlap」必须阻止 exact_nav",
                selectExactNavMatch(
                    lines = listOf(
                        OcrCandidateLine("文件传輸助手", 0.54f, localExact),
                        OcrCandidateLine(tradOverlap, 0.70f, OcrCropBox(200, 134, 320, 170)),
                    ),
                    expectedLabel = "文件传输助手",
                    expectedScreenBox = expected,
                    cropLeft = cropLeft,
                    cropTop = cropTop,
                    hasProtectedKeyword = policy::containsProtectedActionKeyword,
                ),
            )
        }
    }
}

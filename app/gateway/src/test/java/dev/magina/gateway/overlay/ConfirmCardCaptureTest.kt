package dev.magina.gateway.overlay

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ConfirmCardCaptureTest {
    private val cardColor = 0xF2222222.toInt()
    private val target = ConfirmCardTarget(
        left = 0,
        top = 0,
        right = 1260,
        bottom = 620,
        backgroundColor = cardColor,
    )

    @Test
    fun `card drawn over the whole band counts as captured`() {
        assertTrue(visible { _, _ -> cardColor })
    }

    @Test
    fun `screenshot without the card is rejected`() {
        // 2026-07-26 实锤的形态：拍到的是微信会话页（浅色标题栏 + 彩色壁纸），卡完全不在图里。
        assertFalse(visible { _, _ -> 0xFFEDEDED.toInt() })
    }

    @Test
    fun `slight alpha blend from the background still counts as captured`() {
        // 底色带 alpha（#F2 ≈ 95%），亮背景会透上来一点，判据必须按通道容差而不是精确相等。
        assertTrue(visible { _, _ -> 0xFF2E2E2E.toInt() })
    }

    @Test
    fun `text and buttons inside the card do not break the left margin sampling`() {
        // 文字与按钮都画在 padding=48 之内；判据只采左内边距竖带，故整片白也不该影响结论。
        assertTrue(visible { x, _ -> if (x >= 48) 0xFFFFFFFF.toInt() else cardColor })
    }

    @Test
    fun `mostly wrong band is rejected even if a few rows match`() {
        assertFalse(visible { _, y -> if (y < 60) cardColor else 0xFFEDEDED.toInt() })
    }

    @Test
    fun `degenerate geometry is never treated as proof`() {
        val thin = target.copy(right = 12, bottom = 12)
        assertFalse(
            confirmCardVisibleInCapture(
                target = thin,
                width = 1260,
                height = 2800,
                pixelAt = { _, _ -> cardColor },
            )
        )
    }

    @Test
    fun `card reaching outside the capture is clamped instead of trusted blindly`() {
        val overflowing = target.copy(right = 5000, bottom = 5000)
        assertTrue(
            confirmCardVisibleInCapture(
                target = overflowing,
                width = 1260,
                height = 2800,
                pixelAt = { x, y ->
                    if (x < 1260 && y < 2800) cardColor else throw AssertionError("采样越界到 $x,$y")
                },
            )
        )
    }

    private fun visible(pixelAt: (Int, Int) -> Int): Boolean = confirmCardVisibleInCapture(
        target = target,
        width = 1260,
        height = 2800,
        pixelAt = pixelAt,
    )
}

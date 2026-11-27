package dev.magina.gateway.overlay

import android.view.Gravity
import android.view.WindowManager
import androidx.core.content.ContextCompat
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ConfirmOverlayWindowPolicyTest {
    @Test
    fun `accessibility host wins without system alert window`() {
        assertEquals(
            ConfirmOverlayWindowKind.ACCESSIBILITY_OVERLAY,
            chooseConfirmOverlayWindowKind(
                accessibilityHostAvailable = true,
                canDrawOverlays = false,
            ),
        )
    }

    @Test
    fun `accessibility host wins when system alert window exists`() {
        assertEquals(
            ConfirmOverlayWindowKind.ACCESSIBILITY_OVERLAY,
            chooseConfirmOverlayWindowKind(
                accessibilityHostAvailable = true,
                canDrawOverlays = true,
            ),
        )
    }

    @Test
    fun `application overlay is fallback without accessibility host`() {
        assertEquals(
            ConfirmOverlayWindowKind.APPLICATION_OVERLAY,
            chooseConfirmOverlayWindowKind(
                accessibilityHostAvailable = false,
                canDrawOverlays = true,
            ),
        )
    }

    @Test
    fun `no host and no overlay permission is unavailable`() {
        assertEquals(
            ConfirmOverlayWindowKind.UNAVAILABLE,
            chooseConfirmOverlayWindowKind(
                accessibilityHostAvailable = false,
                canDrawOverlays = false,
            ),
        )
    }

    @Test
    fun `default confirm overlay timeout matches backlog 90s decision`() {
        assertEquals(90_000L, ConfirmOverlay.DEFAULT_CONFIRM_TIMEOUT_MS)
    }

    @Test
    fun `confirm overlay anchors at bottom center fits system bars only and ignores ime insets`() {
        val layout = confirmOverlayWindowLayout(
            displayWidthPx = 2800,
            displayHeightPx = 1968,
            density = 2.5f,
        )

        assertEquals(Gravity.BOTTOM, layout.gravity and Gravity.VERTICAL_GRAVITY_MASK)
        assertNotEquals(Gravity.TOP, layout.gravity and Gravity.VERTICAL_GRAVITY_MASK)
        assertEquals(Gravity.CENTER_HORIZONTAL, layout.gravity and Gravity.HORIZONTAL_GRAVITY_MASK)
        assertEquals(WindowManager.LayoutParams.WRAP_CONTENT, layout.height)
        assertTrue(layout.fitSystemBarsAndCutout)
        // 绝不避让 IME：键盘展开时避让输入法会把底部卡片顶回屏幕上半区，再次遮挡通知中心。
        assertFalse(layout.fitIme)
        assertEquals(30, layout.yOffsetPx)
        assertEquals(704, layout.maxBodyHeightPx)
    }

    @Test
    fun `confirm overlay keeps non focusable touch pass through flags without secure or no limits`() {
        val layout = confirmOverlayWindowLayout(
            displayWidthPx = 2800,
            displayHeightPx = 1968,
            density = 2.5f,
        )

        assertTrue(layout.flags and WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE != 0)
        assertTrue(layout.flags and WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL != 0)
        assertEquals(0, layout.flags and WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN)
        assertEquals(0, layout.flags and WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS)
        assertEquals(0, layout.flags and WindowManager.LayoutParams.FLAG_SECURE)
    }

    @Test
    fun `wide tablet caps overlay width and bounds body height while portrait phone uses match parent`() {
        // PA2553 横屏 2800x1968 @ 400dpi (density=2.5): 限制 720dp = 1800px，正文滚动上限 704px 保住上半屏。
        val tabletLandscape = confirmOverlayWindowLayout(
            displayWidthPx = 2800,
            displayHeightPx = 1968,
            density = 2.5f,
        )
        assertEquals(1800, tabletLandscape.width)
        assertEquals(704, tabletLandscape.maxBodyHeightPx)

        // PA2553 竖屏 1968x2800 @ 400dpi (density=2.5): 1968 > 1800 + 80，仍为 1800px。
        val tabletPortrait = confirmOverlayWindowLayout(
            displayWidthPx = 1968,
            displayHeightPx = 2800,
            density = 2.5f,
        )
        assertEquals(1800, tabletPortrait.width)
        assertEquals(1120, tabletPortrait.maxBodyHeightPx)

        // 手机竖屏 1260x2800 @ density=3.0: 窄于上限，走 MATCH_PARENT 避免文字过度折行。
        val phonePortrait = confirmOverlayWindowLayout(
            displayWidthPx = 1260,
            displayHeightPx = 2800,
            density = 3.0f,
        )
        assertEquals(WindowManager.LayoutParams.MATCH_PARENT, phonePortrait.width)
        assertEquals(36, phonePortrait.yOffsetPx)
        assertEquals(1080, phonePortrait.maxBodyHeightPx)

        // 紧凑横屏 2400x1080 @ density=3.0: 正文上限收敛在下半区，防止把按钮顶出屏幕或盖住通知栏。
        val phoneLandscape = confirmOverlayWindowLayout(
            displayWidthPx = 2400,
            displayHeightPx = 1080,
            density = 3.0f,
        )
        assertEquals(2160, phoneLandscape.width)
        assertEquals(240, phoneLandscape.maxBodyHeightPx)
    }

    @Test
    fun `width capping boundary respects horizontal margin`() {
        val exactThreshold = (CONFIRM_OVERLAY_MAX_WIDTH_DP + CONFIRM_OVERLAY_HORIZONTAL_MARGIN_DP * 2) * 2
        assertEquals(
            WindowManager.LayoutParams.MATCH_PARENT,
            confirmOverlayWindowLayout(displayWidthPx = exactThreshold, density = 2.0f).width,
        )
        assertEquals(
            CONFIRM_OVERLAY_MAX_WIDTH_DP * 2,
            confirmOverlayWindowLayout(displayWidthPx = exactThreshold + 1, density = 2.0f).width,
        )
    }

    @Test
    fun `invalid and extreme display metrics degrade safely without integer overflow`() {
        val invalidCases = listOf(
            Triple(0, 0, 2.5f),
            Triple(-100, -200, 2.5f),
            Triple(2800, 1968, 0f),
            Triple(2800, 1968, -2f),
            Triple(2800, 1968, Float.NaN),
            Triple(2800, 1968, Float.POSITIVE_INFINITY),
        )
        invalidCases.forEach { (widthPx, heightPx, density) ->
            val layout = confirmOverlayWindowLayout(
                displayWidthPx = widthPx,
                displayHeightPx = heightPx,
                density = density,
            )
            assertEquals(Gravity.BOTTOM, layout.gravity and Gravity.VERTICAL_GRAVITY_MASK)
            assertEquals(WindowManager.LayoutParams.MATCH_PARENT, layout.width)
            assertTrue(layout.yOffsetPx > 0)
            assertFalse(layout.fitIme)
            if (heightPx <= 0) {
                assertNull(layout.maxBodyHeightPx)
            } else {
                val maxBody = layout.maxBodyHeightPx
                assertNotNull(maxBody)
                assertTrue(maxBody!! in 1..heightPx)
            }
        }

        // 极端大 density 不得在 Int 乘法/加法中溢出成负数并错误绕过宽度上限。
        listOf(5_000_000f, Float.MAX_VALUE).forEach { hugeDensity ->
            val layout = confirmOverlayWindowLayout(
                displayWidthPx = 1000,
                displayHeightPx = 1000,
                density = hugeDensity,
            )
            assertEquals(WindowManager.LayoutParams.MATCH_PARENT, layout.width)
            assertTrue(layout.yOffsetPx in 1..125)
            assertTrue((layout.maxBodyHeightPx ?: 0) in 1..500)
        }

        // 极矮窗口下正文上限仍为正且不超半屏。
        val tiny = confirmOverlayWindowLayout(displayWidthPx = 800, displayHeightPx = 300, density = 2.5f)
        assertEquals(100, tiny.maxBodyHeightPx)
    }

    @Test
    fun `lock broadcast receiver uses exported flag so SystemUI USER_PRESENT is delivered on API 34 plus`() {
        assertEquals(ContextCompat.RECEIVER_EXPORTED, CONFIRM_OVERLAY_LOCK_RECEIVER_FLAGS)
    }
}

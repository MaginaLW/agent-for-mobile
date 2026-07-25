package dev.magina.gateway.a11y

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class VisionTrustPolicyTest {

    @Test
    fun `probe region lands inside the measured input field on the reference device`() {
        // vivo V2352A 实测（2026-07-25 真机截图）：1260x2800，systemBottomInset=63，
        // 微信文字输入框约 y=2634..2755。修正前用屏幕比例算出 2352..2632，整体偏高约 130px
        // 砸在消息列表上；修正后必须完全落在输入框内。
        val box = p0FocusProbeRegion(width = 1260, height = 2800, bottomInset = 63)
        val (left, top, right, bottom) = listOf(box[0], box[1], box[2], box[3])

        assertTrue("上沿应落在输入框内（>=2634），实际 $top", top >= 2634)
        assertTrue("下沿应落在输入框内（<=2755），实际 $bottom", bottom <= 2755)
        // 水平方向避开左侧语音与右侧表情/加号图标。
        assertEquals(302, left)
        assertEquals(957, right)
    }

    @Test
    fun `probe region keeps a margin above the system gesture bar`() {
        val box = p0FocusProbeRegion(width = 1260, height = 2800, bottomInset = 63)
        assertEquals(2800 - 63 - P0_PROBE_BOTTOM_MARGIN_PX, box[3])
    }

    @Test
    fun `probe region height is stable regardless of screen size`() {
        for (height in listOf(1920, 2340, 2800, 3200)) {
            val box = p0FocusProbeRegion(width = 1080, height = height, bottomInset = 48)
            assertEquals("height=$height", P0_PROBE_HEIGHT_PX, box[3] - box[1])
        }
    }

    @Test
    fun `probe region shifts up as the system bottom inset grows`() {
        val noInset = p0FocusProbeRegion(1260, 2800, 0)
        val withInset = p0FocusProbeRegion(1260, 2800, 120)
        assertEquals(120, noInset[3] - withInset[3])
        assertEquals(120, noInset[1] - withInset[1])
    }

    @Test
    fun `recognition tier stays strictly below action tier`() {
        // 识别级只用于"当前在哪个页面"，点击级才是落点安全线；两者不得倒挂或相等。
        assertTrue(MIN_RECOGNITION_OCR_CONFIDENCE < MIN_ACTION_OCR_CONFIDENCE)
    }
}

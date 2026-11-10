package dev.magina.gateway.overlay

import org.junit.Assert.assertEquals
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
}

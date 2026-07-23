package dev.magina.gateway.a11y

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class GatewayOwnedWindowPolicyTest {
    @Test
    fun `gateway non application window is excluded`() {
        assertFalse(
            shouldExposeWindow(
                windowType = 3,
                applicationWindowType = 1,
                inputMethodWindowType = 2,
                rootPackage = "dev.magina.gateway",
                ownPackage = "dev.magina.gateway",
                confirmationAwaiting = false,
            ),
        )
    }

    @Test
    fun `gateway application and foreign overlays remain distinguishable`() {
        assertTrue(shouldExposeWindow(1, 1, 2, "dev.magina.gateway", "dev.magina.gateway", false))
        assertTrue(shouldExposeWindow(3, 1, 2, "com.vendor.overlay", "dev.magina.gateway", false))
        assertFalse(shouldExposeWindow(2, 1, 2, "com.vendor.ime", "dev.magina.gateway", false))
    }

    @Test
    fun `all non application windows are hidden while confirmation is awaiting`() {
        assertFalse(shouldExposeWindow(3, 1, 2, null, "dev.magina.gateway", true))
        assertTrue(shouldExposeWindow(1, 1, 2, "com.tencent.mm", "dev.magina.gateway", true))
    }
}

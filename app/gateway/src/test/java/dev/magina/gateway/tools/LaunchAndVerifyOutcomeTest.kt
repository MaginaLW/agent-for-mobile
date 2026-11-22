package dev.magina.gateway.tools

import dev.magina.gateway.core.ErrorCode
import dev.magina.gateway.core.GatewayError
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/** 验证系统设置 UI 兜底提示与启动/深链/Intent 失败时的 actual_package 诊断载荷。 */
class LaunchAndVerifyOutcomeTest {

    @Test
    fun `system_set_state ui fallback guides app_launch or SETTINGS instead of open_uri`() {
        val fallback = SystemTools.SYSTEM_SET_STATE_UI_FALLBACK
        assertFalse("兜底提示不得指引 open_uri 打开设置页", fallback.contains("open_uri 打开"))
        assertTrue("兜底提示应包含 app_launch", fallback.contains("app_launch"))
        assertTrue("兜底提示应包含 android.settings.SETTINGS", fallback.contains("android.settings.SETTINGS"))
    }

    @Test
    fun `openUriVerifyFailError includes actual_package when known and null when unknown`() {
        val blockedByPopup = openUriVerifyFailError("com.xingin.xhs", "com.vivo.appfilter")
        assertEquals(ErrorCode.E_VERIFY_FAIL, blockedByPopup.code)
        assertEquals("intent", blockedByPopup.channel)
        assertTrue(blockedByPopup.message.orEmpty().contains("com.vivo.appfilter"))
        assertTrue(blockedByPopup.fallback.contains("com.vivo.appfilter"))
        assertEquals("com.xingin.xhs", blockedByPopup.extra?.getString("expect_package"))
        assertEquals("com.vivo.appfilter", blockedByPopup.extra?.getString("actual_package"))

        val unknownFg = openUriVerifyFailError("com.xingin.xhs", "")
        assertEquals(ErrorCode.E_VERIFY_FAIL, unknownFg.code)
        assertTrue(unknownFg.extra?.isNull("actual_package") == true)
    }

    @Test
    fun `buildAppLaunchResult records actual_package and hint when unverified`() {
        val unverified = SystemTools.buildAppLaunchResult("com.xingin.xhs", false, "com.vivo.appfilter")
        assertTrue(unverified.getBoolean("launched"))
        assertEquals("com.xingin.xhs", unverified.getString("package"))
        assertFalse(unverified.getBoolean("foreground_verified"))
        assertEquals("com.vivo.appfilter", unverified.getString("actual_package"))
        assertTrue(unverified.optString("hint").contains("com.vivo.appfilter"))

        val verified = SystemTools.buildAppLaunchResult("com.taobao.taobao", true, "com.taobao.taobao")
        assertTrue(verified.getBoolean("foreground_verified"))
        assertEquals("com.taobao.taobao", verified.getString("actual_package"))
        assertFalse(verified.has("hint"))
    }

    @Test
    fun `finishIntentSend carries actual_package and settings fallback hint on verify fail`() {
        val error = assertThrows(GatewayError::class.java) {
            finishIntentSend(
                targetPackage = "com.android.settings",
                foregroundVerified = false,
                actualPackage = "com.vivo.safecenter",
                extraFallbackHint = "改用 app_launch(\"设置\") 打开主设置后走 UI 导航",
            )
        }
        assertEquals(ErrorCode.E_VERIFY_FAIL, error.code)
        assertTrue(error.message.orEmpty().contains("com.vivo.safecenter"))
        assertEquals("com.android.settings", error.extra?.getString("expect_package"))
        assertEquals("com.vivo.safecenter", error.extra?.getString("actual_package"))
        assertTrue(error.fallback.contains("不要重发同一 Intent"))
        assertTrue(error.fallback.contains("app_launch(\"设置\")"))
    }
}

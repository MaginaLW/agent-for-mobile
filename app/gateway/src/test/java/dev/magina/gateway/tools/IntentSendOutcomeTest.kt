package dev.magina.gateway.tools

import dev.magina.gateway.core.ErrorCode
import dev.magina.gateway.core.GatewayError
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/** 本地 JVM 无 Android Context；验证 startActivity 已接受后的纯落地判据与工具结果。 */
class IntentSendOutcomeTest {

    @Test
    fun `启动不抛错但指定包未到前台必须 E_VERIFY_FAIL`() {
        val target = "com.tencent.mm"
        val landed = isAcceptableLanding("com.android.launcher", "", target, emptyList())

        assertFalse(landed)
        val error = assertThrows(GatewayError::class.java) { finishIntentSend(target, landed) }
        assertEquals(ErrorCode.E_VERIFY_FAIL, error.code)
        assertEquals("intent", error.channel)
        assertTrue(error.fallback.contains("不要重发同一 Intent"))
    }

    @Test
    fun `指定包到前台才报告 verified`() {
        val result = finishIntentSend("com.tencent.mm", true)

        assertTrue(result.getBoolean("sent"))
        assertEquals("com.tencent.mm", result.getString("target_package"))
        assertTrue(result.getBoolean("foreground_verified"))
        assertEquals("package", result.getString("verification_scope"))
        assertEquals("verified", result.getString("verification_status"))
    }

    @Test
    fun `指定组件不能用同包其他 Activity 冒充落地`() {
        val component = "com.tencent.mm.ui.tools.ShareImgUI"
        val activities = expectedIntentLandingActivities(true, component, emptyList())
        val landed = isAcceptableLanding(
            "com.tencent.mm", "com.tencent.mm.app.WeChatSplashActivity",
            "com.tencent.mm", activities,
        )

        assertEquals(listOf(component), activities)
        assertFalse(landed)
        val error = assertThrows(GatewayError::class.java) {
            finishIntentSend("com.tencent.mm", landed, activities)
        }
        assertEquals(ErrorCode.E_VERIFY_FAIL, error.code)
        assertTrue(error.message.orEmpty().contains(component))
    }

    @Test
    fun `组件合法重定向只接受已登记的分享落地页`() {
        val landing = "com.tencent.mm.ui.transmit.MsgRetransmitUI"
        val activities = expectedIntentLandingActivities(
            true, "com.tencent.mm.ui.tools.ShareImgUI", listOf(landing),
        )

        assertEquals(listOf(landing), activities)
        assertTrue(isAcceptableLanding("com.tencent.mm", landing, "com.tencent.mm", activities))
        assertFalse(isAcceptableLanding(
            "com.tencent.mm", "com.tencent.mm.app.WeChatSplashActivity", "com.tencent.mm", activities,
        ))
        assertFalse(isAcceptableLanding("com.example.other", landing, "com.tencent.mm", activities))
        val result = finishIntentSend("com.tencent.mm", true, activities)
        assertEquals("activity", result.getString("verification_scope"))
        assertEquals("verified", result.getString("verification_status"))
    }

    @Test
    fun `非分享 action 不借用分享落地白名单`() {
        val component = "com.tencent.mm.ui.tools.ShareImgUI"
        assertEquals(
            listOf(component),
            expectedIntentLandingActivities(false, component, listOf("com.tencent.mm.OtherActivity")),
        )
    }

    @Test
    fun `没有指定目标只报告已分派未验证`() {
        val result = finishIntentSend(null, null)

        assertTrue(result.getBoolean("sent"))
        assertTrue(result.isNull("target_package"))
        assertTrue(result.isNull("foreground_verified"))
        assertTrue(result.isNull("verification_scope"))
        assertEquals("dispatched_unverified", result.getString("verification_status"))
    }

    @Test
    fun `已知目标但没有前台读回证据不能归入未知目标成功`() {
        assertEquals(
            ErrorCode.E_VERIFY_FAIL,
            assertThrows(GatewayError::class.java) { finishIntentSend("com.tencent.mm", null) }.code,
        )
    }
}

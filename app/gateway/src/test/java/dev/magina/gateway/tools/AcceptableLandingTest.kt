package dev.magina.gateway.tools

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 分享落地判据。
 *
 * 存在的理由是 M1 spike 那次假成功：微信冷启动先闪 splash，包级判据抓到
 * `WeChatSplashActivity` 就判 `true`，分享页根本没出现却报成功。收紧到 activity 级白名单后，
 * splash 不在白名单里就不算落地，轮询会继续等到真正的分享页或超时。
 */
class AcceptableLandingTest {

    private val wechat = "com.tencent.mm"
    private val shareImg = "com.tencent.mm.ui.tools.ShareImgUI"
    private val splash = "com.tencent.mm.ui.WeChatSplashActivity"

    @Test
    fun `包名不符一律不算落地`() {
        assertFalse(isAcceptableLanding("com.vivo.hiboard", "", wechat, emptyList()))
        assertFalse(isAcceptableLanding("com.vivo.hiboard", shareImg, wechat, listOf(shareImg)))
    }

    /** 白名单缺省 = 不限制 activity，回落包级历史行为——不是"没有可接受项"。 */
    @Test
    fun `白名单为空时只验包名`() {
        assertTrue(isAcceptableLanding(wechat, "", wechat, emptyList()))
        assertTrue(isAcceptableLanding(wechat, splash, wechat, emptyList()))
    }

    /** 这条就是 spike 那次假成功的回归：同一个包、同一次分享，splash 不得冒充落地。 */
    @Test
    fun `配了白名单后 splash 不冒充落地`() {
        assertFalse(isAcceptableLanding(wechat, splash, wechat, listOf(shareImg)))
        assertTrue(isAcceptableLanding(wechat, shareImg, wechat, listOf(shareImg)))
    }

    @Test
    fun `白名单命中其一即可`() {
        val landing = listOf(shareImg, "com.tencent.mm.ui.transmit.MsgRetransmitUI")

        assertTrue(isAcceptableLanding(wechat, shareImg, wechat, landing))
        assertTrue(isAcceptableLanding(wechat, landing[1], wechat, landing))
        assertFalse(isAcceptableLanding(wechat, splash, wechat, landing))
    }

    /**
     * activity 读不出来（空串）时**不算落地**。
     * 自举身份天生没有 activity，这时不能假定它落对了——方向是 fail-closed。
     */
    @Test
    fun `配了白名单但 activity 读不出来时不算落地`() {
        assertFalse(isAcceptableLanding(wechat, "", wechat, listOf(shareImg)))
    }

    /**
     * 只做精确全类名匹配，不做后缀或子串匹配：短名在不同 app 里可能重名，
     * 子串匹配会把白名单悄悄放宽成"看着像就行"。
     */
    @Test
    fun `只认全类名精确匹配`() {
        assertFalse(isAcceptableLanding(wechat, "ShareImgUI", wechat, listOf(shareImg)))
        assertFalse(isAcceptableLanding(wechat, "com.evil.app.ui.tools.ShareImgUI", wechat, listOf(shareImg)))
    }
}

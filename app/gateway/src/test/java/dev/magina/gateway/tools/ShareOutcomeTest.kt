package dev.magina.gateway.tools

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 分享终态判定的判据。
 *
 * 为什么只测纯函数不测 [IntentTools.share]：本模块单测环境没有 Robolectric，
 * `Intent`/`Context`/`ComponentName` 一被调用就抛 "not mocked"，所以判据只能挂在
 * 不碰 Android 类型的纯逻辑上。这也是 `resolveShareOutcome` 被抽出来的唯一理由——
 * **判据要挂在能被机械验证的东西上**；把断言写成"源码里有 throw"等于没覆盖。
 */
class ShareOutcomeTest {

    @Test
    fun `直达组件验不上前台判定为假成功`() {
        val outcome = resolveShareOutcome(ShareChannel.DIRECT_COMPONENT, "com.tencent.mm", false)

        assertTrue("验过且没验上必须 fail-closed", outcome.verifyFailed)
        assertEquals(false, outcome.foregroundVerified)
    }

    @Test
    fun `package 定向验不上前台判定为假成功`() {
        val outcome = resolveShareOutcome(ShareChannel.PACKAGE, "com.tencent.mm", false)

        assertTrue(outcome.verifyFailed)
    }

    @Test
    fun `两条定向通道验上前台即通过`() {
        for (channel in listOf(ShareChannel.DIRECT_COMPONENT, ShareChannel.PACKAGE)) {
            val outcome = resolveShareOutcome(channel, "com.tencent.mm", true)

            assertFalse("$channel 验上了不该判失败", outcome.verifyFailed)
            assertEquals(true, outcome.foregroundVerified)
            assertEquals("com.tencent.mm", outcome.target)
        }
    }

    /**
     * `null` 是「不可验」不是「验失败」。系统面板没有已知目标包，前台无从验起；
     * 把不可验当成验失败会把一条本来正常的路径判死，方向恰好与 fail-closed 相反
     * ——它不是更安全，是**诬告**（同 OCR 链上 `Unverified` 与 `Mismatch` 必须分开的道理）。
     */
    @Test
    fun `系统面板不可验时如实报 null 且不判失败`() {
        val outcome = resolveShareOutcome(ShareChannel.CHOOSER, "", null)

        assertFalse(outcome.verifyFailed)
        assertEquals(null, outcome.foregroundVerified)
    }

    /** 系统面板整体豁免于前台判据：即便传入 false 也不判失败，因为它压根没有已知目标可验。 */
    @Test
    fun `系统面板豁免于前台判据`() {
        val outcome = resolveShareOutcome(ShareChannel.CHOOSER, "", false)

        assertFalse(outcome.verifyFailed)
    }

    /** `wireName` 会进结果 JSON 的 `channel` 字段，是对外契约，改动等于改契约。 */
    @Test
    fun `通道名是对外契约不得随枚举改名漂移`() {
        assertEquals("direct_component", ShareChannel.DIRECT_COMPONENT.wireName)
        assertEquals("package", ShareChannel.PACKAGE.wireName)
        assertEquals("chooser", ShareChannel.CHOOSER.wireName)
        assertEquals(3, ShareChannel.entries.size)
    }
}

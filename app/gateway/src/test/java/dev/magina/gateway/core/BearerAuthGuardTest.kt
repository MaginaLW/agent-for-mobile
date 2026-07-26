package dev.magina.gateway.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BearerAuthGuardTest {

    // 故意不做成 32 位裸十六进制：那正是真 token 的形态，凭据扫描会（正确地）把它当泄漏报出来。
    // 测试夹具本来也不该长得像真凭据。
    private val token = "fixture-token-NOT-A-REAL-SECRET"

    @Test
    fun `正确的 Bearer 放行且不产生延迟`() {
        val guard = BearerAuthGuard(token)
        val verdict = guard.check("Bearer $token")
        assertTrue(verdict.allowed)
        assertEquals(0L, verdict.delayMs)
    }

    @Test
    fun `缺头、错前缀、错 token 一律拒绝`() {
        val guard = BearerAuthGuard(token)
        assertFalse(guard.check(null).allowed)
        assertFalse(guard.check("").allowed)
        assertFalse(guard.check(token).allowed)               // 少了 Bearer 前缀
        assertFalse(guard.check("Basic $token").allowed)
        assertFalse(guard.check("Bearer ${token.dropLast(1)}x").allowed)
    }

    @Test
    fun `连续失败超过免费额度后才开始退避，且有上限`() {
        val guard = BearerAuthGuard(token, freeAttempts = 3, stepDelayMs = 100, maxDelayMs = 500)
        repeat(3) { assertEquals(0L, guard.check("Bearer wrong").delayMs) }
        assertEquals(100L, guard.check("Bearer wrong").delayMs)
        assertEquals(200L, guard.check("Bearer wrong").delayMs)
        assertEquals(300L, guard.check("Bearer wrong").delayMs)
        repeat(10) { guard.check("Bearer wrong") }
        assertEquals(500L, guard.check("Bearer wrong").delayMs)
    }

    /** 退避不能变成自我 DoS：同机任何进程乱打之后，持有正确 token 的调用必须照常放行。 */
    @Test
    fun `一次成功即清零退避`() {
        val guard = BearerAuthGuard(token, freeAttempts = 1, stepDelayMs = 100, maxDelayMs = 500)
        repeat(5) { guard.check("Bearer wrong") }
        val ok = guard.check("Bearer $token")
        assertTrue(ok.allowed)
        assertEquals(0L, ok.delayMs)
        assertEquals(0L, guard.check("Bearer wrong").delayMs)
    }

    @Test
    fun `常量时间比较对长度与内容都成立`() {
        assertTrue(BearerAuthGuard.constantTimeEquals("abc", "abc"))
        assertFalse(BearerAuthGuard.constantTimeEquals("abc", "abd"))
        assertFalse(BearerAuthGuard.constantTimeEquals("abc", "ab"))
        assertFalse(BearerAuthGuard.constantTimeEquals("ab", "abc"))
        assertTrue(BearerAuthGuard.constantTimeEquals("", ""))
        // 只差最后一个字节与只差第一个字节都必须判否（不能提前返回造成可测差异）。
        assertFalse(BearerAuthGuard.constantTimeEquals("x0123456789", "y0123456789"))
        assertFalse(BearerAuthGuard.constantTimeEquals("0123456789x", "0123456789y"))
    }
}

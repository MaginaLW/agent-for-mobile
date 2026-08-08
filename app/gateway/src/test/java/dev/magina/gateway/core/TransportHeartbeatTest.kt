package dev.magina.gateway.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 心跳与客户端空闲窗的关系（spec §9.8 / knowledge `brain/harness.md`）。
 *
 * 这套用例存在的理由：**两个数一旦被人分别改动，失效方式是静默的**——心跳变稀或空闲窗
 * 变紧，都只表现为"某次长调用莫名其妙超时"，而那与"功能坏了"在现场分不开。
 * 所以关系写成断言，并在这里被机械执行到。
 */
class TransportHeartbeatTest {

    @Test
    fun `the heartbeat interval leaves real headroom inside the client idle window`() {
        // 2026-08-08 实测：HTTP/SSE 的空闲看门狗是 300s，per-server timeout 抬不动它
        // （文档说能，实测在 claude 2.1.206 上不能）。
        assertEquals(300_000L, TransportHeartbeatPolicy.CLIENT_IDLE_WINDOW_MS)
        assertEquals(60_000L, TransportHeartbeatPolicy.HEARTBEAT_INTERVAL_MS)
        assertEquals(5, TransportHeartbeatPolicy.beatsPerIdleWindow)
        assertTrue(
            "余量必须够 ${TransportHeartbeatPolicy.MIN_BEATS_WITHIN_IDLE_WINDOW} 拍",
            TransportHeartbeatPolicy.beatsPerIdleWindow >=
                TransportHeartbeatPolicy.MIN_BEATS_WITHIN_IDLE_WINDOW,
        )
    }

    @Test
    fun `an unwired heartbeat says so instead of pretending it beat`() {
        // 没装心跳通道 = 一拍没发。**取证串必须能把它与"发过"分开**：
        // 长调用被空闲窗砍掉时，"传输层没顶住"与"判据挡下的"必须当场分得开。
        assertEquals("beats=0,token=no", NoHeartbeat.describe())
    }

    @Test
    fun `the heartbeat evidence string carries both the count and whether a token existed`() {
        // token 缺席时协议上发不了进度通知——那不是"没必要发"，是"发不出去"，
        // 两者在台账上必须分得开。
        val beat = object : CallHeartbeat {
            override fun beats(): Int = 5
            override fun tokenPresent(): Boolean = true
        }

        assertEquals("beats=5,token=yes", beat.describe())
    }

    @Test
    fun `the payload carries no approved content and no instructions`() {
        // 两条约束合成一条用例：心跳是**发给大脑的**，它既不许带已批准内容
        // （那会把 contentNormalized 那一整套"不落盘/不进日志/不进 trace"一次作废），
        // 也不许带任何"正在等前台、稍后回来"这类给执行器的暗示
        // （提示词里特意一个字都不提切走/等待/停留，心跳写了等于从另一头把洞挖开）。
        //
        // 判据挂在**取证串本身**上：它是这条链上唯一会被写进审计的心跳文本。
        val rendered = object : CallHeartbeat {
            override fun beats(): Int = 3
            override fun tokenPresent(): Boolean = true
        }.describe()

        assertTrue(rendered, rendered.matches(Regex("^beats=\\d+,token=(yes|no)$")))
    }
}

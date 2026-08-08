package dev.magina.gateway.core

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * `tools/call` 回流式还是回整包 JSON 的协商判据。
 *
 * **这套用例守的是两个方向，缺一个就等于没守**：
 * - 真实大脑那条 `Accept` 必须仍然走流式——否则心跳消失、300s 空闲窗回来，
 *   而失败形态与批次 4 首跑一模一样（约 90s 断开、无错误码），最难认；
 * - 直连只读探针那条必须仍然走整包 JSON——否则 `data: {...}` 会顶翻它们的解析器，
 *   Allow 腿在第 1 腿判死，**而消息其实已经发出去了**（2026-08-08 实锤）。
 *
 * 只验一个方向，"把 SSE 整个关掉"也能让它变绿——那会悄悄把 300s 天花板放回来。
 */
class AcceptNegotiationTest {

    @Test
    fun `the measured real client accept still selects the streaming path`() {
        // claude 2.1.206 实测（四次独立观测）。**它变了，这条用例先红，而不是真机先红。**
        assertTrue(AcceptNegotiation.wantsEventStream(AcceptNegotiation.MEASURED_CLIENT_ACCEPT))
    }

    @Test
    fun `the direct read-only probes still get one whole json body`() {
        assertFalse(AcceptNegotiation.wantsEventStream(AcceptNegotiation.PLAIN_JSON_ACCEPT))
    }

    @Test
    fun `a missing accept header falls back to the non streaming side`() {
        // fail-safe 方向选这边：猜错成流式会打死一个只会解 JSON 的老实客户端（今天这次），
        // 猜错成非流式只是退回没有心跳的老行为——仍会失败，但不会把别人的解析器打死。
        assertFalse(AcceptNegotiation.wantsEventStream(null))
        assertFalse(AcceptNegotiation.wantsEventStream(""))
    }

    @Test
    fun `content negotiation handles quality values and spacing`() {
        assertTrue(AcceptNegotiation.wantsEventStream("text/event-stream"))
        assertTrue(AcceptNegotiation.wantsEventStream("application/json,text/event-stream"))
        assertTrue(AcceptNegotiation.wantsEventStream("application/json, text/event-stream;q=0.9"))
        assertTrue(AcceptNegotiation.wantsEventStream("TEXT/EVENT-STREAM"))
    }

    @Test
    fun `a lookalike media type does not select streaming`() {
        // 子串匹配会把这些误判成流式；判据按逗号切分再逐项比，不是 contains。
        assertFalse(AcceptNegotiation.wantsEventStream("application/text/event-stream-ish"))
        assertFalse(AcceptNegotiation.wantsEventStream("text/event-streamx"))
        assertFalse(AcceptNegotiation.wantsEventStream("*/*"))
    }
}

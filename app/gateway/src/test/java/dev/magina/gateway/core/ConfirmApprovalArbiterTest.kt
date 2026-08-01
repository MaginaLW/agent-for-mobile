package dev.magina.gateway.core

import java.util.concurrent.CompletableFuture
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * 批次 2 接缝 1（一次性凭据）与接缝 2（两条通道共用一个 CAS）的判据。
 *
 * 这两条是整个通知栏审批的地基：一旦"卡上拒绝、通知上允许"能同时生效，安全门就名存实亡，
 * 而那种状态的失败形态与成功一模一样（Deny 腿假通过已经实锤过这类形态）。
 */
class ConfirmApprovalArbiterTest {

    private lateinit var future: CompletableFuture<Boolean>

    @Before
    fun setUp() {
        ConfirmApprovalArbiter.resetForTest()
        future = CompletableFuture()
    }

    @After
    fun tearDown() {
        ConfirmApprovalArbiter.resetForTest()
    }

    @Test
    fun `first decision wins and the second is dropped`() {
        ConfirmApprovalArbiter.open("c-1", "n-1", future::complete)

        assertEquals(ApprovalOutcome.ACCEPTED, ConfirmApprovalArbiter.decide("c-1", "n-1", true))
        // 同一次确认的第二个决定——不管它说什么——都必须被丢弃。
        assertEquals(ApprovalOutcome.ALREADY_DECIDED, ConfirmApprovalArbiter.decide("c-1", "n-1", false))
        assertTrue("先到的允许必须是最终结果", future.get())
    }

    /** 悬浮卡先点了拒绝：通知那一边随后点允许，绝不能翻盘。 */
    @Test
    fun `overlay decision already taken blocks the notification channel`() {
        ConfirmApprovalArbiter.open("c-1", "n-1", future::complete)
        future.complete(false) // 卡上的按钮直接完成同一个 future

        assertEquals(ApprovalOutcome.ALREADY_DECIDED, ConfirmApprovalArbiter.decide("c-1", "n-1", true))
        assertFalse("卡上先点的拒绝必须是最终结果", future.get())
    }

    @Test
    fun `wrong nonce or id never decides`() {
        ConfirmApprovalArbiter.open("c-1", "n-1", future::complete)

        assertEquals(ApprovalOutcome.NONCE_MISMATCH, ConfirmApprovalArbiter.decide("c-1", "n-2", true))
        assertEquals(ApprovalOutcome.ID_MISMATCH, ConfirmApprovalArbiter.decide("c-2", "n-1", true))
        assertFalse("凭据或编号不符时不得落下任何决定", future.isDone)
    }

    /** 回执重放：上一次确认的 PendingIntent 被再次触发，不得决定**下一次**确认。 */
    @Test
    fun `replayed receipt from a previous confirmation cannot decide the next one`() {
        ConfirmApprovalArbiter.open("c-1", "n-1", future::complete)
        assertEquals(ApprovalOutcome.ACCEPTED, ConfirmApprovalArbiter.decide("c-1", "n-1", true))

        val next = CompletableFuture<Boolean>()
        ConfirmApprovalArbiter.open("c-2", "n-2", next::complete)
        assertEquals(ApprovalOutcome.ID_MISMATCH, ConfirmApprovalArbiter.decide("c-1", "n-1", true))
        assertFalse("旧回执不得决定新的确认", next.isDone)
    }

    @Test
    fun `closed window accepts nothing`() {
        ConfirmApprovalArbiter.open("c-1", "n-1", future::complete)
        ConfirmApprovalArbiter.close("c-1")

        assertEquals(ApprovalOutcome.NO_PENDING, ConfirmApprovalArbiter.decide("c-1", "n-1", true))
        assertFalse(future.isDone)
    }

    /** 只关自己那一次：后开的窗口不该被前一次的收摊误关。 */
    @Test
    fun `close only affects its own confirmation`() {
        ConfirmApprovalArbiter.open("c-2", "n-2", future::complete)
        ConfirmApprovalArbiter.close("c-1")

        assertEquals(ApprovalOutcome.ACCEPTED, ConfirmApprovalArbiter.decide("c-2", "n-2", true))
    }

    @Test
    fun `nonce is long random and never repeats`() {
        val nonces = (1..200).map { ConfirmApprovalArbiter.newNonce() }

        assertEquals("200 个 nonce 必须互不相同", 200, nonces.toSet().size)
        nonces.forEach {
            assertEquals("nonce 必须是 128 位十六进制", 32, it.length)
            assertTrue(it.matches(Regex("[0-9a-f]{32}")))
        }
    }

    /** 并发两条通道同时送决定：只能有一个 ACCEPTED，且 future 只被完成一次。 */
    @Test
    fun `concurrent decisions yield exactly one acceptance`() {
        repeat(50) {
            ConfirmApprovalArbiter.resetForTest()
            val shared = CompletableFuture<Boolean>()
            ConfirmApprovalArbiter.open("c-1", "n-1", shared::complete)
            val outcomes = java.util.concurrent.ConcurrentLinkedQueue<ApprovalOutcome>()
            val start = CompletableFuture<Unit>()
            val threads = listOf(true, false).map { allowed ->
                Thread {
                    start.get()
                    outcomes.add(ConfirmApprovalArbiter.decide("c-1", "n-1", allowed))
                }.also(Thread::start)
            }
            start.complete(Unit)
            threads.forEach(Thread::join)

            assertEquals(
                "恰好一个决定生效",
                1,
                outcomes.count { outcome -> outcome == ApprovalOutcome.ACCEPTED },
            )
            assertTrue(shared.isDone)
        }
    }
}

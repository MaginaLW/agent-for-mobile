package dev.magina.gateway.overlay

import dev.magina.gateway.core.ApprovalChannel
import dev.magina.gateway.core.ApprovalChannelRecorder
import dev.magina.gateway.core.ApprovalOutcome
import dev.magina.gateway.core.ConfirmApprovalArbiter
import java.util.concurrent.CompletableFuture
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class ConfirmDecisionReceiverPolicyTest {

    private lateinit var future: CompletableFuture<Boolean>
    private lateinit var recorder: ApprovalChannelRecorder

    @Before
    fun setUp() {
        ConfirmApprovalArbiter.resetForTest()
        future = CompletableFuture()
        recorder = ApprovalChannelRecorder(future::complete)
        ConfirmApprovalArbiter.open("confirmation-a", "nonce-a") { allowed ->
            recorder.decide(ApprovalChannel.NOTIFICATION, allowed)
        }
    }

    @After
    fun tearDown() {
        ConfirmApprovalArbiter.resetForTest()
    }

    @Test
    fun `forged or residual notification allow cannot approve`() {
        assertNull(decideFromNotification("confirmation-a", "nonce-a", allowed = true))
        assertFalse("allowed=true 广播不得完成确认", future.isDone)
        assertTrue("拒收广播后确认窗口仍应等待真人", ConfirmApprovalArbiter.isPending)
        assertNull(recorder.winner())
    }

    @Test
    fun `rejecting notification allow does not block visible overlay approval`() {
        assertNull(decideFromNotification("confirmation-a", "nonce-a", allowed = true))

        // ConfirmOverlay 的按钮正是直接调用 recorder，不经过广播接收器。
        assertTrue(recorder.decide(ApprovalChannel.OVERLAY, allowed = true))
        assertTrue(future.get())
        assertEquals(ApprovalChannel.OVERLAY, recorder.winner())
    }

    @Test
    fun `notification deny remains a valid one way decision`() {
        assertEquals(
            ApprovalOutcome.ACCEPTED,
            decideFromNotification("confirmation-a", "nonce-a", allowed = false),
        )
        assertFalse(future.get())
        assertEquals(ApprovalChannel.NOTIFICATION, recorder.winner())
    }
}

package dev.magina.gateway.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CompletableFuture

class ApprovalChannelRecorderTest {

    @Test
    fun `no decision means no channel`() {
        val recorder = ApprovalChannelRecorder(CompletableFuture<Boolean>()::complete)

        // 超时那条路上没人点过任何东西；此时记成任一通道都是凭空造证据。
        assertNull(recorder.winner())
    }

    @Test
    fun `winner is the channel whose decision took effect`() {
        val future = CompletableFuture<Boolean>()
        val recorder = ApprovalChannelRecorder(future::complete)

        assertTrue(recorder.decide(ApprovalChannel.NOTIFICATION, true))

        assertEquals(ApprovalChannel.NOTIFICATION, recorder.winner())
        assertTrue(future.get())
    }

    @Test
    fun `late loser neither wins nor overwrites the recorded channel`() {
        val future = CompletableFuture<Boolean>()
        val recorder = ApprovalChannelRecorder(future::complete)

        assertTrue(recorder.decide(ApprovalChannel.OVERLAY, false))
        // 并联的另一条通道随后到达：CAS 只会成功一次，取证也必须跟着胜负走。
        assertFalse(recorder.decide(ApprovalChannel.NOTIFICATION, true))

        assertEquals(ApprovalChannel.OVERLAY, recorder.winner())
        assertFalse(future.get())
    }

    @Test
    fun `recorder adds no second arbitration point`() {
        // complete 说了算：它返回 false 时，这一次决定既不生效也不被记录，
        // 哪怕它是第一个到达 recorder 的。
        val recorder = ApprovalChannelRecorder { false }

        assertFalse(recorder.decide(ApprovalChannel.NOTIFICATION, true))
        assertNull(recorder.winner())
    }

    @Test
    fun `wire names are the ones written into evidence`() {
        // 状态文件与审计里出现的就是这两个串；改了它们等于改取证格式。
        assertEquals("overlay", ApprovalChannel.OVERLAY.wireName)
        assertEquals("notification", ApprovalChannel.NOTIFICATION.wireName)
    }
}

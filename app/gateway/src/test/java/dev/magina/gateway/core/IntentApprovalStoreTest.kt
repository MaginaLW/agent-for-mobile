package dev.magina.gateway.core

import java.util.concurrent.Callable
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class IntentApprovalStoreTest {
    private var now = 1_000L
    private val intent = IntentApprovalFixtures.intent()
    private fun store() = IntentApprovalStore(intent, "confirm-1", "nonce-1", clock = { now })
    private fun IntentApprovalStore.allow() = decide("confirm-1", "nonce-1", true)

    @Test
    fun `未确认的任一档位消费均为空且永远不能再允许`() {
        for (tier in RiskTier.entries) {
            val store = IntentApprovalStore(intent.copy(riskTier = tier), "confirm-1", "nonce-1", clock = { now })
            assertNull(store.consume(intent.intentId))
            assertFalse(store.isPending)
            assertEquals(IntentApprovalOutcome.NO_PENDING, store.allow())
        }
    }

    @Test
    fun `真人允许写一次批准时间且重复允许拒绝都不能刷新`() {
        val store = store()
        now = 80_000
        assertEquals(IntentApprovalOutcome.APPROVED, store.allow())
        assertNull("原始请求始终保持未批准", intent.approvedAtMs)
        now = 90_000
        assertEquals(IntentApprovalOutcome.ALREADY_DECIDED, store.allow())
        assertEquals(IntentApprovalOutcome.ALREADY_DECIDED, store.decide("confirm-1", "nonce-1", false))
        assertEquals(80_000L, store.consume(intent.intentId)?.approvedAtMs)
    }

    @Test
    fun `错误编号与 nonce 不产生决定也不销毁当前审批`() {
        val store = store()
        assertEquals(IntentApprovalOutcome.ID_MISMATCH, store.decide("other", "nonce-1", true))
        assertEquals(IntentApprovalOutcome.NONCE_MISMATCH, store.decide("confirm-1", "nonce-2", true))
        assertEquals(IntentApprovalOutcome.APPROVED, store.allow())
        assertNotNull(store.consume(intent.intentId))
    }

    @Test
    fun `旧回执不能批准下一次确认`() {
        val first = store()
        first.allow()
        first.consume(intent.intentId)
        val nextIntent = intent.copy(intentId = "intent-2")
        val next = IntentApprovalStore(nextIntent, "confirm-2", "nonce-2", clock = { now })
        assertEquals(IntentApprovalOutcome.ID_MISMATCH, next.allow())
        assertEquals(IntentApprovalOutcome.NONCE_MISMATCH, next.decide("confirm-2", "nonce-1", true))
        assertNull(next.consume(nextIntent.intentId))
        assertEquals(IntentApprovalOutcome.NO_PENDING, first.allow())
    }

    @Test
    fun `拒绝获胜后再允许和消费都不能复活`() {
        val store = store()
        assertEquals(IntentApprovalOutcome.DENIED, store.decide("confirm-1", "nonce-1", false))
        assertEquals(IntentApprovalOutcome.NO_PENDING, store.allow())
        assertNull(store.consume(intent.intentId))
    }

    @Test
    fun `决策截止前一毫秒仍可批准且批准后不再受决策时钟取消`() {
        val store = store()
        now = 90_999
        assertEquals(IntentApprovalOutcome.APPROVED, store.allow())
        now = 91_000
        assertFalse(store.expire())
        now = 390_999
        assertNotNull(store.consume(intent.intentId))
    }

    @Test
    fun `决策恰好到期无法批准且回调不能使它复活`() {
        val store = store()
        now = 91_000
        assertEquals(IntentApprovalOutcome.EXPIRED, store.allow())
        now = 91_001
        assertEquals(IntentApprovalOutcome.NO_PENDING, store.allow())
        assertNull(store.consume(intent.intentId))
    }

    @Test
    fun `定时器到期销毁未批准的请求`() {
        val store = store()
        now = 90_999
        assertFalse(store.expire())
        now = 91_000
        assertTrue(store.expire())
        assertFalse(store.expire())
        assertNull(store.consume(intent.intentId))
        assertEquals(IntentApprovalOutcome.NO_PENDING, store.allow())
    }

    @Test
    fun `意图 TTL 从批准起算且恰好到期消费为空`() {
        val store = store()
        now = 80_000
        store.allow()
        now = 440_000
        assertNull(store.consume(intent.intentId))
        assertFalse(store.isPending)
        assertEquals(IntentApprovalOutcome.NO_PENDING, store.allow())
    }

    @Test
    fun `错误消费和取消不影响当前唯一意图`() {
        val store = store()
        store.allow()
        assertNull(store.consume("other"))
        assertFalse(store.discard("other"))
        assertNotNull(store.consume(intent.intentId))
        assertNull(store.consume(intent.intentId))
    }

    @Test
    fun `消费在执行前销毁即使执行抛错也没有第二次机会`() {
        val store = store()
        store.allow()
        var executorCalls = 0
        val failure = runCatching {
            checkNotNull(store.consume(intent.intentId))
            assertFalse(store.isPending)
            executorCalls += 1
            error("模拟执行失败")
        }
        assertTrue(failure.isFailure)
        store.consume(intent.intentId)?.let { executorCalls += 1 }
        assertEquals(1, executorCalls)
        assertEquals(IntentApprovalOutcome.NO_PENDING, store.allow())
    }

    @Test
    fun `主动取消永远销毁这一轮`() {
        val store = store()
        store.allow()
        assertTrue(store.discard(intent.intentId))
        assertFalse(store.discard(intent.intentId))
        assertNull(store.consume(intent.intentId))
        assertEquals(IntentApprovalOutcome.NO_PENDING, store.allow())
    }

    @Test
    fun `时钟倒退必须销毁而不能增加剩余预算`() {
        val store = store()
        now = 2_000
        store.allow()
        now = 3_000
        assertFalse(store.expire())
        now = 2_500 // 仍晚于 approvedAt，但比上次观察早。
        assertNull(store.consume(intent.intentId))
        now = 3_001
        assertEquals(IntentApprovalOutcome.NO_PENDING, store.allow())
    }

    @Test
    fun `批准前时钟回退也必须销毁`() {
        val store = store()
        now = 999
        assertEquals(IntentApprovalOutcome.EXPIRED, store.allow())
        now = 1_000
        assertEquals(IntentApprovalOutcome.NO_PENDING, store.allow())
    }

    @Test
    fun `时钟异常销毁已批准意图且不恢复`() {
        var fails = false
        val store = IntentApprovalStore(intent, "confirm-1", "nonce-1", clock = {
            if (fails) error("模拟时钟故障") else now
        })
        store.allow()
        fails = true
        assertTrue(runCatching { store.expire() }.isFailure)
        fails = false
        assertNull(store.consume(intent.intentId))
    }

    @Test
    fun `已有批准数据不能用来初始化新一轮`() {
        val failure = runCatching {
            IntentApprovalStore(intent.copy(approvedAtMs = 1_000), "confirm-1", "nonce-1")
        }
        assertTrue(failure.exceptionOrNull() is IllegalArgumentException)
    }

    @Test
    fun `并发允许和拒绝恰好只有一个决定生效`() {
        repeat(25) {
            val store = store()
            val outcomes = race(listOf(
                { store.allow() },
                { store.decide("confirm-1", "nonce-1", false) },
            ))
            assertEquals(1, outcomes.count { it == IntentApprovalOutcome.APPROVED || it == IntentApprovalOutcome.DENIED })
            assertEquals(outcomes.contains(IntentApprovalOutcome.APPROVED), store.consume(intent.intentId) != null)
        }
    }

    @Test
    fun `并发消费只有一个调用取得执行数据`() {
        val store = store()
        store.allow()
        val consumed = race(List(8) { { store.consume(intent.intentId) } })
        assertEquals(1, consumed.count { it != null })
        assertFalse(store.isPending)
    }

    @Test
    fun `截止点允许拒绝和超时竞争都不能产出批准`() {
        val store = store()
        now = 91_000
        val outcomes = race(listOf(
            { store.allow().name },
            { store.decide("confirm-1", "nonce-1", false).name },
            { if (store.expire()) "TIMER_EXPIRED" else "NO_PENDING" },
        ))
        assertEquals(1, outcomes.count { it == "EXPIRED" || it == "TIMER_EXPIRED" })
        assertNull(store.consume(intent.intentId))
    }

    private fun <T> race(actions: List<() -> T>): List<T> {
        val executor = Executors.newFixedThreadPool(actions.size)
        val start = CountDownLatch(1)
        try {
            val futures = actions.map { action ->
                executor.submit(Callable { start.await(); action() })
            }
            start.countDown()
            return futures.map { it.get(5, TimeUnit.SECONDS) }
        } finally {
            start.countDown()
            executor.shutdownNow()
            assertTrue(executor.awaitTermination(5, TimeUnit.SECONDS))
        }
    }
}

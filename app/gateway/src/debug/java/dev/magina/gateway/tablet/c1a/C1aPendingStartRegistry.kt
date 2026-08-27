package dev.magina.gateway.tablet.c1a

import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

internal enum class C1aPendingAwait { NONE, COMPLETED, TIMED_OUT }

/**
 * 只为消除 `content write` 关闭 pipe 与首次 status/abort 之间的进程内竞态；不轮询、不 sleep。
 * claim 与 cancel 共用同一把锁，且 claim 在锁内完成 session start，避免 cancel ACK 后晚到的 worker 建 session。
 */
internal class C1aPendingStartRegistry {
    internal inner class Ticket internal constructor(
        val envelope: C1aStartEnvelope,
        internal val future: CompletableFuture<Unit>,
    ) {
        val key: C1aSessionKey get() = envelope.key

        /** 无论 claim 是否成功，worker 持有的原始 T0 都在返回前清零。 */
        fun claimStart(rawT0: ByteArray, block: () -> Unit): Boolean = try {
            claim(this, block)
        } finally {
            rawT0.fill(0)
        }

        /** 输入读取自身失败时，也必须先赢得同一原子 claim 才能落失败终态。 */
        fun claimFailure(block: () -> Unit): Boolean = claim(this, block)

        fun complete() {
            future.complete(Unit)
            synchronized(this@C1aPendingStartRegistry) {
                val current = pending
                if (current?.future === future) {
                    current.state = PendingState.FINISHED
                    pending = null
                }
            }
        }
    }

    private enum class PendingState { OPEN, CLAIMED, CANCELLED, FINISHED }

    private data class Pending(
        val envelope: C1aStartEnvelope,
        val future: CompletableFuture<Unit>,
        val cancelInput: () -> Unit,
        var state: PendingState = PendingState.OPEN,
    )

    @Volatile private var pending: Pending? = null

    @Synchronized
    fun register(envelope: C1aStartEnvelope, cancelInput: () -> Unit): Ticket {
        val future = CompletableFuture<Unit>()
        require(pending == null) { "another T0 write is already pending" }
        pending = Pending(envelope, future, cancelInput)
        return Ticket(envelope, future)
    }

    /**
     * 取消仅能战胜尚未 claim 的同 key pending。onCancelled 在 registry 锁内运行，因此它可用一致的
     * registry -> session lock order 原子写入 nonce/run ledger，并生成可机械核验的 cleanup ACK。
     */
    @Synchronized
    fun <T : Any> cancel(key: C1aSessionKey, onCancelled: (C1aStartEnvelope) -> T): T? {
        val current = pending?.takeIf { it.envelope.key == key && it.state == PendingState.OPEN }
            ?: return null
        current.state = PendingState.CANCELLED
        return try {
            onCancelled(current.envelope)
        } finally {
            runCatching(current.cancelInput)
            current.future.complete(Unit)
            if (pending === current) pending = null
        }
    }

    fun await(key: C1aSessionKey, timeoutMillis: Long): C1aPendingAwait {
        require(timeoutMillis >= 0) { "pending T0 wait timeout is invalid" }
        val future = pending?.takeIf { it.envelope.key == key }?.future ?: return C1aPendingAwait.NONE
        return try {
            future.get(timeoutMillis, TimeUnit.MILLISECONDS)
            C1aPendingAwait.COMPLETED
        } catch (_: TimeoutException) {
            C1aPendingAwait.TIMED_OUT
        } catch (_: Exception) {
            // complete()/cancel() 不异常完成；若 runtime 自身异常，仍按确定性失败处理。
            C1aPendingAwait.TIMED_OUT
        }
    }

    @Synchronized
    private fun claim(ticket: Ticket, block: () -> Unit): Boolean {
        val current = pending?.takeIf {
            it.future === ticket.future && it.envelope == ticket.envelope && it.state == PendingState.OPEN
        } ?: return false
        current.state = PendingState.CLAIMED
        block()
        return true
    }
}

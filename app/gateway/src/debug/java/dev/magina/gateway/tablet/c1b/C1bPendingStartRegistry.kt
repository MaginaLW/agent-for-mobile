package dev.magina.gateway.tablet.c1b

import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

internal enum class C1bPendingAwait { NONE, COMPLETED, TIMED_OUT }

/** Atomically bridges pipe close, worker claim, status, and abort without polling or sleeping. */
internal class C1bPendingStartRegistry {
    internal inner class Ticket internal constructor(
        val envelope: C1bStartEnvelope,
        internal val future: CompletableFuture<Unit>,
    ) {
        val key: C1bSessionKey get() = envelope.key

        fun claimStart(rawT0: ByteArray, block: () -> Unit): Boolean = try {
            claim(this, block)
        } finally {
            rawT0.fill(0)
        }

        fun claimFailure(block: () -> Unit): Boolean = claim(this, block)

        fun complete() {
            future.complete(Unit)
            synchronized(this@C1bPendingStartRegistry) {
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
        val envelope: C1bStartEnvelope,
        val future: CompletableFuture<Unit>,
        val cancelInput: () -> Unit,
        var state: PendingState = PendingState.OPEN,
    )

    @Volatile private var pending: Pending? = null

    @Synchronized
    fun register(envelope: C1bStartEnvelope, cancelInput: () -> Unit): Ticket {
        val future = CompletableFuture<Unit>()
        require(pending == null) { "another C1b T0 write is already pending" }
        pending = Pending(envelope, future, cancelInput)
        return Ticket(envelope, future)
    }

    @Synchronized
    fun <T : Any> cancel(key: C1bSessionKey, onCancelled: (C1bStartEnvelope) -> T): T? {
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

    fun await(key: C1bSessionKey, timeoutMillis: Long): C1bPendingAwait {
        require(timeoutMillis >= 0L) { "pending C1b T0 wait timeout is invalid" }
        val future = pending?.takeIf { it.envelope.key == key }?.future ?: return C1bPendingAwait.NONE
        return try {
            future.get(timeoutMillis, TimeUnit.MILLISECONDS)
            C1bPendingAwait.COMPLETED
        } catch (_: TimeoutException) {
            C1bPendingAwait.TIMED_OUT
        } catch (_: Exception) {
            C1bPendingAwait.TIMED_OUT
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

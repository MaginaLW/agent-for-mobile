package dev.magina.gateway.tablet.visionprobe

/** Metadata-only synchronous borrow: do not retain pixels; close before returning from onSuccess.
 * The adapter also closes on callback exit. close must be idempotent, even after a failed release attempt.
 */
internal interface WindowCaptureBuffer : AutoCloseable {
    val width: Int
    val height: Int
    val timestampUptimeMillis: Long
    override fun close()
}

internal interface WindowCaptureCallback {
    fun onSuccess(buffer: WindowCaptureBuffer)
    fun onFailure(reason: WindowCaptureFailure)
}

internal fun interface WindowCapturePort {
    fun capture(serviceIdentity: Any, windowId: Int, callback: WindowCaptureCallback)
}

internal fun interface WindowCaptureCancellation {
    fun cancel()
}

internal fun interface WindowCaptureScheduler {
    fun schedule(delayMillis: Long, task: () -> Unit): WindowCaptureCancellation
}

internal enum class WindowCaptureFailure {
    UNSUPPORTED_API, INVALID_WINDOW, INVALID_DISPLAY, SECURE_WINDOW, NO_ACCESS, RATE_LIMITED,
    PLATFORM_ERROR, SERVICE_UNAVAILABLE, SERVICE_CHANGED, TIMED_OUT, CANCELLED, CLOCK_INVALID,
    SCHEDULER_ERROR, CAPTURE_ERROR, INVALID_METADATA, BUFFER_CLOSE_FAILED,
}

/** Observed metadata only: these times and dimensions do not prove geometry, freshness or pane identity. */
internal data class WindowCaptureMetadata(
    val width: Int,
    val height: Int,
    val platformTimestampUptimeMillis: Long,
    val requestedUptimeMillis: Long,
    val receivedUptimeMillis: Long,
)

internal sealed interface WindowCaptureReceipt {
    data class Completed(val metadata: WindowCaptureMetadata) : WindowCaptureReceipt
    data class Failed(val reason: WindowCaptureFailure) : WindowCaptureReceipt
}

/**
 * One component owns at most one API request. It exposes no pixels, window ID, throwable or execution grant.
 * operationTimeoutMillis is an explicit operational deadline, not a visual TTL or a sampling guarantee.
 * A committed launch cannot be undone by cancellation; every later callback still releases its owned buffer.
 */
internal class WindowCaptureOnce(
    private val port: WindowCapturePort,
    private val scheduler: WindowCaptureScheduler,
    private val uptimeMillis: () -> Long,
    private val currentServiceIdentity: () -> Any?,
    private val operationTimeoutMillis: Long,
    private val onReceipt: (WindowCaptureReceipt) -> Unit,
) {
    private enum class State { NEW, STARTING, PENDING, TERMINAL }
    private data class Context(val serviceIdentity: Any, val started: Long, val deadline: Long)

    private val lock = Any()
    private var state = State.NEW
    private var context: Context? = null
    private var timer: WindowCaptureCancellation? = null
    private var terminal: WindowCaptureReceipt? = null

    init { require(operationTimeoutMillis > 0) { "Window capture timeout must be positive" } }

    fun snapshot(): WindowCaptureReceipt? = synchronized(lock) { terminal }

    /** Returns false if this instance was already started or cancelled; no second request is issued. */
    fun start(windowId: Int): Boolean {
        synchronized(lock) {
            if (state != State.NEW) return false
            state = State.STARTING
        }
        if (windowId < 0) {
            finish(WindowCaptureReceipt.Failed(WindowCaptureFailure.INVALID_WINDOW))
            return true
        }
        val service = try { currentServiceIdentity() } catch (_: Exception) { null }
            catch (failure: Error) { finishBeforeRethrow(failure) }
        if (service == null) {
            finish(WindowCaptureReceipt.Failed(WindowCaptureFailure.SERVICE_UNAVAILABLE))
            return true
        }
        val started = try { uptimeMillis() } catch (_: Exception) { -1L }
            catch (failure: Error) { finishBeforeRethrow(failure) }
        if (started < 0 || started > Long.MAX_VALUE - operationTimeoutMillis) {
            finish(WindowCaptureReceipt.Failed(WindowCaptureFailure.CLOCK_INVALID))
            return true
        }
        synchronized(lock) {
            if (state != State.STARTING) return true
            context = Context(service, started, started + operationTimeoutMillis)
            state = State.PENDING
        }
        val cancellation = try {
            scheduler.schedule(operationTimeoutMillis, ::deadlineReached)
        } catch (failure: Exception) {
            if (!finish(WindowCaptureReceipt.Failed(WindowCaptureFailure.SCHEDULER_ERROR))) throw failure
            return true
        } catch (failure: Error) {
            finishBeforeRethrow(failure)
        }
        val retainTimer = synchronized(lock) {
            if (state == State.PENDING) { timer = cancellation; true } else false
        }
        if (!retainTimer) {
            cancelTimer(cancellation)
            return true
        }
        val pending = synchronized(lock) { context.takeIf { state == State.PENDING } } ?: return true
        val failure = try { serviceFailure(pending) } catch (fatal: Error) { finishBeforeRethrow(fatal) }
        if (failure != null) {
            finish(WindowCaptureReceipt.Failed(failure))
            return true
        }
        // This lock check commits the one launch. No external callback runs while holding the lock.
        if (!synchronized(lock) { state == State.PENDING }) return true
        try {
            port.capture(pending.serviceIdentity, windowId, object : WindowCaptureCallback {
                override fun onSuccess(buffer: WindowCaptureBuffer) = acceptBuffer(buffer)
                override fun onFailure(reason: WindowCaptureFailure) = acceptFailure(reason)
            })
        } catch (failure: Exception) {
            if (!finish(WindowCaptureReceipt.Failed(WindowCaptureFailure.CAPTURE_ERROR))) throw failure
        } catch (failure: Error) {
            finishBeforeRethrow(failure)
        }
        return true
    }

    fun cancel(): Boolean = finish(WindowCaptureReceipt.Failed(WindowCaptureFailure.CANCELLED))

    /** The owner may signal a known service replacement; callbacks also compare exact service references. */
    fun serviceChanged(): Boolean = finish(WindowCaptureReceipt.Failed(WindowCaptureFailure.SERVICE_CHANGED))

    private fun acceptBuffer(buffer: WindowCaptureBuffer) {
        val pending = synchronized(lock) { context.takeIf { state == State.PENDING } }
        var receipt: WindowCaptureReceipt? = null
        var fatal: Error? = null
        try {
            if (pending != null) {
                val serviceFailure = serviceFailure(pending)
                val received = try { uptimeMillis() } catch (_: Exception) { -1L }
                receipt = when {
                    serviceFailure != null -> WindowCaptureReceipt.Failed(serviceFailure)
                    received < pending.started -> WindowCaptureReceipt.Failed(WindowCaptureFailure.CLOCK_INVALID)
                    received >= pending.deadline -> WindowCaptureReceipt.Failed(WindowCaptureFailure.TIMED_OUT)
                    else -> {
                        val width = buffer.width
                        val height = buffer.height
                        val timestamp = buffer.timestampUptimeMillis
                        if (width !in 1..32_768 || height !in 1..32_768 || timestamp !in 0..received) {
                            WindowCaptureReceipt.Failed(WindowCaptureFailure.INVALID_METADATA)
                        } else {
                            WindowCaptureReceipt.Completed(WindowCaptureMetadata(width, height, timestamp, pending.started, received))
                        }
                    }
                }
            }
        } catch (_: Exception) {
            receipt = WindowCaptureReceipt.Failed(WindowCaptureFailure.INVALID_METADATA)
        } catch (failure: Error) {
            fatal = failure
        } finally {
            try { buffer.close() }
            catch (_: Exception) { receipt = WindowCaptureReceipt.Failed(WindowCaptureFailure.BUFFER_CLOSE_FAILED) }
            catch (failure: Error) {
                if (fatal == null) fatal = failure else if (fatal !== failure) fatal.addSuppressed(failure)
            }
        }
        if (fatal != null) finishBeforeRethrow(fatal)
        if (receipt != null) finish(receipt)
    }

    private fun deadlineReached() {
        val pending = synchronized(lock) { context.takeIf { state == State.PENDING } } ?: return
        val serviceFailure = try { serviceFailure(pending) } catch (failure: Error) { finishBeforeRethrow(failure) }
        val now = try { uptimeMillis() } catch (_: Exception) { -1L }
            catch (failure: Error) { finishBeforeRethrow(failure) }
        val reason = serviceFailure ?: when {
            now < pending.started -> WindowCaptureFailure.CLOCK_INVALID
            now < pending.deadline -> WindowCaptureFailure.SCHEDULER_ERROR
            else -> WindowCaptureFailure.TIMED_OUT
        }
        finish(WindowCaptureReceipt.Failed(reason))
    }

    private fun acceptFailure(reason: WindowCaptureFailure) {
        val pending = synchronized(lock) { context.takeIf { state == State.PENDING } } ?: return
        val serviceFailure = try { serviceFailure(pending) } catch (failure: Error) { finishBeforeRethrow(failure) }
        val now = try { uptimeMillis() } catch (_: Exception) { -1L }
            catch (failure: Error) { finishBeforeRethrow(failure) }
        finish(WindowCaptureReceipt.Failed(serviceFailure ?: when {
            now < pending.started -> WindowCaptureFailure.CLOCK_INVALID
            now >= pending.deadline -> WindowCaptureFailure.TIMED_OUT
            else -> reason
        }))
    }

    private fun serviceFailure(pending: Context): WindowCaptureFailure? {
        val current = try { currentServiceIdentity() } catch (_: Exception) { null }
        return when {
            current == null -> WindowCaptureFailure.SERVICE_UNAVAILABLE
            current !== pending.serviceIdentity -> WindowCaptureFailure.SERVICE_CHANGED
            else -> null
        }
    }

    private fun finish(receipt: WindowCaptureReceipt): Boolean {
        val cancellation = synchronized(lock) {
            if (state == State.TERMINAL) return false
            state = State.TERMINAL
            terminal = receipt
            context = null
            timer.also { timer = null }
        }
        cancellation?.let(::cancelTimer)
        onReceipt(receipt)
        return true
    }

    private fun cancelTimer(cancellation: WindowCaptureCancellation) {
        try { cancellation.cancel() } catch (_: Exception) { /* Late wakeups cannot change the terminal result. */ }
    }

    private fun finishBeforeRethrow(failure: Error): Nothing {
        try { finish(WindowCaptureReceipt.Failed(WindowCaptureFailure.CAPTURE_ERROR)) }
        catch (notificationFailure: Throwable) { if (notificationFailure !== failure) failure.addSuppressed(notificationFailure) }
        throw failure
    }

    override fun toString(): String = synchronized(lock) { "WindowCaptureOnce(state=$state)" }
}

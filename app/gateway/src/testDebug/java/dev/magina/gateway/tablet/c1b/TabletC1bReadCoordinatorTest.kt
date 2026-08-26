package dev.magina.gateway.tablet.c1b

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class TabletC1bReadCoordinatorTest {

    @Test
    fun `happy path is asynchronous serial single-shot and result is consumed once`() {
        val h = Harness()
        val started = h.coordinator.begin("run-happy")
        val lease = started.lease

        assertEquals(C1bReadState.READY_C1, started.state)
        assertEquals(1L, lease.generation)

        val c1Queued = h.coordinator.requestCapture(lease, "c1")
        assertEquals(C1bReadState.CAPTURING_C1, c1Queued.state)
        assertEquals("c1", c1Queued.inFlightToken)
        assertTrue("provider thread must not execute capture", h.readerCalls.isEmpty())
        assertEquals(1, h.worker.queuedCount)

        h.worker.runNext()
        val afterC1 = h.coordinator.status(lease)
        assertEquals(C1bReadState.READY_C2, afterC1.state)
        assertEquals(listOf("c1"), afterC1.committedTokens)

        h.coordinator.requestCapture(lease, "c2")
        assertEquals(1, h.worker.queuedCount)
        h.worker.runNext()
        val complete = h.coordinator.status(lease)
        assertEquals(C1bReadState.COMPLETE, complete.state)
        assertEquals(listOf("c1", "c2"), complete.committedTokens)
        assertEquals(1, complete.c1RequestsAccepted)
        assertEquals(1, complete.c2RequestsAccepted)
        assertEquals(0, complete.recaptureCount)
        assertEquals(listOf("c1", "c2"), h.readerCalls.map { it.second })
        assertEquals(1, h.assemblerCalls)

        val output = h.coordinator.result(lease)
        assertTrue(output is C1bResultRead.Output)
        assertEquals("frame-c1+frame-c2", (output as C1bResultRead.Output).value)
        assertEquals(C1bReadState.ABSENT, h.coordinator.status(lease).state)
        assertTrue(h.coordinator.result(lease) is C1bResultRead.Control)
    }

    @Test
    fun `result log representation never renders the generic output value`() {
        val result = C1bResultRead.Output(C1bRunLease("run-redacted-output", 1L), "raw-artifact-value")

        assertFalse(result.toString().contains("raw-artifact-value"))
        assertTrue(result.toString().contains("value=<redacted>"))
    }

    @Test
    fun `c2 overlap and repeated token fail the run without scheduling a recapture`() {
        val overlap = Harness()
        val overlapLease = overlap.coordinator.begin("run-overlap").lease
        overlap.coordinator.requestCapture(overlapLease, "c1")

        val failed = overlap.coordinator.requestCapture(overlapLease, "c2")
        assertEquals(C1bReadState.FAILED, failed.state)
        assertEquals("capture_sequence_invalid", failed.reasonCode)
        assertEquals(1, failed.c1RequestsAccepted)
        assertEquals(0, failed.c2RequestsAccepted)
        assertEquals(0, failed.recaptureCount)
        overlap.worker.runNext()
        assertTrue("late queued c1 must be discarded before reading", overlap.readerCalls.isEmpty())

        val repeated = Harness()
        val repeatedLease = repeated.coordinator.begin("run-repeated").lease
        repeated.coordinator.requestCapture(repeatedLease, "c1")
        repeated.worker.runNext()
        assertEquals(C1bReadState.READY_C2, repeated.coordinator.status(repeatedLease).state)

        val repeatedFailure = repeated.coordinator.requestCapture(repeatedLease, "c1")
        assertEquals(C1bReadState.FAILED, repeatedFailure.state)
        assertEquals("capture_sequence_invalid", repeatedFailure.reasonCode)
        assertEquals(listOf("c1"), repeated.readerCalls.map { it.second })
        assertEquals(0, repeatedFailure.recaptureCount)
    }

    @Test
    fun `a worker that executes the same runnable twice still reads only once`() {
        val h = Harness()
        val lease = h.coordinator.begin("run-double-worker").lease
        h.coordinator.requestCapture(lease, "c1")

        val task = h.worker.removeNext()
        task.run()
        task.run()

        assertEquals(listOf("c1"), h.readerCalls.map { it.second })
        assertEquals(C1bReadState.READY_C2, h.coordinator.status(lease).state)
        assertEquals(0, h.coordinator.status(lease).recaptureCount)
    }

    @Test
    fun `capture timeout closes the lease and discards an in-flight late result`() {
        val h = Harness(captureTimeoutMillis = 100L, sessionTtlMillis = 1_000L)
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        h.readerBehavior = { _, token ->
            entered.countDown()
            assertTrue(release.await(2, TimeUnit.SECONDS))
            Frame("frame-$token")
        }
        val lease = h.coordinator.begin("run-timeout-late").lease
        h.coordinator.requestCapture(lease, "c1")
        val workerThread = Thread(h.worker.removeNext(), "c1b-test-worker")
        workerThread.start()
        assertTrue(entered.await(2, TimeUnit.SECONDS))

        h.clock.now = 100L
        h.scheduler.fire(1)
        val timedOut = h.coordinator.status(lease)
        assertEquals(C1bReadState.FAILED, timedOut.state)
        assertEquals("capture_c1_timeout", timedOut.reasonCode)

        release.countDown()
        workerThread.join(2_000L)
        assertFalse(workerThread.isAlive)
        val afterLateResult = h.coordinator.status(lease)
        assertEquals(C1bReadState.FAILED, afterLateResult.state)
        assertEquals("capture_c1_timeout", afterLateResult.reasonCode)
        assertTrue(afterLateResult.committedTokens.isEmpty())
        assertEquals(1, h.readerCalls.size)
    }

    @Test
    fun `abort wins an in-flight race and later timeout or worker completion cannot rewrite it`() {
        val h = Harness(captureTimeoutMillis = 100L, sessionTtlMillis = 1_000L)
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        h.readerBehavior = { _, token ->
            entered.countDown()
            assertTrue(release.await(2, TimeUnit.SECONDS))
            Frame("frame-$token")
        }
        val lease = h.coordinator.begin("run-abort-first").lease
        h.coordinator.requestCapture(lease, "c1")
        val workerThread = Thread(h.worker.removeNext(), "c1b-test-worker")
        workerThread.start()
        assertTrue(entered.await(2, TimeUnit.SECONDS))

        val aborted = h.coordinator.abort(lease)
        assertEquals(C1bReadState.ABORTED, aborted.state)
        assertEquals("session_aborted", aborted.reasonCode)
        h.clock.now = 100L
        h.scheduler.fire(1, evenIfCancelled = true)
        release.countDown()
        workerThread.join(2_000L)

        val final = h.coordinator.status(lease)
        assertEquals(C1bReadState.ABORTED, final.state)
        assertEquals("session_aborted", final.reasonCode)
        assertTrue(final.committedTokens.isEmpty())
    }

    @Test
    fun `timeout first is not rewritten by a later abort`() {
        val h = Harness(captureTimeoutMillis = 100L, sessionTtlMillis = 1_000L)
        val lease = h.coordinator.begin("run-timeout-first").lease
        h.coordinator.requestCapture(lease, "c1")
        h.clock.now = 100L
        h.scheduler.fire(1)

        val afterAbort = h.coordinator.abort(lease)
        assertEquals(C1bReadState.FAILED, afterAbort.state)
        assertEquals("capture_c1_timeout", afterAbort.reasonCode)
        h.worker.runNext()
        assertTrue(h.readerCalls.isEmpty())
    }

    @Test
    fun `old generation task cannot enter a replacement run even with the same run id`() {
        val h = Harness()
        val oldLease = h.coordinator.begin("run-generation").lease
        h.coordinator.requestCapture(oldLease, "c1")
        val oldTask = h.worker.removeNext()
        h.coordinator.abort(oldLease)

        val newLease = h.coordinator.begin("run-generation").lease
        assertEquals(oldLease.generation + 1L, newLease.generation)
        oldTask.run()
        assertTrue(h.readerCalls.isEmpty())
        assertEquals(C1bReadState.READY_C1, h.coordinator.status(newLease).state)
        assertEquals(C1bReadState.ABSENT, h.coordinator.status(oldLease).state)

        h.coordinator.requestCapture(newLease, "c1")
        h.worker.runNext()
        assertEquals(listOf("c1"), h.readerCalls.map { it.second })
        assertEquals(C1bReadState.READY_C2, h.coordinator.status(newLease).state)
    }

    @Test
    fun `old generation already inside reader cannot publish after replacement run begins`() {
        val h = Harness()
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        h.readerBehavior = { _, token ->
            entered.countDown()
            assertTrue(release.await(2, TimeUnit.SECONDS))
            Frame("late-$token")
        }
        val oldLease = h.coordinator.begin("run-inflight-generation").lease
        h.coordinator.requestCapture(oldLease, "c1")
        val oldWorker = Thread(h.worker.removeNext(), "c1b-old-generation-worker")
        oldWorker.start()
        assertTrue(entered.await(2, TimeUnit.SECONDS))

        h.coordinator.abort(oldLease)
        val newLease = h.coordinator.begin("run-inflight-generation").lease
        assertEquals(oldLease.generation + 1L, newLease.generation)
        release.countDown()
        oldWorker.join(2_000L)
        assertFalse(oldWorker.isAlive)

        val untouched = h.coordinator.status(newLease)
        assertEquals(C1bReadState.READY_C1, untouched.state)
        assertTrue(untouched.committedTokens.isEmpty())
        assertEquals(0, untouched.c1RequestsAccepted)
        assertEquals(C1bReadState.ABSENT, h.coordinator.status(oldLease).state)
        assertEquals(1, h.readerCalls.size)

        h.readerBehavior = { _, token -> Frame("fresh-$token") }
        h.coordinator.requestCapture(newLease, "c1")
        h.worker.runNext()
        val fresh = h.coordinator.status(newLease)
        assertEquals(C1bReadState.READY_C2, fresh.state)
        assertEquals(listOf("c1"), fresh.committedTokens)
        assertEquals(2, h.readerCalls.size)
    }

    @Test
    fun `session expiry after c1 is terminal and c2 is never submitted`() {
        val h = Harness(captureTimeoutMillis = 100L, sessionTtlMillis = 500L)
        val lease = h.coordinator.begin("run-expiry").lease
        h.coordinator.requestCapture(lease, "c1")
        h.worker.runNext()
        assertEquals(C1bReadState.READY_C2, h.coordinator.status(lease).state)

        h.clock.now = 500L
        h.scheduler.fire(0)
        val expired = h.coordinator.status(lease)
        assertEquals(C1bReadState.EXPIRED, expired.state)
        assertEquals("session_expired", expired.reasonCode)
        val afterC2 = h.coordinator.requestCapture(lease, "c2")
        assertEquals(C1bReadState.EXPIRED, afterC2.state)
        assertEquals(0, afterC2.c2RequestsAccepted)
        assertEquals(0, h.worker.queuedCount)
    }

    @Test
    fun `scheduler and worker rejection fail closed before any frame can commit`() {
        val expiryRejected = Harness()
        expiryRejected.scheduler.rejectNext = true
        val failedBegin = expiryRejected.coordinator.begin("run-expiry-reject")
        assertEquals(C1bReadState.FAILED, failedBegin.state)
        assertEquals("session_expiry_scheduler_rejected", failedBegin.reasonCode)

        val timeoutRejected = Harness()
        val timeoutLease = timeoutRejected.coordinator.begin("run-timeout-reject").lease
        timeoutRejected.scheduler.rejectNext = true
        val failedTimeoutSchedule = timeoutRejected.coordinator.requestCapture(timeoutLease, "c1")
        assertEquals(C1bReadState.FAILED, failedTimeoutSchedule.state)
        assertEquals("capture_timeout_scheduler_rejected", failedTimeoutSchedule.reasonCode)
        assertEquals(0, timeoutRejected.worker.queuedCount)
        assertTrue(timeoutRejected.readerCalls.isEmpty())

        val workerRejected = Harness()
        val workerLease = workerRejected.coordinator.begin("run-worker-reject").lease
        workerRejected.worker.rejectNext = true
        val failedWorker = workerRejected.coordinator.requestCapture(workerLease, "c1")
        assertEquals(C1bReadState.FAILED, failedWorker.state)
        assertEquals("capture_worker_rejected", failedWorker.reasonCode)
        assertTrue(workerRejected.readerCalls.isEmpty())
        assertTrue(workerRejected.scheduler.entries[1].cancelled)
    }

    @Test
    fun `inline worker and inline timer callbacks are rejected as unsafe wiring`() {
        val inlineExpiry = Harness()
        inlineExpiry.scheduler.runInlineNext = true
        val expiryFailure = inlineExpiry.coordinator.begin("run-inline-expiry")
        assertEquals(C1bReadState.FAILED, expiryFailure.state)
        assertEquals("session_expiry_scheduler_rejected", expiryFailure.reasonCode)

        val inlineCaptureTimer = Harness()
        val timerLease = inlineCaptureTimer.coordinator.begin("run-inline-capture-timer").lease
        inlineCaptureTimer.scheduler.runInlineNext = true
        val timerFailure = inlineCaptureTimer.coordinator.requestCapture(timerLease, "c1")
        assertEquals(C1bReadState.FAILED, timerFailure.state)
        assertEquals("capture_timeout_scheduler_rejected", timerFailure.reasonCode)
        assertEquals(0, inlineCaptureTimer.worker.queuedCount)

        val inlineWorker = Harness()
        val workerLease = inlineWorker.coordinator.begin("run-inline-worker").lease
        inlineWorker.worker.runInlineNext = true
        val workerFailure = inlineWorker.coordinator.requestCapture(workerLease, "c1")
        assertEquals(C1bReadState.FAILED, workerFailure.state)
        assertEquals("capture_worker_inline", workerFailure.reasonCode)
        assertTrue(inlineWorker.readerCalls.isEmpty())
    }

    @Test
    fun `early timer wakeups rearm against the exact monotonic deadline`() {
        val sessionWake = Harness(captureTimeoutMillis = 100L, sessionTtlMillis = 1_000L)
        val sessionLease = sessionWake.coordinator.begin("run-early-session-timer").lease
        sessionWake.scheduler.fire(0)
        assertEquals(C1bReadState.READY_C1, sessionWake.coordinator.status(sessionLease).state)
        assertEquals(2, sessionWake.scheduler.entries.size)
        assertEquals(1_000L, sessionWake.scheduler.entries[1].delayMillis)
        assertTrue(sessionWake.scheduler.entries[0].cancelled)

        val captureWake = Harness(captureTimeoutMillis = 100L, sessionTtlMillis = 1_000L)
        val captureLease = captureWake.coordinator.begin("run-early-capture-timer").lease
        captureWake.coordinator.requestCapture(captureLease, "c1")
        captureWake.scheduler.fire(1)
        assertEquals(C1bReadState.CAPTURING_C1, captureWake.coordinator.status(captureLease).state)
        assertEquals(3, captureWake.scheduler.entries.size)
        assertEquals(100L, captureWake.scheduler.entries[2].delayMillis)
        assertTrue(captureWake.scheduler.entries[1].cancelled)
        captureWake.worker.runNext()
        assertEquals(C1bReadState.READY_C2, captureWake.coordinator.status(captureLease).state)
        assertTrue(captureWake.scheduler.entries[2].cancelled)
    }

    @Test
    fun `duplicate and stale timer callbacks are ignored after their first delivery`() {
        val sessionWake = Harness(captureTimeoutMillis = 100L, sessionTtlMillis = 1_000L)
        val sessionLease = sessionWake.coordinator.begin("run-double-session-callback").lease
        sessionWake.scheduler.fire(0)
        assertEquals(2, sessionWake.scheduler.entries.size)
        sessionWake.scheduler.fire(0, evenIfCancelled = true)
        assertEquals("stale callback must not arm another timer", 2, sessionWake.scheduler.entries.size)
        assertEquals(C1bReadState.READY_C1, sessionWake.coordinator.status(sessionLease).state)

        val captureWake = Harness(captureTimeoutMillis = 100L, sessionTtlMillis = 1_000L)
        val captureLease = captureWake.coordinator.begin("run-double-capture-callback").lease
        captureWake.coordinator.requestCapture(captureLease, "c1")
        captureWake.clock.now = 100L
        captureWake.scheduler.fire(1)
        captureWake.scheduler.fire(1, evenIfCancelled = true)
        val failed = captureWake.coordinator.status(captureLease)
        assertEquals(C1bReadState.FAILED, failed.state)
        assertEquals("capture_c1_timeout", failed.reasonCode)
        assertTrue(failed.committedTokens.isEmpty())
    }

    @Test
    fun `service replacement between or during captures fails without a second read`() {
        val between = Harness()
        val betweenLease = between.coordinator.begin("run-service-between").lease
        between.coordinator.requestCapture(betweenLease, "c1")
        between.worker.runNext()
        between.currentService = Service("replacement")

        val rejectedC2 = between.coordinator.requestCapture(betweenLease, "c2")
        assertEquals(C1bReadState.FAILED, rejectedC2.state)
        assertEquals("a11y_service_replaced", rejectedC2.reasonCode)
        assertEquals(listOf("c1"), between.readerCalls.map { it.second })
        assertEquals(0, rejectedC2.c2RequestsAccepted)

        val during = Harness()
        val original = during.currentService
        during.readerBehavior = { service, token ->
            assertSame(original, service)
            during.currentService = Service("replacement-during")
            Frame("frame-$token")
        }
        val duringLease = during.coordinator.begin("run-service-during").lease
        during.coordinator.requestCapture(duringLease, "c1")
        during.worker.runNext()
        val failedDuring = during.coordinator.status(duringLease)
        assertEquals(C1bReadState.FAILED, failedDuring.state)
        assertEquals("a11y_service_replaced", failedDuring.reasonCode)
        assertTrue(failedDuring.committedTokens.isEmpty())
    }

    @Test
    fun `assembly rejection is terminal and both captures remain exactly once`() {
        val h = Harness()
        h.assemblerBehavior = { _, _ -> error("sensitive producer detail") }
        val lease = h.coordinator.begin("run-assembly-failure").lease
        h.coordinator.requestCapture(lease, "c1")
        h.worker.runNext()
        h.coordinator.requestCapture(lease, "c2")
        h.worker.runNext()

        val failed = h.coordinator.status(lease)
        assertEquals(C1bReadState.FAILED, failed.state)
        assertEquals("observation_assembly_failed", failed.reasonCode)
        assertFalse(failed.reasonCode.orEmpty().contains("sensitive"))
        assertEquals(listOf("c1", "c2"), h.readerCalls.map { it.second })
        assertEquals(1, h.assemblerCalls)
        assertEquals(0, failed.recaptureCount)
    }

    @Test
    fun `complete is not rewritten by abort and cancelled capture timer cannot fire late`() {
        val h = Harness(captureTimeoutMillis = 100L, sessionTtlMillis = 1_000L)
        val lease = h.coordinator.begin("run-complete-first").lease
        h.coordinator.requestCapture(lease, "c1")
        h.worker.runNext()
        h.coordinator.requestCapture(lease, "c2")
        h.worker.runNext()
        assertEquals(C1bReadState.COMPLETE, h.coordinator.status(lease).state)

        val afterAbort = h.coordinator.abort(lease)
        assertEquals(C1bReadState.COMPLETE, afterAbort.state)
        h.clock.now = 100L
        h.scheduler.fire(2, evenIfCancelled = true)
        assertEquals(C1bReadState.COMPLETE, h.coordinator.status(lease).state)
    }

    @Test
    fun `unconsumed complete output expires and cannot be read after session ttl`() {
        val h = Harness(captureTimeoutMillis = 100L, sessionTtlMillis = 1_000L)
        val lease = h.coordinator.begin("run-complete-expiry").lease
        h.coordinator.requestCapture(lease, "c1")
        h.worker.runNext()
        h.coordinator.requestCapture(lease, "c2")
        h.worker.runNext()
        assertEquals(C1bReadState.COMPLETE, h.coordinator.status(lease).state)

        h.clock.now = 1_000L
        h.scheduler.fire(0)
        val expired = h.coordinator.status(lease)
        assertEquals(C1bReadState.EXPIRED, expired.state)
        assertEquals("session_expired", expired.reasonCode)
        assertTrue(h.coordinator.result(lease) is C1bResultRead.Control)
    }

    @Test
    fun `shutdown rejects late queued work and all future runs`() {
        val h = Harness()
        val lease = h.coordinator.begin("run-shutdown").lease
        h.coordinator.requestCapture(lease, "c1")
        val queued = h.worker.removeNext()
        h.coordinator.shutdown()
        queued.run()

        assertTrue(h.readerCalls.isEmpty())
        assertEquals(C1bReadState.ABSENT, h.coordinator.status(lease).state)
        val closed = h.coordinator.begin("run-after-shutdown")
        assertEquals(C1bReadState.ABSENT, closed.state)
        assertEquals("coordinator_closed", closed.reasonCode)
    }

    private data class Service(val name: String)
    private data class Frame(val value: String)

    private class FakeClock(var now: Long = 0L)

    private class ManualWorker : C1bReadWorker {
        private val tasks = ArrayDeque<Runnable>()
        var rejectNext = false
        var runInlineNext = false
        val queuedCount: Int get() = tasks.size

        override fun execute(task: Runnable) {
            if (rejectNext) {
                rejectNext = false
                throw IllegalStateException("worker rejected")
            }
            if (runInlineNext) {
                runInlineNext = false
                task.run()
                return
            }
            tasks.addLast(task)
        }

        fun removeNext(): Runnable = tasks.removeFirst()
        fun runNext() = removeNext().run()
    }

    private class ManualScheduler : C1bDeadlineScheduler {
        data class Entry(
            val delayMillis: Long,
            val task: () -> Unit,
            var cancelled: Boolean = false,
        )

        val entries = mutableListOf<Entry>()
        var rejectNext = false
        var runInlineNext = false

        override fun schedule(delayMillis: Long, task: () -> Unit): C1bDeadlineCancellation {
            if (rejectNext) {
                rejectNext = false
                throw IllegalStateException("scheduler rejected")
            }
            val entry = Entry(delayMillis, task)
            entries += entry
            if (runInlineNext) {
                runInlineNext = false
                task()
            }
            return C1bDeadlineCancellation { entry.cancelled = true }
        }

        fun fire(index: Int, evenIfCancelled: Boolean = false) {
            val entry = entries[index]
            if (!entry.cancelled || evenIfCancelled) entry.task()
        }
    }

    private class Harness(
        captureTimeoutMillis: Long = 100L,
        sessionTtlMillis: Long = 1_000L,
    ) {
        val clock = FakeClock()
        val worker = ManualWorker()
        val scheduler = ManualScheduler()
        var currentService: Service? = Service("original")
        val readerCalls = mutableListOf<Pair<Service, String>>()
        var assemblerCalls = 0
        var readerBehavior: (Service, String) -> Frame = { _, token -> Frame("frame-$token") }
        var assemblerBehavior: (Frame, Frame) -> String = { c1, c2 -> "${c1.value}+${c2.value}" }

        val coordinator = TabletC1bReadCoordinator(
            worker = worker,
            scheduler = scheduler,
            currentServiceIdentity = { currentService },
            frameReader = C1bFrameReader { service, token ->
                readerCalls += service to token
                readerBehavior(service, token)
            },
            assembler = C1bFrameAssembler { c1, c2 ->
                assemblerCalls += 1
                assemblerBehavior(c1, c2)
            },
            monotonicMillis = { clock.now },
            captureTimeoutMillis = captureTimeoutMillis,
            sessionTtlMillis = sessionTtlMillis,
        )
    }
}

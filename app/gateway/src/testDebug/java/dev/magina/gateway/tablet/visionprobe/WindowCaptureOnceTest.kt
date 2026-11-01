package dev.magina.gateway.tablet.visionprobe

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class WindowCaptureOnceTest {
    @Test fun synchronousSuccessClosesBeforeNotifyingAndCannotStartTwice() {
        val f = Fixture()
        val image = Buffer()
        f.port.action = { it.onSuccess(image) }
        f.consumer = { assertEquals(1, image.releaseAttempts) }
        assertTrue(f.capture.start(987654321))
        assertFalse(f.capture.start(987654321))
        assertEquals(listOf(987654321), f.port.ids)
        assertSame(f.service, f.port.identities.single())
        assertEquals(1, f.receipts.size)
        val result = f.receipts.single() as WindowCaptureReceipt.Completed
        assertEquals(WindowCaptureMetadata(320, 200, 100, 100, 100), result.metadata)
        assertEquals(1, f.scheduler.cancelCalls)
        assertFalse(f.capture.toString().contains("987654321"))
        assertFalse(result.toString().contains("987654321"))
    }

    @Test fun cancelledBeforeStartDoesNotScheduleOrRequest() {
        val f = Fixture()
        assertTrue(f.capture.cancel())
        assertFalse(f.capture.start(12))
        assertFalse(f.capture.cancel())
        f.failed(WindowCaptureFailure.CANCELLED)
        assertEquals(0, f.scheduler.schedules)
        assertTrue(f.port.ids.isEmpty())
    }

    @Test fun cancellationReleasesLateAndRepeatedBuffersWithoutRetainingHistory() {
        val f = Fixture()
        f.capture.start(12)
        assertTrue(f.capture.cancel())
        val first = Buffer()
        val second = Buffer()
        f.port.callback.onSuccess(first)
        f.port.callback.onSuccess(first)
        f.port.callback.onSuccess(second)
        f.port.callback.onFailure(WindowCaptureFailure.SECURE_WINDOW)
        assertEquals(2, first.closeCalls)
        assertEquals(1, first.releaseAttempts)
        assertEquals(1, second.releaseAttempts)
        assertEquals(0, first.metadataReads)
        f.failed(WindowCaptureFailure.CANCELLED)
    }

    @Test fun duplicateSuccessAndFailureCannotReplaceFirstTerminal() {
        val f = Fixture()
        f.capture.start(12)
        val first = Buffer()
        f.port.callback.onSuccess(first)
        val late = Buffer()
        f.port.callback.onFailure(WindowCaptureFailure.PLATFORM_ERROR)
        f.port.callback.onSuccess(late)
        assertEquals(1, f.receipts.size)
        assertTrue(f.receipts.single() is WindowCaptureReceipt.Completed)
        assertEquals(1, first.releaseAttempts)
        assertEquals(1, late.releaseAttempts)
        assertEquals(0, late.metadataReads)
        assertFalse(f.capture.serviceChanged())
    }

    @Test fun timeoutIsTerminalAndLateSuccessCannotReviveIt() {
        val f = Fixture()
        f.capture.start(12)
        f.now = 110
        f.scheduler.fire()
        val late = Buffer()
        f.port.callback.onSuccess(late)
        f.failed(WindowCaptureFailure.TIMED_OUT)
        assertEquals(1, late.releaseAttempts)
        assertEquals(0, late.metadataReads)
        assertEquals(1, f.port.ids.size)
    }

    @Test fun callbackAtDeadlineFailsEvenBeforeTimerRuns() {
        val f = Fixture()
        f.capture.start(12)
        f.now = 110
        val image = Buffer()
        f.port.callback.onSuccess(image)
        f.failed(WindowCaptureFailure.TIMED_OUT)
        assertEquals(0, image.metadataReads)
        assertEquals(1, image.releaseAttempts)
        val error = Fixture()
        error.capture.start(12)
        error.now = 110
        error.port.callback.onFailure(WindowCaptureFailure.NO_ACCESS)
        error.failed(WindowCaptureFailure.TIMED_OUT)
    }

    @Test fun serviceReferencesAreComparedExactlyRatherThanByEqualityOrHash() {
        class SameIdentity {
            override fun equals(other: Any?) = other is SameIdentity
            override fun hashCode() = 1
        }
        val f = Fixture()
        f.service = SameIdentity()
        f.capture.start(12)
        f.service = SameIdentity()
        val image = Buffer()
        f.port.callback.onSuccess(image)
        f.failed(WindowCaptureFailure.SERVICE_CHANGED)
        assertEquals(0, image.metadataReads)
        assertEquals(1, image.releaseAttempts)
    }

    @Test fun explicitServiceInvalidationAndMissingServiceBothStopTheRequest() {
        val f = Fixture()
        f.capture.start(12)
        assertTrue(f.capture.serviceChanged())
        f.port.callback.onSuccess(Buffer())
        f.failed(WindowCaptureFailure.SERVICE_CHANGED)
        val absent = Fixture()
        absent.service = null
        absent.capture.start(12)
        absent.failed(WindowCaptureFailure.SERVICE_UNAVAILABLE)
        assertTrue(absent.port.ids.isEmpty())
    }

    @Test fun serviceDisappearanceIsCheckedForErrorAndDeadlineCallbacks() {
        for (deadline in listOf(false, true)) {
            val f = Fixture()
            f.capture.start(12)
            f.service = null
            if (deadline) { f.now = 110; f.scheduler.fire() }
            else f.port.callback.onFailure(WindowCaptureFailure.RATE_LIMITED)
            f.failed(WindowCaptureFailure.SERVICE_UNAVAILABLE)
        }
    }

    @Test fun errorsStayClosedAndDoNotRetry() {
        for (reason in listOf(WindowCaptureFailure.INVALID_WINDOW, WindowCaptureFailure.SECURE_WINDOW,
            WindowCaptureFailure.NO_ACCESS, WindowCaptureFailure.RATE_LIMITED, WindowCaptureFailure.PLATFORM_ERROR)) {
            val f = Fixture()
            f.capture.start(12)
            f.port.callback.onFailure(reason)
            f.failed(reason)
            assertEquals(1, f.port.ids.size)
            assertFalse(f.capture.start(34))
        }
    }

    @Test fun invalidWindowAndUnavailableDependenciesNeverIssueApiCalls() {
        val invalid = Fixture()
        invalid.capture.start(-42)
        invalid.failed(WindowCaptureFailure.INVALID_WINDOW)
        assertTrue(invalid.port.ids.isEmpty())
        val broken = Fixture()
        broken.scheduler.failure = IllegalStateException("private scheduler detail")
        broken.capture.start(12)
        broken.failed(WindowCaptureFailure.SCHEDULER_ERROR)
        assertTrue(broken.port.ids.isEmpty())
    }

    @Test fun inlineDeadlineBeforeScheduleReturnsDoesNotLaunch() {
        val f = Fixture()
        f.scheduler.inline = { task -> f.now = 110; task() }
        f.capture.start(12)
        f.failed(WindowCaptureFailure.TIMED_OUT)
        assertEquals(1, f.scheduler.cancelCalls)
        assertTrue(f.port.ids.isEmpty())
    }

    @Test fun earlyTimerIsRejectedRatherThanRescheduled() {
        val f = Fixture()
        f.capture.start(12)
        f.scheduler.fire()
        f.failed(WindowCaptureFailure.SCHEDULER_ERROR)
        assertEquals(1, f.scheduler.schedules)
    }

    @Test fun cancelledDuringScheduleRegistrationCannotIssueApiRequest() {
        val f = Fixture()
        f.scheduler.inline = { f.capture.cancel() }
        f.capture.start(12)
        f.failed(WindowCaptureFailure.CANCELLED)
        assertEquals(1, f.scheduler.cancelCalls)
        assertTrue(f.port.ids.isEmpty())
    }

    @Test fun clockFailureRollbackAndDeadlineOverflowFailClosed() {
        val initial = Fixture()
        initial.clockFailure = IllegalStateException("private clock detail")
        initial.capture.start(12)
        initial.failed(WindowCaptureFailure.CLOCK_INVALID)
        assertTrue(initial.port.ids.isEmpty())
        val overflow = Fixture()
        overflow.now = Long.MAX_VALUE - 5
        overflow.capture.start(12)
        overflow.failed(WindowCaptureFailure.CLOCK_INVALID)
        val rollback = Fixture()
        rollback.capture.start(12)
        rollback.now = 99
        val image = Buffer()
        rollback.port.callback.onSuccess(image)
        rollback.failed(WindowCaptureFailure.CLOCK_INVALID)
        assertEquals(1, image.releaseAttempts)
    }

    @Test fun invalidMetadataAndReadFailureAlwaysAttemptRelease() {
        for (image in listOf(Buffer(widthValue = 0), Buffer(heightValue = 32769), Buffer(timestamp = 101),
            Buffer(timestamp = -1), Buffer(readFailure = IllegalStateException("private bitmap detail")))) {
            val f = Fixture()
            f.capture.start(12)
            f.port.callback.onSuccess(image)
            f.failed(WindowCaptureFailure.INVALID_METADATA)
            assertEquals(1, image.releaseAttempts)
        }
    }

    @Test fun closeFailureReportsUnknownReleaseOutcomeAndDoesNotRetryRelease() {
        val f = Fixture()
        f.capture.start(12)
        val image = Buffer(closeFailure = IllegalStateException("private release detail"))
        f.port.callback.onSuccess(image)
        f.port.callback.onSuccess(image)
        f.failed(WindowCaptureFailure.BUFFER_CLOSE_FAILED)
        assertEquals(2, image.closeCalls)
        assertEquals(1, image.releaseAttempts)
    }

    @Test fun consumerExceptionPropagatesAfterReleaseAndDoesNotReopenRequest() {
        val f = Fixture()
        val image = Buffer()
        val failure = IllegalStateException("private consumer detail")
        f.consumer = { assertEquals(1, image.releaseAttempts); throw failure }
        f.port.action = { it.onSuccess(image) }
        assertSame(failure, thrown { f.capture.start(12) })
        assertTrue(f.capture.snapshot() is WindowCaptureReceipt.Completed)
        assertFalse(f.capture.start(34))
        assertEquals(1, f.receipts.size)
    }

    @Test fun reentrantConsumerCannotCancelOrStartAnotherRequest() {
        val f = Fixture()
        f.consumer = { assertFalse(f.capture.cancel()); assertFalse(f.capture.start(34)) }
        f.port.action = { it.onSuccess(Buffer()) }
        f.capture.start(12)
        assertEquals(1, f.receipts.size)
        assertEquals(1, f.port.ids.size)
    }

    @Test fun cancellationDuringMetadataReadWinsAndStillClosesBuffer() {
        val f = Fixture()
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val image = Buffer(beforeRead = {
            entered.countDown()
            check(release.await(3, TimeUnit.SECONDS))
        })
        f.capture.start(12)
        val worker = Thread { f.port.callback.onSuccess(image) }
        worker.start()
        assertTrue(entered.await(3, TimeUnit.SECONDS))
        f.capture.cancel()
        release.countDown()
        worker.join(3000)
        assertFalse(worker.isAlive)
        f.failed(WindowCaptureFailure.CANCELLED)
        assertEquals(1, image.releaseAttempts)
    }

    @Test fun errorsFromStartDependenciesFreezeStateAndAreNeverSwallowed() {
        for (dependency in listOf("service", "clock", "scheduler", "launchService", "port")) {
            val f = Fixture()
            val fatal = AssertionError("private fatal $dependency")
            when (dependency) {
                "service" -> f.serviceFailure = fatal
                "clock" -> f.clockFailure = fatal
                "scheduler" -> f.scheduler.failure = fatal
                "launchService" -> f.serviceRead = { if (f.serviceReads == 2) throw fatal }
                "port" -> f.port.action = { throw fatal }
            }
            assertSame(fatal, thrown { f.capture.start(12) })
            f.failed(WindowCaptureFailure.CAPTURE_ERROR)
            assertFalse(f.capture.start(34))
            assertFalse(f.capture.toString().contains("private"))
        }
    }

    @Test fun metadataAndReleaseErrorsPreserveOriginalFatalAndCloseOnce() {
        val f = Fixture()
        val fatal = AssertionError("private metadata fatal")
        val image = Buffer(readFailure = fatal, closeFailure = fatal)
        f.capture.start(12)
        assertSame(fatal, thrown { f.port.callback.onSuccess(image) })
        f.failed(WindowCaptureFailure.CAPTURE_ERROR)
        assertEquals(1, image.releaseAttempts)
        assertEquals(0, fatal.suppressed.size)
    }

    @Test fun synchronousPortExceptionStopsWithoutLeakingMessage() {
        val f = Fixture()
        f.port.action = { throw IllegalStateException("private request 987654321") }
        f.capture.start(987654321)
        f.failed(WindowCaptureFailure.CAPTURE_ERROR)
        assertFalse(f.capture.snapshot().toString().contains("private"))
        assertFalse(f.capture.snapshot().toString().contains("987654321"))
    }

    private fun thrown(action: () -> Unit): Throwable {
        try { action() } catch (failure: Throwable) { return failure }
        throw AssertionError("Expected failure")
    }

    private class Fixture {
        var now = 100L
        var service: Any? = Any()
        var clockFailure: Throwable? = null
        var serviceFailure: Throwable? = null
        var serviceReads = 0
        var serviceRead: () -> Unit = {}
        var consumer: (WindowCaptureReceipt) -> Unit = {}
        val port = Port()
        val scheduler = Scheduler()
        val receipts = mutableListOf<WindowCaptureReceipt>()
        val capture = WindowCaptureOnce(port, scheduler,
            uptimeMillis = { clockFailure?.let { throw it }; now },
            currentServiceIdentity = { serviceReads++; serviceRead(); serviceFailure?.let { throw it }; service },
            operationTimeoutMillis = 10,
            onReceipt = { receipts += it; consumer(it) },
        )
        fun failed(reason: WindowCaptureFailure) {
            assertEquals(listOf(WindowCaptureReceipt.Failed(reason)), receipts)
            assertEquals(receipts.single(), capture.snapshot())
        }
    }

    private class Port : WindowCapturePort {
        val ids = mutableListOf<Int>()
        val identities = mutableListOf<Any>()
        lateinit var callback: WindowCaptureCallback
        var action: ((WindowCaptureCallback) -> Unit)? = null
        override fun capture(serviceIdentity: Any, windowId: Int, callback: WindowCaptureCallback) {
            ids += windowId
            identities += serviceIdentity
            this.callback = callback
            action?.invoke(callback)
        }
    }

    private class Scheduler : WindowCaptureScheduler {
        lateinit var task: () -> Unit
        var schedules = 0
        var cancelCalls = 0
        var failure: Throwable? = null
        var inline: ((() -> Unit) -> Unit)? = null
        override fun schedule(delayMillis: Long, task: () -> Unit): WindowCaptureCancellation {
            assertEquals(10L, delayMillis)
            schedules++
            failure?.let { throw it }
            this.task = task
            inline?.invoke(task)
            return WindowCaptureCancellation { cancelCalls++ }
        }
        fun fire() = task()
    }

    private class Buffer(
        private val widthValue: Int = 320,
        private val heightValue: Int = 200,
        private val timestamp: Long = 100,
        private val readFailure: Throwable? = null,
        private val closeFailure: Throwable? = null,
        private val beforeRead: () -> Unit = {},
    ) : WindowCaptureBuffer {
        var closeCalls = 0
        var releaseAttempts = 0
        var metadataReads = 0
        override val width: Int get() { metadataReads++; beforeRead(); readFailure?.let { throw it }; return widthValue }
        override val height: Int get() = heightValue
        override val timestampUptimeMillis: Long get() = timestamp
        override fun close() {
            closeCalls++
            if (releaseAttempts != 0) return
            releaseAttempts++
            closeFailure?.let { throw it }
        }
    }
}

package dev.magina.gateway.tablet.visionprobe

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidWindowCapturePortSetupTest {
    @Test fun acquisitionErrorFreezesPendingBeforeExecutorCatchesIt() {
        val f = Fixture()
        val primary = AssertionError("acquire")
        f.start()
        val caught = catchExecutorError {
            prepareWindowCaptureBuffer<Resource>(f.callback, { throw primary }, { Buffer() })
        }
        assertSame(primary, caught)
        f.assertFailedAndLateSuccessOnlyCloses()
    }

    @Test fun metadataErrorReleasesOwnedResourceThenFreezesBeforeRethrow() {
        val f = Fixture()
        val resource = Resource()
        val primary = AssertionError("metadata")
        f.start()
        val caught = catchExecutorError {
            prepareWindowCaptureBuffer(f.callback, { resource }, { throw primary })
        }
        assertSame(primary, caught)
        assertEquals(1, resource.closeCalls)
        f.assertFailedAndLateSuccessOnlyCloses()
    }

    @Test fun exceptionCleanupErrorFreezesPendingAndIsNotReplaced() {
        val f = Fixture()
        val primary = AssertionError("release")
        val resource = Resource(primary)
        f.start()
        val caught = catchExecutorError {
            prepareWindowCaptureBuffer(f.callback, { resource }, { throw IllegalStateException("metadata") })
        }
        assertSame(primary, caught)
        assertEquals(1, resource.closeCalls)
        f.assertFailedAndLateSuccessOnlyCloses()
    }

    @Test fun cleanupAndNotificationFailuresAreSuppressedOnOriginalSetupError() {
        val f = Fixture()
        val primary = AssertionError("metadata")
        val cleanup = IllegalStateException("release")
        val notification = AssertionError("consumer")
        val resource = Resource(cleanup)
        f.start()
        val callback = object : WindowCaptureCallback {
            override fun onSuccess(buffer: WindowCaptureBuffer) = f.callback.onSuccess(buffer)
            override fun onFailure(reason: WindowCaptureFailure) {
                f.callback.onFailure(reason)
                throw notification
            }
        }
        val caught = catchExecutorError {
            prepareWindowCaptureBuffer(callback, { resource }, { throw primary })
        }
        assertSame(primary, caught)
        assertEquals(listOf(cleanup, notification), primary.suppressed.toList())
        assertEquals(1, resource.closeCalls)
        f.assertFailedAndLateSuccessOnlyCloses()
    }

    @Test fun sameErrorFromCleanupAndNotificationIsNeverSelfSuppressed() {
        val f = Fixture()
        val primary = AssertionError("primary")
        val resource = Resource(primary)
        f.start()
        val callback = object : WindowCaptureCallback {
            override fun onSuccess(buffer: WindowCaptureBuffer) = f.callback.onSuccess(buffer)
            override fun onFailure(reason: WindowCaptureFailure) {
                f.callback.onFailure(reason)
                throw primary
            }
        }
        assertSame(primary, catchExecutorError {
            prepareWindowCaptureBuffer(callback, { resource }, { throw primary })
        })
        assertTrue(primary.suppressed.isEmpty())
        assertEquals(1, resource.closeCalls)
        f.assertFailedAndLateSuccessOnlyCloses()
    }

    @Test fun successfulSetupWaitsForHandoffAndOrdinarySetupFailuresStayClosed() {
        val f = Fixture()
        val resource = Resource()
        val buffer = Buffer { resource.close() }
        f.start()
        assertSame(buffer, prepareWindowCaptureBuffer(f.callback, { resource }, { buffer }))
        assertNull(f.capture.snapshot())
        assertEquals(0, resource.closeCalls)
        f.callback.onSuccess(buffer)
        assertTrue(f.capture.snapshot() is WindowCaptureReceipt.Completed)
        assertEquals(1, buffer.closeCalls)
        assertEquals(1, resource.closeCalls)

        for (closeFails in listOf(false, true)) {
            val failed = Fixture()
            val owned = Resource(if (closeFails) IllegalStateException("release") else null)
            failed.start()
            assertNull(prepareWindowCaptureBuffer(failed.callback, { owned }, { throw IllegalStateException("setup") }))
            assertEquals(1, owned.closeCalls)
            assertEquals(
                WindowCaptureReceipt.Failed(if (closeFails) WindowCaptureFailure.BUFFER_CLOSE_FAILED else WindowCaptureFailure.INVALID_METADATA),
                failed.capture.snapshot(),
            )
        }
    }

    private fun catchExecutorError(task: () -> Unit): Error {
        try { task() } catch (failure: Error) { return failure }
        throw AssertionError("executor did not receive original Error")
    }

    private class Resource(private val failure: Throwable? = null) : AutoCloseable {
        var closeCalls = 0
        override fun close() {
            closeCalls++
            failure?.let { throw it }
        }
    }

    private class Buffer(private val release: () -> Unit = {}) : WindowCaptureBuffer {
        var closeCalls = 0
        var metadataReads = 0
        private var released = false
        override val width: Int get() { metadataReads++; return 320 }
        override val height: Int get() { metadataReads++; return 200 }
        override val timestampUptimeMillis: Long get() { metadataReads++; return 100L }
        override fun close() {
            closeCalls++
            if (!released) { released = true; release() }
        }
    }

    private class Fixture {
        private val service = Any()
        lateinit var callback: WindowCaptureCallback
        val receipts = mutableListOf<WindowCaptureReceipt>()
        val capture = WindowCaptureOnce(
            port = WindowCapturePort { identity, _, receiver -> assertSame(service, identity); callback = receiver },
            scheduler = WindowCaptureScheduler { _, _ -> WindowCaptureCancellation {} },
            uptimeMillis = { 100L },
            currentServiceIdentity = { service },
            operationTimeoutMillis = 10L,
            onReceipt = { receipts += it },
        )

        fun start() { assertTrue(capture.start(12)); assertNull(capture.snapshot()) }

        fun assertFailedAndLateSuccessOnlyCloses() {
            assertEquals(WindowCaptureReceipt.Failed(WindowCaptureFailure.CAPTURE_ERROR), capture.snapshot())
            assertEquals(listOf(capture.snapshot()), receipts)
            val late = Buffer()
            callback.onSuccess(late)
            assertEquals(1, late.closeCalls)
            assertEquals(0, late.metadataReads)
            assertEquals(WindowCaptureReceipt.Failed(WindowCaptureFailure.CAPTURE_ERROR), capture.snapshot())
            assertEquals(1, receipts.size)
        }
    }
}

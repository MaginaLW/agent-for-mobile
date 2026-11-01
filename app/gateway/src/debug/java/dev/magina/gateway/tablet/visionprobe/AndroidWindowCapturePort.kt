package dev.magina.gateway.tablet.visionprobe

import android.accessibilityservice.AccessibilityService
import android.hardware.HardwareBuffer
import android.os.Build
import androidx.annotation.RequiresApi
import java.util.concurrent.Executor
import java.util.concurrent.atomic.AtomicBoolean

/** Unwired debug adapter. A directed request does not establish geometry, pane identity or freshness. */
internal class AndroidWindowCapturePort(
    private val service: AccessibilityService,
    private val executor: Executor,
) : WindowCapturePort {
    override fun capture(serviceIdentity: Any, windowId: Int, callback: WindowCaptureCallback) {
        if (serviceIdentity !== service) {
            callback.onFailure(WindowCaptureFailure.SERVICE_CHANGED)
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            callback.onFailure(WindowCaptureFailure.UNSUPPORTED_API)
            return
        }
        if (windowId < 0) {
            callback.onFailure(WindowCaptureFailure.INVALID_WINDOW)
            return
        }
        // Synchronous request exceptions belong to the caller's single terminal path. Do not catch
        // callback/consumer exceptions here and turn an already delivered success into another callback.
        captureSupported(windowId, callback)
    }

    @RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
    private fun captureSupported(windowId: Int, callback: WindowCaptureCallback) {
        service.takeScreenshotOfWindow(
            windowId,
            executor,
            object : AccessibilityService.TakeScreenshotCallback {
                override fun onSuccess(result: AccessibilityService.ScreenshotResult) {
                    val owned = prepareWindowCaptureBuffer(
                        callback,
                        acquire = { requireNotNull(result.hardwareBuffer) },
                        wrap = { AndroidWindowCaptureBuffer(it, result.timestamp) },
                    ) ?: return
                    var deliveryFailure: Throwable? = null
                    try {
                        // The callback borrows metadata only and closes before notification. The adapter's
                        // idempotent final close also covers callbacks that return/throw without closing.
                        callback.onSuccess(owned)
                    } catch (failure: Throwable) {
                        deliveryFailure = failure
                        throw failure
                    } finally {
                        try {
                            owned.close()
                        } catch (closeFailure: Throwable) {
                            val primary = deliveryFailure
                            if (primary == null) throw closeFailure
                            if (closeFailure !== primary) primary.addSuppressed(closeFailure)
                        }
                    }
                }

                override fun onFailure(errorCode: Int) {
                    callback.onFailure(
                        when (errorCode) {
                            AccessibilityService.ERROR_TAKE_SCREENSHOT_INTERNAL_ERROR -> WindowCaptureFailure.PLATFORM_ERROR
                            AccessibilityService.ERROR_TAKE_SCREENSHOT_NO_ACCESSIBILITY_ACCESS -> WindowCaptureFailure.NO_ACCESS
                            AccessibilityService.ERROR_TAKE_SCREENSHOT_INTERVAL_TIME_SHORT -> WindowCaptureFailure.RATE_LIMITED
                            AccessibilityService.ERROR_TAKE_SCREENSHOT_INVALID_DISPLAY -> WindowCaptureFailure.INVALID_DISPLAY
                            AccessibilityService.ERROR_TAKE_SCREENSHOT_INVALID_WINDOW -> WindowCaptureFailure.INVALID_WINDOW
                            AccessibilityService.ERROR_TAKE_SCREENSHOT_SECURE_WINDOW -> WindowCaptureFailure.SECURE_WINDOW
                            else -> WindowCaptureFailure.PLATFORM_ERROR
                        },
                    )
                }
            },
        )
    }

    override fun toString(): String = "AndroidWindowCapturePort(<unwired>)"
}

/** Actual pre-handoff path shared with JVM tests; an executor may catch its Error and keep running. */
internal fun <T : AutoCloseable> prepareWindowCaptureBuffer(
    callback: WindowCaptureCallback,
    acquire: () -> T,
    wrap: (T) -> WindowCaptureBuffer,
): WindowCaptureBuffer? {
    val resource = try {
        acquire()
    } catch (_: Exception) {
        callback.onFailure(WindowCaptureFailure.INVALID_METADATA)
        return null
    } catch (failure: Error) {
        failWindowCaptureSetupBeforeRethrow(callback, failure)
    }
    return try {
        wrap(resource)
    } catch (_: Exception) {
        val reason = try {
            resource.close()
            WindowCaptureFailure.INVALID_METADATA
        } catch (_: Exception) {
            WindowCaptureFailure.BUFFER_CLOSE_FAILED
        } catch (failure: Error) {
            failWindowCaptureSetupBeforeRethrow(callback, failure)
        }
        callback.onFailure(reason)
        null
    } catch (failure: Error) {
        failWindowCaptureSetupBeforeRethrow(callback, failure) { resource.close() }
    }
}

private fun failWindowCaptureSetupBeforeRethrow(
    callback: WindowCaptureCallback,
    failure: Error,
    release: (() -> Unit)? = null,
): Nothing {
    try {
        release?.invoke()
    } catch (cleanupFailure: Throwable) {
        if (cleanupFailure !== failure) failure.addSuppressed(cleanupFailure)
    }
    try {
        callback.onFailure(WindowCaptureFailure.CAPTURE_ERROR)
    } catch (notificationFailure: Throwable) {
        if (notificationFailure !== failure) failure.addSuppressed(notificationFailure)
    }
    throw failure
}

/** Pixel data never leaves this wrapper; only primitive metadata is available to the debug lifecycle. */
private class AndroidWindowCaptureBuffer(
    private val hardwareBuffer: HardwareBuffer,
    // Raw platform uptime timestamp; it is not an exact compositor sampling time.
    override val timestampUptimeMillis: Long,
) : WindowCaptureBuffer {
    override val width: Int = hardwareBuffer.width
    override val height: Int = hardwareBuffer.height
    private val closed = AtomicBoolean(false)

    override fun close() {
        if (closed.compareAndSet(false, true)) hardwareBuffer.close()
    }

    override fun toString(): String = "AndroidWindowCaptureBuffer(<owned>)"
}

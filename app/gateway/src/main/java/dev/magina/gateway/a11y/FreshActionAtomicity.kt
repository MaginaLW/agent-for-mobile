package dev.magina.gateway.a11y

import dev.magina.gateway.core.ErrorCode
import dev.magina.gateway.core.GatewayError
import java.util.concurrent.atomic.AtomicLong

internal data class VisionCapture<T>(
    val generation: Long,
    val payload: T,
    val revision: Long = 0,
)

/** 独立于 OCR 是否执行的截图世代；每次 fresh 请求都必须真实采样一次。 */
internal class VisionCaptureCoordinator<T>(private val capture: () -> T) {
    private val generation = AtomicLong(0)

    @Synchronized
    fun captureFresh(): VisionCapture<T> {
        val payload = capture()
        return VisionCapture(generation.incrementAndGet(), payload)
    }
}

/** 生产 snapshot 适配器使用的 fresh 会话：同一张新截图既提供世代元数据，也供可选 OCR 消费。 */
internal class FreshVisionSession<T>(
    capture: () -> T,
    private val currentRevision: () -> Long,
) {
    private val captures = VisionCaptureCoordinator(capture)
    private var activeCapture: VisionCapture<T>? = null

    @Synchronized
    fun <R> withFreshCapture(snapshot: () -> R): R {
        check(activeCapture == null) { "fresh vision session must not be nested" }
        activeCapture = captureStable()
        return try {
            val result = snapshot()
            requireRevision(activeCapture!!.revision)
            result
        } finally {
            activeCapture = null
        }
    }

    @Synchronized
    fun current(): VisionCapture<T>? = activeCapture

    @Synchronized
    fun captureForOcr(): VisionCapture<T> = activeCapture ?: captureStable()

    private fun captureStable(): VisionCapture<T> {
        val revisionBefore = currentRevision()
        val capture = captures.captureFresh()
        val revisionAfter = currentRevision()
        if (revisionBefore != revisionAfter) throw staleVision()
        return capture.copy(revision = revisionAfter)
    }

    private fun requireRevision(expected: Long) {
        if (currentRevision() != expected) throw staleVision()
    }

    private fun staleVision() = GatewayError(
        ErrorCode.E_STALE_REF,
        "截图或快照组装期间页面 revision 已变化",
        channel = "vision",
        retryable = true,
    )
}

internal data class FreshClickExpectation(
    val revision: Long,
    val expectedWindowId: Int,
    val expectedPackage: String,
    val imeMustBeHidden: Boolean,
)

internal data class FreshClickCurrent(
    val revision: Long,
    val foregroundKnown: Boolean,
    val windowId: Int,
    val packageName: String,
    val blockingOverlay: Boolean,
    val imeVisible: Boolean,
)

internal data class FreshValidatedRef(
    val ref: String,
    val captureRevision: Long,
    val visionGeneration: Long,
    val foregroundWindowId: Int,
)

/** proof 已完成后的最后一道无副作用闸门；任何漂移都只能重新取样，不能继续点击。 */
internal object FreshClickFinalGuard {
    fun requireCurrent(expected: FreshClickExpectation, current: FreshClickCurrent) {
        if (
            current.revision != expected.revision ||
            current.windowId != expected.expectedWindowId ||
            !current.foregroundKnown || current.packageName != expected.expectedPackage ||
            current.blockingOverlay || (expected.imeMustBeHidden && current.imeVisible)
        ) throw GatewayError(
            ErrorCode.E_STALE_REF,
            "点击前页面、前台窗口、遮挡或 IME 状态已变化",
            channel = "a11y",
            retryable = true,
        )
    }
}

/** 固化 stage 动作顺序：允许 resolve 做慢 OCR，但它返回后必须重新完整校验，才可执行一次动作。 */
internal object FreshClickActionExecutor {
    fun <T> resolveGuardPerform(
        expected: FreshClickExpectation,
        resolve: () -> T,
        readCurrent: () -> FreshClickCurrent,
        perform: (T) -> Boolean,
    ): Boolean {
        val target = resolve()
        FreshClickFinalGuard.requireCurrent(expected, readCurrent())
        return perform(target)
    }
}

internal data class FreshSearchFocusCurrent(
    val nodePresent: Boolean,
    val focused: Boolean,
    val editable: Boolean,
    val screenWidth: Int,
    val screenHeight: Int,
    val left: Int,
    val top: Int,
    val right: Int,
    val bottom: Int,
)

internal object FreshSearchFocusGuard {
    fun isValid(current: FreshSearchFocusCurrent): Boolean = current.nodePresent &&
        current.focused && current.editable && current.screenWidth > 0 && current.screenHeight > 0 &&
        current.left >= 0 && current.top >= 0 && current.right <= current.screenWidth &&
        current.bottom <= current.screenHeight && current.right > current.left && current.bottom > current.top &&
        (current.top + current.bottom) / 2 <= current.screenHeight * 0.30
}

/** 由 service 在 fresh capture 临界区内读取，并在记录后再次硬相等复核。 */
internal data class FreshPreparedInputProof(
    val captureRevision: Long,
    val foregroundWindowId: Int,
    val nodePresent: Boolean,
    val nodeId: String?,
    val imeSessionId: String?,
    val focused: Boolean,
    val editable: Boolean,
    val left: Int,
    val top: Int,
    val right: Int,
    val bottom: Int,
)

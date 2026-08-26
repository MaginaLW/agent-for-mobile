package dev.magina.gateway.tablet.c1b

import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * C1b 只读采集所需的最小 worker 面。实现必须使用专属单 worker 排队，不能在 provider/Binder
 * 调用线程内直接执行 [task]。coordinator 不拥有 worker，因此 shutdown 生命周期由接线方负责。
 */
internal fun interface C1bReadWorker {
    @Throws(Exception::class)
    fun execute(task: Runnable)
}

internal fun interface C1bDeadlineCancellation {
    fun cancel()
}

/** 定时器只负责唤醒；最终是否超时仍由 monotonic deadline 与 generation/lease 二次判定。 */
internal fun interface C1bDeadlineScheduler {
    @Throws(Exception::class)
    fun schedule(delayMillis: Long, task: () -> Unit): C1bDeadlineCancellation
}

/** F 必须是不可变纯值，不能携带 AccessibilityNodeInfo、raw title 或其它 Binder/content 引用。 */
internal fun interface C1bFrameReader<S : Any, F : Any> {
    fun read(serviceIdentity: S, captureToken: String): F
}

/** O 必须是不可变纯值，不能继续持有 AccessibilityNodeInfo、raw title 或其它 Binder/content 引用。 */
internal fun interface C1bFrameAssembler<F : Any, O : Any> {
    fun assemble(c1: F, c2: F): O
}

internal data class C1bRunLease(
    val runId: String,
    val generation: Long,
)

internal enum class C1bReadState(val wire: String) {
    ABSENT("absent"),
    READY_C1("ready_c1"),
    CAPTURING_C1("capturing_c1"),
    READY_C2("ready_c2"),
    CAPTURING_C2("capturing_c2"),
    COMPLETE("complete"),
    FAILED("failed"),
    ABORTED("aborted"),
    EXPIRED("expired"),
}

internal data class C1bReadSnapshot(
    val lease: C1bRunLease,
    val state: C1bReadState,
    val reasonCode: String?,
    val inFlightToken: String?,
    val c1RequestsAccepted: Int,
    val c2RequestsAccepted: Int,
    val committedTokens: List<String>,
    /** 重拍在这个状态机里没有入口，因此该值只能为 0。 */
    val recaptureCount: Int = 0,
)

internal sealed interface C1bResultRead<out O : Any> {
    data class Output<O : Any>(val lease: C1bRunLease, val value: O) : C1bResultRead<O> {
        override fun toString(): String = "C1bResultRead.Output(lease=$lease, value=<redacted>)"
    }

    data class Control(val snapshot: C1bReadSnapshot) : C1bResultRead<Nothing>
}

/**
 * 与 producer 类型解耦的 C1b 两帧只读 coordinator。
 *
 * 安全不变量：
 * - c1/c2 各最多接受一次请求，且只允许 c1 commit 后提交 c2；
 * - 同时最多一份 [CaptureJob]，其 Runnable 即使被 worker 错误执行两次也只会读取一次；
 * - 每个异步边界都复核 Session 引用、generation、token、job 引用、deadline 与 service 引用同一性；
 * - timeout/abort/expiry 为 first-terminal-wins；COMPLETE 拒绝晚到 abort/capture callback，但未消费输出仍受
 *   原 session TTL 约束并在到期时清除；
 * - 失败不回显异常消息，也不保留 frame/service/output 引用。
 */
internal class TabletC1bReadCoordinator<S : Any, F : Any, O : Any>(
    private val worker: C1bReadWorker,
    private val scheduler: C1bDeadlineScheduler,
    private val currentServiceIdentity: () -> S?,
    private val frameReader: C1bFrameReader<S, F>,
    private val assembler: C1bFrameAssembler<F, O>,
    private val monotonicMillis: () -> Long = { System.nanoTime() / 1_000_000L },
    private val captureTimeoutMillis: Long = DEFAULT_CAPTURE_TIMEOUT_MILLIS,
    private val sessionTtlMillis: Long = DEFAULT_SESSION_TTL_MILLIS,
) {
    init {
        require(captureTimeoutMillis in 1L..300_000L) {
            "C1b capture timeout is outside the closed range"
        }
        require(sessionTtlMillis in captureTimeoutMillis..300_000L) {
            "C1b session TTL is outside the closed range"
        }
    }

    private class Session<S : Any, F : Any, O : Any>(
        val lease: C1bRunLease,
        val deadlineMillis: Long,
        var state: C1bReadState = C1bReadState.READY_C1,
        var reasonCode: String? = null,
        var c1RequestsAccepted: Int = 0,
        var c2RequestsAccepted: Int = 0,
        val committedTokens: MutableList<String> = mutableListOf(),
        var boundServiceIdentity: S? = null,
        var firstFrame: F? = null,
        var output: O? = null,
        var activeJob: CaptureJob<S, F, O>? = null,
        var expiryCancellation: C1bDeadlineCancellation? = null,
    )

    private class CaptureJob<S : Any, F : Any, O : Any>(
        val session: Session<S, F, O>,
        val lease: C1bRunLease,
        val token: String,
        val expectedServiceIdentity: S,
        val deadlineMillis: Long,
        val firstFrameForAssembly: F?,
    ) {
        val started = AtomicBoolean(false)
        val submissionReturned = AtomicBoolean(false)
        val submittingThread: Thread = Thread.currentThread()
        var timeoutCancellation: C1bDeadlineCancellation? = null
    }

    private sealed interface WorkerProduct<out F : Any, out O : Any> {
        data class FirstFrame<F : Any>(val frame: F) : WorkerProduct<F, Nothing>
        data class Output<O : Any>(val value: O) : WorkerProduct<Nothing, O>
    }

    private var nextGeneration = 0L
    private var session: Session<S, F, O>? = null
    private var closed = false

    @Synchronized
    fun begin(runId: String): C1bReadSnapshot {
        require(SAFE_RUN_ID.matches(runId)) { "C1b run id is invalid" }
        if (closed) return absent(runId, 0L, "coordinator_closed")
        expireIfNeeded()
        val current = session
        if (current != null && current.state in OCCUPIED_STATES) {
            return absent(runId, 0L, "session_busy")
        }
        if (nextGeneration == Long.MAX_VALUE) return absent(runId, 0L, "generation_exhausted")
        current?.let(::discard)
        val lease = C1bRunLease(runId, ++nextGeneration)
        val created = Session<S, F, O>(
            lease = lease,
            deadlineMillis = deadlineFrom(monotonicMillis(), sessionTtlMillis),
        )
        session = created
        if (!scheduleSessionExpiry(created, sessionTtlMillis)) {
            terminal(created, C1bReadState.FAILED, "session_expiry_scheduler_rejected")
        }
        return snapshot(created)
    }

    /**
     * 只排队，不在调用线程采集。相同 token 的第二次请求也不会成为重拍：它直接把当前 run
     * 收口为 sequence failure，已排队或正在运行的第一份结果随后会被 lease 门丢弃。
     */
    @Synchronized
    fun requestCapture(lease: C1bRunLease, token: String): C1bReadSnapshot {
        expireIfNeeded()
        val current = exactSession(lease) ?: return absent(lease, "session_not_found")
        if (token !in CAPTURE_TOKENS) {
            if (current.state in ACTIVE_STATES) {
                terminal(current, C1bReadState.FAILED, "capture_sequence_invalid")
            }
            return snapshot(current)
        }
        val expectedState = if (token == "c1") C1bReadState.READY_C1 else C1bReadState.READY_C2
        if (current.state != expectedState) {
            if (current.state in ACTIVE_STATES) {
                terminal(current, C1bReadState.FAILED, "capture_sequence_invalid")
            }
            return snapshot(current)
        }

        val service = runCatching(currentServiceIdentity).getOrNull()
        if (service == null) {
            terminal(current, C1bReadState.FAILED, "a11y_service_unavailable")
            return snapshot(current)
        }
        if (token == "c2" && service !== current.boundServiceIdentity) {
            terminal(current, C1bReadState.FAILED, "a11y_service_replaced")
            return snapshot(current)
        }
        val first = if (token == "c2") current.firstFrame else null
        if (token == "c2" && first == null) {
            terminal(current, C1bReadState.FAILED, "capture_sequence_invalid")
            return snapshot(current)
        }

        val now = monotonicMillis()
        if (now >= current.deadlineMillis) {
            terminal(current, C1bReadState.EXPIRED, "session_expired")
            return snapshot(current)
        }
        val job = CaptureJob(
            session = current,
            lease = lease,
            token = token,
            expectedServiceIdentity = service,
            deadlineMillis = minOf(
                deadlineFrom(now, captureTimeoutMillis),
                current.deadlineMillis,
            ),
            firstFrameForAssembly = first,
        )
        current.activeJob = job
        current.state = if (token == "c1") C1bReadState.CAPTURING_C1 else C1bReadState.CAPTURING_C2
        if (token == "c1") current.c1RequestsAccepted += 1 else current.c2RequestsAccepted += 1

        if (!scheduleCaptureTimeout(job, job.deadlineMillis - now)) {
            terminal(current, C1bReadState.FAILED, "capture_timeout_scheduler_rejected")
            return snapshot(current)
        }
        try {
            worker.execute(Runnable {
                // 明确拒绝 `C1bReadWorker { it.run() }` 一类同步 provider-thread 接线。
                if (!job.submissionReturned.get() && Thread.currentThread() === job.submittingThread) {
                    failJob(job, "capture_worker_inline")
                } else {
                    runJob(job)
                }
            })
            job.submissionReturned.set(true)
        } catch (_: Exception) {
            job.submissionReturned.set(true)
            terminal(current, C1bReadState.FAILED, "capture_worker_rejected")
        }
        return snapshot(current)
    }

    @Synchronized
    fun status(lease: C1bRunLease): C1bReadSnapshot {
        expireIfNeeded()
        return exactSession(lease)?.let(::snapshot) ?: absent(lease, "session_not_found")
    }

    /** COMPLETE 对 abort/capture 是终态；原 session TTL 仍会清除未消费输出。输出只允许消费一次。 */
    @Synchronized
    fun result(lease: C1bRunLease): C1bResultRead<O> {
        expireIfNeeded()
        val current = exactSession(lease)
            ?: return C1bResultRead.Control(absent(lease, "session_not_found"))
        val value = current.output
        return if (current.state == C1bReadState.COMPLETE && value != null) {
            cancelSessionExpiry(current)
            current.output = null
            current.firstFrame = null
            current.boundServiceIdentity = null
            session = null
            C1bResultRead.Output(lease, value)
        } else {
            C1bResultRead.Control(snapshot(current))
        }
    }

    @Synchronized
    fun abort(lease: C1bRunLease): C1bReadSnapshot {
        expireIfNeeded()
        val current = exactSession(lease) ?: return absent(lease, "session_not_found")
        if (current.state in ACTIVE_STATES) {
            terminal(current, C1bReadState.ABORTED, "session_aborted")
        }
        return snapshot(current)
    }

    @Synchronized
    fun shutdown() {
        if (closed) return
        closed = true
        session?.let { current ->
            if (current.state in ACTIVE_STATES) {
                terminal(current, C1bReadState.ABORTED, "coordinator_shutdown")
            } else {
                discard(current)
            }
        }
        session = null
    }

    private fun runJob(job: CaptureJob<S, F, O>) {
        // 防御错误 worker 重复执行同一 Runnable；第二次连 reader 都不会进入。
        if (!job.started.compareAndSet(false, true)) return
        if (!jobMayContinue(job)) return

        val serviceAtStart = runCatching(currentServiceIdentity).getOrNull()
        if (serviceAtStart !== job.expectedServiceIdentity) {
            failJob(job, "a11y_service_replaced")
            return
        }
        val frame = try {
            frameReader.read(job.expectedServiceIdentity, job.token)
        } catch (_: Exception) {
            failJob(job, "capture_${job.token}_failed")
            return
        }
        if (!jobMayContinue(job)) return
        if (runCatching(currentServiceIdentity).getOrNull() !== job.expectedServiceIdentity) {
            failJob(job, "a11y_service_replaced")
            return
        }

        val product: WorkerProduct<F, O> = if (job.token == "c1") {
            WorkerProduct.FirstFrame(frame)
        } else {
            val first = job.firstFrameForAssembly ?: run {
                failJob(job, "capture_sequence_invalid")
                return
            }
            val output = try {
                assembler.assemble(first, frame)
            } catch (_: Exception) {
                failJob(job, "observation_assembly_failed")
                return
            }
            WorkerProduct.Output(output)
        }
        if (!jobMayContinue(job)) return
        if (runCatching(currentServiceIdentity).getOrNull() !== job.expectedServiceIdentity) {
            failJob(job, "a11y_service_replaced")
            return
        }
        completeJob(job, product)
    }

    @Synchronized
    private fun jobMayContinue(job: CaptureJob<S, F, O>): Boolean {
        val current = session
        if (closed || current !== job.session || current.lease != job.lease ||
            current.activeJob !== job || current.state !in CAPTURING_STATES
        ) return false
        val now = monotonicMillis()
        if (now >= current.deadlineMillis) {
            terminal(current, C1bReadState.EXPIRED, "session_expired")
            return false
        }
        if (now >= job.deadlineMillis) {
            terminal(current, C1bReadState.FAILED, "capture_${job.token}_timeout")
            return false
        }
        return true
    }

    @Synchronized
    private fun failJob(job: CaptureJob<S, F, O>, reason: String) {
        val current = session
        if (current !== job.session || current.lease != job.lease || current.activeJob !== job ||
            current.state !in CAPTURING_STATES
        ) return
        terminal(current, C1bReadState.FAILED, reason)
    }

    @Synchronized
    private fun completeJob(job: CaptureJob<S, F, O>, product: WorkerProduct<F, O>) {
        if (!jobMayContinue(job)) return
        val current = job.session
        cancelCaptureTimeout(job)
        current.activeJob = null
        when (product) {
            is WorkerProduct.FirstFrame -> {
                if (job.token != "c1") {
                    terminal(current, C1bReadState.FAILED, "capture_sequence_invalid")
                    return
                }
                current.firstFrame = product.frame
                current.boundServiceIdentity = job.expectedServiceIdentity
                current.committedTokens += "c1"
                current.state = C1bReadState.READY_C2
            }
            is WorkerProduct.Output -> {
                if (job.token != "c2") {
                    terminal(current, C1bReadState.FAILED, "capture_sequence_invalid")
                    return
                }
                current.output = product.value
                current.firstFrame = null
                current.boundServiceIdentity = null
                current.committedTokens += "c2"
                current.reasonCode = null
                current.state = C1bReadState.COMPLETE
            }
        }
    }

    @Synchronized
    private fun captureTimeoutScheduled(job: CaptureJob<S, F, O>) {
        val current = session
        if (closed || current !== job.session || current.activeJob !== job ||
            current.state !in CAPTURING_STATES
        ) return
        val now = monotonicMillis()
        if (now < job.deadlineMillis) {
            if (!scheduleCaptureTimeout(job, job.deadlineMillis - now)) {
                terminal(current, C1bReadState.FAILED, "capture_timeout_scheduler_rejected")
            }
            return
        }
        if (now >= current.deadlineMillis) {
            terminal(current, C1bReadState.EXPIRED, "session_expired")
        } else {
            terminal(current, C1bReadState.FAILED, "capture_${job.token}_timeout")
        }
    }

    @Synchronized
    private fun sessionExpiryScheduled(target: Session<S, F, O>) {
        if (closed || session !== target || target.state !in EXPIRABLE_STATES) return
        val now = monotonicMillis()
        if (now < target.deadlineMillis) {
            if (!scheduleSessionExpiry(target, target.deadlineMillis - now)) {
                terminal(target, C1bReadState.FAILED, "session_expiry_scheduler_rejected")
            }
            return
        }
        terminal(target, C1bReadState.EXPIRED, "session_expired")
    }

    private fun scheduleCaptureTimeout(job: CaptureJob<S, F, O>, delayMillis: Long): Boolean = try {
        val registration = AtomicInteger(TIMER_REGISTERING)
        val cancellation = scheduler.schedule(delayMillis.coerceAtLeast(0L)) {
            when {
                registration.compareAndSet(TIMER_ARMED, TIMER_FIRED) -> captureTimeoutScheduled(job)
                registration.compareAndSet(TIMER_REGISTERING, TIMER_FIRED_EARLY) -> Unit
                else -> Unit
            }
        }
        if (!registration.compareAndSet(TIMER_REGISTERING, TIMER_ARMED)) {
            runCatching { cancellation.cancel() }
            false
        } else {
            if (session !== job.session || job.session.activeJob !== job ||
                job.session.state !in CAPTURING_STATES
            ) {
                cancellation.cancel()
            } else {
                job.timeoutCancellation?.let { old -> runCatching { old.cancel() } }
                job.timeoutCancellation = cancellation
            }
            true
        }
    } catch (_: Exception) {
        false
    }

    private fun scheduleSessionExpiry(target: Session<S, F, O>, delayMillis: Long): Boolean = try {
        val registration = AtomicInteger(TIMER_REGISTERING)
        val cancellation = scheduler.schedule(delayMillis.coerceAtLeast(0L)) {
            when {
                registration.compareAndSet(TIMER_ARMED, TIMER_FIRED) -> sessionExpiryScheduled(target)
                registration.compareAndSet(TIMER_REGISTERING, TIMER_FIRED_EARLY) -> Unit
                else -> Unit
            }
        }
        if (!registration.compareAndSet(TIMER_REGISTERING, TIMER_ARMED)) {
            runCatching { cancellation.cancel() }
            false
        } else {
            if (closed || session !== target || target.state !in EXPIRABLE_STATES) {
                cancellation.cancel()
            } else {
                target.expiryCancellation?.let { old -> runCatching { old.cancel() } }
                target.expiryCancellation = cancellation
            }
            true
        }
    } catch (_: Exception) {
        false
    }

    private fun expireIfNeeded() {
        val current = session ?: return
        if (current.state in EXPIRABLE_STATES && monotonicMillis() >= current.deadlineMillis) {
            terminal(current, C1bReadState.EXPIRED, "session_expired")
        }
    }

    private fun terminal(target: Session<S, F, O>, state: C1bReadState, reason: String) {
        // COMPLETE 仍受 session TTL 管理；只有失败类终态不可再被后来事件改写。
        if (target.state in FAILURE_TERMINAL_STATES) return
        cancelSessionExpiry(target)
        target.activeJob?.let(::cancelCaptureTimeout)
        target.activeJob = null
        target.firstFrame = null
        target.boundServiceIdentity = null
        target.output = null
        target.reasonCode = reason
        target.state = state
    }

    private fun discard(target: Session<S, F, O>) {
        cancelSessionExpiry(target)
        target.activeJob?.let(::cancelCaptureTimeout)
        target.activeJob = null
        target.firstFrame = null
        target.boundServiceIdentity = null
        target.output = null
    }

    private fun cancelCaptureTimeout(job: CaptureJob<S, F, O>) {
        val cancellation = job.timeoutCancellation
        job.timeoutCancellation = null
        if (cancellation != null) runCatching { cancellation.cancel() }
    }

    private fun cancelSessionExpiry(target: Session<S, F, O>) {
        val cancellation = target.expiryCancellation
        target.expiryCancellation = null
        if (cancellation != null) runCatching { cancellation.cancel() }
    }

    private fun exactSession(lease: C1bRunLease): Session<S, F, O>? =
        session?.takeIf { it.lease == lease }

    private fun snapshot(target: Session<S, F, O>): C1bReadSnapshot = C1bReadSnapshot(
        lease = target.lease,
        state = target.state,
        reasonCode = target.reasonCode,
        inFlightToken = target.activeJob?.token,
        c1RequestsAccepted = target.c1RequestsAccepted,
        c2RequestsAccepted = target.c2RequestsAccepted,
        committedTokens = target.committedTokens.toList(),
    )

    private fun absent(lease: C1bRunLease, reason: String): C1bReadSnapshot = C1bReadSnapshot(
        lease = lease,
        state = C1bReadState.ABSENT,
        reasonCode = reason,
        inFlightToken = null,
        c1RequestsAccepted = 0,
        c2RequestsAccepted = 0,
        committedTokens = emptyList(),
    )

    private fun absent(runId: String, generation: Long, reason: String): C1bReadSnapshot =
        absent(C1bRunLease(runId, generation), reason)

    private fun deadlineFrom(now: Long, duration: Long): Long =
        if (now > Long.MAX_VALUE - duration) Long.MAX_VALUE else now + duration

    private companion object {
        const val DEFAULT_CAPTURE_TIMEOUT_MILLIS = 5_000L
        const val DEFAULT_SESSION_TTL_MILLIS = 120_000L
        const val TIMER_REGISTERING = 0
        const val TIMER_ARMED = 1
        const val TIMER_FIRED = 2
        const val TIMER_FIRED_EARLY = 3
        val SAFE_RUN_ID = Regex("[a-z0-9][a-z0-9._-]{0,79}")
        val CAPTURE_TOKENS = setOf("c1", "c2")
        val ACTIVE_STATES = setOf(
            C1bReadState.READY_C1,
            C1bReadState.CAPTURING_C1,
            C1bReadState.READY_C2,
            C1bReadState.CAPTURING_C2,
        )
        val CAPTURING_STATES = setOf(C1bReadState.CAPTURING_C1, C1bReadState.CAPTURING_C2)
        val EXPIRABLE_STATES = ACTIVE_STATES + C1bReadState.COMPLETE
        val OCCUPIED_STATES = EXPIRABLE_STATES
        val FAILURE_TERMINAL_STATES = setOf(
            C1bReadState.FAILED,
            C1bReadState.ABORTED,
            C1bReadState.EXPIRED,
        )
    }
}

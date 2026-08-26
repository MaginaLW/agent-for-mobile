package dev.magina.gateway.tablet.c1a

import android.content.ContentProvider
import android.content.ContentProviderOperation
import android.content.ContentProviderResult
import android.content.ContentValues
import android.content.res.AssetFileDescriptor
import android.database.Cursor
import android.net.Uri
import android.os.Binder
import android.os.Bundle
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.os.Process
import dev.magina.gateway.BuildConfig
import dev.magina.gateway.a11y.GatewayA11yService
import dev.magina.gateway.tablet.AndroidTabletLayoutProbeSource
import java.io.FileNotFoundException
import java.nio.charset.StandardCharsets
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

/**
 * debug-only、shell-only 的 T-L1 C1a 只读探针入口。进程外协议只有 openFile 匿名 pipe：
 * T0 从 pipe 写入内存，其余端点从 pipe 读取安全 control JSON 或冻结 observation JSON。
 */
internal class TabletC1aContentProvider : ContentProvider() {
    private val t0PipeExecutor: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "tablet-c1a-t0-pipe").apply { isDaemon = true }
    }
    private val outputPipeExecutor: ExecutorService = Executors.newFixedThreadPool(2) { runnable ->
        Thread(runnable, "tablet-c1a-output-pipe").apply { isDaemon = true }
    }
    private val pendingTimeoutExecutor: ScheduledExecutorService =
        Executors.newSingleThreadScheduledExecutor { runnable ->
            Thread(runnable, "tablet-c1a-pending-timeout").apply { isDaemon = true }
        }
    private val sessionExpiryExecutor: ScheduledExecutorService =
        Executors.newSingleThreadScheduledExecutor { runnable ->
            Thread(runnable, "tablet-c1a-session-expiry").apply { isDaemon = true }
        }
    private val buildIdentity by lazy {
        C1aBuildIdentity(
            packageName = BuildConfig.APPLICATION_ID,
            versionName = BuildConfig.VERSION_NAME,
            versionCode = BuildConfig.VERSION_CODE.toLong(),
            embeddedGitHead = BuildConfig.TABLET_C1A_GIT_HEAD,
            buildChallenge = BuildConfig.TABLET_C1A_BUILD_CHALLENGE,
        )
    }
    private val sessionsDelegate = lazy {
        TabletC1aSessionMachine(
            build = buildIdentity,
            expiryScheduler = C1aExpiryScheduler { delayMillis, task ->
                val future = sessionExpiryExecutor.schedule(task, delayMillis, TimeUnit.MILLISECONDS)
                C1aExpiryCancellation { future.cancel(false) }
            },
        )
    }
    private val sessions: TabletC1aSessionMachine get() = sessionsDelegate.value
    private val pendingStarts = C1aPendingStartRegistry()

    override fun onCreate(): Boolean = true

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        enforceShellCaller()
        val endpoint = try {
            TabletC1aProtocol.parse(uri.toString(), mode)
        } catch (_: IllegalArgumentException) {
            throw FileNotFoundException("unsupported T-L1 C1a request")
        }
        return when (endpoint) {
            is C1aEndpoint.WriteT0 -> openT0InputPipe(endpoint.envelope)
            else -> openJsonOutputPipe(responseFor(endpoint))
        }
    }

    override fun openFile(
        uri: Uri,
        mode: String,
        signal: CancellationSignal?,
    ): ParcelFileDescriptor = openFile(uri, mode)

    private fun openT0InputPipe(envelope: C1aStartEnvelope): ParcelFileDescriptor {
        val pipe = ParcelFileDescriptor.createPipe()
        val pending = try {
            pendingStarts.register(envelope) {
                runCatching { pipe[0].close() }
                Unit
            }
        } catch (_: IllegalArgumentException) {
            pipe.forEach { descriptor -> runCatching { descriptor.close() } }
            throw FileNotFoundException("a T-L1 C1a T0 write is already pending")
        }
        val timeout = try {
            pendingTimeoutExecutor.schedule(
                { runCatching { pipe[0].close() } },
                PENDING_INPUT_TTL_MILLIS,
                TimeUnit.MILLISECONDS,
            )
        } catch (_: Exception) {
            pending.complete()
            pipe.forEach { descriptor -> runCatching { descriptor.close() } }
            throw FileNotFoundException("T-L1 C1a input timeout guard is unavailable")
        }
        try {
            t0PipeExecutor.execute {
                var bytes: ByteArray? = null
                try {
                    val received = ParcelFileDescriptor.AutoCloseInputStream(pipe[0]).use(::readBoundedT0)
                    bytes = received
                    pending.claimStart(received) {
                        try {
                            sessions.start(envelope, received)
                        } catch (_: Exception) {
                            sessions.rejectStart(envelope)
                        }
                    }
                } catch (_: Exception) {
                    bytes?.fill(0)
                    pending.claimFailure { sessions.rejectStart(envelope) }
                    runCatching { pipe[0].close() }
                } finally {
                    timeout.cancel(false)
                    pending.complete()
                }
            }
        } catch (_: Exception) {
            timeout.cancel(false)
            pending.complete()
            pipe.forEach { descriptor -> runCatching { descriptor.close() } }
            throw FileNotFoundException("T-L1 C1a input pipe is unavailable")
        }
        return pipe[1]
    }

    private fun readBoundedT0(input: java.io.InputStream): ByteArray {
        val readBuffer = ByteArray(8_192)
        val bounded = ByteArray(TABLET_C1A_MAX_T0_BYTES)
        var size = 0
        try {
            while (true) {
                val count = input.read(readBuffer)
                if (count < 0) break
                if (count == 0) continue
                require(size + count <= TABLET_C1A_MAX_T0_BYTES) { "T0 input exceeds limit" }
                System.arraycopy(readBuffer, 0, bounded, size, count)
                size += count
            }
            require(size in 1..TABLET_C1A_MAX_T0_BYTES) { "T0 input length is invalid" }
            return bounded.copyOf(size)
        } finally {
            readBuffer.fill(0)
            bounded.fill(0)
        }
    }

    private fun responseFor(endpoint: C1aEndpoint): String = when (endpoint) {
        is C1aEndpoint.Status -> {
            val pending = pendingStarts.await(endpoint.key, STATUS_PENDING_WAIT_MILLIS)
            val snapshot = if (pending == C1aPendingAwait.TIMED_OUT) {
                C1aControlSnapshot(endpoint.key, C1aSessionState.ABSENT, "t0_pending")
            } else {
                sessions.status(endpoint.key)
            }
            controlJson(snapshot)
        }
        is C1aEndpoint.Capture -> controlJson(
            sessions.capture(
                key = endpoint.key,
                token = endpoint.token,
                currentServiceIdentity = { GatewayA11yService.instance },
                frameCapture = C1aFrameCapture { identity, captureId, captureToken, expectedTitleHash ->
                    val service = identity as? GatewayA11yService
                        ?: throw IllegalStateException("A11y service identity type changed")
                    AndroidTabletLayoutProbeSource(
                        service = service,
                        revisionProvider = { c1aCaptureRevision(service.revision, captureToken) },
                    )
                        .captureSingleFrame(captureId, captureToken, expectedTitleHash)
                },
            ),
        )
        is C1aEndpoint.Result -> when (val result = sessions.result(endpoint.key)) {
            is C1aResultRead.Observation -> result.json
            is C1aResultRead.Control -> controlJson(result.snapshot)
        }
        is C1aEndpoint.Abort -> controlJson(
            pendingStarts.cancel(endpoint.key) { envelope -> sessions.abortPending(envelope) }
                ?: sessions.abort(endpoint.key),
        )
        is C1aEndpoint.WriteT0 -> error("write endpoint has no read response")
    }

    private fun controlJson(snapshot: C1aControlSnapshot): String = snapshot.toJson(
        build = buildIdentity,
        a11yServiceReady = GatewayA11yService.instance != null,
    ).toString()

    private fun openJsonOutputPipe(json: String): ParcelFileDescriptor {
        val bytes = json.toByteArray(StandardCharsets.UTF_8)
        require(bytes.size <= TABLET_C1A_MAX_OUTPUT_BYTES) { "C1a output exceeds limit" }
        val pipe = ParcelFileDescriptor.createPipe()
        try {
            outputPipeExecutor.execute {
                try {
                    ParcelFileDescriptor.AutoCloseOutputStream(pipe[1]).use { output ->
                        output.write(bytes)
                    }
                } catch (_: Exception) {
                    runCatching { pipe[1].close() }
                } finally {
                    bytes.fill(0)
                }
            }
        } catch (_: Exception) {
            bytes.fill(0)
            pipe.forEach { descriptor -> runCatching { descriptor.close() } }
            throw FileNotFoundException("T-L1 C1a output pipe is unavailable")
        }
        return pipe[0]
    }

    private fun enforceShellCaller() {
        if (Binder.getCallingUid() != Process.SHELL_UID) {
            throw SecurityException("T-L1 C1a provider is restricted to adb shell")
        }
    }

    /** ContentResolver 的 asset adapter 只允许原样落回同一个 openFile 协议。 */
    override fun openAssetFile(uri: Uri, mode: String): AssetFileDescriptor =
        AssetFileDescriptor(openFile(uri, mode), 0, AssetFileDescriptor.UNKNOWN_LENGTH)

    override fun openAssetFile(
        uri: Uri,
        mode: String,
        signal: CancellationSignal?,
    ): AssetFileDescriptor = AssetFileDescriptor(openFile(uri, mode), 0, AssetFileDescriptor.UNKNOWN_LENGTH)

    // 任何不是 openFile/read-write stream adapter 的 ContentProvider surface 都保持关闭。
    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? = rejectNonStreamSurface()

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
        cancellationSignal: CancellationSignal?,
    ): Cursor? = rejectNonStreamSurface()

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        queryArgs: Bundle?,
        cancellationSignal: CancellationSignal?,
    ): Cursor? = rejectNonStreamSurface()

    override fun getType(uri: Uri): String? = rejectNonStreamSurface()

    override fun insert(uri: Uri, values: ContentValues?): Uri? = rejectNonStreamSurface()

    override fun insert(uri: Uri, values: ContentValues?, extras: Bundle?): Uri? = rejectNonStreamSurface()

    override fun bulkInsert(uri: Uri, values: Array<out ContentValues>): Int = rejectNonStreamSurface()

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int =
        rejectNonStreamSurface()

    override fun delete(uri: Uri, extras: Bundle?): Int = rejectNonStreamSurface()

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = rejectNonStreamSurface()

    override fun update(uri: Uri, values: ContentValues?, extras: Bundle?): Int = rejectNonStreamSurface()

    override fun call(method: String, arg: String?, extras: Bundle?): Bundle? = rejectNonStreamSurface()

    override fun call(authority: String, method: String, arg: String?, extras: Bundle?): Bundle? =
        rejectNonStreamSurface()

    override fun getStreamTypes(uri: Uri, mimeTypeFilter: String): Array<String>? = rejectNonStreamSurface()

    override fun openTypedAssetFile(
        uri: Uri,
        mimeTypeFilter: String,
        opts: Bundle?,
        signal: CancellationSignal?,
    ): AssetFileDescriptor? = rejectNonStreamSurface()

    override fun openTypedAssetFile(
        uri: Uri,
        mimeTypeFilter: String,
        opts: Bundle?,
    ): AssetFileDescriptor? = rejectNonStreamSurface()

    override fun applyBatch(operations: ArrayList<ContentProviderOperation>): Array<ContentProviderResult> =
        rejectNonStreamSurface()

    override fun applyBatch(
        authority: String,
        operations: ArrayList<ContentProviderOperation>,
    ): Array<ContentProviderResult> = rejectNonStreamSurface()

    override fun canonicalize(uri: Uri): Uri? = rejectNonStreamSurface()

    override fun uncanonicalize(uri: Uri): Uri? = rejectNonStreamSurface()

    override fun refresh(uri: Uri, args: Bundle?, cancellationSignal: CancellationSignal?): Boolean =
        rejectNonStreamSurface()

    private fun rejectNonStreamSurface(): Nothing {
        enforceShellCaller()
        throw UnsupportedOperationException("T-L1 C1a supports openFile read/write streams only")
    }

    override fun shutdown() {
        t0PipeExecutor.shutdownNow()
        outputPipeExecutor.shutdownNow()
        pendingTimeoutExecutor.shutdownNow()
        if (sessionsDelegate.isInitialized()) sessions.shutdown()
        sessionExpiryExecutor.shutdownNow()
        super.shutdown()
    }

    private companion object {
        const val STATUS_PENDING_WAIT_MILLIS = 3_000L
        const val PENDING_INPUT_TTL_MILLIS = 15_000L
    }
}

package dev.magina.gateway.tablet.c1b

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
import java.io.FileNotFoundException
import java.nio.charset.StandardCharsets
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

/** Debug-only, shell-only anonymous-pipe surface for the trusted C1b read producer. */
internal class TabletC1bContentProvider : ContentProvider() {
    private val t0PipeExecutor: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "tablet-c1b-t0-pipe").apply { isDaemon = true }
    }
    private val outputPipeExecutor: ExecutorService = Executors.newFixedThreadPool(2) { runnable ->
        Thread(runnable, "tablet-c1b-output-pipe").apply { isDaemon = true }
    }
    private val pendingTimeoutExecutor: ScheduledExecutorService =
        Executors.newSingleThreadScheduledExecutor { runnable ->
            Thread(runnable, "tablet-c1b-pending-timeout").apply { isDaemon = true }
        }
    private val captureWorkerExecutor: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "tablet-c1b-capture-worker").apply { isDaemon = true }
    }
    private val deadlineExecutor: ScheduledExecutorService =
        Executors.newSingleThreadScheduledExecutor { runnable ->
            Thread(runnable, "tablet-c1b-deadline").apply { isDaemon = true }
        }

    private val buildIdentity by lazy {
        C1bProtocolBuildIdentity(
            packageName = BuildConfig.APPLICATION_ID,
            versionName = BuildConfig.VERSION_NAME,
            versionCode = BuildConfig.VERSION_CODE.toLong(),
            embeddedGitHead = BuildConfig.TABLET_C1B_GIT_HEAD,
            buildChallenge = BuildConfig.TABLET_C1B_BUILD_CHALLENGE,
        )
    }
    private val controllerDelegate = lazy {
        TabletC1bRuntimeController(
            build = buildIdentity,
            worker = C1bReadWorker(captureWorkerExecutor::execute),
            scheduler = C1bDeadlineScheduler { delayMillis, task ->
                val future = deadlineExecutor.schedule(task, delayMillis, TimeUnit.MILLISECONDS)
                C1bDeadlineCancellation { future.cancel(false) }
            },
            currentServiceIdentity = { GatewayA11yService.instance },
            frameCapture = C1bRuntimeFrameCapture { service, captureId, captureToken, expectedTitleHash ->
                AndroidTabletC1bSource(
                    service = service,
                    // Keep the closure live so before/layout/IME/after reads can expose event drift.
                    revisionProvider = { c1bCaptureRevision(service.revision, captureToken) },
                ).captureSingleFrame(captureId, captureToken, expectedTitleHash)
            },
        )
    }
    private val controller: TabletC1bRuntimeController<GatewayA11yService>
        get() = controllerDelegate.value
    private val pendingStarts = C1bPendingStartRegistry()

    override fun onCreate(): Boolean = true

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        enforceShellCaller()
        val endpoint = try {
            TabletC1bProtocol.parse(uri.toString(), mode)
        } catch (_: IllegalArgumentException) {
            throw FileNotFoundException("unsupported T-L1 C1b request")
        }
        return when (endpoint) {
            is C1bEndpoint.WriteT0 -> openT0InputPipe(endpoint.envelope)
            else -> openJsonOutputPipe(responseFor(endpoint))
        }
    }

    override fun openFile(
        uri: Uri,
        mode: String,
        signal: CancellationSignal?,
    ): ParcelFileDescriptor = openFile(uri, mode)

    private fun openT0InputPipe(envelope: C1bStartEnvelope): ParcelFileDescriptor {
        val pipe = ParcelFileDescriptor.createPipe()
        val pending = try {
            pendingStarts.register(envelope) {
                runCatching { pipe[0].close() }
                Unit
            }
        } catch (_: IllegalArgumentException) {
            pipe.forEach { descriptor -> runCatching { descriptor.close() } }
            throw FileNotFoundException("a T-L1 C1b T0 write is already pending")
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
            throw FileNotFoundException("T-L1 C1b input timeout guard is unavailable")
        }
        try {
            t0PipeExecutor.execute {
                var bytes: ByteArray? = null
                try {
                    val received = ParcelFileDescriptor.AutoCloseInputStream(pipe[0]).use(::readBoundedT0)
                    bytes = received
                    pending.claimStart(received) {
                        try {
                            controller.start(envelope, received)
                        } catch (_: Exception) {
                            controller.rejectStart(envelope)
                        }
                    }
                } catch (_: Exception) {
                    bytes?.fill(0)
                    pending.claimFailure { controller.rejectStart(envelope) }
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
            throw FileNotFoundException("T-L1 C1b input pipe is unavailable")
        }
        return pipe[1]
    }

    private fun readBoundedT0(input: java.io.InputStream): ByteArray {
        val readBuffer = ByteArray(8_192)
        val bounded = ByteArray(TABLET_C1B_MAX_T0_BYTES)
        var size = 0
        try {
            while (true) {
                val count = input.read(readBuffer)
                if (count < 0) break
                if (count == 0) continue
                require(size + count <= TABLET_C1B_MAX_T0_BYTES) { "T0 input exceeds limit" }
                System.arraycopy(readBuffer, 0, bounded, size, count)
                size += count
            }
            require(size in 1..TABLET_C1B_MAX_T0_BYTES) { "T0 input length is invalid" }
            return bounded.copyOf(size)
        } finally {
            readBuffer.fill(0)
            bounded.fill(0)
        }
    }

    private fun responseFor(endpoint: C1bEndpoint): String = when (endpoint) {
        is C1bEndpoint.Status -> {
            val pending = pendingStarts.await(endpoint.key, STATUS_PENDING_WAIT_MILLIS)
            val control = if (pending == C1bPendingAwait.TIMED_OUT) {
                pendingControl(endpoint.key)
            } else {
                controller.status(endpoint.key)
            }
            controlJson(control)
        }
        is C1bEndpoint.Capture -> controlJson(controller.capture(endpoint.key, endpoint.token))
        is C1bEndpoint.Result -> when (val result = controller.result(endpoint.key)) {
            is C1bRuntimeResult.Observation -> result.json
            is C1bRuntimeResult.Control -> controlJson(result.value)
        }
        is C1bEndpoint.Abort -> controlJson(
            pendingStarts.cancel(endpoint.key) { envelope -> controller.abortPending(envelope) }
                ?: controller.abort(endpoint.key),
        )
        is C1bEndpoint.WriteT0 -> error("write endpoint has no read response")
    }

    private fun pendingControl(key: C1bSessionKey): C1bProtocolControl = C1bProtocolControl(
        key = key,
        generation = 0L,
        state = C1bProtocolState.ABSENT,
        reasonCode = "t0_pending",
        inFlightToken = null,
        c1RequestsAccepted = 0,
        c2RequestsAccepted = 0,
        committedTokens = emptyList(),
        expectedTitleHash = null,
        producerCommitSha = null,
        producerArtifactSha256 = null,
    )

    private fun controlJson(control: C1bProtocolControl): String = control.toJson(
        build = buildIdentity,
        a11yServiceReady = GatewayA11yService.instance != null,
    ).toString()

    private fun openJsonOutputPipe(json: String): ParcelFileDescriptor {
        val bytes = json.toByteArray(StandardCharsets.UTF_8)
        require(bytes.size <= TABLET_C1B_MAX_OUTPUT_BYTES) { "C1b output exceeds limit" }
        val pipe = ParcelFileDescriptor.createPipe()
        try {
            outputPipeExecutor.execute {
                try {
                    ParcelFileDescriptor.AutoCloseOutputStream(pipe[1]).use { output -> output.write(bytes) }
                } catch (_: Exception) {
                    runCatching { pipe[1].close() }
                } finally {
                    bytes.fill(0)
                }
            }
        } catch (_: Exception) {
            bytes.fill(0)
            pipe.forEach { descriptor -> runCatching { descriptor.close() } }
            throw FileNotFoundException("T-L1 C1b output pipe is unavailable")
        }
        return pipe[0]
    }

    private fun enforceShellCaller() {
        if (Binder.getCallingUid() != Process.SHELL_UID) {
            throw SecurityException("T-L1 C1b provider is restricted to adb shell")
        }
    }

    override fun openAssetFile(uri: Uri, mode: String): AssetFileDescriptor =
        AssetFileDescriptor(openFile(uri, mode), 0, AssetFileDescriptor.UNKNOWN_LENGTH)

    override fun openAssetFile(
        uri: Uri,
        mode: String,
        signal: CancellationSignal?,
    ): AssetFileDescriptor = AssetFileDescriptor(openFile(uri, mode), 0, AssetFileDescriptor.UNKNOWN_LENGTH)

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
        throw UnsupportedOperationException("T-L1 C1b supports openFile read/write streams only")
    }

    override fun shutdown() {
        t0PipeExecutor.shutdownNow()
        outputPipeExecutor.shutdownNow()
        pendingTimeoutExecutor.shutdownNow()
        if (controllerDelegate.isInitialized()) controller.shutdown()
        captureWorkerExecutor.shutdownNow()
        deadlineExecutor.shutdownNow()
        super.shutdown()
    }

    private companion object {
        const val STATUS_PENDING_WAIT_MILLIS = 3_000L
        const val PENDING_INPUT_TTL_MILLIS = 15_000L
    }
}

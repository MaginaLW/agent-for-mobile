package dev.magina.gateway.tablet.c1b

import java.nio.charset.StandardCharsets

internal fun interface C1bRuntimeFrameCapture<S : Any> {
    fun capture(
        serviceIdentity: S,
        captureId: String,
        captureToken: String,
        expectedTitleHash: String,
    ): C1bRawFrame
}

internal const val TABLET_C1B_REPLAY_LEDGER_CAPACITY = 128

internal sealed interface C1bRuntimeResult {
    data class Observation(val json: String) : C1bRuntimeResult {
        override fun toString(): String = "C1bRuntimeResult.Observation(json=<redacted>)"
    }

    data class Control(val value: C1bProtocolControl) : C1bRuntimeResult
}

/** Adds trusted-T0 binding and replay ledgers around the generic asynchronous read coordinator. */
internal class TabletC1bRuntimeController<S : Any>(
    private val build: C1bProtocolBuildIdentity,
    worker: C1bReadWorker,
    scheduler: C1bDeadlineScheduler,
    private val currentServiceIdentity: () -> S?,
    private val frameCapture: C1bRuntimeFrameCapture<S>,
    monotonicMillis: () -> Long = { System.nanoTime() / 1_000_000L },
    captureTimeoutMillis: Long = 5_000L,
    sessionTtlMillis: Long = 120_000L,
) {
    private data class BoundFrame(
        val request: C1bAssemblyRequest,
        val frame: C1bRawFrame,
    )

    private data class RuntimeSession(
        val envelope: C1bStartEnvelope,
        val lease: C1bRunLease,
        var assemblyRequest: C1bAssemblyRequest?,
        var lastSnapshot: C1bReadSnapshot,
        var overrideSnapshot: C1bReadSnapshot? = null,
        val coordinatorStarted: Boolean,
    )

    private val consumedNonces = mutableSetOf<String>()
    private val consumedRunIds = mutableSetOf<String>()
    private var active: RuntimeSession? = null
    private var closed = false
    private val observationAssembler = TabletC1bAssembler()
    private val coordinator = TabletC1bReadCoordinator(
        worker = worker,
        scheduler = scheduler,
        currentServiceIdentity = currentServiceIdentity,
        frameReader = C1bFrameReader { service, token ->
            val request = bindingForWorker(token)
            val raw = frameCapture.capture(
                serviceIdentity = service,
                captureId = "capture-$token",
                captureToken = token,
                expectedTitleHash = request.expectedTitleHash,
            )
            require(raw.captureId == "capture-$token" && raw.capture.token == token &&
                raw.expectedTitleHash == request.expectedTitleHash
            ) { "C1b frame binding changed during capture" }
            BoundFrame(request, raw)
        },
        assembler = C1bFrameAssembler { c1, c2 ->
            require(c1.request == c2.request) { "C1b assembly context changed between frames" }
            val json = observationAssembler.assemble(c1.request, listOf(c1.frame, c2.frame)).toJson().toString()
            val bytes = json.toByteArray(StandardCharsets.UTF_8)
            try {
                require(bytes.size <= TABLET_C1B_MAX_OUTPUT_BYTES) { "C1b output exceeds limit" }
            } finally {
                bytes.fill(0)
            }
            json
        },
        monotonicMillis = monotonicMillis,
        captureTimeoutMillis = captureTimeoutMillis,
        sessionTtlMillis = sessionTtlMillis,
    )

    @Synchronized
    fun start(envelope: C1bStartEnvelope, upstreamT0RawUtf8: ByteArray): C1bProtocolControl {
        if (closed) {
            upstreamT0RawUtf8.fill(0)
            return absent(envelope.key, "coordinator_closed")
        }
        val current = active
        if (current != null && currentSnapshot(current).state in OCCUPIED_STATES) {
            upstreamT0RawUtf8.fill(0)
            return if (current.envelope.key == envelope.key) {
                if (currentSnapshot(current).state in ACTIVE_STATES) failReplay(current) else control(current)
            } else {
                absent(envelope.key, "session_busy")
            }
        }
        if (envelope.key.nonce in consumedNonces || envelope.key.runId in consumedRunIds) {
            upstreamT0RawUtf8.fill(0)
            return absent(
                envelope.key,
                if (envelope.key.nonce in consumedNonces) "nonce_reused" else "run_id_reused",
            )
        }
        if (!rememberConsumed(envelope.key)) {
            upstreamT0RawUtf8.fill(0)
            return absent(envelope.key, "replay_ledger_full")
        }
        if (envelope.producerCommitSha != build.embeddedGitHead) {
            upstreamT0RawUtf8.fill(0)
            return installSynthetic(envelope, C1bReadState.FAILED, "build_identity_mismatch")
        }
        val request = try {
            TrustedRuntimeContextFactory.create(
                runId = envelope.key.runId,
                expectedTitleHash = envelope.titleHash,
                c1bProducerCommitSha = envelope.producerCommitSha,
                c1bProducerArtifactSha256 = envelope.producerArtifactSha256,
                upstreamT0RawUtf8 = upstreamT0RawUtf8,
            )
        } catch (_: Exception) {
            return installSynthetic(envelope, C1bReadState.FAILED, "t0_invalid")
        } finally {
            upstreamT0RawUtf8.fill(0)
        }
        val snapshot = coordinator.begin(envelope.key.runId)
        if (snapshot.state == C1bReadState.ABSENT) {
            return absent(envelope.key, requireNotNull(snapshot.reasonCode))
        }
        val created = RuntimeSession(
            envelope = envelope,
            lease = snapshot.lease,
            assemblyRequest = request,
            lastSnapshot = snapshot,
            coordinatorStarted = true,
        )
        active = created
        observe(created, snapshot)
        return control(created)
    }

    @Synchronized
    fun rejectStart(envelope: C1bStartEnvelope): C1bProtocolControl {
        if (closed) return absent(envelope.key, "coordinator_closed")
        val current = active
        if (current != null && currentSnapshot(current).state in OCCUPIED_STATES) {
            return if (current.envelope.key == envelope.key && currentSnapshot(current).state in ACTIVE_STATES) {
                failWith(current, "t0_invalid")
            } else if (current.envelope.key == envelope.key) {
                control(current)
            } else {
                absent(envelope.key, "session_busy")
            }
        }
        if (envelope.key.nonce !in consumedNonces && envelope.key.runId !in consumedRunIds) {
            if (!rememberConsumed(envelope.key)) return absent(envelope.key, "replay_ledger_full")
            return installSynthetic(envelope, C1bReadState.FAILED, "t0_invalid")
        }
        return status(envelope.key)
    }

    @Synchronized
    fun abortPending(envelope: C1bStartEnvelope): C1bProtocolControl {
        if (closed) return absent(envelope.key, "coordinator_closed")
        val current = active?.takeIf { it.envelope.key == envelope.key }
        if (current != null) return abort(envelope.key)
        if (envelope.key.nonce in consumedNonces || envelope.key.runId in consumedRunIds) {
            return absent(
                envelope.key,
                if (envelope.key.nonce in consumedNonces) "nonce_reused" else "run_id_reused",
            )
        }
        if (!rememberConsumed(envelope.key)) return absent(envelope.key, "replay_ledger_full")
        return installSynthetic(envelope, C1bReadState.ABORTED, "session_aborted")
    }

    @Synchronized
    fun status(key: C1bSessionKey): C1bProtocolControl {
        val current = active?.takeIf { it.envelope.key == key } ?: return absent(key, "session_not_found")
        refresh(current)
        return control(current)
    }

    @Synchronized
    fun capture(key: C1bSessionKey, token: String): C1bProtocolControl {
        val current = active?.takeIf { it.envelope.key == key } ?: return absent(key, "session_not_found")
        if (current.overrideSnapshot != null || !current.coordinatorStarted) return control(current)
        val snapshot = coordinator.requestCapture(current.lease, token)
        observe(current, snapshot)
        return control(current)
    }

    @Synchronized
    fun result(key: C1bSessionKey): C1bRuntimeResult {
        val current = active?.takeIf { it.envelope.key == key }
            ?: return C1bRuntimeResult.Control(absent(key, "session_not_found"))
        if (current.overrideSnapshot != null || !current.coordinatorStarted) {
            return C1bRuntimeResult.Control(control(current))
        }
        return when (val read = coordinator.result(current.lease)) {
            is C1bResultRead.Output -> {
                current.assemblyRequest = null
                active = null
                C1bRuntimeResult.Observation(read.value)
            }
            is C1bResultRead.Control -> {
                observe(current, read.snapshot)
                C1bRuntimeResult.Control(control(current))
            }
        }
    }

    @Synchronized
    fun abort(key: C1bSessionKey): C1bProtocolControl {
        val current = active?.takeIf { it.envelope.key == key } ?: return absent(key, "session_not_found")
        if (current.overrideSnapshot != null || !current.coordinatorStarted) return control(current)
        observe(current, coordinator.abort(current.lease))
        return control(current)
    }

    @Synchronized
    fun shutdown() {
        if (closed) return
        closed = true
        coordinator.shutdown()
        active?.assemblyRequest = null
        active = null
        consumedNonces.clear()
        consumedRunIds.clear()
    }

    @Synchronized
    private fun bindingForWorker(token: String): C1bAssemblyRequest {
        val current = active ?: throw IllegalStateException("C1b worker has no active session")
        require(token == "c1" || token == "c2") { "C1b worker token is invalid" }
        require(current.overrideSnapshot == null && current.coordinatorStarted) {
            "C1b worker binding is no longer active"
        }
        return requireNotNull(current.assemblyRequest) { "C1b worker assembly context was cleared" }
    }

    private fun refresh(current: RuntimeSession) {
        if (current.overrideSnapshot == null && current.coordinatorStarted) {
            observe(current, coordinator.status(current.lease))
        }
    }

    private fun currentSnapshot(current: RuntimeSession): C1bReadSnapshot {
        refresh(current)
        return current.overrideSnapshot ?: current.lastSnapshot
    }

    private fun observe(current: RuntimeSession, snapshot: C1bReadSnapshot) {
        current.lastSnapshot = snapshot
        if (snapshot.state in TERMINAL_OR_COMPLETE_STATES) current.assemblyRequest = null
    }

    private fun failReplay(current: RuntimeSession): C1bProtocolControl = failWith(current, "start_replayed")

    private fun failWith(current: RuntimeSession, reason: String): C1bProtocolControl {
        val base = if (current.coordinatorStarted) coordinator.abort(current.lease) else current.lastSnapshot
        val failed = base.copy(state = C1bReadState.FAILED, reasonCode = reason, inFlightToken = null)
        current.overrideSnapshot = failed
        observe(current, failed)
        return control(current)
    }

    private fun installSynthetic(
        envelope: C1bStartEnvelope,
        state: C1bReadState,
        reason: String,
    ): C1bProtocolControl {
        val snapshot = C1bReadSnapshot(
            lease = C1bRunLease(envelope.key.runId, 0L),
            state = state,
            reasonCode = reason,
            inFlightToken = null,
            c1RequestsAccepted = 0,
            c2RequestsAccepted = 0,
            committedTokens = emptyList(),
        )
        val created = RuntimeSession(
            envelope = envelope,
            lease = snapshot.lease,
            assemblyRequest = null,
            lastSnapshot = snapshot,
            overrideSnapshot = snapshot,
            coordinatorStarted = false,
        )
        active = created
        return control(created)
    }

    private fun rememberConsumed(key: C1bSessionKey): Boolean {
        check(key.nonce !in consumedNonces && key.runId !in consumedRunIds) {
            "C1b replay ledger received an already-consumed identity"
        }
        check(consumedNonces.size == consumedRunIds.size) { "C1b replay ledger sets diverged" }
        if (consumedNonces.size >= TABLET_C1B_REPLAY_LEDGER_CAPACITY) return false
        consumedNonces += key.nonce
        consumedRunIds += key.runId
        return true
    }

    @Synchronized
    internal fun replayLedgerSizeForTest(): Int {
        check(consumedNonces.size == consumedRunIds.size) { "C1b replay ledger sets diverged" }
        return consumedNonces.size
    }

    private fun control(current: RuntimeSession): C1bProtocolControl =
        protocolControl(currentSnapshot(current), current.envelope)

    private fun absent(key: C1bSessionKey, reason: String): C1bProtocolControl = C1bProtocolControl(
        key = key,
        generation = 0L,
        state = C1bProtocolState.ABSENT,
        reasonCode = reason,
        inFlightToken = null,
        c1RequestsAccepted = 0,
        c2RequestsAccepted = 0,
        committedTokens = emptyList(),
        expectedTitleHash = null,
        producerCommitSha = null,
        producerArtifactSha256 = null,
    )

    private fun protocolControl(snapshot: C1bReadSnapshot, envelope: C1bStartEnvelope): C1bProtocolControl =
        C1bProtocolControl(
            key = envelope.key,
            generation = snapshot.lease.generation,
            state = snapshot.state.toProtocolState(),
            reasonCode = snapshot.reasonCode,
            inFlightToken = snapshot.inFlightToken,
            c1RequestsAccepted = snapshot.c1RequestsAccepted,
            c2RequestsAccepted = snapshot.c2RequestsAccepted,
            committedTokens = snapshot.committedTokens,
            expectedTitleHash = envelope.titleHash,
            producerCommitSha = envelope.producerCommitSha,
            producerArtifactSha256 = envelope.producerArtifactSha256,
        )

    private companion object {
        val ACTIVE_STATES = setOf(
            C1bReadState.READY_C1,
            C1bReadState.CAPTURING_C1,
            C1bReadState.READY_C2,
            C1bReadState.CAPTURING_C2,
        )
        val OCCUPIED_STATES = ACTIVE_STATES + C1bReadState.COMPLETE
        val TERMINAL_OR_COMPLETE_STATES = setOf(
            C1bReadState.COMPLETE,
            C1bReadState.FAILED,
            C1bReadState.ABORTED,
            C1bReadState.EXPIRED,
        )
    }
}

internal fun c1bCaptureRevision(eventRevision: Long, captureToken: String): Long {
    val ordinal = when (captureToken) {
        "c1" -> 1L
        "c2" -> 2L
        else -> throw IllegalArgumentException("C1b capture token has no revision ordinal")
    }
    require(eventRevision in 0L..(Int.MAX_VALUE.toLong() - ordinal)) {
        "C1b event revision is outside the closed observation schema"
    }
    return eventRevision + ordinal
}

private fun C1bReadState.toProtocolState(): C1bProtocolState = when (this) {
    C1bReadState.ABSENT -> C1bProtocolState.ABSENT
    C1bReadState.READY_C1 -> C1bProtocolState.READY_C1
    C1bReadState.CAPTURING_C1 -> C1bProtocolState.CAPTURING_C1
    C1bReadState.READY_C2 -> C1bProtocolState.READY_C2
    C1bReadState.CAPTURING_C2 -> C1bProtocolState.CAPTURING_C2
    C1bReadState.COMPLETE -> C1bProtocolState.COMPLETE
    C1bReadState.FAILED -> C1bProtocolState.FAILED
    C1bReadState.ABORTED -> C1bProtocolState.ABORTED
    C1bReadState.EXPIRED -> C1bProtocolState.EXPIRED
}

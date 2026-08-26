package dev.magina.gateway.tablet.c1a

import dev.magina.gateway.tablet.RawTabletProbeFrame
import dev.magina.gateway.tablet.TabletLayoutProbe
import dev.magina.gateway.tablet.TabletProbeRunContext
import org.json.JSONObject
import java.nio.charset.StandardCharsets
import java.security.SecureRandom

internal data class C1aBuildIdentity(
    val packageName: String,
    val versionName: String,
    val versionCode: Long,
    val embeddedGitHead: String,
    val buildChallenge: String,
) {
    init {
        require(packageName == "dev.magina.gateway") { "C1a package identity is invalid" }
        require(versionName.isNotBlank()) { "C1a version name is invalid" }
        require(versionCode > 0) { "C1a version code is invalid" }
        require(Regex("[0-9a-f]{40}").matches(embeddedGitHead)) { "C1a embedded Git HEAD is invalid" }
        require(Regex("[a-z0-9][a-z0-9._-]{15,95}").matches(buildChallenge)) {
            "C1a build challenge is invalid"
        }
    }
}

internal enum class C1aSessionState(val wire: String) {
    ABSENT("absent"),
    AWAITING_C1("awaiting_c1"),
    AWAITING_C2("awaiting_c2"),
    COMPLETE("complete"),
    FAILED("failed"),
    ABORTED("aborted"),
    EXPIRED("expired"),
}

internal data class C1aControlSnapshot(
    val key: C1aSessionKey,
    val state: C1aSessionState,
    val reasonCode: String?,
    val captureToken: String? = null,
    val producerCommitSha: String? = null,
    val producerArtifactSha256: String? = null,
) {
    val ok: Boolean get() = state in setOf(
        C1aSessionState.AWAITING_C1,
        C1aSessionState.AWAITING_C2,
        C1aSessionState.COMPLETE,
    )

    private val next: String
        get() = when (state) {
            C1aSessionState.AWAITING_C1 -> "capture_c1"
            C1aSessionState.AWAITING_C2 -> "capture_c2"
            C1aSessionState.COMPLETE -> "read_result"
            else -> "none"
        }

    fun toJson(build: C1aBuildIdentity, a11yServiceReady: Boolean): JSONObject = JSONObject()
        .put("schema", "tablet-c1a-control/v1")
        .put("ok", ok)
        .put("run_id", key.runId)
        .put("state", state.wire)
        .put("next", next)
        .put("reason_code", reasonCode ?: JSONObject.NULL)
        .put("capture_token", captureToken ?: JSONObject.NULL)
        .put("producer_commit_sha", producerCommitSha ?: JSONObject.NULL)
        .put("producer_artifact_sha256", producerArtifactSha256 ?: JSONObject.NULL)
        .put(
            "provider",
            JSONObject()
                .put("authority", TABLET_C1A_AUTHORITY)
                .put("protocol_version", TABLET_C1A_PROTOCOL_VERSION)
                .put("package_name", build.packageName)
                .put("version_name", build.versionName)
                .put("version_code", build.versionCode)
                .put("embedded_git_head", build.embeddedGitHead)
                .put("build_challenge", build.buildChallenge)
                .put("a11y_service_ready", a11yServiceReady),
        )
}

internal sealed interface C1aResultRead {
    data class Observation(val json: String) : C1aResultRead
    data class Control(val snapshot: C1aControlSnapshot) : C1aResultRead
}

internal fun interface C1aFrameCapture {
    fun capture(
        serviceIdentity: Any,
        captureId: String,
        captureToken: String,
        expectedTitleHash: String,
    ): RawTabletProbeFrame
}

internal fun interface C1aExpiryCancellation {
    fun cancel()
}

internal fun interface C1aExpiryScheduler {
    fun schedule(delayMillis: Long, task: () -> Unit): C1aExpiryCancellation
}

/**
 * 仅内存、单活跃 run 的串行状态机。它不 sleep、不触碰文件/网络/动作 API；第一次失败即终态，
 * c1/c2 不允许重拍。serviceIdentity 使用引用同一性绑定两帧到同一 A11yService 实例。
 */
internal class TabletC1aSessionMachine(
    private val build: C1aBuildIdentity,
    private val expiryScheduler: C1aExpiryScheduler,
    private val monotonicMillis: () -> Long = { System.nanoTime() / 1_000_000L },
    private val saltSource: () -> ByteArray = ::secureRunSalt,
    private val ttlMillis: Long = DEFAULT_TTL_MILLIS,
) {
    init {
        require(ttlMillis in 20_000L..300_000L) { "C1a session TTL is outside the closed range" }
    }

    private data class Session(
        val envelope: C1aStartEnvelope,
        val deadlineMillis: Long,
        var state: C1aSessionState,
        var reasonCode: String? = null,
        var context: TabletProbeRunContext? = null,
        var firstFrame: RawTabletProbeFrame? = null,
        var serviceIdentity: Any? = null,
        var observationJson: String? = null,
        var expiryCancellation: C1aExpiryCancellation? = null,
    )

    private val consumedNonces = mutableSetOf<String>()
    private val consumedRunIds = mutableSetOf<String>()
    private var session: Session? = null
    private var closed = false

    @Synchronized
    fun start(envelope: C1aStartEnvelope, upstreamT0RawUtf8: ByteArray): C1aControlSnapshot {
        if (closed) {
            upstreamT0RawUtf8.fill(0)
            return absent(envelope.key, "session_not_found")
        }
        expireIfNeeded()
        val current = session
        if (current != null && current.state in OCCUPIED_STATES) {
            if (current.envelope.key == envelope.key && current.state in ACTIVE_STATES) {
                terminal(current, "start_replayed")
            }
            upstreamT0RawUtf8.fill(0)
            return if (current.envelope.key == envelope.key) snapshot(current) else {
                absent(envelope.key, "session_busy")
            }
        }
        if (envelope.key.nonce in consumedNonces || envelope.key.runId in consumedRunIds) {
            upstreamT0RawUtf8.fill(0)
            return absent(envelope.key, if (envelope.key.nonce in consumedNonces) "nonce_reused" else "run_id_reused")
        }
        consumedNonces += envelope.key.nonce
        consumedRunIds += envelope.key.runId
        val created = Session(
            envelope = envelope,
            deadlineMillis = deadlineFrom(monotonicMillis()),
            state = C1aSessionState.AWAITING_C1,
        )
        session = created
        if (!scheduleExpiry(created, ttlMillis)) {
            terminal(created, "session_expiry_unavailable")
            upstreamT0RawUtf8.fill(0)
            return snapshot(created)
        }
        if (envelope.producerCommitSha != build.embeddedGitHead) {
            terminal(created, "build_identity_mismatch")
            upstreamT0RawUtf8.fill(0)
            return snapshot(created)
        }
        val runSalt = runCatching { saltSource() }.getOrNull()
        if (runSalt == null || runSalt.size != 32) {
            runSalt?.fill(0)
            upstreamT0RawUtf8.fill(0)
            terminal(created, "run_salt_unavailable")
            return snapshot(created)
        }
        try {
            created.context = TrustedRuntimeContextFactory.create(
                runId = envelope.key.runId,
                expectedTitleHash = envelope.titleHash,
                c1aProducerCommitSha = envelope.producerCommitSha,
                c1aProducerArtifactSha256 = envelope.producerArtifactSha256,
                runSalt = runSalt,
                upstreamT0RawUtf8 = upstreamT0RawUtf8,
            )
        } catch (_: Exception) {
            terminal(created, "t0_invalid")
        } finally {
            runSalt.fill(0)
            upstreamT0RawUtf8.fill(0)
        }
        return snapshot(created)
    }

    @Synchronized
    fun rejectStart(envelope: C1aStartEnvelope): C1aControlSnapshot {
        if (closed) return absent(envelope.key, "session_not_found")
        expireIfNeeded()
        val current = session
        if (current != null && current.state in OCCUPIED_STATES) {
            if (current.envelope.key == envelope.key && current.state in ACTIVE_STATES) {
                terminal(current, "t0_invalid")
                return snapshot(current)
            }
            return if (current.envelope.key == envelope.key) snapshot(current) else {
                absent(envelope.key, "session_busy")
            }
        }
        if (envelope.key.nonce !in consumedNonces && envelope.key.runId !in consumedRunIds) {
            consumedNonces += envelope.key.nonce
            consumedRunIds += envelope.key.runId
            session = Session(
                envelope = envelope,
                deadlineMillis = deadlineFrom(monotonicMillis()),
                state = C1aSessionState.FAILED,
                reasonCode = "t0_invalid",
            )
        }
        return snapshotFor(envelope.key)
    }

    /** pending cancel 的 ledger/ACK 落点；不创建 Session，也不保留 T0/context/frame。 */
    @Synchronized
    fun abortPending(envelope: C1aStartEnvelope): C1aControlSnapshot {
        if (closed) return absent(envelope.key, "session_not_found")
        expireIfNeeded()
        val current = session?.takeIf { it.envelope.key == envelope.key }
        if (current != null) {
            abortSession(current)
            return snapshot(current)
        }
        consumedNonces += envelope.key.nonce
        consumedRunIds += envelope.key.runId
        return C1aControlSnapshot(
            key = envelope.key,
            state = C1aSessionState.ABORTED,
            reasonCode = "session_aborted",
            producerCommitSha = envelope.producerCommitSha,
            producerArtifactSha256 = envelope.producerArtifactSha256,
        )
    }

    @Synchronized
    fun status(key: C1aSessionKey): C1aControlSnapshot {
        expireIfNeeded()
        return snapshotFor(key)
    }

    @Synchronized
    fun capture(
        key: C1aSessionKey,
        token: String,
        currentServiceIdentity: () -> Any?,
        frameCapture: C1aFrameCapture,
    ): C1aControlSnapshot {
        expireIfNeeded()
        val active = session?.takeIf { it.envelope.key == key } ?: return absent(key, "session_not_found")
        if (token != "c1" && token != "c2") {
            if (active.state in ACTIVE_STATES) terminal(active, "capture_sequence_invalid")
            return snapshot(active)
        }
        val expectedState = if (token == "c1") C1aSessionState.AWAITING_C1 else C1aSessionState.AWAITING_C2
        if (active.state != expectedState) {
            if (active.state in ACTIVE_STATES) terminal(active, "capture_sequence_invalid")
            return snapshot(active)
        }
        val beforeService = currentServiceIdentity()
        if (beforeService == null) {
            terminal(active, "a11y_service_unavailable")
            return snapshot(active)
        }
        if (token == "c2" && beforeService !== active.serviceIdentity) {
            terminal(active, "a11y_service_replaced")
            return snapshot(active)
        }
        val raw = try {
            frameCapture.capture(
                serviceIdentity = beforeService,
                captureId = "capture-$token",
                captureToken = token,
                expectedTitleHash = active.envelope.titleHash,
            )
        } catch (_: Exception) {
            terminal(active, "capture_${token}_failed")
            return snapshot(active)
        }
        val afterService = currentServiceIdentity()
        if (afterService !== beforeService ||
            raw.captureToken != token || raw.captureId != "capture-$token" ||
            raw.captureExpectedTitleHash != active.envelope.titleHash
        ) {
            terminal(active, if (afterService !== beforeService) {
                "a11y_service_replaced"
            } else {
                "capture_${token}_failed"
            })
            return snapshot(active)
        }
        if (expireSessionIfNeeded(active)) return snapshot(active)
        if (token == "c1") {
            active.firstFrame = raw
            active.serviceIdentity = beforeService
            active.state = C1aSessionState.AWAITING_C2
            return snapshot(active, captureToken = "c1")
        }

        val first = active.firstFrame
        val context = active.context
        if (first == null || context == null) {
            terminal(active, "capture_sequence_invalid")
            return snapshot(active)
        }
        val observation = try {
            TabletLayoutProbe.assemble(context, listOf(first, raw)).toJson().toString()
        } catch (_: Exception) {
            terminal(active, "observation_assembly_failed")
            return snapshot(active)
        }
        if (expireSessionIfNeeded(active)) return snapshot(active)
        if (observation.toByteArray(StandardCharsets.UTF_8).size > TABLET_C1A_MAX_OUTPUT_BYTES) {
            terminal(active, "output_too_large")
            return snapshot(active)
        }
        active.state = C1aSessionState.COMPLETE
        active.observationJson = observation
        active.context = null
        active.firstFrame = null
        active.serviceIdentity = null
        active.reasonCode = null
        return snapshot(active, captureToken = "c2")
    }

    @Synchronized
    fun result(key: C1aSessionKey): C1aResultRead {
        expireIfNeeded()
        val current = session?.takeIf { it.envelope.key == key }
            ?: return C1aResultRead.Control(absent(key, "session_not_found"))
        val json = current.observationJson
        return if (current.state == C1aSessionState.COMPLETE && json != null) {
            // result 是单次消费：openFile 成功取得内容后立即清除全部 run 内存；nonce/run ledger 保留。
            cancelExpiry(current)
            clearPayload(current)
            session = null
            C1aResultRead.Observation(json)
        } else {
            C1aResultRead.Control(snapshot(current))
        }
    }

    @Synchronized
    fun abort(key: C1aSessionKey): C1aControlSnapshot {
        expireIfNeeded()
        val current = session?.takeIf { it.envelope.key == key } ?: return absent(key, "session_not_found")
        // abort 是显式清理面；首个 FAILED/EXPIRED/ABORTED 终态不被后来的 abort 改写。
        abortSession(current)
        return snapshot(current)
    }

    @Synchronized
    fun shutdown() {
        if (closed) return
        closed = true
        session?.let {
            cancelExpiry(it)
            clearPayload(it)
        }
        session = null
        consumedNonces.clear()
        consumedRunIds.clear()
    }

    private fun expireIfNeeded() {
        val current = session ?: return
        expireSessionIfNeeded(current)
    }

    private fun expireSessionIfNeeded(target: Session): Boolean {
        if (target.state in EXPIRABLE_STATES && monotonicMillis() >= target.deadlineMillis) {
            terminal(target, "session_expired", C1aSessionState.EXPIRED)
            return true
        }
        return false
    }

    @Synchronized
    private fun expireScheduled(target: Session) {
        if (closed || session !== target || target.state !in EXPIRABLE_STATES) return
        val now = monotonicMillis()
        if (now < target.deadlineMillis) {
            val remaining = target.deadlineMillis - now
            if (!scheduleExpiry(target, remaining)) {
                terminal(target, "session_expiry_unavailable")
            }
            return
        }
        terminal(target, "session_expired", C1aSessionState.EXPIRED)
    }

    private fun scheduleExpiry(target: Session, delayMillis: Long): Boolean = try {
        val cancellation = expiryScheduler.schedule(delayMillis.coerceAtLeast(0L)) {
            expireScheduled(target)
        }
        if (closed || session !== target || target.state !in EXPIRABLE_STATES) {
            cancellation.cancel()
        } else {
            target.expiryCancellation?.cancel()
            target.expiryCancellation = cancellation
        }
        true
    } catch (_: Exception) {
        false
    }

    private fun terminal(
        target: Session,
        reason: String,
        state: C1aSessionState = C1aSessionState.FAILED,
    ) {
        cancelExpiry(target)
        target.state = state
        target.reasonCode = reason
        clearPayload(target)
    }

    private fun clearPayload(target: Session) {
        target.context = null
        target.firstFrame = null
        target.serviceIdentity = null
        target.observationJson = null
    }

    private fun cancelExpiry(target: Session) {
        val cancellation = target.expiryCancellation
        target.expiryCancellation = null
        if (cancellation != null) runCatching { cancellation.cancel() }
    }

    private fun abortSession(target: Session) {
        when {
            target.state in ACTIVE_STATES || target.state == C1aSessionState.COMPLETE ->
                terminal(target, "session_aborted", C1aSessionState.ABORTED)
            else -> {
                cancelExpiry(target)
                clearPayload(target)
            }
        }
    }

    private fun snapshotFor(key: C1aSessionKey): C1aControlSnapshot =
        session?.takeIf { it.envelope.key == key }?.let(::snapshot)
            ?: absent(key, "session_not_found")

    private fun snapshot(target: Session, captureToken: String? = null): C1aControlSnapshot =
        C1aControlSnapshot(
            key = target.envelope.key,
            state = target.state,
            reasonCode = target.reasonCode,
            captureToken = captureToken,
            producerCommitSha = target.envelope.producerCommitSha,
            producerArtifactSha256 = target.envelope.producerArtifactSha256,
        )

    private fun absent(key: C1aSessionKey, reason: String): C1aControlSnapshot =
        C1aControlSnapshot(key, C1aSessionState.ABSENT, reason)

    private fun deadlineFrom(now: Long): Long =
        if (now > Long.MAX_VALUE - ttlMillis) Long.MAX_VALUE else now + ttlMillis

    private companion object {
        const val DEFAULT_TTL_MILLIS = 120_000L
        val ACTIVE_STATES = setOf(C1aSessionState.AWAITING_C1, C1aSessionState.AWAITING_C2)
        val EXPIRABLE_STATES = ACTIVE_STATES + C1aSessionState.COMPLETE
        val OCCUPIED_STATES = EXPIRABLE_STATES

        fun secureRunSalt(): ByteArray = ByteArray(32).also(SecureRandom()::nextBytes)
    }
}

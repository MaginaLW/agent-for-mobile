package dev.magina.gateway.tablet.c1a

import dev.magina.gateway.tablet.ProbeImeMode
import dev.magina.gateway.tablet.ProbeSize
import dev.magina.gateway.tablet.RawProbeDisplay
import dev.magina.gateway.tablet.RawProbeIme
import dev.magina.gateway.tablet.RawTabletProbeFrame
import dev.magina.gateway.tablet.TRUSTED_T0_PRODUCER_SHA
import dev.magina.gateway.tablet.probeSha256Bytes
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.charset.StandardCharsets

class TabletC1aSessionMachineTest {
    @Test
    fun `happy path binds raw T0 current APK and two frames then consumes result once`() {
        var monotonic = 1_000L
        val machine = machine(clock = { monotonic })
        val rawT0 = t0Raw()
        val rawT0Hash = probeSha256Bytes(rawT0)

        val start = machine.start(ENVELOPE, rawT0)
        assertEquals(C1aSessionState.AWAITING_C1, start.state)
        assertTrue(rawT0.all { it == 0.toByte() })

        val service = Any()
        val c1 = machine.capture(KEY, "c1", { service }) { identity, captureId, token, hash ->
            assertTrue(identity === service)
            frame(captureId, token, hash, "2026-08-26T00:01:00.0000000Z", 1)
        }
        assertEquals(C1aSessionState.AWAITING_C2, c1.state)
        assertEquals("c1", c1.captureToken)

        monotonic += 1_000
        val c2 = machine.capture(KEY, "c2", { service }) { identity, captureId, token, hash ->
            assertTrue(identity === service)
            frame(captureId, token, hash, "2026-08-26T00:01:01.0000000Z", 2)
        }
        assertEquals(C1aSessionState.COMPLETE, c2.state)
        assertEquals("c2", c2.captureToken)

        val result = machine.result(KEY) as C1aResultRead.Observation
        val observation = JSONObject(result.json)
        assertEquals("tablet-layout-observation/v2", observation.getString("schema"))
        assertEquals(RUN_ID, observation.getString("run_id"))
        assertFalse(observation.getBoolean("execution_grant"))
        assertFalse(observation.getJSONObject("provenance").getBoolean("runtime_attested"))
        assertEquals(COMMIT, observation.getJSONObject("provenance").getString("producer_commit_sha"))
        assertEquals(ARTIFACT, observation.getJSONObject("provenance").getString("producer_artifact_sha256"))
        assertEquals(rawT0Hash, observation.getJSONObject("upstream_t0").getString("artifact_sha256"))
        assertEquals(
            TRUSTED_T0_PRODUCER_SHA,
            observation.getJSONObject("upstream_t0").getString("producer_commit_sha"),
        )
        assertEquals("c1", observation.getJSONArray("frames").getJSONObject(0)
            .getJSONObject("capture").getString("token"))
        assertEquals("c2", observation.getJSONArray("frames").getJSONObject(1)
            .getJSONObject("capture").getString("token"))

        val replay = machine.result(KEY) as C1aResultRead.Control
        assertEquals(C1aSessionState.ABSENT, replay.snapshot.state)
        assertEquals("session_not_found", replay.snapshot.reasonCode)
    }

    @Test
    fun `factory derives declarations from raw tree and rejects envelope run id mismatch`() {
        val raw = t0Raw()
        val context = TrustedRuntimeContextFactory.create(
            runId = RUN_ID,
            expectedTitleHash = TABLET_C1A_EXPECTED_TITLE_HASH,
            c1aProducerCommitSha = COMMIT,
            c1aProducerArtifactSha256 = ARTIFACT,
            runSalt = ByteArray(32) { 7 },
            upstreamT0RawUtf8 = raw,
        )
        assertEquals(RUN_ID, context.upstreamT0.runId)
        assertEquals(probeSha256Bytes(raw), context.upstreamT0.artifactSha256)
        assertEquals(TRUSTED_T0_PRODUCER_SHA, context.upstreamT0.producerCommitSha)
        assertNotEquals(ARTIFACT, context.upstreamT0.artifactSha256)

        expectFailure {
            TrustedRuntimeContextFactory.create(
                runId = "different-run-id",
                expectedTitleHash = TABLET_C1A_EXPECTED_TITLE_HASH,
                c1aProducerCommitSha = COMMIT,
                c1aProducerArtifactSha256 = ARTIFACT,
                runSalt = ByteArray(32),
                upstreamT0RawUtf8 = raw,
            )
        }
        expectFailure {
            TrustedRuntimeContextFactory.create(
                runId = RUN_ID,
                expectedTitleHash = "sha256:${"9".repeat(64)}",
                c1aProducerCommitSha = COMMIT,
                c1aProducerArtifactSha256 = ARTIFACT,
                runSalt = ByteArray(32),
                upstreamT0RawUtf8 = raw,
            )
        }
    }

    @Test
    fun `build mismatch and malformed T0 fail before any capture`() {
        val wrongBuild = ENVELOPE.copy(producerCommitSha = "1".repeat(40))
        val machine = machine()
        assertEquals(C1aSessionState.FAILED, machine.start(wrongBuild, t0Raw()).state)
        assertEquals("build_identity_mismatch", machine.status(KEY).reasonCode)

        val malformedMachine = machine()
        val malformed = "{\"schema_version\":5}".toByteArray(StandardCharsets.UTF_8)
        assertEquals(C1aSessionState.FAILED, malformedMachine.start(ENVELOPE, malformed).state)
        var captures = 0
        malformedMachine.capture(KEY, "c1", { Any() }) { _, _, _, _ ->
            captures += 1
            frame("capture-c1", "c1", TABLET_C1A_EXPECTED_TITLE_HASH, "2026-08-26T00:01:00.0000000Z", 1)
        }
        assertEquals(0, captures)
    }

    @Test
    fun `capture failure is terminal and never permits a replacement shot`() {
        val machine = startedMachine()
        val service = Any()
        var calls = 0
        val failed = machine.capture(KEY, "c1", { service }) { _, _, _, _ ->
            calls += 1
            throw IllegalStateException("synthetic read failure")
        }
        assertEquals(C1aSessionState.FAILED, failed.state)
        assertEquals("capture_c1_failed", failed.reasonCode)

        machine.capture(KEY, "c1", { service }) { _, _, _, _ ->
            calls += 1
            frame("capture-c1", "c1", TABLET_C1A_EXPECTED_TITLE_HASH, "2026-08-26T00:01:00.0000000Z", 1)
        }
        assertEquals(1, calls)
    }

    @Test
    fun `c2 requires the exact same live service instance and does not invoke capture after replacement`() {
        val machine = startedMachine()
        val firstService = Any()
        val replacement = Any()
        machine.capture(KEY, "c1", { firstService }) { _, captureId, token, hash ->
            frame(captureId, token, hash, "2026-08-26T00:01:00.0000000Z", 1)
        }
        var c2Calls = 0
        val result = machine.capture(KEY, "c2", { replacement }) { _, _, _, _ ->
            c2Calls += 1
            error("must not capture")
        }
        assertEquals(C1aSessionState.FAILED, result.state)
        assertEquals("a11y_service_replaced", result.reasonCode)
        assertEquals(0, c2Calls)
    }

    @Test
    fun `single active session TTL replay ledger and abort all fail closed`() {
        var now = 0L
        val machine = machine({ now }, ttlMillis = 20_000)
        machine.start(ENVELOPE, t0Raw())
        val other = envelope("tl1-c1a-run-0002", "nonce-2222222222222222")
        val busy = machine.start(other, t0Raw("tl1-c1a-run-0002"))
        assertEquals(C1aSessionState.ABSENT, busy.state)
        assertEquals("session_busy", busy.reasonCode)

        val aborted = machine.abort(KEY)
        assertEquals(C1aSessionState.ABORTED, aborted.state)
        assertEquals("session_aborted", aborted.reasonCode)
        assertTrue(machine.result(KEY) is C1aResultRead.Control)

        val replay = machine.start(ENVELOPE, t0Raw())
        assertEquals(C1aSessionState.ABSENT, replay.state)
        assertEquals("nonce_reused", replay.reasonCode)

        machine.start(other, t0Raw("tl1-c1a-run-0002"))
        now = 20_000
        val expired = machine.status(other.key)
        assertEquals(C1aSessionState.EXPIRED, expired.state)
        assertEquals("session_expired", expired.reasonCode)
        assertNull(expired.captureToken)
    }

    @Test
    fun `complete result occupies the only slot until single consumption`() {
        val scheduler = TestExpiryScheduler()
        val machine = machine(expiryScheduler = scheduler).also {
            assertEquals(C1aSessionState.AWAITING_C1, it.start(ENVELOPE, t0Raw()).state)
        }
        val service = Any()
        machine.capture(KEY, "c1", { service }) { _, captureId, token, hash ->
            frame(captureId, token, hash, "2026-08-26T00:01:00.0000000Z", 1)
        }
        machine.capture(KEY, "c2", { service }) { _, captureId, token, hash ->
            frame(captureId, token, hash, "2026-08-26T00:01:01.0000000Z", 2)
        }
        val other = envelope("tl1-c1a-run-0002", "nonce-2222222222222222")
        val otherRaw = t0Raw("tl1-c1a-run-0002")
        val busy = machine.start(other, otherRaw)
        assertEquals(C1aSessionState.ABSENT, busy.state)
        assertEquals("session_busy", busy.reasonCode)
        assertTrue(otherRaw.all { it == 0.toByte() })
        assertEquals(C1aSessionState.COMPLETE, machine.status(KEY).state)

        assertTrue(machine.result(KEY) is C1aResultRead.Observation)
        assertTrue(scheduler.tasks.first().cancelled)
        assertEquals(C1aSessionState.AWAITING_C1, machine.start(other, t0Raw("tl1-c1a-run-0002")).state)
        scheduler.fire(0, evenIfCancelled = true)
        assertEquals(C1aSessionState.AWAITING_C1, machine.status(other.key).state)
    }

    @Test
    fun `capture and final observation commit recheck TTL after expensive work`() {
        var now = 0L
        val captureExpiry = machine(clock = { now }, ttlMillis = 20_000).also {
            it.start(ENVELOPE, t0Raw())
        }
        val service = Any()
        val expiredC1 = captureExpiry.capture(KEY, "c1", { service }) { _, captureId, token, hash ->
            now = 20_000
            frame(captureId, token, hash, "2026-08-26T00:01:00.0000000Z", 1)
        }
        assertEquals(C1aSessionState.EXPIRED, expiredC1.state)
        assertEquals("session_expired", expiredC1.reasonCode)
        assertNull(expiredC1.captureToken)

        val clockValues = ArrayDeque(listOf(0L, 1_000L, 1_000L, 2_000L, 2_000L, 20_000L))
        val commitExpiry = machine(
            clock = { clockValues.removeFirst() },
            ttlMillis = 20_000,
        )
        commitExpiry.start(ENVELOPE, t0Raw())
        commitExpiry.capture(KEY, "c1", { service }) { _, captureId, token, hash ->
            frame(captureId, token, hash, "2026-08-26T00:01:00.0000000Z", 1)
        }
        val expiredCommit = commitExpiry.capture(KEY, "c2", { service }) { _, captureId, token, hash ->
            frame(captureId, token, hash, "2026-08-26T00:01:01.0000000Z", 2)
        }
        assertEquals(C1aSessionState.EXPIRED, expiredCommit.state)
        assertEquals("session_expired", expiredCommit.reasonCode)
    }

    @Test
    fun `failed and aborted terminal causes do not drift after TTL or later abort`() {
        var now = 0L
        val failedMachine = machine(clock = { now }, ttlMillis = 20_000)
        val malformed = "{\"schema_version\":5}".toByteArray(StandardCharsets.UTF_8)
        assertEquals(C1aSessionState.FAILED, failedMachine.start(ENVELOPE, malformed).state)
        now = 30_000
        assertEquals("t0_invalid", failedMachine.status(KEY).reasonCode)
        val failedAbort = failedMachine.abort(KEY)
        assertEquals(C1aSessionState.FAILED, failedAbort.state)
        assertEquals("t0_invalid", failedAbort.reasonCode)

        now = 0L
        val abortedMachine = machine(clock = { now }, ttlMillis = 20_000)
        abortedMachine.start(ENVELOPE, t0Raw())
        assertEquals(C1aSessionState.ABORTED, abortedMachine.abort(KEY).state)
        now = 30_000
        val stillAborted = abortedMachine.status(KEY)
        assertEquals(C1aSessionState.ABORTED, stillAborted.state)
        assertEquals("session_aborted", stillAborted.reasonCode)
    }

    @Test
    fun `scheduled TTL expires c1 payload without any followup request`() {
        var now = 0L
        val scheduler = TestExpiryScheduler()
        val machine = machine(clock = { now }, ttlMillis = 20_000, expiryScheduler = scheduler)
        val service = Any()
        assertEquals(C1aSessionState.AWAITING_C1, machine.start(ENVELOPE, t0Raw()).state)
        assertEquals(
            C1aSessionState.AWAITING_C2,
            machine.capture(KEY, "c1", { service }) { _, captureId, token, hash ->
                frame(captureId, token, hash, "2026-08-26T00:01:00.0000000Z", 1)
            }.state,
        )
        assertEquals(1, scheduler.tasks.size)
        assertEquals(20_000L, scheduler.tasks.single().delayMillis)
        assertNotNull(retainedPayload(machine, "context"))
        assertNotNull(retainedPayload(machine, "firstFrame"))

        // 唯一触发是 scheduler；随后把测试时钟退回，证明 status 本身没有惰性制造 EXPIRED。
        now = 20_000L
        scheduler.fire(0)
        assertNull(retainedPayload(machine, "context"))
        assertNull(retainedPayload(machine, "firstFrame"))
        assertNull(retainedPayload(machine, "serviceIdentity"))
        assertNull(retainedPayload(machine, "observationJson"))
        now = 0L
        val expired = machine.status(KEY)
        assertEquals(C1aSessionState.EXPIRED, expired.state)
        assertEquals("session_expired", expired.reasonCode)
        assertTrue(scheduler.tasks.single().cancelled)
        var captures = 0
        machine.capture(KEY, "c2", { service }) { _, captureId, token, hash ->
            captures += 1
            frame(captureId, token, hash, "2026-08-26T00:01:01.0000000Z", 2)
        }
        assertEquals(0, captures)
    }

    @Test
    fun `stale expiry callback cannot clear a newer run and consumed ledger remains stable`() {
        var now = 0L
        val scheduler = TestExpiryScheduler()
        val machine = machine(clock = { now }, ttlMillis = 20_000, expiryScheduler = scheduler)
        machine.start(ENVELOPE, t0Raw())
        val oldTask = scheduler.tasks.single()
        assertEquals(C1aSessionState.ABORTED, machine.abort(KEY).state)
        assertTrue(oldTask.cancelled)

        val other = envelope("tl1-c1a-run-0002", "nonce-2222222222222222")
        assertEquals(C1aSessionState.AWAITING_C1, machine.start(other, t0Raw(other.key.runId)).state)
        scheduler.fire(0, evenIfCancelled = true)
        assertEquals(C1aSessionState.AWAITING_C1, machine.status(other.key).state)

        machine.abort(other.key)
        val replayRaw = t0Raw()
        val replay = machine.start(ENVELOPE, replayRaw)
        assertEquals(C1aSessionState.ABSENT, replay.state)
        assertEquals("nonce_reused", replay.reasonCode)
        assertTrue(replayRaw.all { it == 0.toByte() })
    }

    @Test
    fun `pending abort records replay ledger without creating an occupied session`() {
        val machine = machine()
        val cancelled = machine.abortPending(ENVELOPE)
        assertEquals(C1aSessionState.ABORTED, cancelled.state)
        assertEquals("session_aborted", cancelled.reasonCode)
        assertEquals(COMMIT, cancelled.producerCommitSha)
        assertEquals(ARTIFACT, cancelled.producerArtifactSha256)

        val other = envelope("tl1-c1a-run-0002", "nonce-2222222222222222")
        assertEquals(C1aSessionState.AWAITING_C1, machine.start(other, t0Raw(other.key.runId)).state)
        machine.abort(other.key)
        assertEquals("nonce_reused", machine.start(ENVELOPE, t0Raw()).reasonCode)
    }

    @Test
    fun `shutdown cancels active expiry and rejects later starts`() {
        val scheduler = TestExpiryScheduler()
        val machine = machine(expiryScheduler = scheduler)
        machine.start(ENVELOPE, t0Raw())
        val task = scheduler.tasks.single()
        machine.shutdown()
        assertTrue(task.cancelled)
        scheduler.fire(0, evenIfCancelled = true)
        val raw = t0Raw()
        val afterShutdown = machine.start(ENVELOPE, raw)
        assertEquals(C1aSessionState.ABSENT, afterShutdown.state)
        assertEquals("session_not_found", afterShutdown.reasonCode)
        assertTrue(raw.all { it == 0.toByte() })
    }

    @Test
    fun `expiry scheduler rejection fails closed and wipes T0`() {
        val scheduler = C1aExpiryScheduler { _, _ -> error("synthetic scheduler rejection") }
        val machine = machine(expiryScheduler = scheduler)
        val raw = t0Raw()
        val failed = machine.start(ENVELOPE, raw)
        assertEquals(C1aSessionState.FAILED, failed.state)
        assertEquals("session_expiry_unavailable", failed.reasonCode)
        assertTrue(raw.all { it == 0.toByte() })
    }

    private fun startedMachine(): TabletC1aSessionMachine = machine().also {
        assertEquals(C1aSessionState.AWAITING_C1, it.start(ENVELOPE, t0Raw()).state)
    }

    private fun machine(
        clock: () -> Long = { 1_000L },
        ttlMillis: Long = 120_000L,
        expiryScheduler: C1aExpiryScheduler = TestExpiryScheduler(),
    ): TabletC1aSessionMachine = TabletC1aSessionMachine(
        build = BUILD,
        expiryScheduler = expiryScheduler,
        monotonicMillis = clock,
        saltSource = { ByteArray(32) { index -> (index + 1).toByte() } },
        ttlMillis = ttlMillis,
    )

    private class TestExpiryScheduler : C1aExpiryScheduler {
        data class Task(
            val delayMillis: Long,
            val action: () -> Unit,
            var cancelled: Boolean = false,
        )

        val tasks = mutableListOf<Task>()

        override fun schedule(delayMillis: Long, task: () -> Unit): C1aExpiryCancellation {
            val scheduled = Task(delayMillis, task)
            tasks += scheduled
            return C1aExpiryCancellation { scheduled.cancelled = true }
        }

        fun fire(index: Int, evenIfCancelled: Boolean = false) {
            val task = tasks[index]
            if (evenIfCancelled || !task.cancelled) task.action()
        }
    }

    private fun frame(
        captureId: String,
        token: String,
        expectedTitleHash: String,
        capturedAt: String,
        revision: Long,
    ): RawTabletProbeFrame = RawTabletProbeFrame(
        captureId = captureId,
        capturedAt = capturedAt,
        captureToken = token,
        captureExpectedTitleHash = expectedTitleHash,
        revisionBefore = revision,
        revisionAfter = revision,
        layoutRevision = revision,
        imeRevision = revision,
        display = RawProbeDisplay(displayId = 0, effectiveSize = ProbeSize(2560, 1600)),
        interactiveWindows = emptyList(),
        ime = RawProbeIme(visible = false, mode = ProbeImeMode.NONE, bounds = null),
        nodesTruncated = false,
        readErrors = 0,
    )

    private fun retainedPayload(machine: TabletC1aSessionMachine, fieldName: String): Any? {
        val sessionField = TabletC1aSessionMachine::class.java.getDeclaredField("session").apply {
            isAccessible = true
        }
        val active = sessionField.get(machine) ?: return null
        return active.javaClass.getDeclaredField(fieldName).apply { isAccessible = true }.get(active)
    }

    private fun t0Raw(runId: String = RUN_ID): ByteArray = """
        {
          "schema_version": 5,
          "run_id": "$runId",
          "captured_at_utc": "2026-08-26T00:00:00.0000000Z",
          "device": {
            "serial_hash": "sha256:${"1".repeat(64)}",
            "manufacturer": "vivo",
            "model": "tablet",
            "api_level": 36,
            "fingerprint_hash": "sha256:${"2".repeat(64)}"
          },
          "assessment": {
            "intake_status": "accepted",
            "readiness_status": "blocked",
            "readiness_block_reasons": ["application_window_count_not_one"],
            "p0_capability": "unsupported",
            "p0_unsupported_reasons": [
              "application_window_count_not_one",
              "wechat_layout_unverified",
              "tablet_landscape_p0_unimplemented"
            ]
          }
        }
    """.trimIndent().toByteArray(StandardCharsets.UTF_8)

    private fun envelope(runId: String, nonce: String): C1aStartEnvelope = C1aStartEnvelope(
        key = C1aSessionKey(runId, nonce),
        titleHash = TABLET_C1A_EXPECTED_TITLE_HASH,
        producerCommitSha = COMMIT,
        producerArtifactSha256 = ARTIFACT,
    )

    private fun expectFailure(block: () -> Unit) {
        try {
            block()
            throw AssertionError("expected failure")
        } catch (_: IllegalArgumentException) {
            // expected
        }
    }

    private companion object {
        const val RUN_ID = "tl1-c1a-run-0001"
        const val NONCE = "nonce-0123456789abcdef"
        const val COMMIT = "85672f01b39d9041993f9898b589bc87bd03d783"
        const val ARTIFACT = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        val KEY = C1aSessionKey(RUN_ID, NONCE)
        val ENVELOPE = C1aStartEnvelope(KEY, TABLET_C1A_EXPECTED_TITLE_HASH, COMMIT, ARTIFACT)
        val BUILD = C1aBuildIdentity(
            packageName = "dev.magina.gateway",
            versionName = "0.1.0-test",
            versionCode = 1,
            embeddedGitHead = COMMIT,
            buildChallenge = "c1a-test-challenge-20260826",
        )
    }
}

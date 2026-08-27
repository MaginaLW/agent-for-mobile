package dev.magina.gateway.tablet.c1b

import dev.magina.gateway.tablet.probeSha256Bytes
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.charset.StandardCharsets

class TabletC1bRuntimeControllerTest {
    @Test
    fun trustedFactoryBindsExactT0BytesAndNeverRetainsInputAliases() {
        val raw = t0Raw()
        val expectedHash = probeSha256Bytes(raw)
        val request = TrustedRuntimeContextFactory.create(
            runId = RUN_ID,
            expectedTitleHash = TABLET_C1B_EXPECTED_TITLE_HASH,
            c1bProducerCommitSha = COMMIT,
            c1bProducerArtifactSha256 = ARTIFACT,
            upstreamT0RawUtf8 = raw,
        )

        assertEquals(expectedHash, request.upstreamT0.artifactSha256)
        assertEquals(RUN_ID, request.upstreamT0.runId)
        assertEquals(COMMIT, request.provenance.producerCommitSha)
        raw.fill(0)
        assertEquals(expectedHash, request.upstreamT0.artifactSha256)

        expectFailure {
            TrustedRuntimeContextFactory.create(
                RUN_ID,
                TABLET_C1B_EXPECTED_TITLE_HASH,
                COMMIT,
                ARTIFACT,
                t0Raw().decodeToString().replaceFirst("\"run_id\":", "\"run_id\": \"duplicate\", \"run_id\":")
                    .toByteArray(StandardCharsets.UTF_8),
            )
        }
    }

    @Test
    fun captureOnlyQueuesOnCallerAndTwoFramesAssembleThenConsumeOnce() {
        val worker = QueuedWorker()
        val service = FakeService("first")
        var current: FakeService? = service
        var captureCount = 0
        val controller = controller(worker, { current }) { _, _, token, hash ->
            captureCount += 1
            frame(token, hash)
        }
        val raw = t0Raw()

        assertEquals(C1bProtocolState.READY_C1, controller.start(ENVELOPE, raw).state)
        assertTrue(raw.all { it == 0.toByte() })

        val c1Queued = controller.capture(KEY, "c1")
        assertEquals(C1bProtocolState.CAPTURING_C1, c1Queued.state)
        assertEquals(0, captureCount)
        assertEquals(1, worker.size)
        worker.runNext()
        assertEquals(1, captureCount)
        assertEquals(C1bProtocolState.READY_C2, controller.status(KEY).state)

        val c2Queued = controller.capture(KEY, "c2")
        assertEquals(C1bProtocolState.CAPTURING_C2, c2Queued.state)
        assertEquals(1, captureCount)
        worker.runNext()
        assertEquals(2, captureCount)
        assertEquals(C1bProtocolState.COMPLETE, controller.status(KEY).state)

        val result = controller.result(KEY) as C1bRuntimeResult.Observation
        val json = JSONObject(result.json)
        assertEquals(TABLET_C1B_SCHEMA, json.getString("schema"))
        assertEquals(2, json.getJSONArray("frames").length())
        assertFalse(result.toString().contains(result.json))
        val consumed = controller.result(KEY) as C1bRuntimeResult.Control
        assertEquals(C1bProtocolState.ABSENT, consumed.value.state)
        assertEquals("session_not_found", consumed.value.reasonCode)
        controller.shutdown()
        current = null
    }

    @Test
    fun duplicateCaptureFailsClosedWithoutRecapture() {
        val worker = QueuedWorker()
        val service = FakeService("only")
        var captures = 0
        val controller = controller(worker, { service }) { _, _, token, hash ->
            captures += 1
            frame(token, hash)
        }
        controller.start(ENVELOPE, t0Raw())

        assertEquals(C1bProtocolState.CAPTURING_C1, controller.capture(KEY, "c1").state)
        val duplicate = controller.capture(KEY, "c1")
        assertEquals(C1bProtocolState.FAILED, duplicate.state)
        assertEquals("capture_sequence_invalid", duplicate.reasonCode)
        worker.runNext()
        assertEquals(0, captures)
    }

    @Test
    fun serviceReplacementAndInvalidT0NeverReachFrameReader() {
        val worker = QueuedWorker()
        val first = FakeService("first")
        var current: FakeService? = first
        var captures = 0
        val controller = controller(worker, { current }) { _, _, token, hash ->
            captures += 1
            frame(token, hash)
        }
        controller.start(ENVELOPE, t0Raw())
        controller.capture(KEY, "c1")
        worker.runNext()
        current = FakeService("replacement")

        val replacement = controller.capture(KEY, "c2")
        assertEquals(C1bProtocolState.FAILED, replacement.state)
        assertEquals("a11y_service_replaced", replacement.reasonCode)
        assertEquals(1, captures)

        val other = envelope("tl1-c1b-runtime-0002", "n-" + "2".repeat(32))
        val malformed = "{\"schema_version\":5}".toByteArray(StandardCharsets.UTF_8)
        val invalidController = controller(QueuedWorker(), { first }) { _, _, token, hash ->
            captures += 1
            frame(token, hash)
        }
        val failed = invalidController.start(other, malformed)
        assertTrue(malformed.all { it == 0.toByte() })
        assertEquals(C1bProtocolState.FAILED, failed.state)
        assertEquals("t0_invalid", failed.reasonCode)
        assertEquals(1, captures)
    }

    @Test
    fun buildMismatchAndReplayAreBoundedAndWipeRawT0() {
        val worker = QueuedWorker()
        val service = FakeService("service")
        val controller = controller(worker, { service }) { _, _, token, hash -> frame(token, hash) }
        val wrong = C1bStartEnvelope(KEY, TABLET_C1B_EXPECTED_TITLE_HASH, "f".repeat(40), ARTIFACT)
        val wrongRaw = t0Raw()
        val mismatch = controller.start(wrong, wrongRaw)
        assertEquals("build_identity_mismatch", mismatch.reasonCode)
        assertTrue(wrongRaw.all { it == 0.toByte() })

        val replayRaw = t0Raw()
        val replay = controller.start(ENVELOPE, replayRaw)
        assertEquals(C1bProtocolState.ABSENT, replay.state)
        assertEquals("nonce_reused", replay.reasonCode)
        assertTrue(replayRaw.all { it == 0.toByte() })
    }

    @Test
    fun saturatedReplayLedgerRejectsNewIdentityWithoutEvictionOrActiveSessionReplacement() {
        val service = FakeService("service")
        val controller = controller(QueuedWorker(), { service }) { _, _, token, hash -> frame(token, hash) }
        fun failedEnvelope(index: Int): C1bStartEnvelope {
            val runId = "tl1-c1b-ledger-${index.toString().padStart(3, '0')}"
            val nonce = "n-${index.toString(16).padStart(32, '0')}"
            return C1bStartEnvelope(
                C1bSessionKey(runId, nonce),
                TABLET_C1B_EXPECTED_TITLE_HASH,
                "f".repeat(40),
                ARTIFACT,
            )
        }

        repeat(TABLET_C1B_REPLAY_LEDGER_CAPACITY) { index ->
            val raw = byteArrayOf(1)
            assertEquals("build_identity_mismatch", controller.start(failedEnvelope(index), raw).reasonCode)
            assertTrue(raw.single() == 0.toByte())
        }
        assertEquals(TABLET_C1B_REPLAY_LEDGER_CAPACITY, controller.replayLedgerSizeForTest())

        val activeKey = failedEnvelope(TABLET_C1B_REPLAY_LEDGER_CAPACITY - 1).key
        val activeBeforeSaturation = controller.status(activeKey)
        assertEquals(C1bProtocolState.FAILED, activeBeforeSaturation.state)
        val overflowRaw = byteArrayOf(1)
        val overflow = controller.start(failedEnvelope(TABLET_C1B_REPLAY_LEDGER_CAPACITY), overflowRaw)
        assertEquals(C1bProtocolState.ABSENT, overflow.state)
        assertEquals("replay_ledger_full", overflow.reasonCode)
        assertTrue(overflowRaw.single() == 0.toByte())
        assertEquals(TABLET_C1B_REPLAY_LEDGER_CAPACITY, controller.replayLedgerSizeForTest())
        val activeAfterSaturation = controller.status(activeKey)
        assertEquals(activeBeforeSaturation.state, activeAfterSaturation.state)
        assertEquals(activeBeforeSaturation.reasonCode, activeAfterSaturation.reasonCode)
        assertEquals(activeBeforeSaturation.generation, activeAfterSaturation.generation)
        assertEquals(activeBeforeSaturation.committedTokens, activeAfterSaturation.committedTokens)

        val rejectedStart = controller.rejectStart(failedEnvelope(TABLET_C1B_REPLAY_LEDGER_CAPACITY + 1))
        assertEquals(C1bProtocolState.ABSENT, rejectedStart.state)
        assertEquals("replay_ledger_full", rejectedStart.reasonCode)
        assertEquals(TABLET_C1B_REPLAY_LEDGER_CAPACITY, controller.replayLedgerSizeForTest())

        val rejectedAbort = controller.abortPending(failedEnvelope(TABLET_C1B_REPLAY_LEDGER_CAPACITY + 2))
        assertEquals(C1bProtocolState.ABSENT, rejectedAbort.state)
        assertEquals("replay_ledger_full", rejectedAbort.reasonCode)
        assertEquals(TABLET_C1B_REPLAY_LEDGER_CAPACITY, controller.replayLedgerSizeForTest())
        val activeAfterAllSaturationPaths = controller.status(activeKey)
        assertEquals(activeBeforeSaturation.state, activeAfterAllSaturationPaths.state)
        assertEquals(activeBeforeSaturation.reasonCode, activeAfterAllSaturationPaths.reasonCode)
        assertEquals(activeBeforeSaturation.generation, activeAfterAllSaturationPaths.generation)
        assertEquals(activeBeforeSaturation.committedTokens, activeAfterAllSaturationPaths.committedTokens)

        val oldestReplay = controller.start(failedEnvelope(0), byteArrayOf(1))
        assertEquals(C1bProtocolState.ABSENT, oldestReplay.state)
        assertEquals("nonce_reused", oldestReplay.reasonCode)
        assertEquals(TABLET_C1B_REPLAY_LEDGER_CAPACITY, controller.replayLedgerSizeForTest())
    }

    @Test
    fun revisionOrdinalPreservesLiveDriftAndRejectsUnboundedValues() {
        assertEquals(101L, c1bCaptureRevision(100L, "c1"))
        assertEquals(102L, c1bCaptureRevision(100L, "c2"))
        assertNotEquals(c1bCaptureRevision(100L, "c1"), c1bCaptureRevision(101L, "c1"))
        expectFailure { c1bCaptureRevision(-1L, "c1") }
        expectFailure { c1bCaptureRevision(Int.MAX_VALUE.toLong(), "c2") }
        expectFailure { c1bCaptureRevision(1L, "c3") }
    }

    private fun controller(
        worker: QueuedWorker,
        service: () -> FakeService?,
        capture: (FakeService, String, String, String) -> C1bRawFrame,
    ): TabletC1bRuntimeController<FakeService> = TabletC1bRuntimeController(
        build = BUILD,
        worker = worker,
        scheduler = C1bDeadlineScheduler { _, _ -> C1bDeadlineCancellation {} },
        currentServiceIdentity = service,
        frameCapture = C1bRuntimeFrameCapture(capture),
    )

    private fun frame(token: String, expectedHash: String): C1bRawFrame {
        val revision = if (token == "c1") 11L else 12L
        val at = if (token == "c1") {
            "2026-08-26T00:01:00.0000000Z"
        } else {
            "2026-08-26T00:01:01.0000000Z"
        }
        val windows = listOf(
            window("aw1", C1bRect(0, 0, 1_400, 1_968)),
            window("aw2", C1bRect(1_400, 0, 2_800, 1_968)),
        )
        val panes = listOf(
            C1bPaneObservation("ap1", "aw1", requireNotNull(windows[0].bounds)),
            C1bPaneObservation("ap2", "aw2", requireNotNull(windows[1].bounds)),
        )
        val nodes = listOf(
            rootNode("an1", "aw1", "ap1", requireNotNull(windows[0].bounds)),
            rootNode("an2", "aw2", "ap2", requireNotNull(windows[1].bounds)),
        )
        return C1bRawFrame(
            captureId = "capture-$token",
            capturedAt = at,
            capture = C1bCaptureMetadata(token, revision, revision, revision, revision),
            display = C1bDisplayRead(0, 2_800, 1_968),
            windows = windows,
            windowsTruncated = false,
            panes = panes,
            panesTruncated = false,
            nodes = nodes,
            nodesTruncated = false,
            focus = C1bFocusObservation(C1bFocusStatus.ABSENT, null, null),
            ime = C1bImeObservation(false, "none", null, "not_active", null, token),
            expectedTitleHash = expectedHash,
            windowIdentityTokens = mapOf("aw1" to 10, "aw2" to 20),
            nodeIdentityTokens = mapOf(
                "an1" to C1bNodeIdentityToken("r"),
                "an2" to C1bNodeIdentityToken("r"),
            ),
            diagnosticCodes = emptySet(),
        )
    }

    private fun window(label: String, bounds: C1bRect): C1bWindowObservation = C1bWindowObservation(
        windowLabel = label,
        displayId = 0,
        platformTypeCode = 1,
        type = "application",
        rootHandleStatus = C1bRootHandleStatus.READABLE,
        rootPackage = C1B_WECHAT_PACKAGE,
        rootWindowBinding = C1bWindowBinding.EXACT,
        subtreeCapture = C1bSubtreeObservation(
            C1bSubtreeStatus.COMPLETE,
            0,
            1,
            1,
            0,
            0,
            false,
        ),
        expectedWindowTitleMatch = C1bTitleMatchStatus.NO_MATCH,
        layer = 1,
        bounds = bounds,
        touchableBounds = bounds,
        active = false,
        focused = false,
    )

    private fun rootNode(label: String, window: String, pane: String, bounds: C1bRect) = C1bNodeObservation(
        nodeLabel = label,
        windowLabel = window,
        paneLabel = pane,
        isRoot = true,
        windowIdBinding = C1bWindowBinding.EXACT,
        geometryStatus = C1bGeometryStatus.POSITIVE,
        bounds = bounds,
        visible = true,
        enabled = true,
        editable = false,
        scrollable = false,
        focused = false,
    )

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

    private fun envelope(runId: String, nonce: String): C1bStartEnvelope = C1bStartEnvelope(
        C1bSessionKey(runId, nonce),
        TABLET_C1B_EXPECTED_TITLE_HASH,
        COMMIT,
        ARTIFACT,
    )

    private fun expectFailure(block: () -> Unit) {
        try {
            block()
            throw AssertionError("expected failure")
        } catch (_: IllegalArgumentException) {
            // expected
        }
    }

    private class QueuedWorker : C1bReadWorker {
        private val tasks = ArrayDeque<Runnable>()
        val size: Int get() = tasks.size
        override fun execute(task: Runnable) {
            tasks.addLast(task)
        }
        fun runNext() = tasks.removeFirst().run()
    }

    private data class FakeService(val name: String)

    private companion object {
        const val RUN_ID = "tl1-c1b-runtime-0001"
        const val COMMIT = "85672f01b39d9041993f9898b589bc87bd03d783"
        const val ARTIFACT = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        val KEY = C1bSessionKey(RUN_ID, "n-" + "1".repeat(32))
        val ENVELOPE = C1bStartEnvelope(KEY, TABLET_C1B_EXPECTED_TITLE_HASH, COMMIT, ARTIFACT)
        val BUILD = C1bProtocolBuildIdentity(
            packageName = "dev.magina.gateway",
            versionName = "0.1.0-m1a",
            versionCode = 1L,
            embeddedGitHead = COMMIT,
            buildChallenge = "c1b-runtime-unit-challenge",
        )
    }
}

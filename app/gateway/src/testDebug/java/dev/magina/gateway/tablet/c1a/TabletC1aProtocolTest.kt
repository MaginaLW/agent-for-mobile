package dev.magina.gateway.tablet.c1a

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.nio.charset.StandardCharsets
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class TabletC1aProtocolTest {
    @Test
    fun `T0 and read endpoints accept only the frozen URI grammar`() {
        val t0 = TabletC1aProtocol.parse(t0Uri(), "w") as C1aEndpoint.WriteT0
        assertEquals(RUN_ID, t0.key.runId)
        assertEquals(NONCE, t0.key.nonce)
        assertEquals(TABLET_C1A_EXPECTED_TITLE_HASH, t0.envelope.titleHash)
        assertEquals(COMMIT, t0.envelope.producerCommitSha)
        assertEquals(ARTIFACT, t0.envelope.producerArtifactSha256)

        assertTrue(TabletC1aProtocol.parse(readUri("status"), "r") is C1aEndpoint.Status)
        assertEquals("c1", (TabletC1aProtocol.parse(readUri("capture/c1"), "r") as C1aEndpoint.Capture).token)
        assertEquals("c2", (TabletC1aProtocol.parse(readUri("capture/c2"), "r") as C1aEndpoint.Capture).token)
        assertTrue(TabletC1aProtocol.parse(readUri("result"), "r") is C1aEndpoint.Result)
        assertTrue(TabletC1aProtocol.parse(readUri("abort"), "r") is C1aEndpoint.Abort)
    }

    @Test
    fun `query order may change but no duplicate unknown encoding or alias is accepted`() {
        val reordered = "content://$TABLET_C1A_AUTHORITY/t0/$RUN_ID" +
            "?producer_artifact_sha256=$ARTIFACT&nonce=$NONCE" +
            "&producer_commit_sha=$COMMIT&title_hash=$TABLET_C1A_EXPECTED_TITLE_HASH"
        assertTrue(TabletC1aProtocol.parse(reordered, "w") is C1aEndpoint.WriteT0)

        listOf(
            t0Uri() + "&nonce=$NONCE",
            t0Uri() + "&unknown=x",
            t0Uri().replace("title_hash=", "expected_title_hash="),
            t0Uri().replace("sha256:", "sha256%3A"),
            t0Uri().replace(NONCE, "nonce+with+plus0001"),
            t0Uri().replace("?nonce", "?nonce=$NONCE&nonce"),
        ).forEach(::expectWriteInvalid)
    }

    @Test
    fun `wrong target hash mode authority path and nonce fail closed`() {
        listOf(
            t0Uri().replace(TABLET_C1A_EXPECTED_TITLE_HASH, "sha256:" + "9".repeat(64)) to "w",
            t0Uri() to "r",
            readUri("status") to "w",
            readUri("capture/c3") to "r",
            readUri("status") + "/" to "r",
            readUri("status").replace(TABLET_C1A_AUTHORITY, "example.invalid") to "r",
            readUri("status").replace(NONCE, "short") to "r",
            readUri("status") + "#fragment" to "r",
        ).forEach { (uri, mode) -> expectInvalid(uri, mode) }
    }

    @Test
    fun `control JSON has the exact frozen key sets and null placeholders`() {
        val build = C1aBuildIdentity(
            packageName = "dev.magina.gateway",
            versionName = "0.1.0-test",
            versionCode = 7,
            embeddedGitHead = COMMIT,
            buildChallenge = "c1a-test-challenge-20260826",
        )
        val json = C1aControlSnapshot(
            key = C1aSessionKey(RUN_ID, NONCE),
            state = C1aSessionState.AWAITING_C1,
            reasonCode = null,
            producerCommitSha = COMMIT,
            producerArtifactSha256 = ARTIFACT,
        ).toJson(build, a11yServiceReady = true)

        assertEquals(
            setOf(
                "schema", "ok", "run_id", "state", "next", "reason_code", "capture_token",
                "producer_commit_sha", "producer_artifact_sha256", "provider",
            ),
            json.keySet(),
        )
        val provider = json.getJSONObject("provider")
        assertEquals(
            setOf(
                "authority", "protocol_version", "package_name", "version_name", "version_code",
                "embedded_git_head", "build_challenge", "a11y_service_ready",
            ),
            provider.keySet(),
        )
        assertTrue(json.isNull("reason_code"))
        assertTrue(json.isNull("capture_token"))
        assertEquals(COMMIT, provider.getString("embedded_git_head"))
        assertNull(json.optString("not_a_field", null))
    }

    @Test
    fun `pending T0 registry gives one bounded status wait without polling`() {
        val registry = C1aPendingStartRegistry()
        val key = C1aSessionKey(RUN_ID, NONCE)
        assertEquals(C1aPendingAwait.NONE, registry.await(key, 0))
        val ticket = registry.register(envelope()) {}
        assertEquals(C1aPendingAwait.TIMED_OUT, registry.await(key, 0))
        expectFailure { registry.register(envelope()) {} }
        expectFailure {
            registry.register(envelope("other-run", "nonce-2222222222222222")) {}
        }
        ticket.complete()
        assertEquals(C1aPendingAwait.NONE, registry.await(key, 0))
    }

    @Test
    fun `pending cancel atomically defeats a late concurrent worker and wipes raw T0`() {
        val registry = C1aPendingStartRegistry()
        val key = C1aSessionKey(RUN_ID, NONCE)
        val inputCloses = AtomicInteger()
        val starts = AtomicInteger()
        val ticket = registry.register(envelope()) { inputCloses.incrementAndGet() }
        val workerReady = CountDownLatch(1)
        val releaseWorker = CountDownLatch(1)
        val raw = "raw-t0-must-be-wiped".toByteArray(StandardCharsets.UTF_8)
        val executor = Executors.newSingleThreadExecutor()
        try {
            val worker = executor.submit<Boolean> {
                workerReady.countDown()
                releaseWorker.await()
                ticket.claimStart(raw) { starts.incrementAndGet() }
            }
            assertTrue(workerReady.await(5, TimeUnit.SECONDS))
            assertEquals(C1aPendingAwait.TIMED_OUT, registry.await(key, 0))
            val cancelled = registry.cancel(key) { it }
            assertEquals(envelope(), cancelled)
            releaseWorker.countDown()
            assertFalse(worker.get(5, TimeUnit.SECONDS))
            assertEquals(0, starts.get())
            assertEquals(1, inputCloses.get())
            assertTrue(raw.all { it == 0.toByte() })
            assertEquals(C1aPendingAwait.NONE, registry.await(key, 0))
        } finally {
            releaseWorker.countDown()
            executor.shutdownNow()
        }
    }

    @Test
    fun `claimed start serializes ahead of cancel so caller can abort the resulting session`() {
        val registry = C1aPendingStartRegistry()
        val ticket = registry.register(envelope()) {}
        val enteredStart = CountDownLatch(1)
        val releaseStart = CountDownLatch(1)
        val cancelAttempted = CountDownLatch(1)
        val cancelReturned = CountDownLatch(1)
        val raw = "valid-raw-t0".toByteArray(StandardCharsets.UTF_8)
        val executor = Executors.newFixedThreadPool(2)
        try {
            val worker = executor.submit<Boolean> {
                ticket.claimStart(raw) {
                    enteredStart.countDown()
                    releaseStart.await()
                }
            }
            assertTrue(enteredStart.await(5, TimeUnit.SECONDS))
            val cancellation = executor.submit<C1aStartEnvelope?> {
                cancelAttempted.countDown()
                registry.cancel(ticket.key) { it }.also { cancelReturned.countDown() }
            }
            assertTrue(cancelAttempted.await(5, TimeUnit.SECONDS))
            assertFalse(cancelReturned.await(100, TimeUnit.MILLISECONDS))
            releaseStart.countDown()
            assertTrue(worker.get(5, TimeUnit.SECONDS))
            assertNull(cancellation.get(5, TimeUnit.SECONDS))
            assertTrue(raw.all { it == 0.toByte() })
        } finally {
            releaseStart.countDown()
            executor.shutdownNow()
        }
    }

    private fun expectWriteInvalid(uri: String) = expectInvalid(uri, "w")

    private fun expectInvalid(uri: String, mode: String) {
        try {
            TabletC1aProtocol.parse(uri, mode)
            fail("expected invalid URI: $uri")
        } catch (_: IllegalArgumentException) {
            // expected
        }
    }

    private fun expectFailure(block: () -> Unit) {
        try {
            block()
            fail("expected failure")
        } catch (_: IllegalArgumentException) {
            // expected
        }
    }

    private fun t0Uri(): String = "content://$TABLET_C1A_AUTHORITY/t0/$RUN_ID" +
        "?nonce=$NONCE&title_hash=$TABLET_C1A_EXPECTED_TITLE_HASH" +
        "&producer_commit_sha=$COMMIT&producer_artifact_sha256=$ARTIFACT"

    private fun readUri(path: String): String =
        "content://$TABLET_C1A_AUTHORITY/$path/$RUN_ID?nonce=$NONCE"

    private fun envelope(
        runId: String = RUN_ID,
        nonce: String = NONCE,
    ): C1aStartEnvelope = C1aStartEnvelope(
        key = C1aSessionKey(runId, nonce),
        titleHash = TABLET_C1A_EXPECTED_TITLE_HASH,
        producerCommitSha = COMMIT,
        producerArtifactSha256 = ARTIFACT,
    )

    private companion object {
        const val RUN_ID = "tl1-c1a-run-0001"
        const val NONCE = "nonce-0123456789abcdef"
        const val COMMIT = "85672f01b39d9041993f9898b589bc87bd03d783"
        const val ARTIFACT = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }
}

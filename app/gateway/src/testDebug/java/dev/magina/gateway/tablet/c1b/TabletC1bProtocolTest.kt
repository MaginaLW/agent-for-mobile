package dev.magina.gateway.tablet.c1b

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class TabletC1bProtocolTest {

    @Test
    fun `all endpoints round trip through the canonical URI grammar`() {
        val endpoints = listOf(
            C1bEndpoint.WriteT0(ENVELOPE) to "w",
            C1bEndpoint.Status(KEY) to "r",
            C1bEndpoint.Capture(KEY, "c1") to "r",
            C1bEndpoint.Capture(KEY, "c2") to "r",
            C1bEndpoint.Result(KEY) to "r",
            C1bEndpoint.Abort(KEY) to "r",
        )

        endpoints.forEach { (endpoint, mode) ->
            val canonical = TabletC1bProtocol.canonicalUri(endpoint)
            assertEquals(endpoint, TabletC1bProtocol.parse(canonical, mode))
            assertFalse('%' in canonical)
            assertFalse('+' in canonical)
        }
        assertEquals(
            "content://$TABLET_C1B_AUTHORITY/t0/$RUN_ID" +
                "?nonce=$NONCE&title_hash=$TABLET_C1B_EXPECTED_TITLE_HASH" +
                "&producer_commit_sha=$COMMIT&producer_artifact_sha256=$ARTIFACT",
            TabletC1bProtocol.canonicalUri(C1bEndpoint.WriteT0(ENVELOPE)),
        )
    }

    @Test
    fun `T0 has one exact query order and one fixed runtime target hash`() {
        val reordered = "content://$TABLET_C1B_AUTHORITY/t0/$RUN_ID" +
            "?producer_artifact_sha256=$ARTIFACT&nonce=$NONCE" +
            "&producer_commit_sha=$COMMIT&title_hash=$TABLET_C1B_EXPECTED_TITLE_HASH"
        expectInvalid(reordered, "w")
        expectInvalid(t0Uri().replace(TABLET_C1B_EXPECTED_TITLE_HASH, OTHER_HASH), "w")
        expectFailure {
            C1bStartEnvelope(KEY, OTHER_HASH, COMMIT, ARTIFACT)
        }
    }

    @Test
    fun `duplicate unknown encoded plus and malformed query forms fail closed`() {
        listOf(
            t0Uri() + "&nonce=$NONCE",
            t0Uri() + "&unknown=x",
            t0Uri().replace("title_hash=", "expected_title_hash="),
            t0Uri().replace("sha256:", "sha256%3A"),
            t0Uri().replace(NONCE, "nonce+with+plus0001"),
            t0Uri().replace("?nonce", "?nonce=$NONCE&nonce"),
            t0Uri() + "&",
            t0Uri().replace("nonce=$NONCE", "nonce="),
            readUri("status") + "&nonce=$NONCE",
            readUri("status") + "&title_hash=$TABLET_C1B_EXPECTED_TITLE_HASH",
            readUri("status") + "x".repeat(513),
        ).forEach { uri ->
            expectInvalid(uri, if ("/t0/" in uri) "w" else "r")
        }
    }

    @Test
    fun `mode authority path token identity and hashes are exact`() {
        listOf(
            t0Uri() to "r",
            readUri("status") to "w",
            readUri("capture/c3") to "r",
            readUri("capture/C1") to "r",
            readUri("status") + "/" to "r",
            readUri("status").replace(TABLET_C1B_AUTHORITY, "example.invalid") to "r",
            readUri("status").replace("content", "CONTENT") to "r",
            readUri("status").replace(NONCE, "short") to "r",
            readUri("status").replace(NONCE, "nonce-0123456789abcdef") to "r",
            readUri("status").replace(NONCE, "n-" + "A".repeat(32)) to "r",
            readUri("status").replace(RUN_ID, "../escape") to "r",
            readUri("status") + "#fragment" to "r",
            t0Uri().replace(COMMIT, "A".repeat(40)) to "w",
            t0Uri().replace(ARTIFACT, "sha256:" + "A".repeat(64)) to "w",
        ).forEach { (uri, mode) -> expectInvalid(uri, mode) }

        expectFailure { C1bEndpoint.Capture(KEY, "C1") }
        expectFailure { C1bSessionKey("invalid/run", NONCE) }
        expectFailure { C1bSessionKey(RUN_ID, "short") }
        expectFailure { C1bSessionKey(RUN_ID, "nonce-0123456789abcdef") }
        expectFailure { C1bSessionKey(RUN_ID, "n-" + "A".repeat(32)) }
    }

    @Test
    fun `control JSON exposes exact bounded counters and never serializes nonce`() {
        val mutableCommitted = mutableListOf("c1")
        val snapshot = control(
            generation = 7L,
            state = C1bProtocolState.READY_C2,
            c1RequestsAccepted = 1,
            committedTokens = mutableCommitted,
        )
        mutableCommitted += "c2"
        val json = snapshot.toJson(BUILD, a11yServiceReady = true)

        assertEquals(
            setOf(
                "schema", "ok", "run_id", "generation", "state", "next", "reason_code",
                "in_flight_token", "c1_requests_accepted", "c2_requests_accepted",
                "committed_tokens", "recapture_count", "expected_title_hash",
                "producer_commit_sha", "producer_artifact_sha256", "provider",
            ),
            json.keySet(),
        )
        assertEquals("tablet-c1b-control/v1", json.getString("schema"))
        assertTrue(json.getBoolean("ok"))
        assertEquals(RUN_ID, json.getString("run_id"))
        assertFalse(json.has("nonce"))
        assertFalse(json.toString().contains(NONCE))
        assertEquals(7L, json.getLong("generation"))
        assertEquals("ready_c2", json.getString("state"))
        assertEquals("capture_c2", json.getString("next"))
        assertTrue(json.isNull("reason_code"))
        assertTrue(json.isNull("in_flight_token"))
        assertEquals(1, json.getInt("c1_requests_accepted"))
        assertEquals(0, json.getInt("c2_requests_accepted"))
        assertEquals(listOf("c1"), listOf(json.getJSONArray("committed_tokens").getString(0)))
        assertEquals(0, json.getInt("recapture_count"))
        assertEquals(TABLET_C1B_EXPECTED_TITLE_HASH, json.getString("expected_title_hash"))
        assertEquals(COMMIT, json.getString("producer_commit_sha"))
        assertEquals(ARTIFACT, json.getString("producer_artifact_sha256"))

        val provider = json.getJSONObject("provider")
        assertEquals(
            setOf(
                "authority", "protocol_version", "package_name", "version_name", "version_code",
                "embedded_git_head", "build_challenge", "a11y_service_ready",
            ),
            provider.keySet(),
        )
        assertEquals(TABLET_C1B_AUTHORITY, provider.getString("authority"))
        assertEquals(TABLET_C1B_PROTOCOL_VERSION, provider.getString("protocol_version"))
        assertEquals(COMMIT, provider.getString("embedded_git_head"))
        assertTrue(provider.getBoolean("a11y_service_ready"))
    }

    @Test
    fun `DTO log representations redact nonce challenge and artifact binding`() {
        val control = control()
        val values = listOf<Any>(
            KEY,
            ENVELOPE,
            C1bEndpoint.WriteT0(ENVELOPE),
            C1bEndpoint.Status(KEY),
            C1bEndpoint.Capture(KEY, "c1"),
            C1bEndpoint.Result(KEY),
            C1bEndpoint.Abort(KEY),
            BUILD,
            control,
        )

        values.forEach { value ->
            val rendered = value.toString()
            assertFalse("nonce leaked by ${value.javaClass.simpleName}", rendered.contains(NONCE))
            assertFalse(
                "build challenge leaked by ${value.javaClass.simpleName}",
                rendered.contains(BUILD.buildChallenge),
            )
            assertFalse("artifact leaked by ${value.javaClass.simpleName}", rendered.contains(ARTIFACT))
        }
    }

    @Test
    fun `absent control uses null bindings while complete output remains TTL expirable`() {
        val absent = C1bProtocolControl(
            key = KEY,
            generation = 0L,
            state = C1bProtocolState.ABSENT,
            reasonCode = "session_not_found",
            inFlightToken = null,
            c1RequestsAccepted = 0,
            c2RequestsAccepted = 0,
            committedTokens = emptyList(),
            expectedTitleHash = null,
            producerCommitSha = null,
            producerArtifactSha256 = null,
        ).toJson(BUILD, a11yServiceReady = false)
        assertFalse(absent.getBoolean("ok"))
        assertEquals("none", absent.getString("next"))
        assertTrue(absent.isNull("expected_title_hash"))
        assertTrue(absent.isNull("producer_commit_sha"))
        assertTrue(absent.isNull("producer_artifact_sha256"))

        val expiredAfterComplete = control(
            state = C1bProtocolState.EXPIRED,
            reasonCode = "session_expired",
            c1RequestsAccepted = 1,
            c2RequestsAccepted = 1,
            committedTokens = listOf("c1", "c2"),
        )
        assertFalse(expiredAfterComplete.ok)
        assertEquals(0, expiredAfterComplete.toJson(BUILD, true).getInt("recapture_count"))
    }

    @Test
    fun `impossible control tuples and arbitrary reason strings are rejected`() {
        listOf<() -> Unit>(
            { control(state = C1bProtocolState.READY_C1, c1RequestsAccepted = 1) },
            {
                control(
                    state = C1bProtocolState.CAPTURING_C1,
                    inFlightToken = "c2",
                    c1RequestsAccepted = 1,
                )
            },
            { control(state = C1bProtocolState.READY_C2, c1RequestsAccepted = 1) },
            {
                control(
                    state = C1bProtocolState.CAPTURING_C2,
                    inFlightToken = "c2",
                    c1RequestsAccepted = 1,
                    c2RequestsAccepted = 0,
                    committedTokens = listOf("c1"),
                )
            },
            {
                control(
                    state = C1bProtocolState.COMPLETE,
                    c1RequestsAccepted = 1,
                    c2RequestsAccepted = 1,
                    committedTokens = listOf("c1"),
                )
            },
            {
                control(
                    state = C1bProtocolState.FAILED,
                    reasonCode = "capture_c1_timeout",
                    inFlightToken = "c1",
                    c1RequestsAccepted = 1,
                )
            },
            { control(state = C1bProtocolState.EXPIRED, reasonCode = "session_aborted") },
            { control(state = C1bProtocolState.ABSENT, reasonCode = "capture_c1_failed") },
            { control(state = C1bProtocolState.FAILED, reasonCode = "sensitive_chat_content") },
            { control(generation = 0L, state = C1bProtocolState.READY_C1) },
            {
                control(
                    state = C1bProtocolState.READY_C1,
                    expectedTitleHash = null,
                    producerCommitSha = null,
                    producerArtifactSha256 = null,
                )
            },
            { control(producerArtifactSha256 = null) },
            {
                C1bProtocolControl(
                    key = KEY,
                    generation = 0L,
                    state = C1bProtocolState.ABSENT,
                    reasonCode = "session_not_found",
                    inFlightToken = null,
                    c1RequestsAccepted = 0,
                    c2RequestsAccepted = 0,
                    committedTokens = emptyList(),
                    expectedTitleHash = TABLET_C1B_EXPECTED_TITLE_HASH,
                    producerCommitSha = COMMIT,
                    producerArtifactSha256 = ARTIFACT,
                )
            },
            {
                C1bProtocolBuildIdentity(
                    packageName = "dev.magina.gateway",
                    versionName = "0.1.0 debug",
                    versionCode = 7L,
                    embeddedGitHead = COMMIT,
                    buildChallenge = "c1b-test-challenge-20260826",
                )
            },
        ).forEach { invalid -> expectFailure(invalid) }
    }

    private fun control(
        generation: Long = 1L,
        state: C1bProtocolState = C1bProtocolState.READY_C1,
        reasonCode: String? = null,
        inFlightToken: String? = null,
        c1RequestsAccepted: Int = 0,
        c2RequestsAccepted: Int = 0,
        committedTokens: List<String> = emptyList(),
        expectedTitleHash: String? = TABLET_C1B_EXPECTED_TITLE_HASH,
        producerCommitSha: String? = COMMIT,
        producerArtifactSha256: String? = ARTIFACT,
    ): C1bProtocolControl = C1bProtocolControl(
        key = KEY,
        generation = generation,
        state = state,
        reasonCode = reasonCode,
        inFlightToken = inFlightToken,
        c1RequestsAccepted = c1RequestsAccepted,
        c2RequestsAccepted = c2RequestsAccepted,
        committedTokens = committedTokens,
        expectedTitleHash = expectedTitleHash,
        producerCommitSha = producerCommitSha,
        producerArtifactSha256 = producerArtifactSha256,
    )

    private fun expectInvalid(uri: String, mode: String) = expectFailure {
        TabletC1bProtocol.parse(uri, mode)
    }

    private fun expectFailure(block: () -> Unit) {
        try {
            block()
            fail("expected IllegalArgumentException")
        } catch (_: IllegalArgumentException) {
            // expected
        }
    }

    private fun t0Uri(): String = TabletC1bProtocol.canonicalUri(C1bEndpoint.WriteT0(ENVELOPE))

    private fun readUri(path: String): String =
        "content://$TABLET_C1B_AUTHORITY/$path/$RUN_ID?nonce=$NONCE"

    private companion object {
        const val RUN_ID = "tl1-c1b-run-0001"
        val NONCE = "n-" + "0123456789abcdef".repeat(2)
        const val COMMIT = "4b96f89a6622eb8b5fe04bd249571c7d77936b25"
        const val ARTIFACT =
            "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        const val OTHER_HASH =
            "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        val KEY = C1bSessionKey(RUN_ID, NONCE)
        val ENVELOPE = C1bStartEnvelope(
            key = KEY,
            titleHash = TABLET_C1B_EXPECTED_TITLE_HASH,
            producerCommitSha = COMMIT,
            producerArtifactSha256 = ARTIFACT,
        )
        val BUILD = C1bProtocolBuildIdentity(
            packageName = "dev.magina.gateway",
            versionName = "0.1.0-test",
            versionCode = 7L,
            embeddedGitHead = COMMIT,
            buildChallenge = "c1b-test-challenge-20260826",
        )
    }
}

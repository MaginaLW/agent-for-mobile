package dev.magina.gateway.tablet.c1b

import dev.magina.gateway.tablet.StrictProbeJsonValue
import dev.magina.gateway.tablet.TRUSTED_T0_PRODUCER_SHA
import dev.magina.gateway.tablet.parseStrictProbeJson
import dev.magina.gateway.tablet.probeDeviceProfileHash
import dev.magina.gateway.tablet.probeSha256Bytes
import java.time.Instant

/** Derives the complete C1b assembly context from the exact T0 bytes written by the trusted runner. */
internal object TrustedRuntimeContextFactory {
    fun create(
        runId: String,
        expectedTitleHash: String,
        c1bProducerCommitSha: String,
        c1bProducerArtifactSha256: String,
        upstreamT0RawUtf8: ByteArray,
    ): C1bAssemblyRequest {
        require(C1B_RUNTIME_SAFE_ID.matches(runId)) { "trusted runtime C1b run_id is invalid" }
        require(expectedTitleHash == TABLET_C1B_EXPECTED_TITLE_HASH) {
            "trusted runtime title hash does not match the fixed C1b target"
        }
        require(C1B_RUNTIME_GIT_SHA.matches(c1bProducerCommitSha)) {
            "trusted runtime C1b producer commit is invalid"
        }
        require(C1B_RUNTIME_SHA256.matches(c1bProducerArtifactSha256)) {
            "trusted runtime C1b producer artifact hash is invalid"
        }
        require(upstreamT0RawUtf8.size in 1..TABLET_C1B_MAX_T0_BYTES) {
            "trusted runtime C1b T0 byte length is invalid"
        }
        val rawSnapshot = upstreamT0RawUtf8.copyOf()
        try {
            val root = parseStrictProbeJson(rawSnapshot)
            val assessment = root.requiredObject("assessment")
            val upstreamRunId = root.requiredString("run_id")
            require(upstreamRunId == runId) { "trusted runtime T0 run_id does not match the C1b envelope" }
            val capturedAt = root.requiredString("captured_at_utc")
            require(C1B_RUNTIME_TIMESTAMP.matches(capturedAt) &&
                runCatching { Instant.parse(capturedAt) }.isSuccess
            ) { "trusted runtime C1b T0 timestamp is not canonical UTC" }
            require(root.requiredLong("schema_version") == 5L) { "trusted runtime C1b T0 schema is not v5" }
            require(assessment.requiredString("intake_status") == "accepted") {
                "trusted runtime C1b T0 intake was not accepted"
            }
            require(assessment.requiredString("readiness_status") == "blocked") {
                "trusted runtime C1b T0 readiness must remain blocked"
            }
            require(assessment.requiredString("p0_capability") == "unsupported") {
                "trusted runtime C1b T0 P0 capability must remain unsupported"
            }
            val readinessReasons = assessment.requiredStringArray("readiness_block_reasons")
            val p0UnsupportedReasons = assessment.requiredStringArray("p0_unsupported_reasons")
            require(readinessReasons.size in 1..64 &&
                readinessReasons.toSet().size == readinessReasons.size &&
                readinessReasons.all(C1B_RUNTIME_SAFE_ID::matches)
            ) { "trusted runtime C1b T0 readiness reasons are invalid" }
            require(p0UnsupportedReasons.size in 2..64 &&
                p0UnsupportedReasons.toSet().size == p0UnsupportedReasons.size &&
                p0UnsupportedReasons.all(C1B_RUNTIME_SAFE_ID::matches) &&
                "wechat_layout_unverified" in p0UnsupportedReasons &&
                "tablet_landscape_p0_unimplemented" in p0UnsupportedReasons
            ) { "trusted runtime C1b T0 P0 reasons are invalid" }

            return C1bAssemblyRequest(
                runId = runId,
                expectedTitleHash = expectedTitleHash,
                provenance = C1bProvenance(
                    kind = "gateway_runtime_probe",
                    name = "tablet-c1b-provider",
                    producerCommitSha = c1bProducerCommitSha,
                    producerArtifactSha256 = c1bProducerArtifactSha256,
                ),
                upstreamT0 = C1bUpstreamT0(
                    sourceKind = "trusted_runtime",
                    runId = upstreamRunId,
                    capturedAt = capturedAt,
                    artifactSha256 = probeSha256Bytes(rawSnapshot),
                    producerCommitSha = TRUSTED_T0_PRODUCER_SHA,
                    deviceProfileHash = probeDeviceProfileHash(root.requiredObject("device")),
                    readinessReasons = readinessReasons,
                    p0UnsupportedReasons = p0UnsupportedReasons,
                ),
            )
        } finally {
            rawSnapshot.fill(0)
        }
    }
}

private val C1B_RUNTIME_SAFE_ID = Regex("[a-z0-9][a-z0-9._-]{0,79}")
private val C1B_RUNTIME_GIT_SHA = Regex("[0-9a-f]{40}")
private val C1B_RUNTIME_SHA256 = Regex("sha256:[0-9a-f]{64}")
private val C1B_RUNTIME_TIMESTAMP = Regex(
    "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{7}Z",
)

private fun StrictProbeJsonValue.ObjectValue.requiredObject(name: String): StrictProbeJsonValue.ObjectValue =
    members[name] as? StrictProbeJsonValue.ObjectValue
        ?: throw IllegalArgumentException("trusted runtime C1b T0 object field is invalid")

private fun StrictProbeJsonValue.ObjectValue.requiredString(name: String): String =
    (members[name] as? StrictProbeJsonValue.StringValue)?.value
        ?: throw IllegalArgumentException("trusted runtime C1b T0 string field is invalid")

private fun StrictProbeJsonValue.ObjectValue.requiredLong(name: String): Long =
    (members[name] as? StrictProbeJsonValue.LongValue)?.value
        ?: throw IllegalArgumentException("trusted runtime C1b T0 integer field is invalid")

private fun StrictProbeJsonValue.ObjectValue.requiredStringArray(name: String): List<String> =
    ((members[name] as? StrictProbeJsonValue.ArrayValue)?.values
        ?: throw IllegalArgumentException("trusted runtime C1b T0 array field is invalid")).map { value ->
        (value as? StrictProbeJsonValue.StringValue)?.value
            ?: throw IllegalArgumentException("trusted runtime C1b T0 string array is invalid")
    }

package dev.magina.gateway.tablet.c1a

import dev.magina.gateway.tablet.StrictProbeJsonValue
import dev.magina.gateway.tablet.TRUSTED_T0_PRODUCER_SHA
import dev.magina.gateway.tablet.TabletProbeProvenance
import dev.magina.gateway.tablet.TabletProbeRunContext
import dev.magina.gateway.tablet.TabletProbeUpstreamT0
import dev.magina.gateway.tablet.parseStrictProbeJson
import dev.magina.gateway.tablet.probeDeviceProfileHash
import dev.magina.gateway.tablet.probeSha256Bytes
import java.time.Instant

/**
 * 从 runner 写入的 T0 原始字节派生可信声明。调用方不能再提交一份平行的 parsed T0 DTO，
 * 从而避免 raw bytes 与声明被分别解析后发生 TOCTOU/字段漂移。
 */
internal object TrustedRuntimeContextFactory {
    fun create(
        runId: String,
        expectedTitleHash: String,
        c1aProducerCommitSha: String,
        c1aProducerArtifactSha256: String,
        runSalt: ByteArray,
        upstreamT0RawUtf8: ByteArray,
    ): TabletProbeRunContext {
        require(SAFE_ID.matches(runId)) { "trusted runtime C1a run_id is invalid" }
        require(expectedTitleHash == TABLET_C1A_EXPECTED_TITLE_HASH) {
            "trusted runtime title hash does not match the fixed C1a target"
        }
        require(GIT_SHA.matches(c1aProducerCommitSha)) { "trusted runtime producer commit is invalid" }
        require(SHA256.matches(c1aProducerArtifactSha256)) {
            "trusted runtime producer artifact hash is invalid"
        }
        require(upstreamT0RawUtf8.size in 1..TABLET_C1A_MAX_T0_BYTES) {
            "trusted runtime T0 byte length is invalid"
        }
        val rawSnapshot = upstreamT0RawUtf8.copyOf()
        try {
            val root = parseStrictProbeJson(rawSnapshot)
            val assessment = root.requiredObject("assessment")
            val upstreamRunId = root.requiredString("run_id")
            require(upstreamRunId == runId) { "trusted runtime T0 run_id does not match the URI envelope" }
            val capturedAt = root.requiredString("captured_at_utc")
            require(CANONICAL_TIMESTAMP.matches(capturedAt) && runCatching { Instant.parse(capturedAt) }.isSuccess) {
                "trusted runtime T0 timestamp is not canonical UTC"
            }
            val readinessReasons = assessment.requiredStringArray("readiness_block_reasons")
            val p0UnsupportedReasons = assessment.requiredStringArray("p0_unsupported_reasons")
            require(readinessReasons.size in 1..64 && readinessReasons.distinct().size == readinessReasons.size &&
                readinessReasons.all(SAFE_ID::matches)
            ) { "trusted runtime T0 readiness reasons are invalid" }
            require(p0UnsupportedReasons.size in 2..64 &&
                p0UnsupportedReasons.distinct().size == p0UnsupportedReasons.size &&
                p0UnsupportedReasons.all(SAFE_ID::matches) &&
                "wechat_layout_unverified" in p0UnsupportedReasons &&
                "tablet_landscape_p0_unimplemented" in p0UnsupportedReasons
            ) { "trusted runtime T0 P0 reasons are invalid" }
            val upstream = TabletProbeUpstreamT0(
                sourceKind = "trusted_runtime",
                runId = upstreamRunId,
                capturedAt = capturedAt,
                artifactSha256 = probeSha256Bytes(rawSnapshot),
                producerCommitSha = TRUSTED_T0_PRODUCER_SHA,
                deviceProfileHash = probeDeviceProfileHash(root.requiredObject("device")),
                readinessReasons = readinessReasons,
                p0UnsupportedReasons = p0UnsupportedReasons,
            )
            require(root.requiredLong("schema_version") == 5L) { "trusted runtime T0 schema is not v5" }
            require(assessment.requiredString("intake_status") == "accepted") {
                "trusted runtime T0 intake was not accepted"
            }
            require(assessment.requiredString("readiness_status") == "blocked") {
                "trusted runtime T0 readiness must remain blocked"
            }
            require(assessment.requiredString("p0_capability") == "unsupported") {
                "trusted runtime T0 P0 capability must remain unsupported"
            }
            return TabletProbeRunContext(
                runId = runId,
                expectedTitleHash = expectedTitleHash,
                runSalt = runSalt,
                upstreamT0RawUtf8 = rawSnapshot,
                provenance = TabletProbeProvenance(
                    kind = "gateway_runtime_probe",
                    name = "tablet-c1a-provider",
                    version = "v1",
                    producerCommitSha = c1aProducerCommitSha,
                    producerArtifactSha256 = c1aProducerArtifactSha256,
                ),
                upstreamT0 = upstream,
            )
        } finally {
            rawSnapshot.fill(0)
        }
    }
}

private val SAFE_ID = Regex("[a-z0-9][a-z0-9._-]{0,79}")
private val GIT_SHA = Regex("[0-9a-f]{40}")
private val SHA256 = Regex("sha256:[0-9a-f]{64}")
private val CANONICAL_TIMESTAMP = Regex(
    "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{7}Z",
)

private fun StrictProbeJsonValue.ObjectValue.requiredObject(name: String): StrictProbeJsonValue.ObjectValue =
    members[name] as? StrictProbeJsonValue.ObjectValue
        ?: throw IllegalArgumentException("trusted runtime T0 object field is invalid")

private fun StrictProbeJsonValue.ObjectValue.requiredString(name: String): String =
    (members[name] as? StrictProbeJsonValue.StringValue)?.value
        ?: throw IllegalArgumentException("trusted runtime T0 string field is invalid")

private fun StrictProbeJsonValue.ObjectValue.requiredLong(name: String): Long =
    (members[name] as? StrictProbeJsonValue.LongValue)?.value
        ?: throw IllegalArgumentException("trusted runtime T0 integer field is invalid")

private fun StrictProbeJsonValue.ObjectValue.requiredStringArray(name: String): List<String> =
    ((members[name] as? StrictProbeJsonValue.ArrayValue)?.values
        ?: throw IllegalArgumentException("trusted runtime T0 array field is invalid")).map { value ->
        (value as? StrictProbeJsonValue.StringValue)?.value
            ?: throw IllegalArgumentException("trusted runtime T0 string array is invalid")
    }

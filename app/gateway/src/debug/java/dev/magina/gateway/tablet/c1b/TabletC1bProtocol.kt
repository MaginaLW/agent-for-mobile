package dev.magina.gateway.tablet.c1b

import org.json.JSONArray
import org.json.JSONObject
import java.net.URI
import java.util.Collections

internal const val TABLET_C1B_AUTHORITY = "dev.magina.gateway.tablet.c1b"
internal const val TABLET_C1B_PROTOCOL_VERSION = "1"
internal const val TABLET_C1B_MAX_T0_BYTES = 65_536
internal const val TABLET_C1B_MAX_OUTPUT_BYTES = 1_048_576
internal const val TABLET_C1B_EXPECTED_TITLE_HASH =
    "sha256:5d3510ec998c991305fcede15b32be9ea1c4061d82ab15a3994a38faa243311c"

internal data class C1bSessionKey(
    val runId: String,
    val nonce: String,
) {
    init {
        require(C1B_PROTOCOL_SAFE_RUN_ID.matches(runId)) { "C1b run_id is invalid" }
        require(C1B_PROTOCOL_SAFE_NONCE.matches(nonce)) { "C1b nonce is invalid" }
    }

    override fun toString(): String = "C1bSessionKey(runId=$runId, nonce=<redacted>)"
}

internal data class C1bStartEnvelope(
    val key: C1bSessionKey,
    val titleHash: String,
    val producerCommitSha: String,
    val producerArtifactSha256: String,
) {
    init {
        require(titleHash == TABLET_C1B_EXPECTED_TITLE_HASH) {
            "title_hash does not match the fixed C1b runtime target"
        }
        require(C1B_PROTOCOL_GIT_SHA.matches(producerCommitSha)) {
            "producer_commit_sha is not a full lowercase Git SHA"
        }
        require(C1B_PROTOCOL_SHA256.matches(producerArtifactSha256)) {
            "producer_artifact_sha256 is not a strict SHA-256 token"
        }
    }

    override fun toString(): String =
        "C1bStartEnvelope(key=$key, titleHash=<redacted>, producerCommitSha=<redacted>, " +
            "producerArtifactSha256=<redacted>)"
}

internal sealed interface C1bEndpoint {
    val key: C1bSessionKey

    data class WriteT0(val envelope: C1bStartEnvelope) : C1bEndpoint {
        override val key: C1bSessionKey get() = envelope.key
    }

    data class Status(override val key: C1bSessionKey) : C1bEndpoint

    data class Capture(
        override val key: C1bSessionKey,
        val token: String,
    ) : C1bEndpoint {
        init {
            require(token in C1B_PROTOCOL_CAPTURE_TOKENS) { "capture token must be exact c1 or c2" }
        }
    }

    data class Result(override val key: C1bSessionKey) : C1bEndpoint
    data class Abort(override val key: C1bSessionKey) : C1bEndpoint
}

/**
 * 纯 JVM URI 协议层；不引用 Android Uri、provider 或 worker coordinator 类型。
 *
 * 协议字符集不需要 percent decode。拒绝 `%` 与 `+` 可消除路径分隔符、重复键和空格的多重解释；
 * 成功解析后还必须与 [canonicalUri] 字节级相等，因此 query 键、顺序与每键一次都只有一种 wire 形式。
 */
internal object TabletC1bProtocol {
    fun parse(rawUri: String, mode: String): C1bEndpoint {
        require(rawUri.length in 1..MAX_URI_CHARS) { "C1b URI length is invalid" }
        require('%' !in rawUri && '+' !in rawUri) { "encoded C1b URI is not accepted" }
        val uri = runCatching { URI(rawUri) }
            .getOrElse { throw IllegalArgumentException("C1b URI syntax is invalid") }
        require(uri.scheme == "content" && uri.rawAuthority == TABLET_C1B_AUTHORITY) {
            "C1b URI authority is invalid"
        }
        require(uri.rawUserInfo == null && uri.port == -1 && uri.rawFragment == null) {
            "C1b URI contains unsupported authority or fragment fields"
        }
        val path = uri.rawPath ?: throw IllegalArgumentException("C1b URI path is missing")
        require(path.startsWith('/') && !path.endsWith('/') && "//" !in path) {
            "C1b URI path is not canonical"
        }
        val segments = path.removePrefix("/").split('/')
        val query = parseQuery(uri.rawQuery)

        val endpoint = when {
            segments.size == 2 && segments[0] == "t0" -> {
                require(mode == "w") { "T0 endpoint requires exact write mode" }
                require(query.keys == T0_QUERY_KEYS) { "T0 query keys are not exact" }
                C1bEndpoint.WriteT0(
                    C1bStartEnvelope(
                        key = C1bSessionKey(segments[1], query.getValue("nonce")),
                        titleHash = query.getValue("title_hash"),
                        producerCommitSha = query.getValue("producer_commit_sha"),
                        producerArtifactSha256 = query.getValue("producer_artifact_sha256"),
                    ),
                )
            }

            segments.size == 2 && segments[0] == "status" -> {
                require(mode == "r") { "status endpoint requires exact read mode" }
                require(query.keys == READ_QUERY_KEYS) { "status query keys are not exact" }
                C1bEndpoint.Status(C1bSessionKey(segments[1], query.getValue("nonce")))
            }

            segments.size == 3 && segments[0] == "capture" -> {
                require(mode == "r") { "capture endpoint requires exact read mode" }
                require(query.keys == READ_QUERY_KEYS) { "capture query keys are not exact" }
                C1bEndpoint.Capture(
                    key = C1bSessionKey(segments[2], query.getValue("nonce")),
                    token = segments[1],
                )
            }

            segments.size == 2 && segments[0] == "result" -> {
                require(mode == "r") { "result endpoint requires exact read mode" }
                require(query.keys == READ_QUERY_KEYS) { "result query keys are not exact" }
                C1bEndpoint.Result(C1bSessionKey(segments[1], query.getValue("nonce")))
            }

            segments.size == 2 && segments[0] == "abort" -> {
                require(mode == "r") { "abort endpoint requires exact read mode" }
                require(query.keys == READ_QUERY_KEYS) { "abort query keys are not exact" }
                C1bEndpoint.Abort(C1bSessionKey(segments[1], query.getValue("nonce")))
            }

            else -> throw IllegalArgumentException("C1b URI path is unsupported")
        }
        require(rawUri == canonicalUri(endpoint)) { "C1b URI is not the unique canonical wire form" }
        return endpoint
    }

    /** 为 host runner 提供唯一的未编码 wire 形式；所有构造字段已由 DTO 的 closed grammar 校验。 */
    fun canonicalUri(endpoint: C1bEndpoint): String = when (endpoint) {
        is C1bEndpoint.WriteT0 -> with(endpoint.envelope) {
            "content://$TABLET_C1B_AUTHORITY/t0/${key.runId}" +
                "?nonce=${key.nonce}&title_hash=$titleHash" +
                "&producer_commit_sha=$producerCommitSha" +
                "&producer_artifact_sha256=$producerArtifactSha256"
        }

        is C1bEndpoint.Status -> readUri("status", endpoint.key)
        is C1bEndpoint.Capture -> readUri("capture/${endpoint.token}", endpoint.key)
        is C1bEndpoint.Result -> readUri("result", endpoint.key)
        is C1bEndpoint.Abort -> readUri("abort", endpoint.key)
    }

    private fun readUri(path: String, key: C1bSessionKey): String =
        "content://$TABLET_C1B_AUTHORITY/$path/${key.runId}?nonce=${key.nonce}"

    private fun parseQuery(rawQuery: String?): Map<String, String> {
        require(!rawQuery.isNullOrEmpty()) { "C1b URI query is missing" }
        val values = linkedMapOf<String, String>()
        rawQuery.split('&').forEach { pair ->
            val separator = pair.indexOf('=')
            require(separator > 0 && separator == pair.lastIndexOf('=') && separator < pair.lastIndex) {
                "C1b URI query pair is invalid"
            }
            val name = pair.substring(0, separator)
            val value = pair.substring(separator + 1)
            require(name in ALL_QUERY_KEYS && values.put(name, value) == null) {
                "C1b URI query contains an unknown or duplicate key"
            }
        }
        return values
    }

    private val READ_QUERY_KEYS = setOf("nonce")
    private val T0_QUERY_KEYS = setOf(
        "nonce",
        "title_hash",
        "producer_commit_sha",
        "producer_artifact_sha256",
    )
    private val ALL_QUERY_KEYS = READ_QUERY_KEYS + T0_QUERY_KEYS
    private const val MAX_URI_CHARS = 512
}

internal data class C1bProtocolBuildIdentity(
    val packageName: String,
    val versionName: String,
    val versionCode: Long,
    val embeddedGitHead: String,
    val buildChallenge: String,
) {
    init {
        require(packageName == "dev.magina.gateway") { "C1b package identity is invalid" }
        require(C1B_PROTOCOL_VERSION_NAME.matches(versionName)) { "C1b version name is invalid" }
        require(versionCode > 0L) { "C1b version code is invalid" }
        require(C1B_PROTOCOL_GIT_SHA.matches(embeddedGitHead)) {
            "C1b embedded Git HEAD is invalid"
        }
        require(C1B_PROTOCOL_BUILD_CHALLENGE.matches(buildChallenge)) {
            "C1b build challenge is invalid"
        }
    }

    override fun toString(): String =
        "C1bProtocolBuildIdentity(packageName=$packageName, versionName=$versionName, " +
            "versionCode=$versionCode, embeddedGitHead=<redacted>, buildChallenge=<redacted>)"
}

/** 独立 wire enum；provider adapter 只能显式映射 coordinator state，不能把任意字符串写入控制面。 */
internal enum class C1bProtocolState(val wire: String) {
    ABSENT("absent"),
    READY_C1("ready_c1"),
    CAPTURING_C1("capturing_c1"),
    READY_C2("ready_c2"),
    CAPTURING_C2("capturing_c2"),
    COMPLETE("complete"),
    FAILED("failed"),
    ABORTED("aborted"),
    EXPIRED("expired"),
}

/**
 * Provider 可接线的纯值控制 DTO。它不引用 coordinator 类型，也不会序列化 nonce。
 * reason code 是固定集合，避免异常消息或 UI/content 数据借控制面外泄。
 */
internal class C1bProtocolControl(
    val key: C1bSessionKey,
    val generation: Long,
    val state: C1bProtocolState,
    val reasonCode: String?,
    val inFlightToken: String?,
    val c1RequestsAccepted: Int,
    val c2RequestsAccepted: Int,
    committedTokens: List<String>,
    val expectedTitleHash: String?,
    val producerCommitSha: String?,
    val producerArtifactSha256: String?,
) {
    /** 防御 caller 后续修改 mutable list；wire 永远使用构造时的 closed prefix 快照。 */
    val committedTokens: List<String> = Collections.unmodifiableList(committedTokens.toList())

    init {
        require(generation >= 0L) { "C1b generation is invalid" }
        require(reasonCode == null || reasonCode in C1B_PROTOCOL_REASON_CODES) {
            "C1b reason code is not in the fixed set"
        }
        require(inFlightToken == null || inFlightToken in C1B_PROTOCOL_CAPTURE_TOKENS) {
            "C1b in-flight token is invalid"
        }
        require(c1RequestsAccepted in 0..1 && c2RequestsAccepted in 0..1) {
            "C1b accepted capture counts are invalid"
        }
        require(committedTokens in C1B_PROTOCOL_COMMITTED_PREFIXES) {
            "C1b committed token prefix is invalid"
        }
        require(c2RequestsAccepted <= c1RequestsAccepted) { "C1b c2 cannot precede c1" }
        require(committedTokens.size <= c1RequestsAccepted + c2RequestsAccepted) {
            "C1b committed tokens exceed accepted captures"
        }

        val producerFields = listOf(expectedTitleHash, producerCommitSha, producerArtifactSha256)
        require(producerFields.all { it == null } || producerFields.all { it != null }) {
            "C1b producer binding must be all present or all absent"
        }
        if (state == C1bProtocolState.ABSENT) {
            require(expectedTitleHash == null) { "C1b absent control cannot echo producer binding" }
        } else {
            require(expectedTitleHash != null) { "C1b non-absent control requires producer binding" }
        }
        expectedTitleHash?.let {
            require(it == TABLET_C1B_EXPECTED_TITLE_HASH) { "C1b control title hash is invalid" }
        }
        producerCommitSha?.let {
            require(C1B_PROTOCOL_GIT_SHA.matches(it)) { "C1b control producer SHA is invalid" }
        }
        producerArtifactSha256?.let {
            require(C1B_PROTOCOL_SHA256.matches(it)) { "C1b control artifact SHA is invalid" }
        }

        validateStateTuple()
    }

    val ok: Boolean
        get() = state in C1B_PROTOCOL_OK_STATES

    override fun toString(): String =
        "C1bProtocolControl(runId=${key.runId}, generation=$generation, state=${state.wire}, " +
            "reasonCode=$reasonCode, inFlightToken=$inFlightToken, " +
            "c1RequestsAccepted=$c1RequestsAccepted, c2RequestsAccepted=$c2RequestsAccepted, " +
            "committedTokens=$committedTokens, producerBinding=<redacted>)"

    private val next: String
        get() = when (state) {
            C1bProtocolState.READY_C1 -> "capture_c1"
            C1bProtocolState.CAPTURING_C1,
            C1bProtocolState.CAPTURING_C2,
            -> "wait"
            C1bProtocolState.READY_C2 -> "capture_c2"
            C1bProtocolState.COMPLETE -> "read_result"
            else -> "none"
        }

    fun toJson(build: C1bProtocolBuildIdentity, a11yServiceReady: Boolean): JSONObject = JSONObject()
        .put("schema", "tablet-c1b-control/v1")
        .put("ok", ok)
        .put("run_id", key.runId)
        .put("generation", generation)
        .put("state", state.wire)
        .put("next", next)
        .put("reason_code", reasonCode ?: JSONObject.NULL)
        .put("in_flight_token", inFlightToken ?: JSONObject.NULL)
        .put("c1_requests_accepted", c1RequestsAccepted)
        .put("c2_requests_accepted", c2RequestsAccepted)
        .put("committed_tokens", JSONArray(committedTokens))
        .put("recapture_count", 0)
        .put("expected_title_hash", expectedTitleHash ?: JSONObject.NULL)
        .put("producer_commit_sha", producerCommitSha ?: JSONObject.NULL)
        .put("producer_artifact_sha256", producerArtifactSha256 ?: JSONObject.NULL)
        .put(
            "provider",
            JSONObject()
                .put("authority", TABLET_C1B_AUTHORITY)
                .put("protocol_version", TABLET_C1B_PROTOCOL_VERSION)
                .put("package_name", build.packageName)
                .put("version_name", build.versionName)
                .put("version_code", build.versionCode)
                .put("embedded_git_head", build.embeddedGitHead)
                .put("build_challenge", build.buildChallenge)
                .put("a11y_service_ready", a11yServiceReady),
        )

    private fun validateStateTuple() {
        val tuple = Triple(c1RequestsAccepted, c2RequestsAccepted, committedTokens)
        when (state) {
            C1bProtocolState.ABSENT -> {
                require(tuple == C1B_PROTOCOL_EMPTY_TUPLE && inFlightToken == null) {
                    "C1b absent control tuple is invalid"
                }
                require(reasonCode in C1B_PROTOCOL_ABSENT_REASONS) {
                    "C1b absent control reason is invalid"
                }
            }

            C1bProtocolState.READY_C1 -> requireActive(
                tuple == C1B_PROTOCOL_EMPTY_TUPLE && inFlightToken == null,
                "ready_c1",
            )

            C1bProtocolState.CAPTURING_C1 -> requireActive(
                tuple == C1B_PROTOCOL_C1_IN_FLIGHT_TUPLE && inFlightToken == "c1",
                "capturing_c1",
            )

            C1bProtocolState.READY_C2 -> requireActive(
                tuple == C1B_PROTOCOL_C1_COMMITTED_TUPLE && inFlightToken == null,
                "ready_c2",
            )

            C1bProtocolState.CAPTURING_C2 -> requireActive(
                tuple == C1B_PROTOCOL_C2_IN_FLIGHT_TUPLE && inFlightToken == "c2",
                "capturing_c2",
            )

            C1bProtocolState.COMPLETE -> requireActive(
                tuple == C1B_PROTOCOL_COMPLETE_TUPLE && inFlightToken == null,
                "complete",
            )

            C1bProtocolState.FAILED -> {
                require(tuple in C1B_PROTOCOL_TERMINAL_TUPLES && inFlightToken == null) {
                    "C1b failed control tuple is invalid"
                }
                require(reasonCode in C1B_PROTOCOL_FAILURE_REASONS) {
                    "C1b failed control reason is invalid"
                }
            }

            C1bProtocolState.ABORTED -> {
                require(tuple in C1B_PROTOCOL_TERMINAL_TUPLES && inFlightToken == null) {
                    "C1b aborted control tuple is invalid"
                }
                require(reasonCode in C1B_PROTOCOL_ABORT_REASONS) {
                    "C1b aborted control reason is invalid"
                }
            }

            C1bProtocolState.EXPIRED -> {
                require(tuple in C1B_PROTOCOL_EXPIRABLE_TUPLES && inFlightToken == null) {
                    "C1b expired control tuple is invalid"
                }
                require(reasonCode == "session_expired") { "C1b expired control reason is invalid" }
            }
        }
    }

    private fun requireActive(condition: Boolean, stateName: String) {
        require(condition) { "C1b $stateName control tuple is invalid" }
        require(generation > 0L) { "C1b active/complete control requires a generation" }
        require(reasonCode == null) { "C1b active/complete control cannot have a reason" }
    }
}

private val C1B_PROTOCOL_SAFE_RUN_ID = Regex("[a-z0-9][a-z0-9._-]{0,79}")
private val C1B_PROTOCOL_SAFE_NONCE = Regex("n-[0-9a-f]{32}")
private val C1B_PROTOCOL_SHA256 = Regex("sha256:[0-9a-f]{64}")
private val C1B_PROTOCOL_GIT_SHA = Regex("[0-9a-f]{40}")
private val C1B_PROTOCOL_VERSION_NAME = Regex("[A-Za-z0-9][A-Za-z0-9._-]{0,79}")
private val C1B_PROTOCOL_BUILD_CHALLENGE = Regex("[a-z0-9][a-z0-9._-]{15,95}")
private val C1B_PROTOCOL_CAPTURE_TOKENS = setOf("c1", "c2")
private val C1B_PROTOCOL_COMMITTED_PREFIXES = setOf(emptyList(), listOf("c1"), listOf("c1", "c2"))
private val C1B_PROTOCOL_EMPTY_TUPLE = Triple(0, 0, emptyList<String>())
private val C1B_PROTOCOL_C1_IN_FLIGHT_TUPLE = Triple(1, 0, emptyList<String>())
private val C1B_PROTOCOL_C1_COMMITTED_TUPLE = Triple(1, 0, listOf("c1"))
private val C1B_PROTOCOL_C2_IN_FLIGHT_TUPLE = Triple(1, 1, listOf("c1"))
private val C1B_PROTOCOL_COMPLETE_TUPLE = Triple(1, 1, listOf("c1", "c2"))
private val C1B_PROTOCOL_TERMINAL_TUPLES = setOf(
    C1B_PROTOCOL_EMPTY_TUPLE,
    C1B_PROTOCOL_C1_IN_FLIGHT_TUPLE,
    C1B_PROTOCOL_C1_COMMITTED_TUPLE,
    C1B_PROTOCOL_C2_IN_FLIGHT_TUPLE,
)
private val C1B_PROTOCOL_EXPIRABLE_TUPLES =
    C1B_PROTOCOL_TERMINAL_TUPLES + C1B_PROTOCOL_COMPLETE_TUPLE
private val C1B_PROTOCOL_OK_STATES = setOf(
    C1bProtocolState.READY_C1,
    C1bProtocolState.CAPTURING_C1,
    C1bProtocolState.READY_C2,
    C1bProtocolState.CAPTURING_C2,
    C1bProtocolState.COMPLETE,
)
private val C1B_PROTOCOL_ABSENT_REASONS = setOf(
    "coordinator_closed",
    "generation_exhausted",
    "nonce_reused",
    "replay_ledger_full",
    "run_id_reused",
    "session_busy",
    "session_not_found",
    "t0_pending",
)
private val C1B_PROTOCOL_FAILURE_REASONS = setOf(
    "a11y_service_replaced",
    "a11y_service_unavailable",
    "build_identity_mismatch",
    "capture_c1_failed",
    "capture_c1_timeout",
    "capture_c2_failed",
    "capture_c2_timeout",
    "capture_sequence_invalid",
    "capture_timeout_scheduler_rejected",
    "capture_worker_inline",
    "capture_worker_rejected",
    "observation_assembly_failed",
    "session_expiry_scheduler_rejected",
    "start_replayed",
    "t0_invalid",
)
private val C1B_PROTOCOL_ABORT_REASONS = setOf("coordinator_shutdown", "session_aborted")
private val C1B_PROTOCOL_REASON_CODES =
    C1B_PROTOCOL_ABSENT_REASONS + C1B_PROTOCOL_FAILURE_REASONS +
        C1B_PROTOCOL_ABORT_REASONS + "session_expired"

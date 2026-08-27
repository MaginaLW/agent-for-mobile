package dev.magina.gateway.tablet.c1a

import java.net.URI

internal const val TABLET_C1A_AUTHORITY = "dev.magina.gateway.tablet.c1a"
internal const val TABLET_C1A_PROTOCOL_VERSION = "1"
internal const val TABLET_C1A_MAX_T0_BYTES = 65_536
internal const val TABLET_C1A_MAX_OUTPUT_BYTES = 1_048_576
internal const val TABLET_C1A_EXPECTED_TITLE_HASH =
    "sha256:5d3510ec998c991305fcede15b32be9ea1c4061d82ab15a3994a38faa243311c"

internal data class C1aSessionKey(val runId: String, val nonce: String)

internal data class C1aStartEnvelope(
    val key: C1aSessionKey,
    val titleHash: String,
    val producerCommitSha: String,
    val producerArtifactSha256: String,
)

internal sealed interface C1aEndpoint {
    val key: C1aSessionKey

    data class WriteT0(val envelope: C1aStartEnvelope) : C1aEndpoint {
        override val key: C1aSessionKey get() = envelope.key
    }

    data class Status(override val key: C1aSessionKey) : C1aEndpoint
    data class Capture(override val key: C1aSessionKey, val token: String) : C1aEndpoint
    data class Result(override val key: C1aSessionKey) : C1aEndpoint
    data class Abort(override val key: C1aSessionKey) : C1aEndpoint
}

/**
 * URI parser 不做 percent decode：协议字符集本来就不需要转义，拒绝转义可同时消除重复键、
 * 路径分隔符和 `+` 的多重解释。query 顺序不重要，但键集合和每键一次必须完全匹配。
 */
internal object TabletC1aProtocol {
    fun parse(rawUri: String, mode: String): C1aEndpoint {
        require('%' !in rawUri && '+' !in rawUri) { "encoded C1a URI is not accepted" }
        val uri = runCatching { URI(rawUri) }
            .getOrElse { throw IllegalArgumentException("C1a URI syntax is invalid") }
        require(uri.scheme == "content" && uri.rawAuthority == TABLET_C1A_AUTHORITY) {
            "C1a URI authority is invalid"
        }
        require(uri.rawUserInfo == null && uri.port == -1 && uri.rawFragment == null) {
            "C1a URI contains unsupported authority or fragment fields"
        }
        val path = uri.rawPath ?: throw IllegalArgumentException("C1a URI path is missing")
        require(path.startsWith('/') && !path.endsWith('/') && "//" !in path) {
            "C1a URI path is not canonical"
        }
        val segments = path.removePrefix("/").split('/')
        val query = parseQuery(uri.rawQuery)

        return when {
            segments.size == 2 && segments[0] == "t0" -> {
                require(mode == "w") { "T0 endpoint requires exact write mode" }
                require(query.keys == T0_QUERY_KEYS) { "T0 query keys are not exact" }
                val key = key(segments[1], query.getValue("nonce"))
                C1aEndpoint.WriteT0(
                    C1aStartEnvelope(
                        key = key,
                        titleHash = query.getValue("title_hash").requireHash("title_hash").also {
                            require(it == TABLET_C1A_EXPECTED_TITLE_HASH) {
                                "title_hash does not match the fixed C1a target"
                            }
                        },
                        producerCommitSha = query.getValue("producer_commit_sha")
                            .requireGitSha("producer_commit_sha"),
                        producerArtifactSha256 = query.getValue("producer_artifact_sha256")
                            .requireHash("producer_artifact_sha256"),
                    ),
                )
            }
            segments.size == 2 && segments[0] == "status" -> {
                require(mode == "r") { "status endpoint requires exact read mode" }
                require(query.keys == READ_QUERY_KEYS) { "status query keys are not exact" }
                C1aEndpoint.Status(key(segments[1], query.getValue("nonce")))
            }
            segments.size == 3 && segments[0] == "capture" -> {
                require(mode == "r") { "capture endpoint requires exact read mode" }
                require(query.keys == READ_QUERY_KEYS) { "capture query keys are not exact" }
                require(segments[1] == "c1" || segments[1] == "c2") {
                    "capture token must be exact c1 or c2"
                }
                C1aEndpoint.Capture(key(segments[2], query.getValue("nonce")), segments[1])
            }
            segments.size == 2 && segments[0] == "result" -> {
                require(mode == "r") { "result endpoint requires exact read mode" }
                require(query.keys == READ_QUERY_KEYS) { "result query keys are not exact" }
                C1aEndpoint.Result(key(segments[1], query.getValue("nonce")))
            }
            segments.size == 2 && segments[0] == "abort" -> {
                require(mode == "r") { "abort endpoint requires exact read mode" }
                require(query.keys == READ_QUERY_KEYS) { "abort query keys are not exact" }
                C1aEndpoint.Abort(key(segments[1], query.getValue("nonce")))
            }
            else -> throw IllegalArgumentException("C1a URI path is unsupported")
        }
    }

    private fun parseQuery(rawQuery: String?): Map<String, String> {
        require(!rawQuery.isNullOrEmpty()) { "C1a URI query is missing" }
        val values = linkedMapOf<String, String>()
        rawQuery.split('&').forEach { pair ->
            val separator = pair.indexOf('=')
            require(separator > 0 && separator == pair.lastIndexOf('=') && separator < pair.lastIndex) {
                "C1a URI query pair is invalid"
            }
            val name = pair.substring(0, separator)
            val value = pair.substring(separator + 1)
            require(name in ALL_QUERY_KEYS && values.put(name, value) == null) {
                "C1a URI query contains an unknown or duplicate key"
            }
        }
        return values
    }

    private fun key(runId: String, nonce: String): C1aSessionKey {
        require(SAFE_RUN_ID.matches(runId)) { "C1a run_id is invalid" }
        require(SAFE_NONCE.matches(nonce)) { "C1a nonce is invalid" }
        return C1aSessionKey(runId, nonce)
    }

    private fun String.requireHash(name: String): String = also {
        require(SHA256.matches(it)) { "$name is not a strict SHA-256 token" }
    }

    private fun String.requireGitSha(name: String): String = also {
        require(GIT_SHA.matches(it)) { "$name is not a full lowercase Git SHA" }
    }

    private val READ_QUERY_KEYS = setOf("nonce")
    private val T0_QUERY_KEYS = setOf(
        "nonce",
        "title_hash",
        "producer_commit_sha",
        "producer_artifact_sha256",
    )
    private val ALL_QUERY_KEYS = READ_QUERY_KEYS + T0_QUERY_KEYS
    private val SAFE_RUN_ID = Regex("[a-z0-9][a-z0-9._-]{0,79}")
    private val SAFE_NONCE = Regex("[a-z0-9][a-z0-9_-]{15,79}")
    private val SHA256 = Regex("sha256:[0-9a-f]{64}")
    private val GIT_SHA = Regex("[0-9a-f]{40}")
}

package dev.magina.gateway.mcp

import org.json.JSONObject
import java.net.URI

/** MCP 2025-03-26 的无状态 HTTP 边界策略；不依赖 Ktor，便于 JVM 测试。 */
internal object McpTransportPolicy {
    const val SUPPORTED_PROTOCOL_VERSION = "2025-03-26"

    /** 单版本服务器：支持客户端所提版本时原样返回，否则返回服务器唯一支持的版本。 */
    fun negotiateProtocolVersion(requestedVersion: String?): String =
        if (requestedVersion == SUPPORTED_PROTOCOL_VERSION) requestedVersion else SUPPORTED_PROTOCOL_VERSION

    /**
     * initialize 本身负责协商，所以不受请求头版本约束。其后的显式版本必须等于协商版本；
     * 缺头按兼容规则视为 2025-03-26，保留旧客户端可用性。
     */
    fun acceptsProtocolVersion(method: String, headerVersion: String?): Boolean =
        method == "initialize" || headerVersion == null || headerVersion == SUPPORTED_PROTOCOL_VERSION

    /**
     * 原生 CLI/adb 转发调用通常没有 Origin，可以放行；浏览器请求只有来自 loopback Web 页才放行。
     * 不做 DNS 解析，避免把攻击者控制的主机名在校验时解析成 loopback 的 TOCTOU/DNS-rebinding 面。
     */
    fun acceptsOrigin(origin: String?): Boolean {
        if (origin == null) return true
        val uri = runCatching { URI(origin) }.getOrNull() ?: return false
        if (uri.scheme?.lowercase() !in setOf("http", "https")) return false
        if (uri.rawUserInfo != null || !uri.rawPath.isNullOrEmpty() || uri.rawQuery != null || uri.rawFragment != null) {
            return false
        }
        if (uri.port !in -1..65535) return false
        val host = uri.host?.removePrefix("[")?.removeSuffix("]")?.lowercase()?.trimEnd('.') ?: return false
        return host == "localhost" || host == "::1" || host == "0:0:0:0:0:0:0:1" || isIpv4Loopback(host)
    }

    /**
     * 只有 JSON boolean `true` 才表示成功。`JSONObject.optBoolean` 会把字符串 `"true"`
     * 也强制转换为 true，反而会让格式退化或伪造的信封被 MCP 客户端误认为执行成功。
     */
    fun toolResultIsError(envelope: JSONObject): Boolean = envelope.opt("ok") != true

    private fun isIpv4Loopback(host: String): Boolean {
        val parts = host.split('.')
        if (parts.size != 4 || parts[0] != "127") return false
        return parts.all { part ->
            val value = part.toIntOrNull()
            part.isNotEmpty() && part.all(Char::isDigit) && value != null && value in 0..255
        }
    }
}

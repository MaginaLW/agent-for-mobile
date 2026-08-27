package dev.magina.gateway.mcp

import org.json.JSONObject
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertEquals
import org.junit.Test

class McpTransportPolicyTest {

    @Test
    fun `initialize 只会协商到服务器支持的版本而不回显任意输入`() {
        assertEquals(
            McpTransportPolicy.SUPPORTED_PROTOCOL_VERSION,
            McpTransportPolicy.negotiateProtocolVersion("2099-12-31"),
        )
        assertEquals(
            McpTransportPolicy.SUPPORTED_PROTOCOL_VERSION,
            McpTransportPolicy.negotiateProtocolVersion(McpTransportPolicy.SUPPORTED_PROTOCOL_VERSION),
        )
        assertEquals(
            McpTransportPolicy.SUPPORTED_PROTOCOL_VERSION,
            McpTransportPolicy.negotiateProtocolVersion(null),
        )
    }

    @Test
    fun `initialize 可携任意提议版本但后续显式版本必须受支持`() {
        assertTrue(McpTransportPolicy.acceptsProtocolVersion("initialize", "2099-12-31"))
        assertTrue(McpTransportPolicy.acceptsProtocolVersion("tools/list", null))
        assertTrue(
            McpTransportPolicy.acceptsProtocolVersion(
                "tools/list",
                McpTransportPolicy.SUPPORTED_PROTOCOL_VERSION,
            ),
        )
        assertFalse(McpTransportPolicy.acceptsProtocolVersion("tools/list", "2025-06-18"))
        assertFalse(McpTransportPolicy.acceptsProtocolVersion("notifications/initialized", ""))
    }

    @Test
    fun `Origin 仅放行缺省或明确 loopback HTTP 来源`() {
        assertTrue(McpTransportPolicy.acceptsOrigin(null))
        assertTrue(McpTransportPolicy.acceptsOrigin("http://localhost"))
        assertTrue(McpTransportPolicy.acceptsOrigin("https://localhost:8443"))
        assertTrue(McpTransportPolicy.acceptsOrigin("http://127.0.0.1:3000"))
        assertTrue(McpTransportPolicy.acceptsOrigin("http://127.42.7.9"))
        assertTrue(McpTransportPolicy.acceptsOrigin("http://[::1]:3000"))

        assertFalse(McpTransportPolicy.acceptsOrigin("null"))
        assertFalse(McpTransportPolicy.acceptsOrigin("https://example.com"))
        assertFalse(McpTransportPolicy.acceptsOrigin("http://localhost.example.com"))
        assertFalse(McpTransportPolicy.acceptsOrigin("file://localhost/tmp"))
        assertFalse(McpTransportPolicy.acceptsOrigin("http://user@localhost"))
        assertFalse(McpTransportPolicy.acceptsOrigin("http://localhost/path"))
    }

    @Test
    fun `工具执行结果从 envelope ok 映射 isError 且缺字段失败关闭`() {
        assertFalse(McpTransportPolicy.toolResultIsError(JSONObject().put("ok", true)))
        assertTrue(McpTransportPolicy.toolResultIsError(JSONObject().put("ok", false)))
        assertTrue(McpTransportPolicy.toolResultIsError(JSONObject().put("ok", "true")))
        assertTrue(McpTransportPolicy.toolResultIsError(JSONObject().put("ok", 1)))
        assertTrue(McpTransportPolicy.toolResultIsError(JSONObject()))
    }
}

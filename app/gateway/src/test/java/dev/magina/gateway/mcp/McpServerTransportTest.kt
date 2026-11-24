package dev.magina.gateway.mcp

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class McpServerTransportTest {

    @Test
    fun `idle timeout exceeds 90s confirm overlay budget and enables reuseAddress`() {
        assertTrue(
            "connectionIdleTimeoutSeconds 必须 >= 180 以覆盖 ConfirmOverlay 90s 等待",
            McpTransportPolicy.CONNECTION_IDLE_TIMEOUT_SECONDS >= 180,
        )
        assertTrue(McpTransportPolicy.REUSE_ADDRESS)
    }

    @Test
    fun `internalErrorJsonRpc redacts raw exception message and preserves id types`() {
        val secret = "bearer-" + "01234567".repeat(4)
        val err = IllegalStateException("leak $secret in exception message")

        val withIntId = McpTransportPolicy.internalErrorJsonRpc(42, err)
        assertEquals("2.0", withIntId.getString("jsonrpc"))
        assertEquals(42, withIntId.getInt("id"))
        val errObj = withIntId.getJSONObject("error")
        assertEquals(-32603, errObj.getInt("code"))
        assertEquals("internal server error: IllegalStateException", errObj.getString("message"))
        assertFalse(withIntId.toString().contains(secret))

        val withNullId = McpTransportPolicy.internalErrorJsonRpc(null, err)
        assertEquals(JSONObject.NULL, withNullId.get("id"))

        val withStrId = McpTransportPolicy.internalErrorJsonRpc("req-1", err)
        assertEquals("req-1", withStrId.getString("id"))
    }
}

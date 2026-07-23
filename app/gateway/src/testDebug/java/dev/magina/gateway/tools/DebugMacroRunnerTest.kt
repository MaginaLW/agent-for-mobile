package dev.magina.gateway.tools

// debug-only macro catalog/runtime tests.

import dev.magina.gateway.core.ErrorCode
import dev.magina.gateway.core.GatewayError
import dev.magina.gateway.mcp.ToolRegistry
import org.json.JSONObject
import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class DebugMacroRunnerTest {
    @Test
    fun `debug dispatcher rejects every non-whitelisted macro before Android access`() {
        try {
            MacroRunner.run(JSONObject().put("name", "anything_else"))
            fail("expected fail-closed dispatcher")
        } catch (error: GatewayError) {
            assertEquals(ErrorCode.E_INVALID_ARG, error.code)
        }
    }

    @Test
    fun `macro schema is closed and exposes only the exact debug name`() {
        val schema = ToolRegistry.tools.single { it.name == "macro_run" }.inputSchema
        val properties = schema.getJSONObject("properties")
        val names = properties.getJSONObject("name").getJSONArray("enum")

        assertFalse(schema.getBoolean("additionalProperties"))
        assertEquals(setOf("name"), properties.keys().asSequence().toSet())
        assertEquals(1, names.length())
        assertEquals("p0_wechat_file_transfer_prepare", names.getString(0))
    }

    @Test
    fun `macro runtime rejects extra arguments before Android access`() {
        for ((key, value) in listOf("text" to "x", "contact" to "someone", "x" to 500, "y" to 1_800)) {
            val args = JSONObject()
                .put("name", "p0_wechat_file_transfer_prepare")
                .put(key, value)

            try {
                MacroRunner.run(args)
                fail("expected closed argument contract for $key")
            } catch (error: GatewayError) {
                assertEquals(ErrorCode.E_INVALID_ARG, error.code)
            }
        }
    }

    @Test
    fun `macro runtime rejects missing name`() {
        try {
            MacroRunner.run(JSONObject())
            fail("expected required name")
        } catch (error: GatewayError) {
            assertEquals(ErrorCode.E_INVALID_ARG, error.code)
        }
    }
}

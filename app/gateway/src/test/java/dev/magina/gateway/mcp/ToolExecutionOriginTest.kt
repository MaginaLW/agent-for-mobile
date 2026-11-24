package dev.magina.gateway.mcp

import dev.magina.gateway.core.SafetyPolicy
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ToolExecutionOriginTest {

    @Test
    fun `macro call origin appends non-duplicated audit token`() {
        val call = ToolRegistry.CallScope("ui_action", SafetyPolicy.fingerprint(JSONObject()))
        call.appendSafetyNote(ToolExecutionPipeline.originAuditToken(CallOrigin.MACRO))
        call.appendSafetyNote(ToolExecutionPipeline.originAuditToken(CallOrigin.MACRO))
        call.appendSafetyNote(ToolRegistry.OCR_REVERIFY_EXACT_NAV_NOTE)

        assertEquals("origin=macro;ocr_reverify=exact_nav", call.safetyNote)
    }

    @Test
    fun `facade exposes consistent catalog and channel mapping`() {
        val listedNames = (0 until ToolRegistry.listToolsJson().length())
            .map { ToolRegistry.listToolsJson().getJSONObject(it).getString("name") }
        assertEquals(ToolRegistry.tools.map { it.name }, listedNames)
        assertTrue("skillpack_lookup" in ToolRegistry.BLOCKED_APP_ALLOWED)
        assertEquals("a11y", ToolRegistry.channelOf("ui_snapshot"))
        assertEquals("intent", ToolRegistry.channelOf("open_uri"))
    }
}

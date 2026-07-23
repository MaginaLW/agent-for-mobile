package dev.magina.gateway.mcp

import org.junit.Assert.assertFalse
import org.junit.Test

class ReleaseMacroToolCatalogTest {
    @Test
    fun `release tool catalog does not publish macro run`() {
        assertFalse(ToolRegistry.tools.any { it.name == "macro_run" })
        assertFalse(ToolRegistry.listToolsJson().toString().contains("macro_run"))
    }
}

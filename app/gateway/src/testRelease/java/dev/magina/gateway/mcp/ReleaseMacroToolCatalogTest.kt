package dev.magina.gateway.mcp

import org.junit.Assert.assertFalse
import org.junit.Test

class ReleaseMacroToolCatalogTest {
    @Test
    fun `release tool catalog does not publish macro run or removed stub tools`() {
        assertFalse(ToolRegistry.tools.any { it.name == "macro_run" })
        val listJson = ToolRegistry.listToolsJson().toString()
        assertFalse(listJson.contains("macro_run"))
        listOf("app_stop", "notifications_list", "notification_reply", "ui_diff").forEach { removed ->
            assertFalse("不应继续发布占位工具 $removed", ToolRegistry.tools.any { it.name == removed })
        }
    }
}

package dev.magina.gateway.mcp

import dev.magina.gateway.core.Level
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ReleaseMacroToolCatalogTest {
    @Test
    fun `release tool catalog does not publish macro run or removed stub tools`() {
        assertFalse(ToolRegistry.tools.any { it.name == "macro_run" })
        val listJson = ToolRegistry.listToolsJson().toString()
        assertFalse(listJson.contains("macro_run"))
        listOf("app_stop", "notification_reply", "ui_diff").forEach { removed ->
            assertFalse("不应继续发布占位工具 $removed", ToolRegistry.tools.any { it.name == removed })
        }
    }

    @Test
    fun `notifications_list is registered as Level R on notif channel and excluded from blocked app bypass`() {
        val spec = ToolRegistry.tools.firstOrNull { it.name == "notifications_list" }
        assertNotNull("release 目录应注册 notifications_list", spec)
        assertEquals(Level.R, spec!!.level)
        assertEquals("notif", ToolRegistry.channelOf("notifications_list"))
        assertFalse(
            "notifications_list 不得加入 BLOCKED_APP_ALLOWED",
            "notifications_list" in ToolRegistry.BLOCKED_APP_ALLOWED,
        )
        val listedNames = (0 until ToolRegistry.listToolsJson().length())
            .map { ToolRegistry.listToolsJson().getJSONObject(it).getString("name") }
        assertTrue("tools/list 应包含 notifications_list", "notifications_list" in listedNames)
    }
}

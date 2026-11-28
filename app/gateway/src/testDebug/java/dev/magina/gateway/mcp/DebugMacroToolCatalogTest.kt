package dev.magina.gateway.mcp

import dev.magina.gateway.core.Level
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

class DebugMacroToolCatalogTest {
    @Test
    fun `probe region precheck stays read only and argument free`() {
        val tool = ToolRegistry.tools.firstOrNull { it.name == "p0_probe_region_state" }
        assertNotNull("debug 目录应发布候选区只读预检工具", tool)
        // 必须是 R：跑测前的预检要在 foreground_known=false 时也能调（W/D 会被硬门直接拒），
        // 而且它本身只看不改，升级成 W 等于给"只读自查"加上一层不必要的安全面。
        assertEquals(Level.R, tool!!.level)
        assertEquals(0, tool.inputSchema.getJSONObject("properties").length())
        assertEquals(0, tool.inputSchema.getJSONArray("required").length())
        assertEquals(false, tool.inputSchema.getBoolean("additionalProperties"))
    }

    @Test
    fun `unimplemented m1b stub tools are not exposed in tools list`() {
        listOf("app_stop", "notification_reply", "ui_diff").forEach { removed ->
            org.junit.Assert.assertFalse(
                "不应继续发布占位工具 $removed",
                ToolRegistry.tools.any { it.name == removed },
            )
        }
    }

    @Test
    fun `notifications_list is registered as Level R on notif channel and excluded from blocked app bypass`() {
        val spec = ToolRegistry.tools.firstOrNull { it.name == "notifications_list" }
        assertNotNull("debug 目录应注册 notifications_list", spec)
        assertEquals(Level.R, spec!!.level)
        assertEquals("notif", ToolRegistry.channelOf("notifications_list"))
        org.junit.Assert.assertFalse(
            "notifications_list 不得加入 BLOCKED_APP_ALLOWED",
            "notifications_list" in ToolRegistry.BLOCKED_APP_ALLOWED,
        )
        val listedNames = (0 until ToolRegistry.listToolsJson().length())
            .map { ToolRegistry.listToolsJson().getJSONObject(it).getString("name") }
        org.junit.Assert.assertTrue("tools/list 应包含 notifications_list", "notifications_list" in listedNames)
    }
}

package dev.magina.gateway.mcp

import dev.magina.gateway.core.Level
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SkillMacroToolCatalogTest {

    @Test
    fun `skill_macro_list and skill_macro_exec are registered with expected levels, channels, and blocked-app boundaries`() {
        val listSpec = ToolRegistry.tools.firstOrNull { it.name == "skill_macro_list" }
        val runSpec = ToolRegistry.tools.firstOrNull { it.name == "skill_macro_exec" }

        assertNotNull("必须注册 skill_macro_list", listSpec)
        assertNotNull("必须注册 skill_macro_exec", runSpec)

        assertEquals(Level.R, listSpec!!.level)
        assertEquals("api", ToolRegistry.channelOf("skill_macro_list"))
        assertTrue("skill_macro_list 应允许用于只读查宏目录", "skill_macro_list" in ToolRegistry.BLOCKED_APP_ALLOWED)

        assertEquals(Level.W, runSpec!!.level)
        assertEquals("macro", ToolRegistry.channelOf("skill_macro_exec"))
        assertFalse("skill_macro_exec 不得在敏感应用前台绕过放行", "skill_macro_exec" in ToolRegistry.BLOCKED_APP_ALLOWED)

        val names = (0 until ToolRegistry.listToolsJson().length())
            .map { ToolRegistry.listToolsJson().getJSONObject(it).getString("name") }
        assertTrue("skill_macro_list" in names)
        assertTrue("skill_macro_exec" in names)
    }
}

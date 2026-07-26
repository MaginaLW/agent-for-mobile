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
}

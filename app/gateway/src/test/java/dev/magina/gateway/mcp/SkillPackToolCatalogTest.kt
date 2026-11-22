package dev.magina.gateway.mcp

import dev.magina.gateway.core.Level
import dev.magina.gateway.core.SafetyContext
import dev.magina.gateway.core.SafetyDecision
import dev.magina.gateway.core.SafetyPolicy
import dev.magina.gateway.core.SafetyTarget
import java.io.File
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** 验证 skillpack_lookup 注册表契约与电商只读安全词表判定。 */
class SkillPackToolCatalogTest {

    private fun loadSafetyJson(): JSONObject {
        val userDir = requireNotNull(System.getProperty("user.dir")) { "JVM 未提供 user.dir" }
        var cursor: File? = File(userDir).absoluteFile
        while (cursor != null) {
            listOf(
                File(cursor, "gateway/src/main/assets/skillpack/safety.json"),
                File(cursor, "app/gateway/src/main/assets/skillpack/safety.json"),
            ).firstOrNull(File::isFile)?.let { return JSONObject(it.readText()) }
            cursor = cursor.parentFile
        }
        error("找不到 skillpack/safety.json（user.dir=$userDir）")
    }

    @Test
    fun `skillpack_lookup is Level R in tool catalog, api channel, and allowed on blocked foreground`() {
        val spec = ToolRegistry.tools.firstOrNull { it.name == "skillpack_lookup" }
        assertNotNull("ToolRegistry 必须注册 skillpack_lookup", spec)
        assertEquals(Level.R, spec!!.level)
        assertEquals("api", ToolRegistry.channelOf("skillpack_lookup"))
        assertTrue(
            "skillpack_lookup 应允许用于只读查黑名单原因",
            "skillpack_lookup" in ToolRegistry.BLOCKED_APP_ALLOWED,
        )

        val listed = ToolRegistry.listToolsJson()
        val names = (0 until listed.length()).map { listed.getJSONObject(it).getString("name") }
        assertTrue("tools/list 必须包含 skillpack_lookup", "skillpack_lookup" in names)
    }

    @Test
    fun `safety policy allows ecommerce logistics read and blocks purchase or delete clicks`() {
        val safety = loadSafetyJson()
        fun words(key: String) = safety.getJSONArray(key).let { arr ->
            (0 until arr.length()).map(arr::getString)
        }
        val policy = SafetyPolicy(
            irreversibleWords = words("danger_words"),
            retractableWords = words("send_words"),
            sensitiveTargets = words("sensitive_targets"),
            actionConfirmWords = words("action_confirm_words"),
        )
        val args = JSONObject().put("ref", "r1").put("action", "click")

        val allowed = policy.assess(
            toolName = "ui_action",
            level = Level.W,
            args = args,
            context = SafetyContext(
                packageName = "com.taobao.taobao",
                activityName = ".order.OrderListActivity",
                revision = 10,
                target = SafetyTarget(ref = "r1", text = "查看物流", bounds = "[0,0][100,40]", source = "a11y"),
            ),
        )
        assertTrue("查看物流应作为普通只读点击放行", allowed is SafetyDecision.Allowed)

        for (dangerText in listOf("立即购买", "去结算", "删除订单", "确认", "确定")) {
            val decision = policy.assess(
                toolName = "ui_action",
                level = Level.W,
                args = args,
                context = SafetyContext(
                    packageName = "com.jingdong.app.mall",
                    activityName = ".order.OrderDetailActivity",
                    revision = 11,
                    target = SafetyTarget(ref = "r2", text = dangerText, bounds = "[0,0][100,40]", source = "a11y"),
                ),
            )
            assertTrue("「$dangerText」必须触发确认卡", decision is SafetyDecision.ConfirmationRequired)
        }
    }
}

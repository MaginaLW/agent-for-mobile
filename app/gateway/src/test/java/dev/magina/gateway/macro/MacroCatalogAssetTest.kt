package dev.magina.gateway.macro

import dev.magina.gateway.core.SkillPack
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File

class MacroCatalogAssetTest {

    private fun skillpackDir(): File {
        val userDir = requireNotNull(System.getProperty("user.dir")) { "JVM 未提供 user.dir" }
        var cursor: File? = File(userDir).absoluteFile
        while (cursor != null) {
            listOf(
                File(cursor, "gateway/src/main/assets/skillpack"),
                File(cursor, "app/gateway/src/main/assets/skillpack"),
            ).firstOrNull(File::isDirectory)?.let { return it }
            cursor = cursor.parentFile
        }
        error("找不到 assets/skillpack 目录（user.dir=$userDir）")
    }

    private fun loadPack(): SkillPack {
        val dir = skillpackDir()
        return SkillPack(
            appsJson = JSONObject(File(dir, "apps.json").readText()),
            deeplinksJson = JSONObject(File(dir, "deeplinks.json").readText()),
            safetyJson = JSONObject(File(dir, "safety.json").readText()),
        )
    }

    private fun loadRealMacros(pack: SkillPack): MacroCatalog {
        val macroDir = File(skillpackDir(), "macros")
        val index = JSONObject(File(macroDir, "index.json").readText())
        val files = index.getJSONArray("files")
        assertTrue("macros/index.json 不得为空", files.length() >= 1)
        val raw = (0 until files.length()).map { idx ->
            JSONObject(File(macroDir, files.getString(idx)).readText())
        }
        return MacroCatalog(raw, pack::isBlockedApp)
    }

    @Test
    fun `real macro assets load cleanly and reflect verified vs unverified status`() {
        val pack = loadPack()
        val catalog = loadRealMacros(pack)

        val xhs = catalog.find("xhs_search_prepare")
        assertNotNull("必须加载 xhs_search_prepare", xhs)
        assertEquals("com.xingin.xhs", xhs!!.expectPackage)
        assertEquals("", xhs.verified)
        assertTrue(xhs.readonly)
        assertEquals(6, xhs.steps.size)

        val taobao = catalog.find("taobao_readonly_prepare")
        assertNotNull("必须加载 taobao_readonly_prepare", taobao)
        assertEquals("com.taobao.taobao", taobao!!.expectPackage)
        assertEquals("2026-11-25", taobao.verified)
        assertTrue(taobao.readonly)
        assertTrue(taobao.params.isEmpty())
        assertEquals(5, taobao.steps.size)

        val wechat = catalog.find("wechat_readonly_prepare")
        assertNotNull("必须加载 wechat_readonly_prepare", wechat)
        assertEquals("com.tencent.mm", wechat!!.expectPackage)
        assertEquals("", wechat.verified)
        assertTrue(wechat.readonly)
        assertTrue(wechat.params.isEmpty())
        assertEquals(5, wechat.steps.size)
        val wechatAllowedTools = setOf("foreground_app", "app_launch", "wait_for", "ui_snapshot")
        assertTrue(
            "wechat_readonly_prepare 严禁包含点击、输入或发送步骤",
            wechat.steps.all { it.tool in wechatAllowedTools },
        )

        for (spec in catalog.all()) {
            assertFalse(pack.isBlockedApp(spec.expectPackage))
            for (step in spec.steps) {
                if (step.tool == "app_launch") {
                    assertTrue(
                        "${spec.id}/${step.id} app_launch 必须使用 name 参数",
                        step.argsTemplate.optString("name").isNotBlank() && !step.argsTemplate.has("app"),
                    )
                }
            }
        }

        val listed = catalog.listForBrain()
        assertEquals(3, listed.getInt("count"))
        val byId = HashMap<String, JSONObject>()
        val macros = listed.getJSONArray("macros")
        for (i in 0 until macros.length()) {
            val item = macros.getJSONObject(i)
            assertFalse(pack.isBlockedApp(item.getString("expect_package")))
            byId[item.getString("id")] = item
        }
        assertEquals("candidate_unverified", byId.getValue("xhs_search_prepare").getString("status"))
        assertEquals("", byId.getValue("xhs_search_prepare").getString("verified"))
        assertEquals("verified", byId.getValue("taobao_readonly_prepare").getString("status"))
        assertEquals("2026-11-25", byId.getValue("taobao_readonly_prepare").getString("verified"))
        assertEquals("candidate_unverified", byId.getValue("wechat_readonly_prepare").getString("status"))
        assertEquals("", byId.getValue("wechat_readonly_prepare").getString("verified"))
    }

    @Test
    fun `rejects blocked expect_package, nested macro tool, undeclared param, empty steps, duplicate id, and bad verified date`() {
        val pack = loadPack()
        val base = JSONObject(
            """
            {
              "id": "sample_macro",
              "version": 1,
              "app": "小红书",
              "expect_package": "com.xingin.xhs",
              "description": "test",
              "readonly": true,
              "verified": "",
              "params": {"keyword": {"type": "string", "required": true, "min_length": 1, "max_length": 32}},
              "steps": [{"id": "s1", "tool": "foreground_app", "args": {}}]
            }
            """.trimIndent(),
        )

        fun assertRejected(mutator: (JSONObject) -> Unit, expectedMsgPart: String) {
            val copy = JSONObject(base.toString())
            mutator(copy)
            try {
                MacroContract.parseMacroSpec(copy, pack::isBlockedApp)
                fail("预期应抛出 IllegalArgumentException（$expectedMsgPart）")
            } catch (e: IllegalArgumentException) {
                assertTrue("异常消息未包含 $expectedMsgPart：${e.message}", e.message?.contains(expectedMsgPart) == true)
            }
        }

        assertRejected({ it.put("expect_package", "com.eg.android.AlipayGphone") }, "黑名单")
        assertRejected({
            it.put(
                "steps",
                JSONArray().put(JSONObject().put("id", "s1").put("tool", "skill_macro_exec").put("args", JSONObject())),
            )
        }, "白名单")
        assertRejected({
            it.put(
                "steps",
                JSONArray().put(
                    JSONObject().put("id", "s1").put("tool", "open_uri")
                        .put("args", JSONObject().put("uri", "xhsdiscover://search?q={{missing}}")),
                ),
            )
        }, "未声明参数")
        assertRejected({ it.put("steps", JSONArray()) }, "steps")
        assertRejected({ it.put("verified", "2026/11/24") }, "verified")

        try {
            MacroCatalog(listOf(base, JSONObject(base.toString())), pack::isBlockedApp)
            fail("重复宏 id 必须被拒绝")
        } catch (e: IllegalArgumentException) {
            assertTrue(e.message?.contains("重复宏定义") == true)
        }
    }
}

package dev.magina.gateway.macro

import dev.magina.gateway.core.SafetyPolicy
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
        assertEquals("2026-11-25", xhs.verified)
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
        assertEquals("2026-11-25", wechat.verified)
        assertTrue(wechat.readonly)
        assertTrue(wechat.params.isEmpty())
        assertEquals(5, wechat.steps.size)
        val wechatAllowedTools = setOf("foreground_app", "app_launch", "wait_for", "ui_snapshot")
        assertTrue(
            "wechat_readonly_prepare 严禁包含点击、输入或发送步骤",
            wechat.steps.all { it.tool in wechatAllowedTools },
        )

        val jd = catalog.find("jd_readonly_prepare")
        assertNotNull("必须加载 jd_readonly_prepare", jd)
        assertEquals("com.jingdong.app.mall", jd!!.expectPackage)
        assertEquals("", jd.verified)
        assertTrue(jd.readonly)
        assertTrue(jd.params.isEmpty())
        assertEquals(5, jd.steps.size)
        val jdReadonlyTools = setOf("foreground_app", "app_launch", "wait_for", "ui_snapshot")
        assertTrue(
            "jd_readonly_prepare 必须仅包含只读前置步骤",
            jd.steps.all { it.tool in jdReadonlyTools },
        )

        val bili = catalog.find("bili_readonly_prepare")
        assertNotNull("必须加载 bili_readonly_prepare", bili)
        assertEquals("tv.danmaku.bili", bili!!.expectPackage)
        assertEquals("2026-11-25", bili.verified)
        assertTrue(bili.readonly)
        assertTrue(bili.params.isEmpty())
        assertEquals(5, bili.steps.size)
        assertTrue(
            "bili_readonly_prepare 必须仅包含只读前置步骤",
            bili.steps.all { it.tool in jdReadonlyTools },
        )

        val safetyPolicy = SafetyPolicy(
            irreversibleWords = pack.dangerWords,
            retractableWords = pack.sendWords,
            sensitiveTargets = pack.sensitiveTargets,
            actionConfirmWords = pack.actionConfirmWords,
        )

        val biliFeed = catalog.find("bili_readonly_feed_prepare")
        assertNotNull("必须加载 bili_readonly_feed_prepare", biliFeed)
        assertEquals("tv.danmaku.bili", biliFeed!!.expectPackage)
        assertEquals("2026-11-26", biliFeed.verified)
        assertTrue(biliFeed.readonly)
        assertTrue(biliFeed.params.isEmpty())
        assertEquals(8, biliFeed.steps.size)
        assertTrue(
            "bili_readonly_feed_prepare 的 ui_action 必须配置 skip_if_ref_missing=true",
            biliFeed.steps.filter { it.tool == "ui_action" }.all { it.skipIfRefMissing },
        )
        val dismissPushStep = biliFeed.steps.first { it.id == "find_dismiss_push_prompt" }
        assertEquals("button", dismissPushStep.argsTemplate.optString("role"))
        assertEquals("暂不开启", dismissPushStep.argsTemplate.optString("text"))
        assertFalse(dismissPushStep.argsTemplate.optBoolean("scroll_search", true))
        assertFalse(
            "暂不开启不应命中危险/确认词",
            safetyPolicy.containsProtectedActionKeyword("暂不开启"),
        )

        val taobaoOrders = catalog.find("taobao_orders_prepare")
        assertNotNull("必须加载 taobao_orders_prepare", taobaoOrders)
        assertEquals("com.taobao.taobao", taobaoOrders!!.expectPackage)
        assertEquals("2026-11-26", taobaoOrders.verified)
        assertTrue(taobaoOrders.readonly)
        assertTrue(taobaoOrders.params.isEmpty())
        assertEquals(11, taobaoOrders.steps.size)
        assertTrue(
            "taobao_orders_prepare 的 ui_action 必须配置 skip_if_ref_missing=true",
            taobaoOrders.steps.filter { it.tool == "ui_action" }.all { it.skipIfRefMissing },
        )
        val findMyTaobao = taobaoOrders.steps.first { it.id == "find_my_taobao" }
        assertEquals("button", findMyTaobao.argsTemplate.optString("role"))
        assertEquals("我的淘宝", findMyTaobao.argsTemplate.optString("desc"))
        assertFalse(findMyTaobao.argsTemplate.optBoolean("scroll_search", true))
        val findAllOrders = taobaoOrders.steps.first { it.id == "find_all_orders" }
        assertEquals("button", findAllOrders.argsTemplate.optString("role"))
        assertEquals("我的订单", findAllOrders.argsTemplate.optString("desc"))
        assertFalse(findAllOrders.argsTemplate.optBoolean("scroll_search", true))
        for (targetLabel in listOf("我的淘宝", "我的订单", "我的订单全部", "全部订单")) {
            assertFalse(
                "$targetLabel 不应命中危险/确认词",
                safetyPolicy.containsProtectedActionKeyword(targetLabel),
            )
        }

        val settingsCheck = catalog.find("settings_state_readonly_check")
        assertNotNull("必须加载 settings_state_readonly_check", settingsCheck)
        assertEquals("com.android.settings", settingsCheck!!.expectPackage)
        assertEquals("2026-11-27", settingsCheck.verified)
        assertTrue(settingsCheck.readonly)
        assertTrue(settingsCheck.params.containsKey("key"))
        assertEquals(1, settingsCheck.steps.size)
        assertEquals("system_get_state", settingsCheck.steps[0].tool)
        assertTrue(settingsCheck.steps[0].captureAsFinalSnapshot)

        val builtinPrepareExpectations = listOf(
            "gallery_readonly_prepare" to "com.vivo.gallery",
            "clock_readonly_prepare" to "com.android.BBKClock",
            "calendar_readonly_prepare" to "com.bbk.calendar",
            "notes_readonly_prepare" to "com.android.notes",
            "filemanager_readonly_prepare" to "com.android.filemanager",
            "calculator_readonly_prepare" to "com.android.bbkcalculator",
        )
        for ((macroId, expectedPkg) in builtinPrepareExpectations) {
            val spec = catalog.find(macroId)
            assertNotNull("必须加载 $macroId", spec)
            assertEquals(expectedPkg, spec!!.expectPackage)
            assertEquals("2026-11-27", spec.verified)
            assertTrue("$macroId 必须为只读宏", spec.readonly)
            assertTrue("$macroId 应无参数", spec.params.isEmpty())
            assertEquals(5, spec.steps.size)
            assertTrue(
                "$macroId 必须仅包含只读前置步骤",
                spec.steps.all { it.tool in jdReadonlyTools },
            )
        }

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
        assertEquals(14, listed.getInt("count"))
        val byId = HashMap<String, JSONObject>()
        val macros = listed.getJSONArray("macros")
        for (i in 0 until macros.length()) {
            val item = macros.getJSONObject(i)
            assertFalse(pack.isBlockedApp(item.getString("expect_package")))
            byId[item.getString("id")] = item
        }
        assertEquals("verified", byId.getValue("xhs_search_prepare").getString("status"))
        assertEquals("2026-11-25", byId.getValue("xhs_search_prepare").getString("verified"))
        assertEquals("verified", byId.getValue("taobao_readonly_prepare").getString("status"))
        assertEquals("2026-11-25", byId.getValue("taobao_readonly_prepare").getString("verified"))
        assertEquals("verified", byId.getValue("wechat_readonly_prepare").getString("status"))
        assertEquals("2026-11-25", byId.getValue("wechat_readonly_prepare").getString("verified"))
        assertEquals("candidate_unverified", byId.getValue("jd_readonly_prepare").getString("status"))
        assertEquals("", byId.getValue("jd_readonly_prepare").getString("verified"))
        assertEquals("verified", byId.getValue("bili_readonly_prepare").getString("status"))
        assertEquals("2026-11-25", byId.getValue("bili_readonly_prepare").getString("verified"))
        assertEquals("verified", byId.getValue("bili_readonly_feed_prepare").getString("status"))
        assertEquals("2026-11-26", byId.getValue("bili_readonly_feed_prepare").getString("verified"))
        assertEquals("verified", byId.getValue("taobao_orders_prepare").getString("status"))
        assertEquals("2026-11-26", byId.getValue("taobao_orders_prepare").getString("verified"))
        for (verifiedBuiltinId in listOf(
            "settings_state_readonly_check",
            "gallery_readonly_prepare",
            "clock_readonly_prepare",
            "calendar_readonly_prepare",
            "notes_readonly_prepare",
            "filemanager_readonly_prepare",
            "calculator_readonly_prepare",
        )) {
            assertEquals("verified", byId.getValue(verifiedBuiltinId).getString("status"))
            assertEquals("2026-11-27", byId.getValue(verifiedBuiltinId).getString("verified"))
        }
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
        assertRejected({
            it.put(
                "steps",
                JSONArray().put(
                    JSONObject().put("id", "s1").put("tool", "ui_action")
                        .put("args", JSONObject().put("ref", "e1").put("action", "click"))
                        .put("skip_if_ref_missing", true),
                ),
            )
        }, "未引用")
        assertRejected({
            it.put(
                "steps",
                JSONArray().put(
                    JSONObject().put("id", "s1").put("tool", "ui_action")
                        .put("args", JSONObject().put("ref", "{{ref:missing}}").put("action", "click"))
                        .put("skip_if_ref_missing", true),
                ),
            )
        }, "未由前序步骤 save_ref 声明")

        try {
            MacroCatalog(listOf(base, JSONObject(base.toString())), pack::isBlockedApp)
            fail("重复宏 id 必须被拒绝")
        } catch (e: IllegalArgumentException) {
            assertTrue(e.message?.contains("重复宏定义") == true)
        }
    }
}

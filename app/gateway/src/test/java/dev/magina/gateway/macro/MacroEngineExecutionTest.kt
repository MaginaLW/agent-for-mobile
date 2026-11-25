package dev.magina.gateway.macro

import dev.magina.gateway.core.Envelope
import dev.magina.gateway.core.ErrorCode
import dev.magina.gateway.core.GatewayError
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File

class MacroEngineExecutionTest {

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
        error("找不到 skillpack 目录")
    }

    private fun loadXhsCatalog(): MacroCatalog {
        val macroJson = JSONObject(File(skillpackDir(), "macros/xhs_search_prepare.json").readText())
        return MacroCatalog(listOf(macroJson)) { pkg ->
            pkg != null && pkg.startsWith("com.eg.android.AlipayGphone")
        }
    }

    private fun ctx(app: String, known: Boolean = true): JSONObject =
        JSONObject().put("app", app).put("activity", "").put("foreground_known", known)

    @Test
    fun `xhs_search_prepare completes end-to-end with urlencoded Chinese keyword and returns final snapshot`() {
        val catalog = loadXhsCatalog()
        val calls = mutableListOf<Pair<String, JSONObject>>()
        val engine = MacroEngine(
            catalog = catalog,
            isBlockedApp = { false },
            loginWallKeywordsForPackage = { listOf("登录", "请先登录") },
        ) { tool, args ->
            calls.add(tool to args)
            when (tool) {
                "foreground_app" -> Envelope.ok(JSONObject().put("package", "com.android.launcher"), ctx("com.android.launcher"), "a-1")
                "open_uri" -> Envelope.ok(JSONObject().put("opened", true).put("foreground_verified", true), ctx("com.xingin.xhs"), "a-2")
                "wait_for" -> Envelope.ok(JSONObject().put("satisfied", true), ctx("com.xingin.xhs"), "a-3")
                "ui_find" -> Envelope.err(GatewayError(ErrorCode.E_NOT_FOUND, "未见全部标签"), ctx("com.xingin.xhs"), "a-4")
                "ui_snapshot" -> Envelope.ok(
                    JSONObject()
                        .put("blocking_overlay", false)
                        .put("count", 2)
                        .put("elements", JSONArray().put(JSONObject().put("ref", "e1").put("text", "东京三日游攻略").put("desc", ""))),
                    ctx("com.xingin.xhs"),
                    "a-5",
                )
                else -> error("unexpected tool: $tool")
            }
        }

        val result = engine.run(
            JSONObject().put("name", "xhs_search_prepare").put("params", JSONObject().put("keyword", "东京三日游")),
        )

        assertEquals("completed", result.getString("status"))
        assertEquals(6, result.getInt("steps_executed"))
        assertEquals(listOf("check_all_tab"), (0 until result.getJSONArray("skipped_steps").length()).map {
            result.getJSONArray("skipped_steps").getString(it)
        })
        assertEquals(
            "xhsdiscover://search/result?keyword=%E4%B8%9C%E4%BA%AC%E4%B8%89%E6%97%A5%E6%B8%B8",
            calls[1].second.getString("uri"),
        )
        assertTrue(result.has("final_snapshot"))
        assertEquals(2, result.getJSONObject("final_snapshot").getInt("count"))
    }

    @Test
    fun `hands off cleanly without calling open_uri when already in xiaohongshu`() {
        val calls = mutableListOf<String>()
        val engine = MacroEngine(
            catalog = loadXhsCatalog(),
            isBlockedApp = { false },
            loginWallKeywordsForPackage = { emptyList() },
        ) { tool, _ ->
            calls.add(tool)
            Envelope.ok(JSONObject().put("package", "com.xingin.xhs"), ctx("com.xingin.xhs"), "a-1")
        }

        val res = engine.run(
            JSONObject().put("name", "xhs_search_prepare").put("params", JSONObject().put("keyword", "东京三日游")),
        )
        assertEquals("handoff_required", res.getString("status"))
        assertTrue(res.getBoolean("handoff_allowed"))
        assertEquals("check_foreground", res.getString("failed_step"))
        assertEquals("HANDOFF_PRECONDITION", res.getString("failure_code"))
        assertFalse(res.getBoolean("blocker_detected"))
        assertEquals(listOf("foreground_app"), calls)
    }

    @Test
    fun `detects vivo appfilter blocker and login wall as handoff_required`() {
        val blockerEngine = MacroEngine(
            catalog = loadXhsCatalog(),
            isBlockedApp = { false },
            loginWallKeywordsForPackage = { emptyList() },
        ) { tool, _ ->
            when (tool) {
                "foreground_app" -> Envelope.ok(JSONObject().put("package", "com.android.launcher"), ctx("com.android.launcher"), "a-1")
                "open_uri" -> Envelope.err(
                    GatewayError(
                        ErrorCode.E_VERIFY_FAIL,
                        "未切到 com.xingin.xhs",
                        extra = JSONObject().put("actual_package", "com.vivo.appfilter"),
                    ),
                    ctx("com.vivo.appfilter"),
                    "a-2",
                )
                else -> error("unexpected tool: $tool")
            }
        }
        val blockerRes = blockerEngine.run(
            JSONObject().put("name", "xhs_search_prepare").put("params", JSONObject().put("keyword", "东京")),
        )
        assertEquals("handoff_required", blockerRes.getString("status"))
        assertTrue(blockerRes.getBoolean("blocker_detected"))
        assertEquals("open_search_deeplink", blockerRes.getString("failed_step"))

        val loginWallEngine = MacroEngine(
            catalog = loadXhsCatalog(),
            isBlockedApp = { false },
            loginWallKeywordsForPackage = { listOf("请先登录", "手机号登录") },
        ) { tool, _ ->
            when (tool) {
                "foreground_app" -> Envelope.ok(JSONObject().put("package", "com.android.launcher"), ctx("com.android.launcher"), "a-1")
                "open_uri", "wait_for", "ui_find" -> Envelope.ok(JSONObject(), ctx("com.xingin.xhs"), "a-2")
                "ui_snapshot" -> Envelope.ok(
                    JSONObject()
                        .put("blocking_overlay", false)
                        .put("elements", JSONArray().put(JSONObject().put("text", "请先登录后查看").put("desc", ""))),
                    ctx("com.xingin.xhs"),
                    "a-3",
                )
                else -> error("unexpected tool: $tool")
            }
        }
        val loginRes = loginWallEngine.run(
            JSONObject().put("name", "xhs_search_prepare").put("params", JSONObject().put("keyword", "东京")),
        )
        assertEquals("handoff_required", loginRes.getString("status"))
        assertEquals("LOGIN_WALL", loginRes.getString("failure_code"))
        assertTrue(loginRes.getBoolean("blocker_detected"))
    }

    @Test
    fun `safety terminal errors abort immediately with matching ErrorCode and handoff_allowed false`() {
        for (terminalCode in listOf(
            ErrorCode.E_BLOCKED,
            ErrorCode.E_CONFIRM_TIMEOUT,
            ErrorCode.E_STALE_REF,
            ErrorCode.E_CONFIRM_REQUIRED,
        )) {
            val calls = mutableListOf<String>()
            val engine = MacroEngine(
                catalog = loadXhsCatalog(),
                isBlockedApp = { false },
                loginWallKeywordsForPackage = { emptyList() },
            ) { tool, _ ->
                calls.add(tool)
                when (tool) {
                    "foreground_app" -> Envelope.ok(JSONObject().put("package", "com.android.launcher"), ctx("com.android.launcher"), "a-1")
                    "open_uri" -> Envelope.err(GatewayError(terminalCode, "safety fail"), ctx("com.android.launcher"), "a-2")
                    else -> error("后续步骤绝不允许在安全终态后执行: $tool")
                }
            }
            try {
                engine.run(
                    JSONObject().put("name", "xhs_search_prepare").put("params", JSONObject().put("keyword", "东京")),
                )
                fail("预期安全终态 $terminalCode 必须抛 GatewayError")
            } catch (e: GatewayError) {
                assertEquals(terminalCode, e.code)
                assertFalse(e.retryable)
                assertEquals(false, e.extra?.getBoolean("handoff_allowed"))
                assertEquals("open_search_deeplink", e.extra?.getString("failed_step"))
                assertEquals(listOf("foreground_app", "open_uri"), calls)
            }
        }
    }

    @Test
    fun `clears saved ref across mutating step and rejects invalid params`() {
        val rawMacro = JSONObject(
            """
            {
              "id": "click_then_reuse_ref",
              "version": 1,
              "app": "小红书",
              "expect_package": "com.xingin.xhs",
              "description": "verify savedRef cleared after mutation",
              "readonly": true,
              "verified": "",
              "params": {"q": {"type": "string", "required": true, "min_length": 1, "max_length": 10}},
              "steps": [
                {"id": "find1", "tool": "ui_find", "args": {"text": "{{q}}"}, "save_ref": "target"},
                {"id": "click1", "tool": "ui_action", "args": {"ref": "{{ref:target}}", "action": "click"}},
                {"id": "click2_stale", "tool": "ui_action", "args": {"ref": "{{ref:target}}", "action": "click"}}
              ]
            }
            """.trimIndent(),
        )
        val engine = MacroEngine(
            catalog = MacroCatalog(listOf(rawMacro)) { false },
            isBlockedApp = { false },
            loginWallKeywordsForPackage = { emptyList() },
        ) { tool, _ ->
            when (tool) {
                "ui_find" -> Envelope.ok(
                    JSONObject().put("matches", JSONArray().put(JSONObject().put("ref", "e-9"))),
                    ctx("com.xingin.xhs"),
                    "a-1",
                )
                "ui_action" -> Envelope.ok(JSONObject().put("done", true), ctx("com.xingin.xhs"), "a-2")
                else -> error("unexpected $tool")
            }
        }

        try {
            engine.run(JSONObject().put("name", "click_then_reuse_ref").put("params", JSONObject().put("q", "搜索")))
            fail("跨写动作复用旧 ref 必须抛 E_STALE_REF")
        } catch (e: GatewayError) {
            assertEquals(ErrorCode.E_STALE_REF, e.code)
        }

        for (badArgs in listOf(
            JSONObject().put("name", "click_then_reuse_ref"),
            JSONObject().put("name", "click_then_reuse_ref").put("params", JSONObject().put("q", "12345678901")),
            JSONObject().put("name", "click_then_reuse_ref").put("params", JSONObject().put("q", "ok").put("extra", "bad")),
        )) {
            try {
                engine.run(badArgs)
                fail("非法参数应抛 E_INVALID_ARG: $badArgs")
            } catch (e: GatewayError) {
                assertEquals(ErrorCode.E_INVALID_ARG, e.code)
            }
        }
    }
}

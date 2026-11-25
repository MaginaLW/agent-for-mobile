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

    private fun loadRealCatalog(): MacroCatalog {
        val macroDir = File(skillpackDir(), "macros")
        val files = JSONObject(File(macroDir, "index.json").readText()).getJSONArray("files")
        val raw = (0 until files.length()).map { idx ->
            JSONObject(File(macroDir, files.getString(idx)).readText())
        }
        return MacroCatalog(raw) { pkg ->
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

    @Test
    fun `taobao_readonly_prepare dispatches ToolCatalog-aligned args and captures final snapshot`() {
        val calls = mutableListOf<Pair<String, JSONObject>>()
        val engine = MacroEngine(
            catalog = loadRealCatalog(),
            isBlockedApp = { false },
            loginWallKeywordsForPackage = { listOf("登录", "请先登录") },
        ) { tool, args ->
            calls.add(tool to args)
            when (tool) {
                "foreground_app" -> Envelope.ok(JSONObject().put("package", "com.android.launcher"), ctx("com.android.launcher"), "t-1")
                "app_launch" -> Envelope.ok(JSONObject().put("launched", true).put("foreground_verified", true), ctx("com.taobao.taobao"), "t-2")
                "wait_for" -> Envelope.ok(JSONObject().put("met", true), ctx("com.taobao.taobao"), "t-3")
                "ui_snapshot" -> Envelope.ok(
                    JSONObject()
                        .put("blocking_overlay", false)
                        .put("count", 1)
                        .put("elements", JSONArray().put(JSONObject().put("ref", "e1").put("text", "我的淘宝").put("desc", ""))),
                    ctx("com.taobao.taobao"),
                    "t-4",
                )
                else -> error("unexpected tool: $tool")
            }
        }

        val res = engine.run(JSONObject().put("name", "taobao_readonly_prepare").put("params", JSONObject()))
        assertEquals("completed", res.getString("status"))
        assertEquals(5, res.getInt("steps_executed"))
        assertTrue(res.has("final_snapshot"))
        assertEquals(listOf("foreground_app", "app_launch", "wait_for", "wait_for", "ui_snapshot"), calls.map { it.first })

        assertEquals(0, calls[0].second.length())
        assertEquals("淘宝", calls[1].second.getString("name"))
        assertFalse(calls[1].second.has("app"))
        assertEquals("app_foreground", calls[2].second.getString("condition"))
        assertEquals("com.taobao.taobao", calls[2].second.getString("package"))
        assertEquals(5000, calls[2].second.getInt("timeout_ms"))
        assertEquals("idle", calls[3].second.getString("condition"))
        assertEquals(800, calls[3].second.getInt("quiet_ms"))
        assertEquals(5000, calls[3].second.getInt("timeout_ms"))
        assertEquals("full", calls[4].second.getString("scope"))
    }

    @Test
    fun `taobao_readonly_prepare hands off on appfilter blocker and login wall`() {
        val blockerCalls = mutableListOf<String>()
        val blockerEngine = MacroEngine(
            catalog = loadRealCatalog(),
            isBlockedApp = { false },
            loginWallKeywordsForPackage = { listOf("请先登录") },
        ) { tool, _ ->
            blockerCalls.add(tool)
            Envelope.ok(JSONObject().put("package", "com.vivo.appfilter"), ctx("com.vivo.appfilter"), "tb-1")
        }
        val blockerRes = blockerEngine.run(JSONObject().put("name", "taobao_readonly_prepare").put("params", JSONObject()))
        assertEquals("handoff_required", blockerRes.getString("status"))
        assertEquals("SYSTEM_BLOCKER", blockerRes.getString("failure_code"))
        assertTrue(blockerRes.getBoolean("blocker_detected"))
        assertEquals(listOf("foreground_app"), blockerCalls)

        val loginEngine = MacroEngine(
            catalog = loadRealCatalog(),
            isBlockedApp = { false },
            loginWallKeywordsForPackage = { listOf("请先登录", "手机号登录") },
        ) { tool, _ ->
            when (tool) {
                "foreground_app" -> Envelope.ok(JSONObject().put("package", "com.android.launcher"), ctx("com.android.launcher"), "tl-1")
                "app_launch", "wait_for" -> Envelope.ok(JSONObject(), ctx("com.taobao.taobao"), "tl-2")
                "ui_snapshot" -> Envelope.ok(
                    JSONObject()
                        .put("blocking_overlay", false)
                        .put("elements", JSONArray().put(JSONObject().put("text", "请先登录后查看订单").put("desc", ""))),
                    ctx("com.taobao.taobao"),
                    "tl-3",
                )
                else -> error("unexpected tool: $tool")
            }
        }
        val loginRes = loginEngine.run(JSONObject().put("name", "taobao_readonly_prepare").put("params", JSONObject()))
        assertEquals("handoff_required", loginRes.getString("status"))
        assertEquals("LOGIN_WALL", loginRes.getString("failure_code"))
        assertTrue(loginRes.getBoolean("blocker_detected"))
    }

    @Test
    fun `wechat_readonly_prepare dispatches ToolCatalog-aligned readonly steps without input or click`() {
        val calls = mutableListOf<Pair<String, JSONObject>>()
        val engine = MacroEngine(
            catalog = loadRealCatalog(),
            isBlockedApp = { false },
            loginWallKeywordsForPackage = { emptyList() },
        ) { tool, args ->
            calls.add(tool to args)
            when (tool) {
                "foreground_app" -> Envelope.ok(JSONObject().put("package", "com.android.launcher"), ctx("com.android.launcher"), "w-1")
                "app_launch" -> Envelope.ok(JSONObject().put("launched", true).put("foreground_verified", true), ctx("com.tencent.mm"), "w-2")
                "wait_for" -> Envelope.ok(JSONObject().put("met", true), ctx("com.tencent.mm"), "w-3")
                "ui_snapshot" -> Envelope.ok(
                    JSONObject()
                        .put("blocking_overlay", false)
                        .put("count", 1)
                        .put("elements", JSONArray().put(JSONObject().put("ref", "e1").put("text", "微信").put("desc", ""))),
                    ctx("com.tencent.mm"),
                    "w-4",
                )
                else -> error("unexpected tool: $tool")
            }
        }

        val res = engine.run(JSONObject().put("name", "wechat_readonly_prepare").put("params", JSONObject()))
        assertEquals("completed", res.getString("status"))
        assertEquals(5, res.getInt("steps_executed"))
        assertTrue(res.has("final_snapshot"))
        assertEquals(listOf("foreground_app", "app_launch", "wait_for", "wait_for", "ui_snapshot"), calls.map { it.first })

        assertEquals(0, calls[0].second.length())
        assertEquals("微信", calls[1].second.getString("name"))
        assertFalse(calls[1].second.has("app"))
        assertEquals("app_foreground", calls[2].second.getString("condition"))
        assertEquals("com.tencent.mm", calls[2].second.getString("package"))
        assertEquals(5000, calls[2].second.getInt("timeout_ms"))
        assertEquals("idle", calls[3].second.getString("condition"))
        assertEquals(800, calls[3].second.getInt("quiet_ms"))
        assertEquals(5000, calls[3].second.getInt("timeout_ms"))
        assertEquals("full", calls[4].second.getString("scope"))
    }

    @Test
    fun `jd_readonly_prepare completes 5 readonly steps with app_launch name 京东 and returns final snapshot`() {
        val calls = mutableListOf<Pair<String, JSONObject>>()
        val engine = MacroEngine(
            catalog = loadRealCatalog(),
            isBlockedApp = { false },
            loginWallKeywordsForPackage = { listOf("登录", "请先登录") },
        ) { tool, args ->
            calls.add(tool to args)
            when (tool) {
                "foreground_app" -> Envelope.ok(JSONObject().put("package", "com.android.launcher"), ctx("com.android.launcher"), "j-1")
                "app_launch" -> Envelope.ok(JSONObject().put("launched", true).put("foreground_verified", true), ctx("com.jingdong.app.mall"), "j-2")
                "wait_for" -> Envelope.ok(JSONObject().put("met", true), ctx("com.jingdong.app.mall"), "j-3")
                "ui_snapshot" -> Envelope.ok(
                    JSONObject()
                        .put("blocking_overlay", false)
                        .put("count", 1)
                        .put("elements", JSONArray().put(JSONObject().put("ref", "e1").put("text", "我的京东").put("desc", ""))),
                    ctx("com.jingdong.app.mall"),
                    "j-4",
                )
                else -> error("unexpected tool: $tool")
            }
        }

        val res = engine.run(JSONObject().put("name", "jd_readonly_prepare").put("params", JSONObject()))
        assertEquals("completed", res.getString("status"))
        assertEquals(5, res.getInt("steps_executed"))
        assertTrue(res.has("final_snapshot"))
        assertEquals(1, res.getJSONObject("final_snapshot").getInt("count"))
        assertEquals(listOf("foreground_app", "app_launch", "wait_for", "wait_for", "ui_snapshot"), calls.map { it.first })

        assertEquals(0, calls[0].second.length())
        assertEquals("京东", calls[1].second.getString("name"))
        assertFalse(calls[1].second.has("app"))
        assertEquals("app_foreground", calls[2].second.getString("condition"))
        assertEquals("com.jingdong.app.mall", calls[2].second.getString("package"))
        assertEquals(5000, calls[2].second.getInt("timeout_ms"))
        assertEquals("idle", calls[3].second.getString("condition"))
        assertEquals(800, calls[3].second.getInt("quiet_ms"))
        assertEquals(5000, calls[3].second.getInt("timeout_ms"))
        assertEquals("full", calls[4].second.getString("scope"))
    }

    @Test
    fun `jd_readonly_prepare hands off on SYSTEM_BLOCKER and LOGIN_WALL`() {
        val blockerCalls = mutableListOf<String>()
        val blockerEngine = MacroEngine(
            catalog = loadRealCatalog(),
            isBlockedApp = { false },
            loginWallKeywordsForPackage = { listOf("请先登录") },
        ) { tool, _ ->
            blockerCalls.add(tool)
            Envelope.ok(JSONObject().put("package", "com.vivo.appfilter"), ctx("com.vivo.appfilter"), "jb-1")
        }
        val blockerRes = blockerEngine.run(JSONObject().put("name", "jd_readonly_prepare").put("params", JSONObject()))
        assertEquals("handoff_required", blockerRes.getString("status"))
        assertEquals("SYSTEM_BLOCKER", blockerRes.getString("failure_code"))
        assertTrue(blockerRes.getBoolean("blocker_detected"))
        assertEquals(listOf("foreground_app"), blockerCalls)

        val loginEngine = MacroEngine(
            catalog = loadRealCatalog(),
            isBlockedApp = { false },
            loginWallKeywordsForPackage = { listOf("请先登录", "手机号登录") },
        ) { tool, _ ->
            when (tool) {
                "foreground_app" -> Envelope.ok(JSONObject().put("package", "com.android.launcher"), ctx("com.android.launcher"), "jl-1")
                "app_launch", "wait_for" -> Envelope.ok(JSONObject(), ctx("com.jingdong.app.mall"), "jl-2")
                "ui_snapshot" -> Envelope.ok(
                    JSONObject()
                        .put("blocking_overlay", false)
                        .put("elements", JSONArray().put(JSONObject().put("text", "请先登录后查看订单").put("desc", ""))),
                    ctx("com.jingdong.app.mall"),
                    "jl-3",
                )
                else -> error("unexpected tool: $tool")
            }
        }
        val loginRes = loginEngine.run(JSONObject().put("name", "jd_readonly_prepare").put("params", JSONObject()))
        assertEquals("handoff_required", loginRes.getString("status"))
        assertEquals("LOGIN_WALL", loginRes.getString("failure_code"))
        assertTrue(loginRes.getBoolean("blocker_detected"))
    }

    @Test
    fun `bili_readonly_prepare completes 5 readonly steps with app_launch name 哔哩哔哩 and returns final snapshot`() {
        val calls = mutableListOf<Pair<String, JSONObject>>()
        val engine = MacroEngine(
            catalog = loadRealCatalog(),
            isBlockedApp = { false },
            loginWallKeywordsForPackage = { listOf("手机号登录", "扫码登录", "一键登录", "请先登录", "登录后即可") },
        ) { tool, args ->
            calls.add(tool to args)
            when (tool) {
                "foreground_app" -> Envelope.ok(JSONObject().put("package", "com.android.launcher"), ctx("com.android.launcher"), "b-1")
                "app_launch" -> Envelope.ok(JSONObject().put("launched", true).put("foreground_verified", true), ctx("tv.danmaku.bili"), "b-2")
                "wait_for" -> Envelope.ok(JSONObject().put("met", true), ctx("tv.danmaku.bili"), "b-3")
                "ui_snapshot" -> Envelope.ok(
                    JSONObject()
                        .put("blocking_overlay", false)
                        .put("count", 2)
                        .put(
                            "elements",
                            JSONArray()
                                .put(JSONObject().put("ref", "e0").put("text", "登录").put("desc", ""))
                                .put(JSONObject().put("ref", "e1").put("text", "公开视频推荐").put("desc", "")),
                        ),
                    ctx("tv.danmaku.bili"),
                    "b-4",
                )
                else -> error("unexpected tool: $tool")
            }
        }

        val res = engine.run(JSONObject().put("name", "bili_readonly_prepare").put("params", JSONObject()))
        assertEquals("completed", res.getString("status"))
        assertEquals(5, res.getInt("steps_executed"))
        assertTrue(res.has("final_snapshot"))
        assertEquals(2, res.getJSONObject("final_snapshot").getInt("count"))
        assertEquals(listOf("foreground_app", "app_launch", "wait_for", "wait_for", "ui_snapshot"), calls.map { it.first })

        assertEquals(0, calls[0].second.length())
        assertEquals("哔哩哔哩", calls[1].second.getString("name"))
        assertFalse(calls[1].second.has("app"))
        assertEquals("app_foreground", calls[2].second.getString("condition"))
        assertEquals("tv.danmaku.bili", calls[2].second.getString("package"))
        assertEquals(5000, calls[2].second.getInt("timeout_ms"))
        assertEquals("idle", calls[3].second.getString("condition"))
        assertEquals(800, calls[3].second.getInt("quiet_ms"))
        assertEquals(5000, calls[3].second.getInt("timeout_ms"))
        assertEquals("full", calls[4].second.getString("scope"))
    }

    @Test
    fun `bili_readonly_prepare hands off on SYSTEM_BLOCKER and LOGIN_WALL`() {
        val blockerCalls = mutableListOf<String>()
        val blockerEngine = MacroEngine(
            catalog = loadRealCatalog(),
            isBlockedApp = { false },
            loginWallKeywordsForPackage = { listOf("请先登录") },
        ) { tool, _ ->
            blockerCalls.add(tool)
            Envelope.ok(JSONObject().put("package", "com.vivo.appfilter"), ctx("com.vivo.appfilter"), "bb-1")
        }
        val blockerRes = blockerEngine.run(JSONObject().put("name", "bili_readonly_prepare").put("params", JSONObject()))
        assertEquals("handoff_required", blockerRes.getString("status"))
        assertEquals("SYSTEM_BLOCKER", blockerRes.getString("failure_code"))
        assertTrue(blockerRes.getBoolean("blocker_detected"))
        assertEquals(listOf("foreground_app"), blockerCalls)

        val loginEngine = MacroEngine(
            catalog = loadRealCatalog(),
            isBlockedApp = { false },
            loginWallKeywordsForPackage = { listOf("手机号登录", "扫码登录", "一键登录", "请先登录", "登录后即可") },
        ) { tool, _ ->
            when (tool) {
                "foreground_app" -> Envelope.ok(JSONObject().put("package", "com.android.launcher"), ctx("com.android.launcher"), "bl-1")
                "app_launch", "wait_for" -> Envelope.ok(JSONObject(), ctx("tv.danmaku.bili"), "bl-2")
                "ui_snapshot" -> Envelope.ok(
                    JSONObject()
                        .put("blocking_overlay", false)
                        .put("elements", JSONArray().put(JSONObject().put("text", "请先登录后继续观看").put("desc", ""))),
                    ctx("tv.danmaku.bili"),
                    "bl-3",
                )
                else -> error("unexpected tool: $tool")
            }
        }
        val loginRes = loginEngine.run(JSONObject().put("name", "bili_readonly_prepare").put("params", JSONObject()))
        assertEquals("handoff_required", loginRes.getString("status"))
        assertEquals("LOGIN_WALL", loginRes.getString("failure_code"))
        assertTrue(loginRes.getBoolean("blocker_detected"))
    }

    @Test
    fun `bili_readonly_feed_prepare clicks dismiss prompt when unique and skips cleanly when absent or ambiguous`() {
        val clickCalls = mutableListOf<Pair<String, JSONObject>>()
        val clickEngine = MacroEngine(
            catalog = loadRealCatalog(),
            isBlockedApp = { false },
            loginWallKeywordsForPackage = { listOf("手机号登录", "扫码登录", "一键登录", "请先登录", "登录后即可") },
        ) { tool, args ->
            clickCalls.add(tool to args)
            when (tool) {
                "foreground_app" -> Envelope.ok(JSONObject().put("package", "com.android.launcher"), ctx("com.android.launcher"), "bf-1")
                "app_launch" -> Envelope.ok(JSONObject().put("launched", true).put("foreground_verified", true), ctx("tv.danmaku.bili"), "bf-2")
                "wait_for" -> Envelope.ok(JSONObject().put("met", true), ctx("tv.danmaku.bili"), "bf-3")
                "ui_find" -> Envelope.ok(
                    JSONObject().put("matches", JSONArray().put(JSONObject().put("ref", "e-dismiss").put("text", "暂不开启"))),
                    ctx("tv.danmaku.bili"),
                    "bf-4",
                )
                "ui_action" -> Envelope.ok(JSONObject().put("clicked", true), ctx("tv.danmaku.bili"), "bf-5")
                "ui_snapshot" -> Envelope.ok(
                    JSONObject()
                        .put("blocking_overlay", false)
                        .put("count", 1)
                        .put("elements", JSONArray().put(JSONObject().put("ref", "e1").put("text", "公开视频标题").put("desc", ""))),
                    ctx("tv.danmaku.bili"),
                    "bf-6",
                )
                else -> error("unexpected tool: $tool")
            }
        }
        val clickedRes = clickEngine.run(JSONObject().put("name", "bili_readonly_feed_prepare").put("params", JSONObject()))
        assertEquals("completed", clickedRes.getString("status"))
        assertEquals(8, clickedRes.getInt("steps_executed"))
        assertEquals(0, clickedRes.getJSONArray("skipped_steps").length())
        val biliFindArgs = clickCalls.first { it.first == "ui_find" }.second
        assertEquals("button", biliFindArgs.optString("role"))
        assertEquals("暂不开启", biliFindArgs.optString("text"))
        assertFalse(biliFindArgs.optBoolean("scroll_search", true))
        assertEquals("e-dismiss", clickCalls.first { it.first == "ui_action" }.second.getString("ref"))

        val absentCalls = mutableListOf<String>()
        val absentEngine = MacroEngine(
            catalog = loadRealCatalog(),
            isBlockedApp = { false },
            loginWallKeywordsForPackage = { listOf("手机号登录", "扫码登录", "一键登录", "请先登录", "登录后即可") },
        ) { tool, _ ->
            absentCalls.add(tool)
            when (tool) {
                "foreground_app" -> Envelope.ok(JSONObject().put("package", "com.android.launcher"), ctx("com.android.launcher"), "ba-1")
                "app_launch" -> Envelope.ok(JSONObject().put("launched", true).put("foreground_verified", true), ctx("tv.danmaku.bili"), "ba-2")
                "wait_for" -> Envelope.ok(JSONObject().put("met", true), ctx("tv.danmaku.bili"), "ba-3")
                "ui_find" -> Envelope.err(GatewayError(ErrorCode.E_NOT_FOUND, "未见暂不开启"), ctx("tv.danmaku.bili"), "ba-4")
                "ui_snapshot" -> Envelope.ok(
                    JSONObject()
                        .put("blocking_overlay", false)
                        .put("count", 1)
                        .put("elements", JSONArray().put(JSONObject().put("ref", "e1").put("text", "公开视频标题").put("desc", ""))),
                    ctx("tv.danmaku.bili"),
                    "ba-5",
                )
                else -> error("未命中的可选弹窗不应触发工具：$tool")
            }
        }
        val absentRes = absentEngine.run(JSONObject().put("name", "bili_readonly_feed_prepare").put("params", JSONObject()))
        assertEquals("completed", absentRes.getString("status"))
        assertFalse("ui_action" in absentCalls)
        assertEquals(
            listOf("find_dismiss_push_prompt", "dismiss_push_prompt"),
            (0 until absentRes.getJSONArray("skipped_steps").length()).map {
                absentRes.getJSONArray("skipped_steps").getString(it)
            },
        )

        val multiCalls = mutableListOf<String>()
        val multiEngine = MacroEngine(
            catalog = loadRealCatalog(),
            isBlockedApp = { false },
            loginWallKeywordsForPackage = { emptyList() },
        ) { tool, _ ->
            multiCalls.add(tool)
            when (tool) {
                "foreground_app" -> Envelope.ok(JSONObject().put("package", "com.android.launcher"), ctx("com.android.launcher"), "bm-1")
                "app_launch", "wait_for" -> Envelope.ok(JSONObject().put("met", true), ctx("tv.danmaku.bili"), "bm-2")
                "ui_find" -> Envelope.ok(
                    JSONObject().put(
                        "matches",
                        JSONArray()
                            .put(JSONObject().put("ref", "e-1"))
                            .put(JSONObject().put("ref", "e-2")),
                    ),
                    ctx("tv.danmaku.bili"),
                    "bm-3",
                )
                "ui_snapshot" -> Envelope.ok(
                    JSONObject().put("blocking_overlay", false).put("count", 0).put("elements", JSONArray()),
                    ctx("tv.danmaku.bili"),
                    "bm-4",
                )
                else -> error("多条匹配未绑定 ref 时不应触发：$tool")
            }
        }
        val multiRes = multiEngine.run(JSONObject().put("name", "bili_readonly_feed_prepare").put("params", JSONObject()))
        assertEquals("completed", multiRes.getString("status"))
        assertFalse("ui_action" in multiCalls)
        assertEquals(
            listOf("dismiss_push_prompt"),
            (0 until multiRes.getJSONArray("skipped_steps").length()).map {
                multiRes.getJSONArray("skipped_steps").getString(it)
            },
        )
    }

    @Test
    fun `taobao_orders_prepare navigates through my taobao and all orders and enforces login wall`() {
        val calls = mutableListOf<Pair<String, JSONObject>>()
        val engine = MacroEngine(
            catalog = loadRealCatalog(),
            isBlockedApp = { false },
            loginWallKeywordsForPackage = { listOf("登录", "请先登录") },
        ) { tool, args ->
            calls.add(tool to args)
            when (tool) {
                "foreground_app" -> Envelope.ok(JSONObject().put("package", "com.android.launcher"), ctx("com.android.launcher"), "to-1")
                "app_launch" -> Envelope.ok(JSONObject().put("launched", true).put("foreground_verified", true), ctx("com.taobao.taobao"), "to-2")
                "wait_for" -> Envelope.ok(JSONObject().put("met", true), ctx("com.taobao.taobao"), "to-3")
                "ui_find" -> {
                    assertEquals("button", args.optString("role"))
                    assertFalse(args.optBoolean("scroll_search", true))
                    val slotRef = when (args.optString("desc")) {
                        "我的淘宝" -> "e-my"
                        "我的订单" -> "e-orders"
                        else -> error("unexpected ui_find args: $args")
                    }
                    Envelope.ok(
                        JSONObject().put("matches", JSONArray().put(JSONObject().put("ref", slotRef))),
                        ctx("com.taobao.taobao"),
                        "to-4",
                    )
                }
                "ui_action" -> Envelope.ok(JSONObject().put("clicked", true), ctx("com.taobao.taobao"), "to-5")
                "ui_snapshot" -> Envelope.ok(
                    JSONObject()
                        .put("blocking_overlay", false)
                        .put("count", 1)
                        .put("elements", JSONArray().put(JSONObject().put("ref", "e1").put("text", "全部订单").put("desc", ""))),
                    ctx("com.taobao.taobao"),
                    "to-6",
                )
                else -> error("unexpected tool: $tool")
            }
        }
        val res = engine.run(JSONObject().put("name", "taobao_orders_prepare").put("params", JSONObject()))
        assertEquals("completed", res.getString("status"))
        assertEquals(11, res.getInt("steps_executed"))
        assertEquals(0, res.getJSONArray("skipped_steps").length())
        val uiFindCalls = calls.filter { it.first == "ui_find" }.map { it.second }
        assertEquals(2, uiFindCalls.size)
        assertEquals("button", uiFindCalls[0].optString("role"))
        assertEquals("我的淘宝", uiFindCalls[0].optString("desc"))
        assertEquals("button", uiFindCalls[1].optString("role"))
        assertEquals("我的订单", uiFindCalls[1].optString("desc"))
        assertEquals(listOf("e-my", "e-orders"), calls.filter { it.first == "ui_action" }.map { it.second.getString("ref") })

        val loginWallEngine = MacroEngine(
            catalog = loadRealCatalog(),
            isBlockedApp = { false },
            loginWallKeywordsForPackage = { listOf("登录", "请先登录") },
        ) { tool, _ ->
            when (tool) {
                "foreground_app" -> Envelope.ok(JSONObject().put("package", "com.android.launcher"), ctx("com.android.launcher"), "tl-1")
                "app_launch", "wait_for" -> Envelope.ok(JSONObject().put("met", true), ctx("com.taobao.taobao"), "tl-2")
                "ui_find" -> Envelope.err(GatewayError(ErrorCode.E_NOT_FOUND, "not found"), ctx("com.taobao.taobao"), "tl-3")
                "ui_snapshot" -> Envelope.ok(
                    JSONObject()
                        .put("blocking_overlay", false)
                        .put("elements", JSONArray().put(JSONObject().put("text", "请先登录淘宝").put("desc", ""))),
                    ctx("com.taobao.taobao"),
                    "tl-4",
                )
                else -> error("unexpected tool: $tool")
            }
        }
        val loginRes = loginWallEngine.run(JSONObject().put("name", "taobao_orders_prepare").put("params", JSONObject()))
        assertEquals("handoff_required", loginRes.getString("status"))
        assertEquals("LOGIN_WALL", loginRes.getString("failure_code"))
        assertTrue(loginRes.getBoolean("blocker_detected"))
        assertEquals(
            listOf("find_my_taobao", "open_my_taobao", "find_all_orders", "open_all_orders"),
            (0 until loginRes.getJSONArray("skipped_steps").length()).map {
                loginRes.getJSONArray("skipped_steps").getString(it)
            },
        )
    }

    @Test
    fun `skip_if_ref_missing never swallows safety terminal errors during real execution`() {
        for (terminalCode in listOf(
            ErrorCode.E_STALE_REF,
            ErrorCode.E_BLOCKED,
            ErrorCode.E_CONFIRM_TIMEOUT,
        )) {
            val engine = MacroEngine(
                catalog = loadRealCatalog(),
                isBlockedApp = { false },
                loginWallKeywordsForPackage = { emptyList() },
            ) { tool, _ ->
                when (tool) {
                    "foreground_app" -> Envelope.ok(JSONObject().put("package", "com.android.launcher"), ctx("com.android.launcher"), "s-1")
                    "app_launch", "wait_for" -> Envelope.ok(JSONObject().put("met", true), ctx("tv.danmaku.bili"), "s-2")
                    "ui_find" -> Envelope.ok(
                        JSONObject().put("matches", JSONArray().put(JSONObject().put("ref", "e-dismiss"))),
                        ctx("tv.danmaku.bili"),
                        "s-3",
                    )
                    "ui_action" -> Envelope.err(
                        GatewayError(terminalCode, "safety failure on click"),
                        ctx("tv.danmaku.bili"),
                        "s-4",
                    )
                    else -> error("安全终态后不得继续执行：$tool")
                }
            }
            try {
                engine.run(JSONObject().put("name", "bili_readonly_feed_prepare").put("params", JSONObject()))
                fail("skip_if_ref_missing=true 绝不能吞掉执行期 $terminalCode")
            } catch (e: GatewayError) {
                assertEquals(terminalCode, e.code)
                assertFalse(e.retryable)
                assertEquals(false, e.extra?.getBoolean("handoff_allowed"))
                assertEquals("dismiss_push_prompt", e.extra?.getString("failed_step"))
            }
        }
    }
}

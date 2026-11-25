package dev.magina.gateway.core

import java.io.File
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** 钉住 SkillPack 资产结构、未实测深链状态、app_guides 守卫与 lookupForBrain 只读查询。 */
class SkillPackAssetAndLookupTest {

    private fun loadAsset(name: String): JSONObject {
        val userDir = requireNotNull(System.getProperty("user.dir")) { "JVM 未提供 user.dir" }
        var cursor: File? = File(userDir).absoluteFile
        while (cursor != null) {
            listOf(
                File(cursor, "gateway/src/main/assets/skillpack/$name"),
                File(cursor, "app/gateway/src/main/assets/skillpack/$name"),
            ).firstOrNull(File::isFile)?.let { return JSONObject(it.readText()) }
            cursor = cursor.parentFile
        }
        error("找不到 skillpack/$name（user.dir=$userDir）")
    }

    private fun loadPack(): SkillPack = SkillPack(
        appsJson = loadAsset("apps.json"),
        deeplinksJson = loadAsset("deeplinks.json"),
        safetyJson = loadAsset("safety.json"),
    )

    @Test
    fun `deeplinks registry invariants and unverified candidates remain unpromoted`() {
        val pack = loadPack()
        val registeredPackages = pack.appAliases.values.toSet()
        val prefixes = pack.deeplinks.map { it.prefix }

        assertEquals("deeplinks.json 不得存在重复 prefix", prefixes.size, prefixes.toSet().size)
        val dateRegex = Regex("""^\d{4}-\d{2}-\d{2}$""")
        for (entry in pack.deeplinks) {
            assertTrue("prefix 不能为空", entry.prefix.isNotBlank())
            assertTrue("expect_package 不能为空：${entry.prefix}", entry.expectPackage.isNotBlank())
            assertTrue(
                "expect_package=${entry.expectPackage} 必须已登记在 apps.json aliases",
                entry.expectPackage in registeredPackages,
            )
            assertFalse(
                "deeplinks 不得包含黑名单应用：${entry.expectPackage}",
                pack.isBlockedApp(entry.expectPackage),
            )
            assertTrue(
                "verified 格式不合法：${entry.prefix} -> ${entry.verified}",
                entry.verified.isEmpty() || dateRegex.matches(entry.verified),
            )
        }

        val byPrefix = pack.deeplinks.associateBy { it.prefix }
        assertEquals("2026-07-16", byPrefix["xhsdiscover://search/result"]?.verified)
        for (unverifiedPrefix in listOf(
            "xhsdiscover://",
            "taobao://",
            "taobao://s.taobao.com",
            "openapp.jdmobile://",
            "openapp.jdmobile://virtual",
            "tmall://",
        )) {
            val item = byPrefix[unverifiedPrefix]
            assertNotNull("缺少候选深链：$unverifiedPrefix", item)
            assertEquals("未实测候选不得伪造 verified 日期：$unverifiedPrefix", "", item!!.verified)
        }
    }

    @Test
    fun `matchDeeplink selects longest prefix and returns null for unknown uri`() {
        val pack = loadPack()

        assertEquals(
            "xhsdiscover://search/result",
            pack.matchDeeplink("xhsdiscover://search/result?keyword=tokyo")?.prefix,
        )
        assertEquals(
            "openapp.jdmobile://virtual",
            pack.matchDeeplink("openapp.jdmobile://virtual?params=%7B%7D")?.prefix,
        )
        assertEquals(
            "taobao://s.taobao.com",
            pack.matchDeeplink("taobao://s.taobao.com?q=test")?.prefix,
        )
        assertEquals(
            "taobao://",
            pack.matchDeeplink("taobao://home")?.prefix,
        )
        assertNull(pack.matchDeeplink("https://example.invalid/path"))
    }

    @Test
    fun `app_guides and unreliable_settings_actions cover target apps safely`() {
        val pack = loadPack()
        val registeredPackages = pack.appAliases.values.toSet()

        val expectedGuidePackages = setOf(
            "com.xingin.xhs",
            "com.jingdong.app.mall",
            "com.taobao.taobao",
            "com.android.settings",
            "tv.danmaku.bili",
        )
        assertTrue(
            "app_guides 必须覆盖目标 App 集合",
            pack.appGuides.keys.containsAll(expectedGuidePackages),
        )
        for ((pkg, guide) in pack.appGuides) {
            assertTrue("app_guides key=$pkg 不在 aliases 值集合内", pkg in registeredPackages)
            assertTrue("app_guides[$pkg].preGuards 不得为空", guide.preGuards.isNotEmpty())
            assertTrue("app_guides[$pkg].readonlyRules 不得为空", guide.readonlyRules.isNotEmpty())
            val joined = (guide.preGuards + guide.postLaunchGuards + guide.readonlyRules).joinToString("\n")
            assertFalse("守卫文本不得包含绕过确认卡字样", joined.contains("绕过确认"))
            assertFalse("守卫文本不得鼓励代登录", joined.contains("自动代登录"))
        }

        val btAction = pack.findUnreliableSettingsAction("android.settings.BLUETOOTH_SETTINGS")
        assertNotNull("unreliable_settings_actions 应包含 BLUETOOTH_SETTINGS", btAction)
        assertTrue(btAction!!.fallback.contains("app_launch"))
    }

    @Test
    fun `lookupForBrain returns readonly sanitized summary and marks blocked apps`() {
        val pack = loadPack()

        val all = pack.lookupForBrain(null)
        assertTrue(all.getBoolean("matched"))
        assertTrue(all.getJSONObject("aliases").has("淘宝"))
        assertTrue(all.getJSONArray("deeplinks").length() >= 7)
        assertTrue(all.getJSONObject("app_guides").has("com.taobao.taobao"))
        assertFalse("lookupForBrain 不得返回 token 字段", all.toString().contains("\"token\""))

        val tb = pack.lookupForBrain("com.taobao.taobao")
        assertTrue(tb.getBoolean("matched"))
        assertFalse(tb.getBoolean("blocked"))
        assertEquals("com.taobao.taobao", tb.getString("package"))
        assertTrue(tb.has("app_guide"))
        assertEquals(2, tb.getJSONArray("deeplinks").length())

        val xhs = pack.lookupForBrain("小红书")
        assertEquals("com.xingin.xhs", xhs.getString("package"))
        assertFalse(xhs.getBoolean("blocked"))

        val bili = pack.lookupForBrain("哔哩哔哩")
        assertTrue(bili.getBoolean("matched"))
        assertEquals("tv.danmaku.bili", bili.getString("package"))
        assertFalse(bili.getBoolean("blocked"))
        assertTrue(bili.has("app_guide"))

        val alipay = pack.lookupForBrain("支付宝")
        assertTrue(alipay.getBoolean("matched"))
        assertTrue(alipay.getBoolean("blocked"))
        assertEquals("com.eg.android.AlipayGphone", alipay.getString("package"))

        val unknown = pack.lookupForBrain("不存在的应用")
        assertFalse(unknown.getBoolean("matched"))
        assertTrue(unknown.has("available_aliases"))
    }
}

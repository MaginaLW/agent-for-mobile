package dev.magina.gateway.core

import java.io.File
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** 直接钉住随 APK 发布的安全资产，避免运行时代码正确但黑名单数据写错。 */
class SkillPackSafetyAssetTest {
    @Test
    fun `alipay alias is covered by the blocked package prefixes`() {
        val apps = loadAsset("apps.json")
        val safety = loadAsset("safety.json")
        val alipayPackage = apps.getJSONObject("aliases").getString("支付宝")
        val blockedPrefixes = safety.getJSONArray("blocked_app_prefixes").let { array ->
            (0 until array.length()).map(array::getString)
        }

        assertEquals("com.eg.android.AlipayGphone", alipayPackage)
        assertTrue(
            "支付宝主包必须被 blocked_app_prefixes 覆盖",
            blockedPrefixes.any(alipayPackage::startsWith),
        )
        assertTrue(
            "黑名单应从支付宝主包开始，而不是只拦不存在的 security 子包",
            blockedPrefixes.contains(alipayPackage),
        )

        val actionConfirmWords = safety.getJSONArray("action_confirm_words").let { array ->
            (0 until array.length()).map(array::getString)
        }
        assertTrue("safety.json 应配置 action_confirm_words", actionConfirmWords.containsAll(listOf("确认", "确定", "提交", "下单")))
    }

    @Test
    fun `blocked app outbound guard rejects blocked target package and allows normal package`() {
        val safety = loadAsset("safety.json")
        val blockedPrefixes = safety.getJSONArray("blocked_app_prefixes").let { array ->
            (0 until array.length()).map(array::getString)
        }
        val isBlocked: (String?) -> Boolean = { pkg ->
            pkg != null && blockedPrefixes.any { pkg.startsWith(it) }
        }

        val blocked = try {
            ensureTargetPackageAllowed("com.eg.android.AlipayGphone", isBlocked)
            null
        } catch (error: GatewayError) {
            error
        }
        assertEquals(ErrorCode.E_BLOCKED, blocked?.code)
        ensureTargetPackageAllowed("com.xingin.xhs", isBlocked)
    }

    private fun loadAsset(name: String): JSONObject {
        val userDir = requireNotNull(System.getProperty("user.dir")) { "JVM 未提供 user.dir" }
        var cursor: File? = File(userDir).absoluteFile
        while (cursor != null) {
            val candidates = listOf(
                File(cursor, "gateway/src/main/assets/skillpack/$name"),
                File(cursor, "app/gateway/src/main/assets/skillpack/$name"),
            )
            candidates.firstOrNull(File::isFile)?.let { return JSONObject(it.readText()) }
            cursor = cursor.parentFile
        }
        error("找不到 skillpack/$name（user.dir=$userDir）")
    }
}

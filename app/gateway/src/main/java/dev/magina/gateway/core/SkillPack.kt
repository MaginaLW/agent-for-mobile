package dev.magina.gateway.core

import android.content.Context
import org.json.JSONObject

/**
 * 执行器侧技能包（既定约束：路由数据下沉执行器，M1 spec §11）：路由数据（深链注册表 / app 别名 / 分享组件 / 安全词表）。
 * 数据源头是 docs/knowledge/apps/（deeplinks.md、各 app 册），入库规程：先真机实测再进 assets。
 */
class SkillPack(context: Context) {

    data class DeepLink(val prefix: String, val expectPackage: String, val note: String)

    val deeplinks: List<DeepLink>
    val appAliases: Map<String, String>          // 别名 → 包名
    val shareComponents: Map<String, String>     // 包名 → 直达分享组件类名
    val dangerWords: List<String>
    val sendWords: List<String>
    val sendWhitelistContexts: List<String>
    val blockedAppPrefixes: List<String>
    val sensitiveTargets: List<String>

    init {
        fun load(name: String) = JSONObject(
            context.assets.open("skillpack/$name").readBytes().decodeToString()
        )

        val dl = load("deeplinks.json").getJSONArray("entries")
        deeplinks = (0 until dl.length()).map {
            val o = dl.getJSONObject(it)
            DeepLink(o.getString("prefix"), o.optString("expect_package"), o.optString("note"))
        }

        val apps = load("apps.json")
        appAliases = apps.getJSONObject("aliases").let { o ->
            o.keys().asSequence().associateWith { k -> o.getString(k) }
        }
        shareComponents = apps.getJSONObject("share_components").let { o ->
            o.keys().asSequence().associateWith { k -> o.getString(k) }
        }

        val safety = load("safety.json")
        fun arr(k: String) = safety.getJSONArray(k).let { a -> (0 until a.length()).map { a.getString(it) } }
        dangerWords = arr("danger_words")
        sendWords = arr("send_words")
        sendWhitelistContexts = arr("send_whitelist_contexts")
        blockedAppPrefixes = arr("blocked_app_prefixes")
        sensitiveTargets = arr("sensitive_targets")
    }

    fun resolvePackage(nameOrPackage: String): String =
        appAliases[nameOrPackage] ?: nameOrPackage

    fun matchDeeplink(uri: String): DeepLink? =
        deeplinks.filter { uri.startsWith(it.prefix) }.maxByOrNull { it.prefix.length }

    fun isBlockedApp(pkg: String?): Boolean =
        pkg != null && blockedAppPrefixes.any { pkg.startsWith(it) }

    /** 目标文本命中危险词 → 需要带内确认；命中发送词但白名单上下文可见 → 放行。 */
    fun dangerHit(targetText: String, visibleTexts: () -> List<String>): String? {
        val t = targetText.trim()
        if (t.isEmpty()) return null
        dangerWords.firstOrNull { t.contains(it) }?.let { return it }
        sendWords.firstOrNull { t.contains(it) }?.let { hit ->
            val whitelisted = sendWhitelistContexts.any { wl -> visibleTexts().any { v -> v.contains(wl) } }
            return if (whitelisted) null else hit
        }
        sensitiveTargets.firstOrNull { t.contains(it) }?.let { return it }
        return null
    }
}

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

    /**
     * 包名 → 可接受的分享**落地** activity 全类名白名单。配了就把 share 的前台判据从包级
     * 收紧到 activity 级；缺省（不配）则回落包级，即历史行为。
     *
     * **启动组件 ≠ 落地 activity**：M1 spike 观测到启动 [shareComponents] 里的 `ShareImgUI`、
     * 实际落地 `MsgRetransmitUI`，所以这里必须填落地那个；填成启动组件会把真实成功判失败。
     */
    val shareLandingActivities: Map<String, List<String>>
    val dangerWords: List<String>
    val sendWords: List<String>
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
        shareLandingActivities = apps.optJSONObject("share_landing_activities").let { o ->
            if (o == null) emptyMap() else o.keys().asSequence().associateWith { k ->
                val a = o.getJSONArray(k)
                val list = (0 until a.length()).map { a.getString(it) }
                // 空数组不是"不限制"而是"没有任何 activity 可接受"，会把该包的分享永远判失败。
                // 与其让它悄悄生效，不如在装配期就炸——配置写错必须响，不能变成运行时假阴性。
                require(list.isNotEmpty()) { "share_landing_activities[$k] 不得为空数组" }
                list
            }
        }

        val safety = load("safety.json")
        fun arr(k: String) = safety.getJSONArray(k).let { a -> (0 until a.length()).map { a.getString(it) } }
        dangerWords = arr("danger_words")
        sendWords = arr("send_words")
        blockedAppPrefixes = arr("blocked_app_prefixes")
        sensitiveTargets = arr("sensitive_targets")
    }

    fun resolvePackage(nameOrPackage: String): String =
        appAliases[nameOrPackage] ?: nameOrPackage

    fun matchDeeplink(uri: String): DeepLink? =
        deeplinks.filter { uri.startsWith(it.prefix) }.maxByOrNull { it.prefix.length }

    fun isBlockedApp(pkg: String?): Boolean =
        pkg != null && blockedAppPrefixes.any { pkg.startsWith(it) }

}

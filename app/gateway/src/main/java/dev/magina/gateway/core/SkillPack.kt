package dev.magina.gateway.core

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/**
 * 执行器侧技能包（既定约束：路由数据下沉执行器，M1 spec §11）：路由数据（深链注册表 / app 别名 / 分享组件 / 安全词表 / 应用前置守卫）。
 * 数据源头是 docs/knowledge/apps/（deeplinks.md、各 app 册），入库规程：先真机实测再进 assets。
 */
class SkillPack internal constructor(
    appsJson: JSONObject,
    deeplinksJson: JSONObject,
    safetyJson: JSONObject,
) {

    constructor(context: Context) : this(
        appsJson = loadAsset(context, "apps.json"),
        deeplinksJson = loadAsset(context, "deeplinks.json"),
        safetyJson = loadAsset(context, "safety.json"),
    )

    data class DeepLink(
        val prefix: String,
        val app: String,
        val expectPackage: String,
        val note: String,
        val verified: String,
    )

    data class UnreliableSettingsAction(
        val action: String,
        val deviceScope: String,
        val fallback: String,
        val verified: String,
    )

    data class AppGuide(
        val packageName: String,
        val app: String,
        val knownBlockers: List<String>,
        val loginWallKeywords: List<String>,
        val preGuards: List<String>,
        val postLaunchGuards: List<String>,
        val readonlyRules: List<String>,
        val preferApiFirst: List<String>,
    )

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
    val unreliableSettingsActions: List<UnreliableSettingsAction>
    val appGuides: Map<String, AppGuide>
    val dangerWords: List<String>
    val actionConfirmWords: List<String>
    val sendWords: List<String>
    val blockedAppPrefixes: List<String>
    val sensitiveTargets: List<String>

    init {
        val dl = deeplinksJson.getJSONArray("entries")
        deeplinks = (0 until dl.length()).map {
            val o = dl.getJSONObject(it)
            DeepLink(
                prefix = o.getString("prefix"),
                app = o.optString("app"),
                expectPackage = o.optString("expect_package"),
                note = o.optString("note"),
                verified = o.optString("verified"),
            )
        }

        appAliases = appsJson.getJSONObject("aliases").let { o ->
            o.keys().asSequence().associateWith { k -> o.getString(k) }
        }
        shareComponents = appsJson.getJSONObject("share_components").let { o ->
            o.keys().asSequence().associateWith { k -> o.getString(k) }
        }
        shareLandingActivities = appsJson.optJSONObject("share_landing_activities").let { o ->
            if (o == null) emptyMap() else o.keys().asSequence().associateWith { k ->
                val a = o.getJSONArray(k)
                val list = (0 until a.length()).map { a.getString(it) }
                // 空数组不是"不限制"而是"没有任何 activity 可接受"，会把该包的分享永远判失败。
                // 与其让它悄悄生效，不如在装配期就炸——配置写错必须响，不能变成运行时假阴性。
                require(list.isNotEmpty()) { "share_landing_activities[$k] 不得为空数组" }
                list
            }
        }
        unreliableSettingsActions = appsJson.optJSONArray("unreliable_settings_actions").let { arr ->
            if (arr == null) emptyList() else (0 until arr.length()).map { idx ->
                val o = arr.getJSONObject(idx)
                UnreliableSettingsAction(
                    action = o.getString("action"),
                    deviceScope = o.optString("device_scope"),
                    fallback = o.optString("fallback"),
                    verified = o.optString("verified"),
                )
            }
        }
        appGuides = appsJson.optJSONObject("app_guides").let { o ->
            if (o == null) emptyMap() else o.keys().asSequence().associateWith { pkg ->
                val g = o.getJSONObject(pkg)
                AppGuide(
                    packageName = pkg,
                    app = g.optString("app"),
                    knownBlockers = stringList(g.optJSONArray("known_blockers")),
                    loginWallKeywords = stringList(g.optJSONArray("login_wall_keywords")),
                    preGuards = stringList(g.optJSONArray("pre_guards")),
                    postLaunchGuards = stringList(g.optJSONArray("post_launch_guards")),
                    readonlyRules = stringList(g.optJSONArray("readonly_rules")),
                    preferApiFirst = stringList(g.optJSONArray("prefer_api_first")),
                )
            }
        }

        dangerWords = stringList(safetyJson.getJSONArray("danger_words"))
        actionConfirmWords = safetyJson.optJSONArray("action_confirm_words")?.let(::stringList)
            ?: SafetyPolicy.DEFAULT_ACTION_CONFIRM_WORDS
        sendWords = stringList(safetyJson.getJSONArray("send_words"))
        blockedAppPrefixes = stringList(safetyJson.getJSONArray("blocked_app_prefixes"))
        sensitiveTargets = stringList(safetyJson.getJSONArray("sensitive_targets"))
    }

    fun resolvePackage(nameOrPackage: String): String =
        appAliases[nameOrPackage] ?: nameOrPackage

    fun matchDeeplink(uri: String): DeepLink? =
        deeplinks.filter { uri.startsWith(it.prefix) }.maxByOrNull { it.prefix.length }

    fun isBlockedApp(pkg: String?): Boolean =
        pkg != null && blockedAppPrefixes.any { pkg.startsWith(it) }

    fun findUnreliableSettingsAction(action: String): UnreliableSettingsAction? =
        unreliableSettingsActions.firstOrNull { it.action == action }

    fun lookupForBrain(appOrPackageOrUri: String? = null): JSONObject {
        val query = appOrPackageOrUri?.trim()?.takeIf { it.isNotEmpty() }
        if (query == null) {
            return JSONObject()
                .put("matched", true)
                .put("aliases", aliasesJson())
                .put("deeplinks", JSONArray().apply { deeplinks.forEach { put(it.toJson()) } })
                .put("app_guides", JSONObject().apply {
                    appGuides.forEach { (pkg, guide) -> put(pkg, guide.toJson()) }
                })
                .put("unreliable_settings_actions", JSONArray().apply {
                    unreliableSettingsActions.forEach { put(it.toJson()) }
                })
        }

        val uriMatch = if ("://" in query) matchDeeplink(query) else null
        val settingsAction = findUnreliableSettingsAction(query)
        val resolvedPkg = when {
            uriMatch != null && uriMatch.expectPackage.isNotEmpty() -> uriMatch.expectPackage
            settingsAction != null || query.startsWith("android.settings.") -> "com.android.settings"
            else -> resolvePackage(query)
        }
        val knownPkg = resolvedPkg in appAliases.values ||
            resolvedPkg in appGuides ||
            deeplinks.any { it.expectPackage == resolvedPkg } ||
            isBlockedApp(resolvedPkg)
        val matched = uriMatch != null || settingsAction != null || knownPkg
        val blocked = isBlockedApp(resolvedPkg)

        val matchedDeeplinks = when {
            uriMatch != null -> listOf(uriMatch)
            matched -> deeplinks.filter { it.expectPackage == resolvedPkg }
            else -> emptyList()
        }
        val matchedSettingsActions = when {
            settingsAction != null -> listOf(settingsAction)
            resolvedPkg == "com.android.settings" -> unreliableSettingsActions
            else -> emptyList()
        }

        return JSONObject()
            .put("matched", matched)
            .put("query", query)
            .put("package", if (matched) resolvedPkg else JSONObject.NULL)
            .put("blocked", blocked)
            .apply {
                if (blocked) {
                    put("blocked_reason", "目标属于敏感黑名单（blocked_app_prefixes），禁止启动或读写")
                }
                if (matchedDeeplinks.isNotEmpty()) {
                    put("deeplinks", JSONArray().apply { matchedDeeplinks.forEach { put(it.toJson()) } })
                } else {
                    put("deeplinks", JSONArray())
                }
                appGuides[resolvedPkg]?.let { put("app_guide", it.toJson()) }
                if (matchedSettingsActions.isNotEmpty()) {
                    put("unreliable_settings_actions", JSONArray().apply {
                        matchedSettingsActions.forEach { put(it.toJson()) }
                    })
                }
                if (!matched) {
                    put("available_aliases", aliasesJson())
                }
            }
    }

    private fun aliasesJson(): JSONObject = JSONObject().apply {
        appAliases.forEach { (alias, pkg) -> put(alias, pkg) }
    }

    private fun DeepLink.toJson(): JSONObject = JSONObject()
        .put("prefix", prefix)
        .put("app", app)
        .put("expect_package", expectPackage)
        .put("verified", verified)
        .put("status", if (verified.isNotEmpty()) "verified" else "candidate_unverified")
        .put("note", note)

    private fun UnreliableSettingsAction.toJson(): JSONObject = JSONObject()
        .put("action", action)
        .put("device_scope", deviceScope)
        .put("fallback", fallback)
        .put("verified", verified)

    private fun AppGuide.toJson(): JSONObject = JSONObject()
        .put("package", packageName)
        .put("app", app)
        .put("known_blockers", JSONArray(knownBlockers))
        .put("login_wall_keywords", JSONArray(loginWallKeywords))
        .put("pre_guards", JSONArray(preGuards))
        .put("post_launch_guards", JSONArray(postLaunchGuards))
        .put("readonly_rules", JSONArray(readonlyRules))
        .put("prefer_api_first", JSONArray(preferApiFirst))

    private companion object {
        fun loadAsset(context: Context, name: String): JSONObject = JSONObject(
            context.assets.open("skillpack/$name").readBytes().decodeToString(),
        )

        fun stringList(arr: JSONArray?): List<String> =
            if (arr == null) emptyList() else (0 until arr.length()).map { arr.getString(it) }
    }
}

/** 目标包出站前黑名单拦截，供 app_launch/open_uri/intent_send/share 共用。 */
internal fun ensureTargetPackageAllowed(
    targetPackage: String?,
    isBlocked: (String?) -> Boolean,
) {
    if (isBlocked(targetPackage)) {
        throw GatewayError(
            ErrorCode.E_BLOCKED,
            "目标应用（$targetPackage）属于敏感黑名单，拒绝启动或派发",
            channel = "safety",
            fallback = "按站规在报告中说明目标属于敏感黑名单，不得进入",
        )
    }
}

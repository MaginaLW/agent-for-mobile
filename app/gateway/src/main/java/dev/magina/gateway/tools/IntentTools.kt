package dev.magina.gateway.tools

import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import dev.magina.gateway.Gateway
import dev.magina.gateway.core.ErrorCode
import dev.magina.gateway.core.GatewayError
import org.json.JSONObject

/**
 * L2 意图通道：深链/Intent/分享。铁则（M0 发现 #1，OriginOS 深链假成功实锤）：
 * 执行后必验前台，验不上抛 E_VERIFY_FAIL，UI 导航兜底留给大脑决策。
 */
object IntentTools {

    private val ctx: Context get() = Gateway.appContext

    private val ACTION_WHITELIST = listOf(
        Intent.ACTION_VIEW, Intent.ACTION_SEND, Intent.ACTION_SENDTO, Intent.ACTION_MAIN,
    )
    private const val SETTINGS_PREFIX = "android.settings."

    fun openUri(uri: String): JSONObject {
        val hit = Gateway.skills.matchDeeplink(uri)
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(uri)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            ctx.startActivity(intent)
        } catch (e: ActivityNotFoundException) {
            throw GatewayError(
                ErrorCode.E_NOT_FOUND, "无 app 可处理 URI：$uri",
                channel = "intent", fallback = "app_launch 目标 app 后走 UI 导航",
            )
        }
        var verified: Boolean? = null
        if (hit != null && hit.expectPackage.isNotEmpty()) {
            verified = SystemTools.waitForeground(hit.expectPackage, 3000)
            if (!verified) throw GatewayError(
                ErrorCode.E_VERIFY_FAIL,
                "深链已发出但 3s 内前台不是 ${hit.expectPackage}（OriginOS 深链假成功模式）",
                channel = "intent", retryable = false,
                fallback = "app_launch(${hit.expectPackage}) 后按技能包页面地图走 UI 导航",
            )
        }
        return JSONObject()
            .put("opened", true)
            .put("registry_hit", hit != null)
            .put("expect_package", hit?.expectPackage ?: "")
            .put("foreground_verified", verified ?: JSONObject.NULL)
    }

    fun intentSend(action: String, uri: String?, extras: JSONObject?, pkg: String?, component: String?): JSONObject {
        if (action !in ACTION_WHITELIST && !action.startsWith(SETTINGS_PREFIX)) throw GatewayError(
            ErrorCode.E_BLOCKED, "action「$action」不在白名单",
            fallback = "白名单：VIEW/SEND/SENDTO/MAIN/android.settings.*",
        )
        val intent = Intent(action).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        uri?.let { intent.data = Uri.parse(it) }
        extras?.keys()?.forEach { k -> intent.putExtra(k, extras.getString(k)) }
        val resolvedPackage = pkg?.let(Gateway.skills::resolvePackage)
        resolvedPackage?.let(intent::setPackage)
        var componentPackage: String? = null
        component?.let { comp ->
            // 显式组件只接受技能包注册项（防大脑幻觉组件名乱撞）
            if (comp !in Gateway.skills.shareComponents.values) throw GatewayError(
                ErrorCode.E_BLOCKED, "组件「$comp」未在技能包注册",
                fallback = "改用 package 定向 + 系统解析，或先在 apps.json 注册组件",
            )
            val p = Gateway.skills.shareComponents.entries.first { it.value == comp }.key
            if (resolvedPackage != null && resolvedPackage != p) throw GatewayError(
                ErrorCode.E_INVALID_ARG,
                "package「$resolvedPackage」与组件「$comp」所属包「$p」不一致",
                channel = "intent",
            )
            intent.component = ComponentName(p, comp)
            componentPackage = p
        }
        try {
            ctx.startActivity(intent)
        } catch (e: ActivityNotFoundException) {
            throw GatewayError(ErrorCode.E_NOT_FOUND, "Intent 无接收方：$action", channel = "intent")
        }
        // 显式组件的包名是最终目标；不能拿可同时传入的 package 参数验证另一个 app。
        val targetPackage = componentPackage ?: resolvedPackage
        val acceptableActivities = expectedIntentLandingActivities(
            isShareAction = action == Intent.ACTION_SEND,
            component = component,
            registeredShareLandingActivities = targetPackage?.let {
                Gateway.skills.shareLandingActivities[it]
            }.orEmpty(),
        )
        val verified = targetPackage?.let { target ->
            SystemTools.waitForegroundLanding(target, acceptableActivities, VERIFY_TIMEOUT_MS)
        }
        return finishIntentSend(targetPackage, verified, acceptableActivities)
    }

    fun shareText(text: String, target: String?): JSONObject = share(
        Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text), target,
    )

    fun shareFile(uri: String, mime: String, target: String?): JSONObject = share(
        Intent(Intent.ACTION_SEND).setType(mime)
            .putExtra(Intent.EXTRA_STREAM, Uri.parse(uri))
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION),
        target,
    )

    /**
     * 分享三级：技能包直达组件 → package 定向 → 系统分享面板。任务 4 的核心捷径。
     *
     * **降级只由 `startActivity` 抛异常触发，前台验不上不降级而是抛 [ErrorCode.E_VERIFY_FAIL]**
     * ——见本文件类注释那条铁则。两件事必须分开：
     * - `startActivity` 抛异常 = 这一级根本没被系统接受（组件失效、无接收方），换下一级是对的；
     * - 启动被接受但前台没起来 = **假成功**，换一级只会把同一个 app 再打一次。
     *
     * 所以验证一定要放在 `catch` **外面**：早先的写法把 `waitForeground` 和 `startActivity` 裹在
     * 同一个 `catch (e: Exception)` 里，一旦验证改成抛错就会被自己的降级分支吞掉，
     * 表现成"静默降级后报成功"，正是这条铁则要挡的形态。
     */
    private fun share(base: Intent, target: String?): JSONObject {
        base.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (target != null) {
            val pkg = Gateway.skills.resolvePackage(target)
            val direct = Gateway.skills.shareComponents[pkg]
            if (direct != null) {
                // 组件失效（如微信改版）→ 静默降级 package 定向（网关内机械回退，spec §3）
                val started = runCatching {
                    ctx.startActivity(Intent(base).setComponent(ComponentName(pkg, direct)))
                }.isSuccess
                if (started) return finishShare(
                    ShareChannel.DIRECT_COMPONENT, pkg, awaitLanding(pkg),
                )
            }
            val started = runCatching { ctx.startActivity(Intent(base).setPackage(pkg)) }.isSuccess
            if (started) return finishShare(ShareChannel.PACKAGE, pkg, awaitLanding(pkg))
        }
        val chooser = Intent.createChooser(base, "分享").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            ctx.startActivity(chooser)
        } catch (e: ActivityNotFoundException) {
            throw GatewayError(ErrorCode.E_NOT_FOUND, "无可分享的接收方", channel = "intent")
        }
        // 系统面板没有已知目标包，前台无从验起：如实报 null，不冒充验过。
        return finishShare(ShareChannel.CHOOSER, target ?: "", null)
    }

    /**
     * 等目标包落地；技能包给该包配了落地 activity 白名单就一并收紧到 activity 级。
     * 白名单缺省 = 回落包级（历史行为），不是"没有可接受项"。
     */
    private fun awaitLanding(pkg: String): Boolean = SystemTools.waitForegroundLanding(
        pkg, Gateway.skills.shareLandingActivities[pkg].orEmpty(), VERIFY_TIMEOUT_MS,
    )

    private fun finishShare(
        channel: ShareChannel,
        target: String,
        foregroundVerified: Boolean?,
    ): JSONObject {
        val outcome = resolveShareOutcome(channel, target, foregroundVerified)
        if (outcome.verifyFailed) throw GatewayError(
            ErrorCode.E_VERIFY_FAIL,
            "分享已发出但 ${VERIFY_TIMEOUT_MS}ms 内前台不是 ${outcome.target}" +
                "（${outcome.channel.wireName} 通道；OriginOS 深链假成功模式）",
            channel = "intent", retryable = false,
            fallback = "app_launch(${outcome.target}) 后按技能包页面地图走 UI 导航",
        )
        return JSONObject()
            .put("shared", true)
            .put("channel", outcome.channel.wireName)
            .put("target", outcome.target)
            .put("foreground_verified", outcome.foregroundVerified ?: JSONObject.NULL)
    }

    private const val VERIFY_TIMEOUT_MS = 3000L
}

/** 分享三级降级用到的通道。`wireName` 是进结果 JSON 的那个值，改它等于改对外契约。 */
internal enum class ShareChannel(val wireName: String) {
    DIRECT_COMPONENT("direct_component"),
    PACKAGE("package"),
    CHOOSER("chooser"),
}

/** [resolveShareOutcome] 的结论。`verifyFailed` 为真时调用方必须抛 `E_VERIFY_FAIL`，不许报成功。 */
internal data class ShareOutcome(
    val channel: ShareChannel,
    val target: String,
    val foregroundVerified: Boolean?,
    val verifyFailed: Boolean,
)

/**
 * 分享终态判定。
 *
 * 抽成**不碰 Android 类型**的顶层纯函数，是为了能在纯 JVM 单测里覆盖：本模块单测没有
 * Robolectric，`Intent`/`Context` 一被调用就抛 "not mocked"，判据只能挂在纯逻辑上
 * （同 `resolveForeground` / `Audit.dirProvider` 的既有范式）。
 *
 * 判据只有一条，来自 `IntentTools` 类注释的铁则：**有已知目标包时，执行后前台必须验上**。
 * `foregroundVerified` 三态的语义要分清——
 * - `true`：验上了；
 * - `false`：验过且没验上 → **假成功，必须 fail-closed**；
 * - `null`：**不可验**（系统面板没有已知目标包），不是"验失败"，不得据此判失败。
 */
internal fun resolveShareOutcome(
    channel: ShareChannel,
    target: String,
    foregroundVerified: Boolean?,
): ShareOutcome = ShareOutcome(
    channel = channel,
    target = target,
    foregroundVerified = foregroundVerified,
    verifyFailed = channel != ShareChannel.CHOOSER && foregroundVerified == false,
)

/** intent_send 分派成功后的终态：有目标但没取得正向前台证据时必须 E_VERIFY_FAIL。 */
internal data class IntentSendOutcome(
    val targetPackage: String?,
    val foregroundVerified: Boolean?,
    val verifyFailed: Boolean,
)

internal fun resolveIntentSendOutcome(
    targetPackage: String?,
    foregroundVerified: Boolean?,
): IntentSendOutcome {
    val target = targetPackage?.takeIf(String::isNotBlank)
    return IntentSendOutcome(
        targetPackage = target,
        foregroundVerified = if (target == null) null else foregroundVerified,
        verifyFailed = target != null && foregroundVerified != true,
    )
}

/**
 * 组件名只证明启动目标，不自动证明最终页面：已登记的分享落地页优先；否则要求组件本身
 * 成为前台 Activity。不能把同包的 splash 或其他页面当作组件落地。
 */
internal fun expectedIntentLandingActivities(
    isShareAction: Boolean,
    component: String?,
    registeredShareLandingActivities: List<String>,
): List<String> = when {
    isShareAction && registeredShareLandingActivities.isNotEmpty() -> registeredShareLandingActivities
    component != null -> listOf(component)
    else -> emptyList()
}

/** 已分派不等于已落地；仅有正向前台证据时才允许报告已验证。 */
internal fun finishIntentSend(
    targetPackage: String?,
    foregroundVerified: Boolean?,
    acceptableActivities: List<String> = emptyList(),
): JSONObject {
    val outcome = resolveIntentSendOutcome(targetPackage, foregroundVerified)
    val expected = if (acceptableActivities.isEmpty()) outcome.targetPackage
        else "${outcome.targetPackage}/${acceptableActivities.joinToString("|")}"
    if (outcome.verifyFailed) throw GatewayError(
        ErrorCode.E_VERIFY_FAIL,
        "Intent 已分派但未能确认前台落在 $expected",
        channel = "intent", retryable = false,
        fallback = "只读核对当前前台与目标页面；未确认前不要重发同一 Intent",
    )
    return JSONObject()
        .put("sent", true)
        .put("target_package", outcome.targetPackage ?: JSONObject.NULL)
        .put("foreground_verified", outcome.foregroundVerified ?: JSONObject.NULL)
        .put("verification_scope", when {
            outcome.targetPackage == null -> JSONObject.NULL
            acceptableActivities.isEmpty() -> "package"
            else -> "activity"
        })
        .put("verification_status", if (outcome.foregroundVerified == true) "verified" else "dispatched_unverified")
}

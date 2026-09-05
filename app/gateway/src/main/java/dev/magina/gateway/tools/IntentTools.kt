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
        pkg?.let { intent.setPackage(Gateway.skills.resolvePackage(it)) }
        component?.let { comp ->
            // 显式组件只接受技能包注册项（防大脑幻觉组件名乱撞）
            if (comp !in Gateway.skills.shareComponents.values) throw GatewayError(
                ErrorCode.E_BLOCKED, "组件「$comp」未在技能包注册",
                fallback = "改用 package 定向 + 系统解析，或先在 apps.json 注册组件",
            )
            val p = Gateway.skills.shareComponents.entries.first { it.value == comp }.key
            intent.component = ComponentName(p, comp)
        }
        try {
            ctx.startActivity(intent)
        } catch (e: ActivityNotFoundException) {
            throw GatewayError(ErrorCode.E_NOT_FOUND, "Intent 无接收方：$action", channel = "intent")
        }
        return JSONObject().put("sent", true)
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

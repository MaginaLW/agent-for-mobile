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

    /** 分享三级：技能包直达组件 → package 定向 → 系统分享面板。任务 4 的核心捷径。 */
    private fun share(base: Intent, target: String?): JSONObject {
        base.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        var channelUsed = "chooser"
        if (target != null) {
            val pkg = Gateway.skills.resolvePackage(target)
            val direct = Gateway.skills.shareComponents[pkg]
            if (direct != null) {
                try {
                    ctx.startActivity(Intent(base).setComponent(ComponentName(pkg, direct)))
                    channelUsed = "direct_component"
                    val verified = SystemTools.waitForeground(pkg, 3000)
                    return JSONObject().put("shared", true).put("channel", channelUsed)
                        .put("target", pkg).put("foreground_verified", verified)
                } catch (e: Exception) {
                    // 组件失效（如微信改版）→ 静默降级 package 定向（网关内机械回退，spec §3）
                }
            }
            try {
                ctx.startActivity(Intent(base).setPackage(pkg))
                channelUsed = "package"
                val verified = SystemTools.waitForeground(pkg, 3000)
                return JSONObject().put("shared", true).put("channel", channelUsed)
                    .put("target", pkg).put("foreground_verified", verified)
            } catch (e: Exception) {
                // 再降级系统面板
            }
        }
        val chooser = Intent.createChooser(base, "分享").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            ctx.startActivity(chooser)
        } catch (e: ActivityNotFoundException) {
            throw GatewayError(ErrorCode.E_NOT_FOUND, "无可分享的接收方", channel = "intent")
        }
        return JSONObject().put("shared", true).put("channel", channelUsed)
            .put("target", target ?: "").put("foreground_verified", JSONObject.NULL)
    }
}

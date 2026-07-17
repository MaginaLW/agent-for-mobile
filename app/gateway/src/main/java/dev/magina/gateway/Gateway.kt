package dev.magina.gateway

import android.content.Context
import android.provider.Settings
import dev.magina.gateway.a11y.GatewayA11yService
import dev.magina.gateway.core.Audit
import dev.magina.gateway.core.RetryGuard
import dev.magina.gateway.core.SkillPack
import dev.magina.gateway.ime.ImeBridge
import java.util.UUID

/** L0 全局装配：技能包、审计、重试守卫、能力位、token/端口。 */
object Gateway {

    const val DEFAULT_PORT = 8848

    lateinit var appContext: Context
        private set
    lateinit var skills: SkillPack
        private set
    lateinit var audit: Audit
        private set
    val retryGuard = RetryGuard()

    fun init(context: Context) {
        if (::appContext.isInitialized) return
        appContext = context.applicationContext
        skills = SkillPack(appContext)
        audit = Audit(appContext)
    }

    val token: String
        get() {
            val prefs = appContext.getSharedPreferences("gateway", Context.MODE_PRIVATE)
            prefs.getString("token", null)?.let { return it }
            val t = UUID.randomUUID().toString().replace("-", "")
            prefs.edit().putString("token", t).apply()
            return t
        }

    /** 能力位：进 ctx.caps，大脑与工具降级逻辑都看它。 */
    fun caps(): List<String> {
        val out = ArrayList<String>()
        if (GatewayA11yService.instance != null) out.add("a11y")
        if (imeEnabled()) out.add("ime")
        if (ImeBridge.active) out.add("ime_active")
        if (Settings.canDrawOverlays(appContext)) out.add("overlay")
        // "shizuku" / "notif" / "ocr"：M1b 接入后上报
        return out
    }

    fun imeEnabled(): Boolean {
        val enabled = Settings.Secure.getString(
            appContext.contentResolver, Settings.Secure.ENABLED_INPUT_METHODS
        ) ?: return false
        return enabled.contains(appContext.packageName)
    }
}

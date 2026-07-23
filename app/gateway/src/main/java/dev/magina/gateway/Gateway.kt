package dev.magina.gateway

import android.content.Context
import android.provider.Settings
import android.view.inputmethod.InputMethodManager
import dev.magina.gateway.a11y.GatewayA11yService
import dev.magina.gateway.core.Audit
import dev.magina.gateway.core.InputCommitEvidenceStore
import dev.magina.gateway.core.PreparedTargetEvidenceStore
import dev.magina.gateway.core.RetryGuard
import dev.magina.gateway.core.SkillPack
import dev.magina.gateway.core.UiMutationCoordinator
import dev.magina.gateway.ime.ImeBridge
import dev.magina.gateway.testing.TestControl
import dev.magina.gateway.testing.TestControlProvider
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
    lateinit var testControl: TestControl
        private set
    val retryGuard = RetryGuard()
    val inputCommitEvidence = InputCommitEvidenceStore()
    val preparedTargetEvidence = PreparedTargetEvidenceStore()
    val uiMutationCoordinator = UiMutationCoordinator()

    fun init(context: Context) {
        if (::appContext.isInitialized) return
        appContext = context.applicationContext
        skills = SkillPack(appContext)
        audit = Audit(appContext)
        testControl = TestControlProvider.create(appContext)
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
        // 不可直读 Settings.Secure.ENABLED_INPUT_METHODS：targetSdk≥34 抛 SecurityException（真机日首跑实锤）
        val imm = appContext.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        return imm.enabledInputMethodList.any { it.packageName == appContext.packageName }
    }
}

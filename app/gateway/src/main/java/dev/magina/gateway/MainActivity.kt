package dev.magina.gateway

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import dev.magina.gateway.a11y.GatewayA11yService
import dev.magina.gateway.core.AuditFilter
import dev.magina.gateway.core.AuditLogReader
import dev.magina.gateway.core.AuditPage
import dev.magina.gateway.mcp.McpServer
import dev.magina.gateway.ui.GatewayDashboardModel
import dev.magina.gateway.ui.GatewayHealthSnapshot
import dev.magina.gateway.ui.PermissionCheckItem
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * 设备端执行网关控制台（4 标签原生面板：状态自检 / 只读宏目录 / 只读技能包 / 只读审计回放）。
 *
 * 保持 `.MainActivity` 名称与轻量启动路径不变，兼容 `bootstrap-gateway.ps1` 与通知「查看全部证据」跳转。
 */
class MainActivity : Activity() {

    private enum class Tab(val label: String) {
        STATUS("状态"),
        MACROS("宏目录"),
        SKILLS("技能包"),
        AUDIT("审计"),
    }

    private var activeTab: Tab = Tab.STATUS
    private var tokenVisible: Boolean = false
    private var auditFilter: AuditFilter = AuditFilter.ALL
    private var selectedAuditDay: String? = null
    private var availableAuditDays: List<String> = emptyList()
    private var auditGeneration: Int = 0

    private lateinit var headerView: TextView
    private val tabButtons = LinkedHashMap<Tab, Button>()
    private val tabContainers = LinkedHashMap<Tab, LinearLayout>()

    private lateinit var statusSummaryView: TextView
    private lateinit var tokenValueView: TextView
    private lateinit var tokenToggleButton: Button

    private lateinit var macroSummaryView: TextView
    private lateinit var macroListContainer: LinearLayout
    private lateinit var skillPackView: TextView

    private lateinit var auditDayButton: Button
    private lateinit var auditContentView: TextView
    private val auditFilterButtons = LinkedHashMap<AuditFilter, Button>()

    private val auditExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Gateway.init(this)

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.parseColor("#F5F6F8"))
            setPadding(32, 48, 32, 32)
        }

        headerView = TextView(this).apply {
            text = "手机 Agent 执行网关  v${BuildConfig.VERSION_NAME}"
            textSize = 18f
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(Color.parseColor("#1A1C1E"))
            setPadding(4, 0, 4, 16)
        }
        root.addView(headerView)

        val tabBar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, 0, 0, 16)
        }
        Tab.values().forEach { tab ->
            val btn = Button(this).apply {
                text = tab.label
                textSize = 13f
                setOnClickListener { switchTab(tab) }
            }
            tabButtons[tab] = btn
            tabBar.addView(btn, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        }
        root.addView(tabBar)

        val scrollContent = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
        }
        scrollContent.addView(buildStatusTab().also { tabContainers[Tab.STATUS] = it })
        scrollContent.addView(buildMacrosTab().also { tabContainers[Tab.MACROS] = it })
        scrollContent.addView(buildSkillsTab().also { tabContainers[Tab.SKILLS] = it })
        scrollContent.addView(buildAuditTab().also { tabContainers[Tab.AUDIT] = it })

        root.addView(
            ScrollView(this).apply { addView(scrollContent) },
            LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f),
        )

        setContentView(root)
        switchTab(Tab.STATUS)
    }

    override fun onResume() {
        super.onResume()
        refreshAll()
    }

    override fun onPause() {
        if (tokenVisible) {
            tokenVisible = false
            updateTokenDisplay()
        }
        super.onPause()
    }

    override fun onDestroy() {
        auditExecutor.shutdownNow()
        super.onDestroy()
    }

    private fun buildStatusTab(): LinearLayout {
        val container = cardContainer()
        statusSummaryView = monospaceTextView().apply {
            setPadding(0, 0, 0, 24)
        }
        container.addView(statusSummaryView)

        val tokenBox = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = cardBackground("#EEF2F6")
            setPadding(24, 20, 24, 20)
        }
        tokenValueView = TextView(this).apply {
            textSize = 13f
            typeface = Typeface.MONOSPACE
            setTextColor(Color.parseColor("#1A1C1E"))
            setPadding(0, 0, 0, 12)
        }
        tokenBox.addView(tokenValueView)
        val tokenActions = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        tokenToggleButton = Button(this).apply {
            text = "显示 token"
            setOnClickListener {
                tokenVisible = !tokenVisible
                updateTokenDisplay()
            }
        }
        val copyTokenButton = Button(this).apply {
            text = "复制 token"
            setOnClickListener {
                val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                cm.setPrimaryClip(ClipData.newPlainText("gateway-token", Gateway.token()))
                Toast.makeText(this@MainActivity, "token 已复制", Toast.LENGTH_SHORT).show()
            }
        }
        tokenActions.addView(tokenToggleButton, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        tokenActions.addView(copyTokenButton, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        tokenBox.addView(tokenActions)
        container.addView(tokenBox)

        fun addActionButton(label: String, onClick: () -> Unit) {
            container.addView(
                Button(this).apply {
                    text = label
                    setOnClickListener { onClick() }
                },
            )
        }

        addActionButton("① 授予运行权限（蓝牙/通知/媒体）") { requestRuntimePermissions() }
        addActionButton("② 开启无障碍服务") {
            openSettingsScreen(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
        }
        addActionButton("③ 启用网关输入法") {
            openSettingsScreen(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS))
        }
        addActionButton("④ 授予悬浮窗（确认层）") {
            openSettingsScreen(
                Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName")),
            )
        }
        addActionButton("⑤ 电池优化 / 后台保活设置") { openBatteryOptimizationSettings() }
        addActionButton("⑥ 启动网关（开机自动恢复）") { serviceAction(start = true) }
        addActionButton("停止网关（同时关闭开机恢复）") { serviceAction(start = false) }
        addActionButton("刷新状态") { refreshStatus() }
        return container
    }

    private fun buildMacrosTab(): LinearLayout {
        val container = cardContainer()
        macroSummaryView = TextView(this).apply {
            textSize = 13f
            setTextColor(Color.parseColor("#374151"))
            setPadding(0, 0, 0, 16)
        }
        container.addView(macroSummaryView)
        macroListContainer = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
        }
        container.addView(macroListContainer)
        return container
    }

    private fun buildSkillsTab(): LinearLayout {
        val container = cardContainer()
        skillPackView = monospaceTextView()
        container.addView(skillPackView)
        return container
    }

    private fun buildAuditTab(): LinearLayout {
        val container = cardContainer()
        val filterRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, 0, 0, 8)
        }
        AuditFilter.values().forEach { filter ->
            val btn = Button(this).apply {
                text = filter.label
                textSize = 12f
                setOnClickListener {
                    auditFilter = filter
                    refreshAuditTab()
                }
            }
            auditFilterButtons[filter] = btn
            filterRow.addView(btn, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        }
        container.addView(filterRow)

        val controlRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, 0, 0, 12)
        }
        auditDayButton = Button(this).apply {
            text = "切换日期"
            setOnClickListener {
                if (availableAuditDays.size > 1) {
                    val currentIndex = availableAuditDays.indexOf(selectedAuditDay)
                    val nextIndex = if (currentIndex < 0) 0 else (currentIndex + 1) % availableAuditDays.size
                    selectedAuditDay = availableAuditDays[nextIndex]
                    refreshAuditTab()
                } else {
                    Toast.makeText(this@MainActivity, "当前仅有 1 天审计记录", Toast.LENGTH_SHORT).show()
                }
            }
        }
        val refreshAuditBtn = Button(this).apply {
            text = "刷新审计"
            setOnClickListener { refreshAuditTab() }
        }
        controlRow.addView(auditDayButton, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        controlRow.addView(refreshAuditBtn, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        container.addView(controlRow)

        auditContentView = monospaceTextView()
        container.addView(auditContentView)
        return container
    }

    private fun switchTab(target: Tab) {
        activeTab = target
        Tab.values().forEach { tab ->
            tabContainers[tab]?.visibility = if (tab == target) View.VISIBLE else View.GONE
            val selected = tab == target
            tabButtons[tab]?.apply {
                setTypeface(null, if (selected) Typeface.BOLD else Typeface.NORMAL)
                alpha = if (selected) 1.0f else 0.7f
            }
        }
        when (target) {
            Tab.STATUS -> refreshStatus()
            Tab.MACROS -> refreshMacrosTab()
            Tab.SKILLS -> refreshSkillsTab()
            Tab.AUDIT -> refreshAuditTab()
        }
    }

    private fun refreshAll() {
        refreshStatus()
        if (activeTab == Tab.MACROS) refreshMacrosTab()
        if (activeTab == Tab.SKILLS) refreshSkillsTab()
        if (activeTab == Tab.AUDIT) refreshAuditTab()
    }

    private fun refreshStatus() {
        val diag = GatewayA11yService.instance?.let { service ->
            runCatching { service.foregroundDiagnostics() }.getOrNull()
        }
        val fgSummary = when {
            GatewayA11yService.instance == null -> "无障碍未连接"
            diag == null -> "诊断暂不可用"
            diag.optBoolean("foreground_known", false) -> {
                val pkg = diag.optString("package")
                val act = diag.optString("activity").ifBlank { "(bootstrap)" }
                "$pkg / $act"
            }
            else -> "未知（${diag.optString("foreground_reason", "unknown")}）"
        }
        val topology = diag?.optString("window_topology", "unknown")?.ifBlank { "unknown" } ?: "a11y_disconnected"
        val batteryIgnored = isIgnoringBatteryOptimizations()
        val bootRestoreState = when {
            GatewayService.bootChoiceSaveUnconfirmed -> "UNKNOWN（选择保存未确认）"
            GatewayService.resumeAfterBoot(this) -> "已开启"
            else -> "未开启"
        }
        val snapshot = GatewayHealthSnapshot(
            versionName = BuildConfig.VERSION_NAME,
            port = Gateway.DEFAULT_PORT,
            serverRunning = McpServer.running,
            bootRestoreState = bootRestoreState,
            capabilities = Gateway.caps(),
            auditWriteFailures = Gateway.audit.writeFailures,
            foregroundSummary = fgSummary,
            windowTopology = topology,
            batteryOptimizationIgnored = batteryIgnored,
            permissions = collectPermissions(batteryIgnored),
        )
        statusSummaryView.text = GatewayDashboardModel.formatHealthSummary(snapshot)
        updateTokenDisplay()
    }

    private fun updateTokenDisplay() {
        val rawToken = Gateway.token()
        val shown = if (tokenVisible) rawToken else GatewayDashboardModel.maskToken(rawToken)
        tokenValueView.text = "Token：$shown"
        tokenToggleButton.text = if (tokenVisible) "隐藏 token" else "显示 token"
    }

    private fun refreshMacrosTab() {
        val cards = GatewayDashboardModel.buildMacroCards(Gateway.macros.all())
        val verifiedCount = cards.count { it.isVerified }
        macroSummaryView.text = "共 ${cards.size} 枚内置声明式宏（已转正 $verifiedCount / 候选 ${cards.size - verifiedCount}）。\n" +
            "本页仅只读展示；宏仅可经 MCP skill_macro_exec 调用并受统一安全门与确认卡约束。"
        macroListContainer.removeAllViews()
        cards.forEach { card ->
            val block = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                background = cardBackground(if (card.isVerified) "#ECFDF5" else "#F3F4F6")
                setPadding(24, 18, 24, 18)
            }
            val title = TextView(this).apply {
                val badge = if (card.isVerified) "✅ 已转正 ${card.verified}" else "🧪 候选未实测"
                text = "${card.id}  [$badge]"
                textSize = 14f
                setTypeface(typeface, Typeface.BOLD)
                setTextColor(Color.parseColor(if (card.isVerified) "#065F46" else "#374151"))
            }
            val detail = TextView(this).apply {
                val mode = if (card.readonly) "只读" else "读写"
                text = buildString {
                    appendLine("应用：${card.app}（${card.expectPackage}） | $mode")
                    appendLine("用途：${card.description}")
                    appendLine("参数：${card.paramsSummary}")
                    append("步骤（${card.stepCount}）：${card.stepToolsFlow}")
                }
                textSize = 12f
                typeface = Typeface.MONOSPACE
                setTextColor(Color.parseColor("#1F2937"))
                setPadding(0, 8, 0, 0)
            }
            block.addView(title)
            block.addView(detail)
            val lp = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            ).apply { setMargins(0, 0, 0, 14) }
            macroListContainer.addView(block, lp)
        }
    }

    private fun refreshSkillsTab() {
        skillPackView.text = GatewayDashboardModel.buildSkillPackOverview(Gateway.skills).renderedText
    }

    private fun refreshAuditTab() {
        AuditFilter.values().forEach { filter ->
            val selected = filter == auditFilter
            auditFilterButtons[filter]?.apply {
                setTypeface(null, if (selected) Typeface.BOLD else Typeface.NORMAL)
                alpha = if (selected) 1.0f else 0.7f
            }
        }
        val gen = ++auditGeneration
        val requestedDay = selectedAuditDay
        val filter = auditFilter
        val auditDir = Gateway.audit.auditDirectory()
        auditContentView.text = "正在读取审计日志…"
        auditExecutor.execute {
            val page: AuditPage = AuditLogReader.readDay(auditDir, requestedDay, filter)
            val rendered = GatewayDashboardModel.formatAuditPage(page, filter)
            runOnUiThread {
                if (isFinishing || isDestroyed || gen != auditGeneration) return@runOnUiThread
                availableAuditDays = page.availableDays
                selectedAuditDay = page.dayKey
                auditDayButton.text = if (page.dayKey != null) "日期：${page.dayKey}" else "切换日期"
                auditContentView.text = rendered
            }
        }
    }

    private fun collectPermissions(batteryIgnored: Boolean): List<PermissionCheckItem> {
        val btGranted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
        val notifGranted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
        val mediaGranted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            checkSelfPermission(Manifest.permission.READ_MEDIA_IMAGES) == PackageManager.PERMISSION_GRANTED
        } else {
            checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
        }
        return listOf(
            PermissionCheckItem(
                key = "a11y",
                label = "无障碍服务（GatewayA11yService）",
                granted = GatewayA11yService.instance != null,
                requiredForCore = true,
                guidance = "点「开启无障碍服务」启用执行网关",
            ),
            PermissionCheckItem(
                key = "overlay",
                label = "悬浮窗权限（ConfirmOverlay）",
                granted = Settings.canDrawOverlays(this),
                requiredForCore = true,
                guidance = "点「授予悬浮窗」以允许危险动作确认卡",
            ),
            PermissionCheckItem(
                key = "ime",
                label = "网关输入法（GatewayIme）",
                granted = Gateway.imeEnabled(),
                requiredForCore = true,
                guidance = "点「启用网关输入法」以启用中文注入通道",
            ),
            PermissionCheckItem(
                key = "notifications",
                label = "通知权限（前台服务与审批提醒）",
                granted = notifGranted,
                requiredForCore = false,
                guidance = "点「授予运行权限」允许弹窗通知",
            ),
            PermissionCheckItem(
                key = "bluetooth",
                label = "蓝牙读取权限（BLUETOOTH_CONNECT）",
                granted = btGranted,
                requiredForCore = false,
                guidance = "点「授予运行权限」后才可读取蓝牙状态",
            ),
            PermissionCheckItem(
                key = "media",
                label = "媒体读取权限（media_query）",
                granted = mediaGranted,
                requiredForCore = false,
                guidance = "点「授予运行权限」后可查截图与相册",
            ),
            PermissionCheckItem(
                key = "battery",
                label = "忽略电池优化（后台保活）",
                granted = batteryIgnored,
                requiredForCore = false,
                guidance = "点「电池优化 / 后台保活设置」放行执行网关",
            ),
        )
    }

    private fun isIgnoringBatteryOptimizations(): Boolean = runCatching {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        pm.isIgnoringBatteryOptimizations(packageName)
    }.getOrDefault(false)

    private fun requestRuntimePermissions() {
        val perms = buildList {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                add(Manifest.permission.BLUETOOTH_CONNECT)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                add(Manifest.permission.POST_NOTIFICATIONS)
                add(Manifest.permission.READ_MEDIA_IMAGES)
            } else {
                add(Manifest.permission.READ_EXTERNAL_STORAGE)
            }
        }
        if (perms.isNotEmpty()) {
            requestPermissions(perms.toTypedArray(), 1)
        }
    }

    private fun openBatteryOptimizationSettings() {
        val batteryIntent = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
        try {
            startActivity(batteryIntent)
        } catch (_: ActivityNotFoundException) {
            openSettingsScreen(
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")),
            )
        }
    }

    private fun openSettingsScreen(intent: Intent) {
        try {
            startActivity(intent)
        } catch (error: ActivityNotFoundException) {
            Log.w("GatewayUi", "无法打开设置页: ${intent.action}", error)
            Toast.makeText(this, "设备未提供对应设置入口，请在系统设置手动查找", Toast.LENGTH_LONG).show()
        }
    }

    private fun serviceAction(start: Boolean) {
        try {
            if (start) GatewayService.start(this) else GatewayService.stop(this)
        } catch (error: RuntimeException) {
            Log.w("GatewayUi", "用户切换网关服务失败", error)
            val message = if (GatewayService.bootChoiceSaveUnconfirmed) {
                "操作未完整完成；开机恢复选择保存未确认，请检查状态"
            } else {
                "系统未完成服务操作，请检查状态"
            }
            Toast.makeText(this, message, Toast.LENGTH_LONG).show()
        }
        headerView.postDelayed({
            if (!isFinishing && !isDestroyed) refreshStatus()
        }, 500)
    }

    private fun cardContainer(): LinearLayout = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        background = cardBackground("#FFFFFF")
        setPadding(28, 28, 28, 28)
    }

    private fun monospaceTextView(): TextView = TextView(this).apply {
        textSize = 13f
        typeface = Typeface.MONOSPACE
        setTextColor(Color.parseColor("#1F2937"))
    }

    private fun cardBackground(hexColor: String): GradientDrawable = GradientDrawable().apply {
        setColor(Color.parseColor(hexColor))
        cornerRadius = 16f
    }
}

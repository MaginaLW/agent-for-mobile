package dev.magina.gateway.ui

import dev.magina.gateway.core.AuditDaySummary
import dev.magina.gateway.core.AuditFilter
import dev.magina.gateway.core.AuditPage
import dev.magina.gateway.core.AuditRecord
import dev.magina.gateway.core.SkillPack
import dev.magina.gateway.macro.MacroCatalog
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class GatewayDashboardModelTest {

    @Test
    fun `maskToken hides middle characters and short tokens`() {
        val sampleToken = "a1b2c3d4".repeat(4)
        val masked = GatewayDashboardModel.maskToken(sampleToken)
        assertEquals("a1b2••••••••c3d4", masked)
        assertFalse(masked.contains(sampleToken))

        assertEquals("••••••••", GatewayDashboardModel.maskToken("short"))
        assertEquals("••••••••", GatewayDashboardModel.maskToken(""))
    }

    @Test
    fun `formatHealthSummary reports version missing core permissions and audit failures`() {
        val snapshot = GatewayHealthSnapshot(
            versionName = "0.2.0-m3",
            port = 8848,
            serverRunning = true,
            bootRestoreState = "已开启",
            capabilities = listOf("a11y", "ime", "overlay", "ocr"),
            auditWriteFailures = 3,
            foregroundSummary = "com.xingin.xhs / .MainActivity",
            windowTopology = "single",
            batteryOptimizationIgnored = false,
            permissions = listOf(
                PermissionCheckItem("a11y", "无障碍服务", granted = true, requiredForCore = true, guidance = ""),
                PermissionCheckItem("overlay", "悬浮窗", granted = false, requiredForCore = true, guidance = "去设置开启"),
                PermissionCheckItem("battery", "电池白名单", granted = false, requiredForCore = false, guidance = "建议放行"),
            ),
        )

        val text = GatewayDashboardModel.formatHealthSummary(snapshot)
        assertTrue(text.contains("执行网关 0.2.0-m3"))
        assertTrue(text.contains("运行中 ✅"))
        assertTrue(text.contains("审计写盘告警：累计失败 3 次"))
        assertTrue(text.contains("缺失核心 1 项 / 总缺失 2 项"))
        assertTrue(text.contains("⚠ 悬浮窗（必需缺失）：去设置开启"))
    }

    @Test
    fun `buildMacroCards sorts verified first and formats params and tool chain`() {
        val rawMacros = listOf(
            JSONObject(
                """
                {
                  "id": "jd_readonly_prepare",
                  "version": 1,
                  "app": "京东",
                  "expect_package": "com.jingdong.app.mall",
                  "description": "京东只读前置",
                  "readonly": true,
                  "verified": "",
                  "params": {},
                  "steps": [
                    {"id": "s1", "tool": "app_launch", "args": {"name": "京东"}},
                    {"id": "s2", "tool": "ui_snapshot", "args": {"scope": "full"}}
                  ]
                }
                """.trimIndent(),
            ),
            JSONObject(
                """
                {
                  "id": "xhs_search_prepare",
                  "version": 1,
                  "app": "小红书",
                  "expect_package": "com.xingin.xhs",
                  "description": "小红书搜索直达",
                  "readonly": true,
                  "verified": "2026-11-25",
                  "params": {
                    "keyword": {"type": "string", "required": true, "min_length": 1, "max_length": 64}
                  },
                  "steps": [
                    {"id": "s1", "tool": "foreground_app", "args": {}},
                    {"id": "s2", "tool": "open_uri", "args": {"uri": "xhsdiscover://search/result?keyword={{keyword|urlencode}}"}},
                    {"id": "s3", "tool": "ui_snapshot", "args": {"scope": "full"}}
                  ]
                }
                """.trimIndent(),
            ),
        )
        val catalog = MacroCatalog(rawMacros) { false }
        val cards = GatewayDashboardModel.buildMacroCards(catalog.all())

        assertEquals(listOf("xhs_search_prepare", "jd_readonly_prepare"), cards.map { it.id })
        assertTrue(cards[0].isVerified)
        assertEquals("keyword(必填, 1..64字)", cards[0].paramsSummary)
        assertEquals("foreground_app → open_uri → ui_snapshot", cards[0].stepToolsFlow)
        assertFalse(cards[1].isVerified)
        assertEquals("无参数", cards[1].paramsSummary)

        val rendered = GatewayDashboardModel.formatMacroCatalogText(cards)
        assertTrue(rendered.contains("已转正 1 / 候选 1"))
    }

    @Test
    fun `buildSkillPackOverview summarizes repository skillpack assets accurately`() {
        val assetDir = findSkillpackDir()
        val skills = SkillPack(
            appsJson = JSONObject(File(assetDir, "apps.json").readText()),
            deeplinksJson = JSONObject(File(assetDir, "deeplinks.json").readText()),
            safetyJson = JSONObject(File(assetDir, "safety.json").readText()),
        )

        val overview = GatewayDashboardModel.buildSkillPackOverview(skills)
        assertEquals(skills.appAliases.size, overview.aliasCount)
        assertEquals(skills.blockedAppPrefixes.size, overview.blockedAppPrefixCount)
        assertEquals(
            skills.deeplinks.size,
            overview.verifiedDeeplinkCount + overview.candidateDeeplinkCount,
        )
        assertTrue(overview.renderedText.contains("xhsdiscover://search/result"))
        assertTrue(overview.renderedText.contains("com.eg.android.AlipayGphone"))
    }

    @Test
    fun `formatAuditPage renders summary and records cleanly`() {
        val page = AuditPage(
            dayKey = "20261126",
            availableDays = listOf("20261126", "20261125"),
            summary = AuditDaySummary(
                dayKey = "20261126",
                totalCount = 10,
                okCount = 9,
                failureCount = 1,
                safetyCount = 2,
                macroCount = 4,
                malformedLines = 1,
            ),
            records = listOf(
                AuditRecord(
                    timestamp = "2026-11-26T22:00:00.000",
                    id = "a-000010",
                    tool = "skill_macro_exec",
                    result = "OK",
                    channel = "macro",
                    elapsedMs = 3500,
                    note = "",
                    argsSummary = "name=taobao_orders_prepare",
                    isMacroChild = false,
                    isSafetyEvent = false,
                    isFailure = false,
                ),
            ),
        )
        val text = GatewayDashboardModel.formatAuditPage(page, AuditFilter.ALL)
        assertTrue(text.contains("日期：20261126（共 2 天记录）"))
        assertTrue(text.contains("总 10 | OK 9 | 失败 1 | 安全 2 | 宏子步 4"))
        assertTrue(text.contains("已容错跳过损坏行：1 行"))
        assertTrue(text.contains("a-000010 [22:00:00.000] skill_macro_exec → OK (3500ms, macro)"))
    }

    private fun findSkillpackDir(): File {
        var cursor: File? = File(requireNotNull(System.getProperty("user.dir"))).absoluteFile
        while (cursor != null) {
            listOf(
                File(cursor, "gateway/src/main/assets/skillpack"),
                File(cursor, "app/gateway/src/main/assets/skillpack"),
            ).firstOrNull(File::isDirectory)?.let { return it }
            cursor = cursor.parentFile
        }
        error("找不到 skillpack 目录")
    }
}

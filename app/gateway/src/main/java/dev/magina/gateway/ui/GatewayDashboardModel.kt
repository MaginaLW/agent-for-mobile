package dev.magina.gateway.ui

import dev.magina.gateway.core.AuditFilter
import dev.magina.gateway.core.AuditPage
import dev.magina.gateway.core.SkillPack
import dev.magina.gateway.macro.MacroSpec

data class PermissionCheckItem(
    val key: String,
    val label: String,
    val granted: Boolean,
    val requiredForCore: Boolean,
    val guidance: String,
)

data class GatewayHealthSnapshot(
    val versionName: String,
    val port: Int,
    val serverRunning: Boolean,
    val bootRestoreState: String,
    val capabilities: List<String>,
    val auditWriteFailures: Long,
    val foregroundSummary: String,
    val windowTopology: String,
    val batteryOptimizationIgnored: Boolean,
    val permissions: List<PermissionCheckItem>,
)

internal data class MacroCardModel(
    val id: String,
    val app: String,
    val expectPackage: String,
    val description: String,
    val readonly: Boolean,
    val verified: String,
    val isVerified: Boolean,
    val paramsSummary: String,
    val stepCount: Int,
    val stepToolsFlow: String,
)

data class SkillPackOverviewModel(
    val aliasCount: Int,
    val verifiedDeeplinkCount: Int,
    val candidateDeeplinkCount: Int,
    val blockedAppPrefixCount: Int,
    val dangerWordCount: Int,
    val actionConfirmWordCount: Int,
    val sendWordCount: Int,
    val unreliableSettingsCount: Int,
    val renderedText: String,
)

/**
 * 网关设备端面板的纯 Kotlin 视图模型与脱敏格式化器（零 Android UI 依赖，供 JVM 单测覆盖）。
 */
object GatewayDashboardModel {

    fun maskToken(token: String): String {
        val trimmed = token.trim()
        if (trimmed.length < 8) return "••••••••"
        return "${trimmed.take(4)}••••••••${trimmed.takeLast(4)}"
    }

    fun formatPermissionLine(item: PermissionCheckItem): String = if (item.granted) {
        "✅ ${item.label}"
    } else {
        val levelTag = if (item.requiredForCore) "必需缺失" else "可选缺失"
        "⚠ ${item.label}（$levelTag）：${item.guidance}"
    }

    fun formatHealthSummary(snapshot: GatewayHealthSnapshot): String = buildString {
        appendLine("== 执行网关 ${snapshot.versionName} ==")
        appendLine("MCP 端点：http://127.0.0.1:${snapshot.port}/mcp")
        appendLine("服务状态：${if (snapshot.serverRunning) "运行中 ✅" else "未启动"}")
        appendLine("开机恢复：${snapshot.bootRestoreState}")
        appendLine("能力位：${snapshot.capabilities.joinToString(", ").ifEmpty { "无" }}")
        appendLine("前台诊断：${snapshot.foregroundSummary}")
        appendLine("窗口拓扑：${snapshot.windowTopology}")
        appendLine("电池白名单：${if (snapshot.batteryOptimizationIgnored) "已忽略电池优化 ✅" else "未配置（建议加白名单保活）"}")
        if (snapshot.auditWriteFailures > 0) {
            appendLine("⚠ 审计写盘告警：累计失败 ${snapshot.auditWriteFailures} 次，请检查存储状态")
        } else {
            appendLine("审计证据链：正常（writeFailures=0）")
        }

        val missingCore = snapshot.permissions.count { it.requiredForCore && !it.granted }
        val missingAny = snapshot.permissions.count { !it.granted }
        appendLine()
        appendLine("== 权限与通道自检（缺失核心 $missingCore 项 / 总缺失 $missingAny 项）==")
        snapshot.permissions.forEach { appendLine(formatPermissionLine(it)) }

        appendLine()
        appendLine("== PC 侧接入 ==")
        appendLine("adb forward tcp:${snapshot.port} tcp:${snapshot.port}")
        append("在 PC 仓库通过 scripts/dispatch.ps1（Codex + gateway）派单")
    }

    internal fun buildMacroCards(macros: List<MacroSpec>): List<MacroCardModel> = macros
        .sortedWith(compareByDescending<MacroSpec> { it.verified.isNotEmpty() }.thenBy { it.id })
        .map { spec ->
            val paramsSummary = if (spec.params.isEmpty()) {
                "无参数"
            } else {
                spec.params.values.joinToString("；") { param ->
                    val req = if (param.required) "必填" else "可选"
                    "${param.name}($req, ${param.minLength}..${param.maxLength}字)"
                }
            }
            MacroCardModel(
                id = spec.id,
                app = spec.app,
                expectPackage = spec.expectPackage,
                description = spec.description,
                readonly = spec.readonly,
                verified = spec.verified,
                isVerified = spec.verified.isNotEmpty(),
                paramsSummary = paramsSummary,
                stepCount = spec.steps.size,
                stepToolsFlow = spec.steps.joinToString(" → ") { it.tool },
            )
        }

    internal fun formatMacroCatalogText(cards: List<MacroCardModel>): String = buildString {
        val verifiedCount = cards.count { it.isVerified }
        appendLine("== 内置声明式宏目录（只读，共 ${cards.size} 枚：已转正 $verifiedCount / 候选 ${cards.size - verifiedCount}）==")
        appendLine("说明：宏仅可经 MCP skill_macro_exec 调用，每步均走统一黑名单与 SafetyGate/ConfirmOverlay。")
        if (cards.isEmpty()) {
            append("暂无已注册宏。")
            return@buildString
        }
        cards.forEach { card ->
            appendLine()
            val badge = if (card.isVerified) "✅ 已转正（${card.verified}）" else "🧪 候选未实测"
            val mode = if (card.readonly) "只读" else "读写"
            appendLine("• ${card.id}  [$badge | $mode]")
            appendLine("  应用：${card.app}（${card.expectPackage}）")
            appendLine("  用途：${card.description}")
            appendLine("  参数：${card.paramsSummary}")
            appendLine("  步骤（${card.stepCount}）：${card.stepToolsFlow}")
        }
    }

    fun buildSkillPackOverview(skills: SkillPack): SkillPackOverviewModel {
        val verifiedDeeplinks = skills.deeplinks.count { it.verified.isNotEmpty() }
        val candidateDeeplinks = skills.deeplinks.size - verifiedDeeplinks
        val rendered = buildString {
            appendLine("== 内置技能包与安全守卫（只读）==")
            appendLine("App 别名：${skills.appAliases.size} 个 | 指南：${skills.appGuides.size} 个")
            appendLine("深链注册：${skills.deeplinks.size} 条（✅ 已实测 $verifiedDeeplinks / 🔵 候选 $candidateDeeplinks）")
            appendLine("黑名单前缀：${skills.blockedAppPrefixes.size} 个 | 敏感目标：${skills.sensitiveTargets.size} 个")
            appendLine("词表规模：不可逆 ${skills.dangerWords.size} / 泛化确认 ${skills.actionConfirmWords.size} / 可撤回发送 ${skills.sendWords.size}")

            appendLine()
            appendLine("【已登记 App 别名】")
            skills.appAliases.entries.sortedBy { it.key }.forEach { (alias, pkg) ->
                val guideFlag = if (pkg in skills.appGuides) " [含守卫]" else ""
                appendLine("• $alias → $pkg$guideFlag")
            }

            appendLine()
            appendLine("【深链注册表】")
            skills.deeplinks.forEach { dl ->
                val mark = if (dl.verified.isNotEmpty()) "✅ ${dl.verified}" else "🔵 未实测"
                appendLine("• ${dl.prefix} → ${dl.app}（${dl.expectPackage}）[$mark]")
            }

            if (skills.unreliableSettingsActions.isNotEmpty()) {
                appendLine()
                appendLine("【不可靠系统设置 Action】")
                skills.unreliableSettingsActions.forEach { item ->
                    appendLine("• ${item.action}（${item.deviceScope}）：${item.fallback}")
                }
            }

            appendLine()
            appendLine("【敏感黑名单前缀（人工确认不可绕过）】")
            appendLine(skills.blockedAppPrefixes.joinToString("、").ifEmpty { "无" })
        }
        return SkillPackOverviewModel(
            aliasCount = skills.appAliases.size,
            verifiedDeeplinkCount = verifiedDeeplinks,
            candidateDeeplinkCount = candidateDeeplinks,
            blockedAppPrefixCount = skills.blockedAppPrefixes.size,
            dangerWordCount = skills.dangerWords.size,
            actionConfirmWordCount = skills.actionConfirmWords.size,
            sendWordCount = skills.sendWords.size,
            unreliableSettingsCount = skills.unreliableSettingsActions.size,
            renderedText = rendered,
        )
    }

    fun formatAuditPage(page: AuditPage, filter: AuditFilter): String = buildString {
        appendLine("== 审计日志回放（只读 · 筛选：${filter.label}）==")
        val summary = page.summary
        if (page.dayKey == null || summary == null) {
            append("本地尚无审计 jsonl 记录。派单或调用 MCP 工具后会自动落盘于 filesDir/audit/YYYYMMDD.jsonl。")
            return@buildString
        }
        appendLine("日期：${page.dayKey}（共 ${page.availableDays.size} 天记录）")
        appendLine(
            "当日汇总：总 ${summary.totalCount} | OK ${summary.okCount} | 失败 ${summary.failureCount} | 安全 ${summary.safetyCount} | 宏子步 ${summary.macroCount}",
        )
        if (summary.malformedLines > 0) {
            appendLine("⚠ 已容错跳过损坏行：${summary.malformedLines} 行")
        }
        if (page.records.isEmpty()) {
            append("\n当前筛选「${filter.label}」下无匹配记录。")
            return@buildString
        }
        appendLine("\n显示最近 ${page.records.size} 条（新 → 旧）：")
        page.records.forEach { r ->
            appendLine()
            val timePart = r.timestamp.substringAfter('T', r.timestamp)
            val channelPart = r.channel.ifBlank { "-" }
            appendLine("${r.id} [$timePart] ${r.tool} → ${r.result} (${r.elapsedMs}ms, $channelPart)")
            if (r.argsSummary.isNotBlank()) {
                appendLine("  参数：${r.argsSummary}")
            }
            if (r.note.isNotBlank()) {
                appendLine("  备注：${r.note}")
            }
        }
    }
}

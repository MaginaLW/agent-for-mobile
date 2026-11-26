package dev.magina.gateway.mcp

import dev.magina.gateway.Gateway
import dev.magina.gateway.a11y.ConversationTitleElement
import dev.magina.gateway.a11y.ConversationTitlePolicy
import dev.magina.gateway.a11y.GatewayA11yService
import dev.magina.gateway.core.IntentEvidenceReadback
import dev.magina.gateway.core.IntentEvidenceReader
import dev.magina.gateway.core.IntentReadbackChannel
import dev.magina.gateway.tools.UiTools
import org.json.JSONObject

internal fun parseConversationTitleElements(
    snapshotJson: JSONObject,
    paneFilter: String? = null,
): List<ConversationTitleElement> {
    val elements = snapshotJson.optJSONArray("elements") ?: return emptyList()
    return buildList(elements.length()) {
        for (i in 0 until elements.length()) {
            val item = elements.optJSONObject(i) ?: continue
            val pane = item.optString("pane")
            if (!paneFilter.isNullOrBlank() && pane.isNotBlank() && pane != paneFilter && pane != "full") {
                continue
            }
            val bounds = item.optJSONArray("bounds") ?: continue
            if (bounds.length() != 4) continue
            val confidence = if (item.has("confidence")) {
                item.optDouble("confidence").takeIf { it.isFinite() }
            } else {
                null
            }
            add(
                ConversationTitleElement(
                    text = item.optString("text"),
                    description = item.optString("desc"),
                    source = item.optString("source"),
                    confidence = confidence,
                    left = bounds.optInt(0),
                    top = bounds.optInt(1),
                    right = bounds.optInt(2),
                    bottom = bounds.optInt(3),
                ),
            )
        }
    }
}

/**
 * Android 只读目标与内容重建通道（spec `2026-08-02-语义意图审批` §2.4 / §5）。
 *
 * 严格只读重读当前前台包名、目标会话标题（a11y 或 OCR）与输入框内容，
 * 绝不写入输入框、绝不点击导航或覆盖等待期间用户手动编辑的内容。
 */
internal class AndroidIntentEvidenceReader(
    private val a11yProvider: () -> GatewayA11yService?,
    private val targetPaneProvider: () -> String?,
) : IntentEvidenceReader {

    override fun read(): IntentEvidenceReadback {
        val a11y = a11yProvider() ?: return unavailable()
        val ctx = runCatching { a11y.ctx(Gateway.caps()) }.getOrNull() ?: return unavailable()
        val pkg = ctx.optString("app").takeIf { ctx.optBoolean("foreground_known", false) && it.isNotBlank() }
            ?: return unavailable()

        val pane = targetPaneProvider()
        val snap = runCatching { a11y.forceFreshVision("interactive") }.getOrNull()
        val titleObservation = if (snap != null) {
            val region = a11y.paneRegionBounds(pane)
            ConversationTitlePolicy.readTitle(
                elements = parseConversationTitleElements(snap, pane),
                regionLeft = region.left,
                regionTop = region.top,
                regionWidth = region.width(),
                regionHeight = region.height(),
                blockingOverlay = snap.optBoolean("blocking_overlay", false),
            )
        } else {
            null
        }

        val focused = runCatching { UiTools.focusedInputSnapshot(a11y) }.getOrNull()
        val a11yText = focused?.readableText
        val (contentText, contentChannel) = if (a11yText != null) {
            a11yText to IntentReadbackChannel.A11Y
        } else {
            val ocrText = runCatching {
                a11y.ocrReadInputBarRegion(focused?.bounds).text
            }.getOrNull()
            ocrText to IntentReadbackChannel.OCR
        }

        return IntentEvidenceReadback(
            packageName = pkg,
            targetLabel = titleObservation?.label,
            content = contentText,
            targetChannel = titleObservation?.channel ?: IntentReadbackChannel.A11Y,
            contentChannel = contentChannel,
        )
    }

    private fun unavailable(): IntentEvidenceReadback = IntentEvidenceReadback(
        packageName = null,
        targetLabel = null,
        content = null,
        targetChannel = IntentReadbackChannel.A11Y,
        contentChannel = IntentReadbackChannel.A11Y,
    )
}

package dev.magina.gateway.a11y

import dev.magina.gateway.core.IntentReadbackChannel
import dev.magina.gateway.core.TextNorm

internal data class ConversationTitleElement(
    val text: String,
    val description: String,
    val source: String,
    val confidence: Double?,
    val left: Int,
    val top: Int,
    val right: Int,
    val bottom: Int,
)

internal data class ConversationTitleObservation(
    val label: String,
    val channel: IntentReadbackChannel,
    val source: String,
)

/**
 * 会话标题读取策略（生产与 debug P0 准备宏同源，绝不另起弱化版本）。
 *
 * 复用 [MIN_RECOGNITION_OCR_CONFIDENCE] 与顶部工具栏几何带判据；生产提取要求在区域工具栏带内
 * 仅存在**唯一一个**非状态栏噪声的标题候选，0 个或多个不同候选一律 fail-closed 返回 `null`。
 */
internal object ConversationTitlePolicy {

    private val TIME_PATTERN = Regex("^\\d{1,2}:\\d{2}$")
    private val PERCENT_PATTERN = Regex("^\\d{1,3}%$")
    private val SPEED_PATTERN = Regex("^\\d+(\\.\\d+)?\\s*[KMG]?B/s$", RegexOption.IGNORE_CASE)
    private val PUNCT_ONLY_PATTERN = Regex("^[\\p{Punct}\\s·•]+$")

    fun isTrustedForRecognition(source: String, confidence: Double?): Boolean = when (source) {
        "a11y" -> true
        "ocr", "fused" -> confidence != null &&
            confidence.isFinite() &&
            confidence >= MIN_RECOGNITION_OCR_CONFIDENCE
        else -> false
    }

    fun isInToolbarBand(
        left: Int,
        top: Int,
        right: Int,
        bottom: Int,
        regionLeft: Int,
        regionTop: Int,
        regionWidth: Int,
        regionHeight: Int,
    ): Boolean {
        if (regionWidth <= 0 || regionHeight <= 0) return false
        val regionRight = regionLeft + regionWidth
        val regionBottom = regionTop + regionHeight
        if (left < regionLeft || top < regionTop || right > regionRight || bottom > regionBottom) {
            return false
        }
        if (right <= left || bottom <= top) return false
        val centerX = left + (right - left) / 2
        val centerY = top + (bottom - top) / 2
        val minY = regionTop + (regionHeight * 0.02).toInt()
        val maxY = regionTop + (regionHeight * 0.12).toInt()
        val minX = regionLeft + (regionWidth * 0.30).toInt()
        val maxX = regionLeft + (regionWidth * 0.70).toInt()
        return centerY in minY..maxY && centerX in minX..maxX
    }

    fun isStatusBarNoise(label: String): Boolean {
        val trimmed = label.trim()
        if (trimmed.isEmpty()) return true
        if (TIME_PATTERN.matches(trimmed)) return true
        if (PERCENT_PATTERN.matches(trimmed)) return true
        if (SPEED_PATTERN.matches(trimmed)) return true
        if (PUNCT_ONLY_PATTERN.matches(trimmed)) return true
        return false
    }

    fun readTitle(
        elements: List<ConversationTitleElement>,
        regionLeft: Int,
        regionTop: Int,
        regionWidth: Int,
        regionHeight: Int,
        blockingOverlay: Boolean,
    ): ConversationTitleObservation? {
        if (blockingOverlay || regionWidth <= 0 || regionHeight <= 0) return null
        val candidates = elements.mapNotNull { element ->
            if (!isTrustedForRecognition(element.source, element.confidence)) return@mapNotNull null
            if (!isInToolbarBand(
                    element.left, element.top, element.right, element.bottom,
                    regionLeft, regionTop, regionWidth, regionHeight,
                )
            ) return@mapNotNull null
            val rawLabel = element.text.trim().ifEmpty { element.description.trim() }
            if (isStatusBarNoise(rawLabel)) return@mapNotNull null
            val channel = if (element.source == "a11y") IntentReadbackChannel.A11Y else IntentReadbackChannel.OCR
            ConversationTitleObservation(label = rawLabel, channel = channel, source = element.source)
        }
        if (candidates.isEmpty()) return null
        val a11yCandidates = candidates.filter { it.channel == IntentReadbackChannel.A11Y }
        val pool = a11yCandidates.ifEmpty { candidates }
        val uniqueByNorm = LinkedHashMap<String, ConversationTitleObservation>()
        for (candidate in pool) {
            val norm = TextNorm.label(candidate.label)
            if (norm.isEmpty()) continue
            uniqueByNorm.putIfAbsent(norm, candidate)
        }
        if (uniqueByNorm.size != 1) return null
        return uniqueByNorm.values.first()
    }
}

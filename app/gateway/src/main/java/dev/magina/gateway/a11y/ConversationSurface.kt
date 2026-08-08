package dev.magina.gateway.a11y

import dev.magina.gateway.core.LabelMatchPolicy
import dev.magina.gateway.core.TextNorm
import org.json.JSONObject

/**
 * 会话页识别（"现在停在哪个会话"）的**唯一一份实现**。
 *
 * 为什么在 `src/main`：这条判据原先整条只活在 `src/debug`（`P0MacroSnapshot` /
 * `P0ElementStage` / `isTargetLabelLoosely` / `trustedForRecognition` 都是 debug-only），
 * 而语义意图的「执行前重读会话标题」跑在 `SafetyGate.execute` **内部**——那一刻大脑不在场、
 * 调不了宏，**生产代码结构上调不到它**（spec `2026-08-02-语义意图审批` §9.6，
 * backlog §8 决定记录）。
 *
 * backlog §8 定的方向是**下沉，不是另写一个读取器**——"判据有两份迟早只改一份"这条学费
 * 本仓已经付过多次（marker 归一化、Enter 通道、残留焦点节点三处）。所以：
 * 这里是实现，debug 宏 [dev.magina.gateway.a11y.P0WeChatPrepareMacro] 调的就是这一份，
 * 类型也是同一批（debug 侧只留 typealias）。
 *
 * 纯数据 + 纯函数，不碰任何 Android 对象，离线可测。
 */
internal data class SurfaceRect(
    val left: Int,
    val top: Int,
    val right: Int,
    val bottom: Int,
) {
    val centerX: Int get() = left + (right - left) / 2
    val centerY: Int get() = top + (bottom - top) / 2
    val width: Int get() = right - left
    val height: Int get() = bottom - top

    fun contains(x: Int, y: Int): Boolean = x in left..right && y in top..bottom
}

internal enum class SurfaceStage { TOOLBAR, SEARCH, CONTENT, BOTTOM_INPUT }

internal data class SurfaceElement(
    val ref: String,
    val role: String,
    val text: String,
    val description: String,
    val bounds: SurfaceRect,
    val source: String = "a11y",
    val confidence: Double? = null,
    val stage: SurfaceStage = SurfaceStage.CONTENT,
)

internal object ConversationSurfacePolicy {

    /**
     * 元素落在哪一段版面。原先是 `DebugMacroRunner` 的 private 方法，一起下沉：
     * 标题判据里那条 `stage == TOOLBAR` 依赖它，**分家就等于判据分家**。
     */
    fun stageOf(role: String, text: String, centerY: Int, screenHeight: Int): SurfaceStage {
        val normalized = text.replace(STAGE_SEPARATORS, "")
        return when {
            (role == "input" && centerY <= screenHeight * 0.30) ||
                normalized == "搜索" || normalized == "取消" -> SurfaceStage.SEARCH
            centerY in (screenHeight * 0.02).toInt()..(screenHeight * 0.12).toInt() -> SurfaceStage.TOOLBAR
            centerY >= screenHeight * 0.75 -> SurfaceStage.BOTTOM_INPUT
            else -> SurfaceStage.CONTENT
        }
    }

    fun validBounds(bounds: SurfaceRect, screenWidth: Int, screenHeight: Int): Boolean =
        bounds.left >= 0 && bounds.top >= 0 && bounds.right <= screenWidth &&
            bounds.bottom <= screenHeight && bounds.width > 0 && bounds.height > 0

    /**
     * 仅用于页面识别，**不用于任何点击目标**；门槛是识别级的 [MIN_RECOGNITION_OCR_CONFIDENCE]。
     * 点击目标独立走 [MIN_ACTION_OCR_CONFIDENCE]，不受这里影响。
     */
    fun trustedForRecognition(
        element: SurfaceElement,
        screenWidth: Int,
        screenHeight: Int,
    ): Boolean = when (element.source) {
        "a11y" -> true
        "ocr", "fused" -> element.confidence?.let {
            it.isFinite() && it >= MIN_RECOGNITION_OCR_CONFIDENCE
        } == true
        else -> false
    } && validBounds(element.bounds, screenWidth, screenHeight)

    /**
     * 标题带里那个可信的文字元素——**不看它写的是什么**。
     *
     * 生产侧（`EvidenceRebuildPolicy`）要的正是这个：先拿到"现在标题带上到底是什么字"，
     * 再由判据去和已批准的标签比。把比对塞进读取器里，判据就变成了平凡真
     * （"读回来的和读回来的一样"——发送后验踩过这个坑）。
     */
    fun toolbarTitle(
        elements: List<SurfaceElement>,
        screenWidth: Int,
        screenHeight: Int,
    ): SurfaceElement? {
        if (screenWidth <= 0 || screenHeight <= 0) return null
        return elements.firstOrNull { element ->
            element.stage == SurfaceStage.TOOLBAR &&
                trustedForRecognition(element, screenWidth, screenHeight) &&
                inTitleBand(element, screenWidth, screenHeight) &&
                labelTextOf(element).isNotEmpty()
        }
    }

    /**
     * "现在是不是 [expectedLabel] 这个会话页"。宏原来的 `conversationTitle` 就是它，
     * 只是把写死的 `文件传输助手` 换成参数——生产要比的是意图里那份 `targetLabel`。
     *
     * 宽松匹配的理由原样保留：2026-07-24 真机实锤 OCR 把标题识别成「文件传输助手8」
     * （尾随多识别出一个字符，置信度完全正常），严格相等在这类场景下永远漏判。
     * 现在这条宽松规则由 [LabelMatchPolicy] 提供，**与执行前重建时用的是同一条**。
     */
    fun conversationTitle(
        elements: List<SurfaceElement>,
        screenWidth: Int,
        screenHeight: Int,
        expectedLabel: String,
    ): SurfaceElement? {
        if (screenWidth <= 0 || screenHeight <= 0) return null
        return elements.firstOrNull { element ->
            looselyLabeled(element, expectedLabel) &&
                trustedForRecognition(element, screenWidth, screenHeight) &&
                element.stage == SurfaceStage.TOOLBAR &&
                inTitleBand(element, screenWidth, screenHeight)
        }
    }

    fun isConversationSurface(
        elements: List<SurfaceElement>,
        screenWidth: Int,
        screenHeight: Int,
        expectedLabel: String,
    ): Boolean = conversationTitle(elements, screenWidth, screenHeight, expectedLabel) != null

    /** 元素上"能当标题读"的那段字：text 优先，空则退 description。 */
    fun labelTextOf(element: SurfaceElement): String =
        TextNorm.label(element.text).ifEmpty { TextNorm.label(element.description) }

    /**
     * snapshot JSON → 元素表。**宏与生产解的是同一个 JSON、同一套 stage**——
     * 宏那边原先在 `DebugMacroRunner.decodeSnapshot` 里逐字段解一遍，生产要是再解一遍，
     * 两边的 stage 划分迟早会分叉，而标题判据正好挂在 stage 上。
     */
    fun decodeElements(raw: JSONObject, screenHeight: Int): List<SurfaceElement> {
        val array = raw.optJSONArray("elements") ?: return emptyList()
        return buildList {
            for (index in 0 until array.length()) {
                val item = array.optJSONObject(index) ?: continue
                val bounds = item.optJSONArray("bounds") ?: continue
                if (bounds.length() != 4) continue
                val role = item.optString("role")
                val text = item.optString("text")
                val description = item.optString("desc")
                val rect = SurfaceRect(
                    bounds.getInt(0),
                    bounds.getInt(1),
                    bounds.getInt(2),
                    bounds.getInt(3),
                )
                add(
                    SurfaceElement(
                        ref = item.optString("ref"),
                        role = role,
                        text = text,
                        description = description,
                        bounds = rect,
                        source = item.optString("source"),
                        confidence = item.takeIf { it.has("confidence") }
                            ?.optDouble("confidence")
                            ?.takeIf { it.isFinite() },
                        stage = stageOf(
                            role = role,
                            text = text + description,
                            centerY = rect.centerY,
                            screenHeight = screenHeight,
                        ),
                    ),
                )
            }
        }
    }

    private fun looselyLabeled(element: SurfaceElement, expectedLabel: String): Boolean =
        LabelMatchPolicy.matches(expectedLabel, element.text) ||
            LabelMatchPolicy.matches(expectedLabel, element.description)

    /**
     * 顶部标题带的几何：纵向 2%~12%、横向居中 30%~70%。宏原值，一个数没动。
     *
     * 不是 private：[SurfaceTitleReadPolicy] 在读不到标题时要报"标题带里到底有几个元素"，
     * 而那个数必须按**这一条**几何算——另写一份就等于报的不是同一件事。
     */
    fun inTitleBand(
        element: SurfaceElement,
        screenWidth: Int,
        screenHeight: Int,
    ): Boolean =
        validBounds(element.bounds, screenWidth, screenHeight) &&
            element.bounds.centerY in
            (screenHeight * 0.02).toInt()..(screenHeight * 0.12).toInt() &&
            element.bounds.centerX in
            (screenWidth * 0.3).toInt()..(screenWidth * 0.7).toInt()

    /** `stageOf` 里那条分隔符规则（与标签归一不同，刻意保持原样）。 */
    private val STAGE_SEPARATORS = Regex("[\\s：:]+")
}

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
    /**
     * 这个元素来自哪个 a11y 窗口；纯 OCR 元素没有窗口（它是屏幕像素，不是节点）。
     *
     * **2026-08-09 第四跑逼出来的**：a11y 是**跨窗口**的，而状态栏是它自己的窗口。
     * 网关因此把状态栏那个每秒都在跳的实时网速 `7.70KB/s` 当成了会话标题，
     * 并据此告诉用户"你换了会话"——**而用户全程没动过**。
     */
    val windowId: Int? = null,
    /** 是否来自**前台应用窗口**。缺省 false = fail-closed（缺字段的旧快照不冒充可信）。 */
    val foregroundWindow: Boolean = false,
)

/**
 * 一帧屏幕的几何上下文。
 *
 * 单独成型而不是散着传 `screenWidth`/`screenHeight`/`systemTopInset` 三个 Int：
 * 三个同类型参数并排传，**写反了编译器一声不吭**；而且新增一项时所有调用点都得记得跟上，
 * 这正是本册那条"判据要挂在能被机械验证的东西上，不挂需要有人记得填对的字段"。
 * 现在它由 [of] 从快照 JSON 一次解出来，调用方无从填错。
 */
internal data class SurfaceFrame(
    val screenWidth: Int,
    val screenHeight: Int,
    /**
     * 顶部系统装饰（状态栏/刘海区）的下沿，物理像素。**标题带一律从它之下开始。**
     *
     * 走真实窗口几何而不是"按屏幕比例猜一个状态栏高度"：盲点安全区那次已经付过这个学费
     * （按 0.84h~0.94h 写死，在这台机器上整整偏高 130px）。
     */
    val systemTopInset: Int,
) {
    companion object {
        fun of(raw: JSONObject, screenWidth: Int, screenHeight: Int): SurfaceFrame = SurfaceFrame(
            screenWidth = screenWidth,
            screenHeight = screenHeight,
            systemTopInset = raw.optInt("system_top_inset", 0),
        )
    }
}

/** 标题带里的一个候选，以及**它为什么没被选中**。 */
internal data class SurfaceCandidate(
    val text: String,
    val bounds: SurfaceRect,
    val source: String,
    val windowId: Int?,
    val foregroundWindow: Boolean,
    /** null = 全部门槛都过了（也就是可选中的那一类）。 */
    val rejectedBy: String?,
) {
    /** 给人看的一行。**含文本，所以只进错误信息，不进审计 note 那条分号串。** */
    fun describe(): String = buildString {
        append('「').append(text).append('」')
        append(" bounds=").append(bounds.left).append(',').append(bounds.top)
        append('-').append(bounds.right).append(',').append(bounds.bottom)
        append(" source=").append(source)
        append(" win=").append(windowId ?: "-")
        append(if (foregroundWindow) "(前台应用)" else "(非前台应用)")
        append(" → ").append(rejectedBy ?: "可选中")
    }

    companion object {
        const val REJECT_WINDOW = "不属于前台应用窗口"
        const val REJECT_CONFIDENCE = "识别置信度不够"
        const val REJECT_BOUNDS = "几何非法"
        const val REJECT_EMPTY = "归一后没有可读文字"
    }
}

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

    const val SOURCE_A11Y = "a11y"
    const val SOURCE_OCR = "ocr"
    const val SOURCE_FUSED = "fused"

    fun validBounds(bounds: SurfaceRect, frame: SurfaceFrame): Boolean =
        bounds.left >= 0 && bounds.top >= 0 && bounds.right <= frame.screenWidth &&
            bounds.bottom <= frame.screenHeight && bounds.width > 0 && bounds.height > 0

    /**
     * 仅用于页面识别，**不用于任何点击目标**；门槛是识别级的 [MIN_RECOGNITION_OCR_CONFIDENCE]。
     * 点击目标独立走 [MIN_ACTION_OCR_CONFIDENCE]，不受这里影响。
     *
     * 除置信度外还有一道**窗口归属**：有节点的元素（a11y / fused）必须来自前台应用窗口。
     * 理由见 [SurfaceElement.windowId]——a11y 跨窗口，状态栏是它自己的窗口，
     * 而状态栏上常驻着每秒都在跳的实时网速。纯 OCR 元素没有窗口信息，只能靠几何
     * （[inTitleBand] 的状态栏下沿那一刀），这是这两条门槛各自的能力边界。
     */
    fun trustedForRecognition(element: SurfaceElement, frame: SurfaceFrame): Boolean =
        rejectionOf(element, frame) == null

    /** 与 [trustedForRecognition] 同一套规则，但说得出**是哪一条**挡的（取证用）。 */
    fun rejectionOf(element: SurfaceElement, frame: SurfaceFrame): String? = when {
        !validBounds(element.bounds, frame) -> SurfaceCandidate.REJECT_BOUNDS
        element.source != SOURCE_OCR && !element.foregroundWindow -> SurfaceCandidate.REJECT_WINDOW
        element.source == SOURCE_A11Y -> null
        element.source == SOURCE_OCR || element.source == SOURCE_FUSED ->
            if (element.confidence?.let { it.isFinite() && it >= MIN_RECOGNITION_OCR_CONFIDENCE } == true) {
                null
            } else {
                SurfaceCandidate.REJECT_CONFIDENCE
            }
        else -> SurfaceCandidate.REJECT_BOUNDS
    }

    /**
     * 标题带里的**全部**候选，逐个带上"为什么"。
     *
     * 存在的理由是 2026-08-09 第四跑：现场只知道"读成了 `7.70KB/s`"，
     * "标题带把状态栏圈进去了"是**推断**——而 C 道的 `uiautomator dump` 只看得见前台应用窗口，
     * 坐实不了（它没把"我的工具看不见"报成"那东西不存在"，这是对的）。
     * **跨窗口的东西只有网关自己看得见，所以只能由网关把它打出来。**
     */
    fun titleBandCandidates(elements: List<SurfaceElement>, frame: SurfaceFrame): List<SurfaceCandidate> =
        elements.filter { it.stage == SurfaceStage.TOOLBAR && inTitleBand(it, frame) }
            .map { element ->
                SurfaceCandidate(
                    text = element.text.ifBlank { element.description },
                    bounds = element.bounds,
                    source = element.source,
                    windowId = element.windowId,
                    foregroundWindow = element.foregroundWindow,
                    rejectedBy = rejectionOf(element, frame)
                        ?: SurfaceCandidate.REJECT_EMPTY.takeIf { labelTextOf(element).isEmpty() },
                )
            }

    /**
     * 标题带里那个可信的文字元素——**不看它写的是什么**。
     *
     * 生产侧（`EvidenceRebuildPolicy`）要的正是这个：先拿到"现在标题带上到底是什么字"，
     * 再由判据去和已批准的标签比。把比对塞进读取器里，判据就变成了平凡真
     * （"读回来的和读回来的一样"——发送后验踩过这个坑）。
     */
    fun toolbarTitle(elements: List<SurfaceElement>, frame: SurfaceFrame): SurfaceElement? {
        if (frame.screenWidth <= 0 || frame.screenHeight <= 0) return null
        return elements.firstOrNull { element ->
            element.stage == SurfaceStage.TOOLBAR &&
                trustedForRecognition(element, frame) &&
                inTitleBand(element, frame) &&
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
        frame: SurfaceFrame,
        expectedLabel: String,
    ): SurfaceElement? {
        if (frame.screenWidth <= 0 || frame.screenHeight <= 0) return null
        return elements.firstOrNull { element ->
            looselyLabeled(element, expectedLabel) &&
                trustedForRecognition(element, frame) &&
                element.stage == SurfaceStage.TOOLBAR &&
                inTitleBand(element, frame)
        }
    }

    fun isConversationSurface(
        elements: List<SurfaceElement>,
        frame: SurfaceFrame,
        expectedLabel: String,
    ): Boolean = conversationTitle(elements, frame, expectedLabel) != null

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
                        windowId = if (item.has("window_id")) item.optInt("window_id") else null,
                        // 缺字段 → false → 有节点的元素一律不可信。**方向是 fail-closed**：
                        // 旧快照不冒充"来自前台应用窗口"。
                        foregroundWindow = item.optBoolean("fg_window", false),
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
     * 顶部标题带的几何：纵向 2%~12%、横向居中 30%~70%，**且整体在状态栏下沿之下**。
     *
     * 前两条是宏原值，一个数没动；第三条是 2026-08-09 新加的：2% 在 2800px 上是 y=56，
     * 而状态栏文字中心**实测在 65~70px**（C 道从截图量得），**落在带内**——
     * 所以状态栏的字一直是这条带的合法候选，昨晚被选中是运气，不是回归。
     * 用真实窗口几何划线（[SurfaceFrame.systemTopInset]），不按屏幕比例猜一个状态栏高度：
     * 盲点安全区那次按比例写死，在这台机器上偏了 130px。
     *
     * 不是 private：[SurfaceTitleReadPolicy] 在读不到标题时要报"标题带里到底有几个元素"，
     * 而那个数必须按**这一条**几何算——另写一份就等于报的不是同一件事。
     */
    fun inTitleBand(element: SurfaceElement, frame: SurfaceFrame): Boolean =
        validBounds(element.bounds, frame) &&
            element.bounds.top >= frame.systemTopInset &&
            element.bounds.centerY in
            (frame.screenHeight * 0.02).toInt()..(frame.screenHeight * 0.12).toInt() &&
            element.bounds.centerX in
            (frame.screenWidth * 0.3).toInt()..(frame.screenWidth * 0.7).toInt()

    /** `stageOf` 里那条分隔符规则（与标签归一不同，刻意保持原样）。 */
    private val STAGE_SEPARATORS = Regex("[\\s：:]+")
}

package dev.magina.gateway.a11y

// debug-only P0 验收状态机；release 源集不可见。

import dev.magina.gateway.core.ErrorCode
import dev.magina.gateway.core.GatewayError
import dev.magina.gateway.core.SafetyPolicy
import org.json.JSONObject

internal const val P0_WECHAT_PACKAGE = "com.tencent.mm"
internal const val P0_FILE_TRANSFER_ASSISTANT = "文件传输助手"
internal const val P0_PREPARE_MACRO_NAME = "p0_wechat_file_transfer_prepare"
internal const val P0_FIXED_FILE_TRANSFER_QUERY = "文件传输助手"

internal data class P0MacroForeground(
    val known: Boolean,
    val packageName: String,
)

internal data class P0MacroRect(
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

internal data class P0MacroElement(
    val ref: String,
    val role: String,
    val text: String,
    val description: String,
    val bounds: P0MacroRect,
    val source: String = "a11y",
    val confidence: Double? = null,
    val stage: P0ElementStage = P0ElementStage.CONTENT,
)

internal enum class P0ElementStage { TOOLBAR, SEARCH, CONTENT, BOTTOM_INPUT }

internal data class P0MacroSnapshot(
    val screenWidth: Int,
    val screenHeight: Int,
    val elements: List<P0MacroElement>,
    val revision: Long = 0,
    val captureRevision: Long = revision,
    val foregroundWindowId: Int = 1,
    /** 每次绕过 OCR cache 的视觉采样单调递增；普通 snapshot 可为 0。 */
    val visionGeneration: Long = 0,
    /** 受保护的标题带或底栏候选区被额外窗口覆盖。 */
    val blockingOverlay: Boolean = false,
    val imeVisible: Boolean = false,
    val systemBottomInset: Int = 0,
)

internal data class P0MacroFocus(
    /** 微信树空时，聚焦后 findFocus(FOCUS_INPUT) 仍必须给出真实节点。 */
    val nodePresent: Boolean,
    val imeActive: Boolean,
    val inputConnectionAvailable: Boolean,
    val fingerprint: String?,
    val focused: Boolean = nodePresent,
    /** 必须由真实节点显式观测；省略时 fail-closed，不能从 nodePresent 推断。 */
    val editable: Boolean = false,
    val stage: P0ElementStage? = null,
) {
    val ready: Boolean
        get() = nodePresent && focused && editable && imeActive && inputConnectionAvailable &&
            !fingerprint.isNullOrBlank()
}

/** 只描述已经由状态机验证过的屏幕相对聚焦候选区，不暴露任意坐标动作。 */
internal data class P0FocusProbe(
    val screenWidth: Int,
    val screenHeight: Int,
    val region: P0MacroRect,
    val x: Int,
    val y: Int,
    val snapshotRevision: Long,
    val captureRevision: Long,
    val foregroundWindowId: Int,
    val proof: P0FocusProof,
)

internal data class P0FocusProof(
    val title: String,
    val titleSource: String,
    val titleConfidence: Double,
    val titleBounds: P0MacroRect,
    val captureRevision: Long,
    val visionGeneration: Long,
    val foregroundWindowId: Int,
    val sensitiveSurfaceAbsent: Boolean,
    val blockingOverlayAbsent: Boolean,
)

internal enum class P0RefStage { SEARCH_ENTRY, TARGET_CONVERSATION, INPUT_FIELD }

internal data class P0StageRefAction(
    val stage: P0RefStage,
    val expectedText: String,
    val screenWidth: Int,
    val screenHeight: Int,
    val snapshotRevision: Long,
    val visionGeneration: Long,
)

/**
 * 宏可用动作被刻意压到最小：没有输入文本、按键、确认卡或任意坐标接口。
 * Android adapter 只能点击刚由 snapshot 产生的 ref，或执行一次已校验的输入区探针。
 */
internal interface P0WeChatPrepareAdapter {
    fun foreground(): P0MacroForeground
    fun snapshot(): P0MacroSnapshot
    /** 内部专用：丢弃 OCR cache 后重新截图识别，不改变 MCP 工具面。 */
    fun forceFreshVision(): P0MacroSnapshot
    /** 只提交编译期固定查询词；实现不得接收调用方文本。 */
    fun enterFixedFileTransferQuery(): Boolean
    fun clickStage(action: P0StageRefAction): Boolean
    fun probeFocus(probe: P0FocusProbe): Boolean
    fun focusedInput(): P0MacroFocus
    fun monotonicMs(): Long
    fun sleep(ms: Long)
}

/** title-only 坐标探针的共享纯验证器；宏预检和 Android 动作瞬间复用同一规则。 */
internal object P0FocusProbeValidator {
    /**
     * 这里的 title 只用于"证明当前在文件传输助手会话里"，从不是点击目标本身——真正的
     * 盲点坐标是 [build] 里独立算出的固定底栏区域，不依赖标题的位置/置信度。因此和
     * [conversationTitle]/[hasTopTitle] 同理使用识别专用阈值，而不是点击级的
     * [MIN_ACTION_OCR_CONFIDENCE]（2026-07-24 真机实锤：该标题置信度约 0.55，
     * 过不了点击级门槛，导致空白输入框场景下宏永远无法进入这条已有的坐标兜底路径）。
     * 这里的置信度会进入 [P0FocusProof]/`PreparedTargetEvidence`，但危险 Enter 前
     * 仍会独立复核 label/包名/bounds，这条证据链本身不会因为这处阈值降低而失去保护。
     */
    private val MIN_OCR_CONFIDENCE = MIN_RECOGNITION_OCR_CONFIDENCE.toDouble()

    fun build(snapshot: P0MacroSnapshot, sensitiveSurfaceWords: List<String>): P0FocusProbe? {
        val w = snapshot.screenWidth
        val h = snapshot.screenHeight
        val aspect = h.toDouble() / w.toDouble().coerceAtLeast(1.0)
        if (
            w < 480 || h < 800 || h <= w || aspect !in 1.4..2.7 || snapshot.blockingOverlay ||
            snapshot.imeVisible || snapshot.systemBottomInset < 0 ||
            snapshot.systemBottomInset > (h * 0.06).toInt()
        ) return null
        if (hasSensitiveOrBlockingSurface(snapshot, sensitiveSurfaceWords)) return null

        val title = snapshot.elements.firstOrNull { element ->
            // 2026-07-24 真机实锤：OCR 把标题识别成"文件传输助手8"（尾随多识别出一个字符，
            // confidence 完全正常，不是置信度问题）；这里只用于"证明在文件传输助手会话里"
            // 这一识别判断，从不是点击目标（真正的盲点坐标是下面独立算出的固定 region），
            // 严格相等在这类 OCR 附加字符场景下会永远漏判，改用 contains。
            normalized(element.text).contains(P0_FILE_TRANSFER_ASSISTANT) &&
                element.source in setOf("ocr", "fused") &&
                element.confidence?.let { it.isFinite() && it >= MIN_OCR_CONFIDENCE } == true &&
                element.stage == P0ElementStage.TOOLBAR &&
                validBounds(element.bounds, w, h) &&
                element.bounds.centerY in (h * 0.02).toInt()..(h * 0.12).toInt() &&
                element.bounds.centerX in (w * 0.30).toInt()..(w * 0.70).toInt()
        } ?: return null

        // 中心安全底栏，几何由 [p0FocusProbeRegion] 统一计算——Android 侧
        // performValidatedFocusProbe 用自己独立获得的 inset 调同一函数复核，两边必然一致。
        val box = p0FocusProbeRegion(w, h, snapshot.systemBottomInset)
        val region = P0MacroRect(left = box[0], top = box[1], right = box[2], bottom = box[3])
        if (!validBounds(region, w, h) || region.width < w * 0.40 || region.height < 40) return null

        // 空白输入框没有 OCR 文本；候选区出现任何可见文字时拒绝猜测。
        val textInRegion = snapshot.elements.any { element ->
            normalized(element.text + element.description).isNotEmpty() &&
                intersects(element.bounds, region)
        }
        val visibleSendControl = snapshot.elements.any { element ->
            element.bounds.centerY >= h * 0.72 &&
                normalized(element.text + element.description).contains("发送")
        }
        if (textInRegion || visibleSendControl) return null

        return P0FocusProbe(
            screenWidth = w,
            screenHeight = h,
            region = region,
            x = region.centerX,
            y = region.centerY,
            snapshotRevision = snapshot.revision,
            captureRevision = snapshot.captureRevision,
            foregroundWindowId = snapshot.foregroundWindowId,
            proof = P0FocusProof(
                title = P0_FILE_TRANSFER_ASSISTANT,
                titleSource = title.source,
                titleConfidence = title.confidence!!,
                titleBounds = title.bounds,
                captureRevision = snapshot.captureRevision,
                visionGeneration = snapshot.visionGeneration,
                foregroundWindowId = snapshot.foregroundWindowId,
                sensitiveSurfaceAbsent = true,
                blockingOverlayAbsent = true,
            ),
        )
    }

    fun revalidateForAction(
        expected: P0FocusProbe,
        fresh: P0MacroSnapshot,
        foreground: P0MacroForeground,
        sensitiveSurfaceWords: List<String>,
    ): P0FocusProbe {
        if (!foreground.known || foreground.packageName != P0_WECHAT_PACKAGE) {
            throw stale("动作瞬间不再是已知微信前台")
        }
        val actual = build(fresh, sensitiveSurfaceWords)
            ?: throw stale("动作瞬间的标题、敏感面、遮挡或安全底栏校验失败")
        val sameStableProof = actual.screenWidth == expected.screenWidth &&
            actual.screenHeight == expected.screenHeight && actual.region == expected.region &&
            actual.x == expected.x && actual.y == expected.y &&
            actual.snapshotRevision == expected.snapshotRevision &&
            actual.captureRevision == actual.snapshotRevision &&
            actual.captureRevision == expected.captureRevision &&
            actual.foregroundWindowId == expected.foregroundWindowId &&
            actual.proof.title == expected.proof.title &&
            actual.proof.titleSource == expected.proof.titleSource &&
            actual.proof.captureRevision == actual.snapshotRevision &&
            actual.proof.captureRevision == expected.proof.captureRevision &&
            actual.proof.foregroundWindowId == expected.proof.foregroundWindowId &&
            actual.proof.sensitiveSurfaceAbsent && actual.proof.blockingOverlayAbsent
        if (!sameStableProof || actual.proof.visionGeneration <= expected.proof.visionGeneration) {
            throw stale("动作瞬间未取得更新视觉样本，或完整 proof 已变化")
        }
        return actual
    }

    fun hasSensitiveOrBlockingSurface(
        snapshot: P0MacroSnapshot,
        sensitiveSurfaceWords: List<String>,
    ): Boolean {
        if (snapshot.blockingOverlay) return true
        // 只扫真实弹窗/对话框会用的原生 a11y 节点；WeChat 聊天列表行本身 a11y 稀疏（root=null
        // 常见），其可读文字来自 OCR 融合（fusion=ocr/fused），混入无关会话预览、官方账号
        // （如「微信支付」）、转账/到账系统横幅，会让整页扫描对任何真实账号必然误报（2026-07-23
        // 真机实锤：聊天列表干净无弹窗，仅因存在「微信支付」入口即命中危险词「支付」）。
        val signals = snapshot.elements
            .filter { it.source == "a11y" }
            .map { normalized(it.text + it.description) }
            .filter(String::isNotEmpty)
        if (SafetyPolicy.hasSensitiveSurfaceSemantics(signals, sensitiveSurfaceWords)) return true
        if (signals.any { it.contains("发送给") || it.contains("确认发送") }) return true
        val hasCancel = signals.any { it == "取消" || it.contains("拒绝") || it.contains("稍后") }
        val hasConfirm = signals.any {
            it == "确定" || it == "确认" || it.contains("允许") || it.contains("继续") ||
                it.contains("去设置")
        }
        return hasCancel && hasConfirm
    }

    private fun intersects(a: P0MacroRect, b: P0MacroRect): Boolean =
        a.left < b.right && a.right > b.left && a.top < b.bottom && a.bottom > b.top

    private fun validBounds(bounds: P0MacroRect, screenWidth: Int, screenHeight: Int): Boolean =
        bounds.left >= 0 && bounds.top >= 0 && bounds.right <= screenWidth &&
            bounds.bottom <= screenHeight && bounds.width > 0 && bounds.height > 0

    private fun normalized(value: String): String = value.replace(Regex("[\\s：:·•]+"), "").trim()

    private fun stale(message: String) = GatewayError(
        ErrorCode.E_STALE_REF,
        message,
        channel = "p0-wechat-prepare",
        retryable = false,
        extra = JSONObject().put("stage", "focus_probe_action_revalidation"),
    )
}

/** 固定搜索词提交前的纯校验；没有任何调用方文本参数。 */
internal object P0FixedQueryValidator {
    fun requireAllowed(
        snapshot: P0MacroSnapshot,
        foreground: P0MacroForeground,
        focus: P0MacroFocus,
        sensitiveSurfaceWords: List<String>,
    ) {
        val w = snapshot.screenWidth
        val h = snapshot.screenHeight
        val searchInput = snapshot.elements.firstOrNull { element ->
            element.role == "input" && element.stage == P0ElementStage.SEARCH &&
                element.bounds.left >= 0 && element.bounds.top >= 0 &&
                element.bounds.right <= w && element.bounds.bottom <= h &&
                element.bounds.width > 0 && element.bounds.height > 0 &&
                element.bounds.centerY <= h * 0.30 && when (element.source) {
                    "a11y" -> true
                    "ocr", "fused" -> element.confidence?.let {
                        it.isFinite() && it >= MIN_ACTION_OCR_CONFIDENCE
                    } == true
                    else -> false
                }
        }
        // 守卫判断（"是否已经在目标会话所以该拒绝提交搜索"），从不是点击目标；用 contains
        // 而非严格相等，同 P0FocusProbeValidator 的标题识别一样对付 OCR 附加字符
        // （2026-07-24 真机实锤"文件传输助手8"）。放宽只会让这道守卫更容易触发（更保守），
        // 不会削弱它本来的保护意图。
        val targetToolbarPresent = snapshot.elements.any {
            it.stage == P0ElementStage.TOOLBAR &&
                (it.text.replace(" ", "").contains(P0_FILE_TRANSFER_ASSISTANT) ||
                    it.description.replace(" ", "").contains(P0_FILE_TRANSFER_ASSISTANT))
        }
        if (
            !foreground.known || foreground.packageName != P0_WECHAT_PACKAGE ||
            snapshot.captureRevision != snapshot.revision || snapshot.foregroundWindowId < 0 ||
            snapshot.visionGeneration <= 0 || snapshot.blockingOverlay ||
            P0FocusProbeValidator.hasSensitiveOrBlockingSurface(snapshot, sensitiveSurfaceWords) ||
            searchInput == null || targetToolbarPresent || !focus.ready ||
            focus.stage != P0ElementStage.SEARCH
        ) throw GatewayError(
            ErrorCode.E_BLOCKED,
            "固定查询只允许在已验证微信搜索页和真实 editable 搜索焦点中提交",
            channel = "p0-wechat-prepare",
            retryable = false,
            extra = JSONObject().put("stage", "fixed_search_query_validation"),
        )
    }
}

/** search/target/input 三类 ref 的受限动作 proof；fresh snapshot 中重新找目标，不复用旧 ref。 */
internal object P0StageRefActionValidator {
    fun build(stage: P0RefStage, snapshot: P0MacroSnapshot): P0StageRefAction {
        val element = find(stage, snapshot) ?: throw blocked("阶段目标不可信或区域不合法")
        return P0StageRefAction(
            stage = stage,
            expectedText = normalized(element.text + element.description),
            screenWidth = snapshot.screenWidth,
            screenHeight = snapshot.screenHeight,
            snapshotRevision = snapshot.revision,
            visionGeneration = snapshot.visionGeneration,
        )
    }

    fun revalidate(
        expected: P0StageRefAction,
        fresh: P0MacroSnapshot,
        foreground: P0MacroForeground,
        sensitiveSurfaceWords: List<String>,
    ): P0MacroElement {
        if (!foreground.known || foreground.packageName != P0_WECHAT_PACKAGE) throw stale("阶段点击前台已变化")
        if (
            fresh.blockingOverlay ||
            P0FocusProbeValidator.hasSensitiveOrBlockingSurface(fresh, sensitiveSurfaceWords)
        ) throw stale("阶段点击前出现敏感面、弹窗或遮挡")
        if (
            fresh.screenWidth != expected.screenWidth || fresh.screenHeight != expected.screenHeight ||
            fresh.revision != expected.snapshotRevision || fresh.captureRevision != fresh.revision ||
            fresh.foregroundWindowId < 0 ||
            fresh.visionGeneration <= expected.visionGeneration
        ) throw stale("阶段点击没有取得更新视觉样本，或页面 proof 已变化")
        if (expected.stage in setOf(P0RefStage.SEARCH_ENTRY, P0RefStage.INPUT_FIELD) && fresh.imeVisible) {
            throw stale("阶段点击要求 IME 不可见")
        }
        val actual = find(expected.stage, fresh) ?: throw stale("阶段目标在 fresh vision 中不再可信")
        if (normalized(actual.text + actual.description) != expected.expectedText) {
            throw stale("阶段目标文本已变化")
        }
        return actual
    }

    private fun find(stage: P0RefStage, snapshot: P0MacroSnapshot): P0MacroElement? {
        val h = snapshot.screenHeight
        val w = snapshot.screenWidth
        return snapshot.elements.firstOrNull { element ->
            val trusted = when (element.source) {
                "a11y" -> true
                "ocr", "fused" -> element.confidence?.let {
                    it.isFinite() && it >= MIN_ACTION_OCR_CONFIDENCE
                } == true
                else -> false
            }
            val valid = element.bounds.left >= 0 && element.bounds.top >= 0 &&
                element.bounds.right <= w && element.bounds.bottom <= h &&
                element.bounds.width > 0 && element.bounds.height > 0
            if (!trusted || !valid) return@firstOrNull false
            val signal = normalized(element.text + element.description)
            when (stage) {
                P0RefStage.SEARCH_ENTRY -> element.stage == P0ElementStage.SEARCH &&
                    signal == "搜索" && element.bounds.centerY <= h * 0.30
                P0RefStage.TARGET_CONVERSATION -> element.stage == P0ElementStage.CONTENT &&
                    signal == P0_FILE_TRANSFER_ASSISTANT &&
                    element.bounds.centerY in (h * 0.12).toInt()..(h * 0.85).toInt()
                P0RefStage.INPUT_FIELD -> element.stage == P0ElementStage.BOTTOM_INPUT &&
                    (element.role == "input" || signal.contains("输入消息") || signal.contains("说点什么")) &&
                    element.bounds.centerY in (h * 0.75).toInt()..(h * 0.98).toInt()
            }
        }
    }

    private fun normalized(value: String) = value.replace(Regex("[\\s：:·•]+"), "").trim()
    private fun blocked(message: String) = GatewayError(ErrorCode.E_BLOCKED, message, channel = "p0-wechat-prepare")
    private fun stale(message: String) = GatewayError(ErrorCode.E_STALE_REF, message, channel = "p0-wechat-prepare")
}

internal data class P0WeChatPrepareConfig(
    val searchSurfaceTimeoutMs: Long = 8_000,
    val targetTimeoutMs: Long = 8_000,
    val conversationTimeoutMs: Long = 8_000,
    val focusTimeoutMs: Long = 5_000,
    val pollIntervalMs: Long = 150,
    val stableSamples: Int = 2,
    /** 来自执行器技能包的附加危险/敏感词；基础词与 SafetyPolicy 共源。 */
    val sensitiveSurfaceWords: List<String> = emptyList(),
    /**
     * 纯感知阶段（还没做任何点击/盲点）的重试次数：OCR 漏识有实测抖动（深色模式灰底灰字
     * 约 40%，2026-07-24 真机对比度增强修复后仍会偶发），重新截屏给抖动翻盘机会。只覆盖
     * "识别当前在哪"（`unrecognized_entry`/`sensitive_entry`）和"能否构建盲点探针"
     * （`focus_probe_validation`）——一旦尝试了点击或坐标盲点，"故意不重试"继续有效，
     * 不受这个字段影响。
     */
    val perceptionRetryAttempts: Int = 3,
    val perceptionRetryDelayMs: Long = 800,
)

internal data class P0WeChatPrepareResult(
    val ready: Boolean,
    val packageName: String,
    val conversation: String,
    val focusedInputFingerprint: String,
    val stableSamples: Int,
    val usedCoordinateFallback: Boolean,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("name", P0_PREPARE_MACRO_NAME)
        .put("ready", ready)
        .put("foreground_known", true)
        .put("package", packageName)
        .put("conversation", conversation)
        .put("input_focused", true)
        .put("input_editable", true)
        .put("ime_active", true)
        .put("input_connection_available", true)
        .put("focused_input_fingerprint", focusedInputFingerprint)
        .put("stable_samples", stableSamples)
        .put("coordinate_fallback_used", usedCoordinateFallback)
}

/** debug 验收专用的确定性状态机；生产可调用性由 build-type dispatcher 隔离。 */
internal class P0WeChatPrepareMacro(
    private val adapter: P0WeChatPrepareAdapter,
    private val config: P0WeChatPrepareConfig = P0WeChatPrepareConfig(),
) {
    init {
        require(config.stableSamples >= 2) { "focused fingerprint 至少连续采样两次" }
        require(config.pollIntervalMs > 0) { "pollIntervalMs 必须为正数" }
        require(config.perceptionRetryAttempts >= 1) { "perceptionRetryAttempts 至少为 1" }
    }

    fun run(): P0WeChatPrepareResult {
        requireWeChatForeground(initial = true)
        var current = requireRecognizedEntryWithRetry(adapter.snapshot())

        if (!isConversationSurface(current)) {
            val directTarget = findTargetConversation(current)
            if (directTarget != null) {
                clickOrFail(current, P0RefStage.TARGET_CONVERSATION, "目标会话")
            } else {
                val search = findSearchEntry(current) ?: throw macroError(
                    ErrorCode.E_NOT_FOUND,
                    "微信当前页没有可验证的搜索入口",
                    "search_entry",
                )
                clickOrFail(current, P0RefStage.SEARCH_ENTRY, "搜索入口")
                waitSnapshot(
                    stage = "search_surface",
                    label = "微信搜索页",
                    timeoutMs = config.searchSurfaceTimeoutMs,
                ) { isSearchSurface(it) }
                if (!adapter.enterFixedFileTransferQuery()) throw macroError(
                    ErrorCode.E_VERIFY_FAIL,
                    "固定文件传输助手查询提交失败",
                    "fixed_search_query",
                )
                val targetSurface = waitSnapshot(
                    stage = "target_conversation",
                    label = "文件传输助手目标会话",
                    timeoutMs = config.targetTimeoutMs,
                ) { findTargetConversation(it) != null }
                clickOrFail(targetSurface, P0RefStage.TARGET_CONVERSATION, "目标会话")
            }

            current = waitSnapshot(
                stage = "conversation_surface",
                label = "文件传输助手会话页",
                timeoutMs = config.conversationTimeoutMs,
            ) { isConversationSurface(it) }
        }

        val alreadyFocused = adapter.focusedInput().takeIf {
            it.ready && it.stage == P0ElementStage.BOTTOM_INPUT
        }
        val input = findInput(current)
        var usedCoordinateFallback = false
        if (alreadyFocused != null) {
            // 会话页和真实输入 session 已同时成立，不额外点击或探针。
        } else if (input != null) {
            clickOrFail(current, P0RefStage.INPUT_FIELD, "输入框")
        } else {
            val plannedProbe = buildFocusProbeWithRetry(current) ?: throw macroError(
                ErrorCode.E_BLOCKED,
                "空白输入框没有 ref，且屏幕/会话标题/输入候选区校验失败",
                "focus_probe_validation",
            )
            requireWeChatForeground(initial = false)
            val revalidated = adapter.forceFreshVision()
            val currentProbe = P0FocusProbeValidator.revalidateForAction(
                expected = plannedProbe,
                fresh = revalidated,
                foreground = adapter.foreground(),
                sensitiveSurfaceWords = config.sensitiveSurfaceWords,
            )
            // 故意不重试：一次坐标探针失败后必须停下，避免连续误触。
            usedCoordinateFallback = true
            if (!adapter.probeFocus(currentProbe)) throw macroError(
                ErrorCode.E_VERIFY_FAIL,
                "唯一一次输入框相对坐标聚焦探针未生效",
                "focus_probe",
            )
        }

        val firstFocus = alreadyFocused ?: waitForReadyFocus()
        val fingerprint = requireStableFingerprint(firstFocus)

        // 成功前重新验证页面身份与前台，避免把已切页但仍残留的 InputConnection 当成成功。
        requireWeChatForeground(initial = false)
        val finalSurface = adapter.forceFreshVision()
        requireSnapshotGeometry(finalSurface)
        if (
            !isConversationSurface(finalSurface) ||
            hasSensitiveOrBlockingSurface(finalSurface)
        ) throw macroError(
            ErrorCode.E_STALE_REF,
            "输入框聚焦后文件传输助手会话身份已变化，或出现敏感面/弹窗/遮挡",
            "final_conversation",
        )
        val finalFocus = adapter.focusedInput()
        if (
            !finalFocus.ready || finalFocus.stage != P0ElementStage.BOTTOM_INPUT ||
            finalFocus.fingerprint != fingerprint
        ) throw macroError(
            ErrorCode.E_STALE_REF,
            "最终复核时 focused input fingerprint 或 InputConnection 已变化",
            "final_focus",
        )

        return P0WeChatPrepareResult(
            ready = true,
            packageName = P0_WECHAT_PACKAGE,
            conversation = P0_FILE_TRANSFER_ASSISTANT,
            focusedInputFingerprint = fingerprint,
            stableSamples = config.stableSamples,
            usedCoordinateFallback = usedCoordinateFallback,
        )
    }

    private fun waitForReadyFocus(): P0MacroFocus {
        val started = adapter.monotonicMs()
        var last = adapter.focusedInput()
        while (!last.ready || last.stage != P0ElementStage.BOTTOM_INPUT) {
            if (adapter.monotonicMs() - started >= config.focusTimeoutMs) {
                val missing = buildList {
                    if (!last.nodePresent) add("输入框焦点节点")
                    if (!last.focused) add("节点未 focused")
                    if (!last.editable) add("节点非 editable")
                    if (last.stage != P0ElementStage.BOTTOM_INPUT) add("焦点不是底部聊天输入框")
                    if (!last.imeActive) add("IME 未激活")
                    if (!last.inputConnectionAvailable) add("InputConnection 不可用")
                    if (last.fingerprint.isNullOrBlank()) add("focused fingerprint 为空")
                }.joinToString("、")
                throw macroError(
                    ErrorCode.E_TIMEOUT,
                    "输入框焦点后置条件超时：$missing",
                    "focus_ready",
                )
            }
            requireWeChatForeground(initial = false)
            adapter.sleep(config.pollIntervalMs)
            last = adapter.focusedInput()
        }
        return last
    }

    private fun requireStableFingerprint(first: P0MacroFocus): String {
        val expected = first.fingerprint!!
        repeat(config.stableSamples - 1) {
            requireWeChatForeground(initial = false)
            adapter.sleep(config.pollIntervalMs)
            val next = adapter.focusedInput()
            if (
                !next.ready || next.stage != P0ElementStage.BOTTOM_INPUT ||
                next.fingerprint != expected
            ) throw macroError(
                ErrorCode.E_STALE_REF,
                "连续采样时 focused input fingerprint 或 InputConnection 发生变化",
                "focus_stability",
            )
        }
        return expected
    }

    private fun waitSnapshot(
        stage: String,
        label: String,
        timeoutMs: Long,
        predicate: (P0MacroSnapshot) -> Boolean,
    ): P0MacroSnapshot {
        val started = adapter.monotonicMs()
        while (true) {
            requireWeChatForeground(initial = false)
            val current = adapter.snapshot()
            requireSnapshotGeometry(current)
            if (hasSensitiveOrBlockingSurface(current)) throw macroError(
                ErrorCode.E_BLOCKED,
                "微信导航过程中出现敏感语义或弹窗，拒绝继续",
                "navigation_surface",
            )
            if (predicate(current)) return current
            if (adapter.monotonicMs() - started >= timeoutMs) throw macroError(
                ErrorCode.E_TIMEOUT,
                "$label 后置条件超时",
                stage,
            )
            adapter.sleep(config.pollIntervalMs)
        }
    }

    private fun requireWeChatForeground(initial: Boolean) {
        val foreground = adapter.foreground()
        if (foreground.known && foreground.packageName == P0_WECHAT_PACKAGE) return
        throw macroError(
            if (initial) ErrorCode.E_BLOCKED else ErrorCode.E_STALE_REF,
            if (initial) "准备宏要求已知微信前台" else "准备宏执行中不再是已知微信前台",
            if (initial) "initial_foreground" else "foreground_changed",
        )
    }

    private fun requireSnapshotGeometry(snapshot: P0MacroSnapshot) {
        if (snapshot.screenWidth < 480 || snapshot.screenHeight < 800) throw macroError(
            ErrorCode.E_BLOCKED,
            "微信快照缺少可信屏幕尺寸，拒绝导航或坐标探针",
            "snapshot_geometry",
        )
    }

    private fun requireRecognizedNonSensitiveEntry(snapshot: P0MacroSnapshot) {
        if (hasSensitiveOrBlockingSurface(snapshot)) throw macroError(
            ErrorCode.E_BLOCKED,
            "微信当前页命中敏感语义或弹窗，拒绝开始导航",
            "sensitive_entry",
        )
        val recognizedConversation = isConversationSurface(snapshot)
        // 微信聊天列表的搜索入口是纯图标、无 OCR 可读文字（2026-07-23 真机实锤：47 个
        // OCR 元素里不存在任何「搜索」候选，不是置信度问题，是压根没有文字可识别）；
        // 要求"能在此阶段就找到可信搜索入口"这条precondition 永远无法满足。真正的点击
        // 安全性不受影响——真要点搜索入口时 clickOrFail 仍会独立走
        // P0StageRefActionValidator.find 的 MIN_ACTION_OCR_CONFIDENCE 复核，找不到就在
        // 那一步 fail-closed；这里只需确认"看起来是微信自己的聊天列表页"。
        val recognizedChatList = hasTopTitle(snapshot, "微信")
        val recognizedSearch = isSearchSurface(snapshot) && findTargetConversation(snapshot) != null
        if (!recognizedConversation && !recognizedChatList && !recognizedSearch) throw macroError(
            ErrorCode.E_BLOCKED,
            "无法确认微信当前页属于宏允许的非敏感页面",
            "unrecognized_entry",
        )
    }

    /**
     * 还没做任何点击/输入，纯粹是"这一屏看起来是什么"的判断，重试是安全的——重新截屏给
     * OCR 抖动翻盘机会，不属于"故意不重试"约束的范围（那条只管点击/盲点之后）。
     */
    private fun requireRecognizedEntryWithRetry(initial: P0MacroSnapshot): P0MacroSnapshot {
        var snapshot = initial
        repeat(config.perceptionRetryAttempts) { attempt ->
            requireSnapshotGeometry(snapshot)
            try {
                requireRecognizedNonSensitiveEntry(snapshot)
                return snapshot
            } catch (error: GatewayError) {
                if (attempt == config.perceptionRetryAttempts - 1) throw error
                adapter.sleep(config.perceptionRetryDelayMs)
                snapshot = adapter.forceFreshVision()
            }
        }
        error("unreachable：repeat 循环要么 return 要么在最后一次抛出")
    }

    private fun clickOrFail(snapshot: P0MacroSnapshot, stage: P0RefStage, label: String) {
        val action = P0StageRefActionValidator.build(stage, snapshot)
        if (!adapter.clickStage(action)) throw macroError(
            ErrorCode.E_VERIFY_FAIL,
            "$label ref 点击未生效",
            "click_${label}",
        )
    }

    private fun isSearchSurface(snapshot: P0MacroSnapshot): Boolean {
        val h = snapshot.screenHeight
        if (h <= 0) return false
        return snapshot.elements.any { element ->
            trustedRef(element, snapshot) && element.stage == P0ElementStage.SEARCH &&
            element.bounds.centerY <= h * 0.3 && (
                element.role == "input" || normalized(element.text) == "取消" ||
                    normalized(element.description) == "取消"
                )
        }
    }

    private fun isConversationSurface(snapshot: P0MacroSnapshot): Boolean {
        val w = snapshot.screenWidth
        val h = snapshot.screenHeight
        if (w <= 0 || h <= 0) return false
        return conversationTitle(snapshot) != null
    }

    /**
     * 仅用于"是否在会话页"识别，从不作为点击目标（唯一调用方 [isConversationSurface]）；
     * 因此和 [hasTopTitle] 同理使用识别专用的 [MIN_RECOGNITION_OCR_CONFIDENCE]。
     * 真正的点击目标（[findTargetConversation]）独立走 [MIN_ACTION_OCR_CONFIDENCE]，不受此影响。
     */
    private fun conversationTitle(snapshot: P0MacroSnapshot): P0MacroElement? {
        val w = snapshot.screenWidth
        val h = snapshot.screenHeight
        if (w <= 0 || h <= 0) return null
        return snapshot.elements.firstOrNull { element ->
            isTargetLabelLoosely(element) && trustedForRecognition(element, snapshot) &&
                element.stage == P0ElementStage.TOOLBAR &&
                validBounds(element.bounds, w, h) &&
                element.bounds.centerY in (h * 0.02).toInt()..(h * 0.12).toInt() &&
                element.bounds.centerX in (w * 0.3).toInt()..(w * 0.7).toInt() &&
                validBounds(element.bounds, w, h)
        }
    }

    /** 仅用于页面识别，不用于任何点击目标；置信度门槛见 [MIN_RECOGNITION_OCR_CONFIDENCE]。 */
    private fun trustedForRecognition(element: P0MacroElement, snapshot: P0MacroSnapshot): Boolean =
        when (element.source) {
            "a11y" -> true
            "ocr", "fused" -> element.confidence?.let {
                it.isFinite() && it >= MIN_RECOGNITION_OCR_CONFIDENCE
            } == true
            else -> false
        } && validBounds(element.bounds, snapshot.screenWidth, snapshot.screenHeight)

    private fun hasTopTitle(snapshot: P0MacroSnapshot, title: String): Boolean {
        val w = snapshot.screenWidth
        val h = snapshot.screenHeight
        return snapshot.elements.any { element ->
            (normalized(element.text) == title || normalized(element.description) == title) &&
                trustedForRecognition(element, snapshot) && element.stage == P0ElementStage.TOOLBAR &&
                element.bounds.centerY in (h * 0.02).toInt()..(h * 0.12).toInt() &&
                element.bounds.centerX in (w * 0.3).toInt()..(w * 0.7).toInt()
        }
    }

    private fun findSearchEntry(snapshot: P0MacroSnapshot): P0MacroElement? =
        snapshot.elements
            .filter { normalized(it.text) == "搜索" || normalized(it.description) == "搜索" }
            .filter { trustedRef(it, snapshot) && it.stage == P0ElementStage.SEARCH }
            .filter { it.bounds.centerY <= snapshot.screenHeight * 0.30 }
            .minByOrNull { it.bounds.centerY }

    private fun findTargetConversation(snapshot: P0MacroSnapshot): P0MacroElement? =
        snapshot.elements
            .filter(::isTargetLabel)
            .filter { trustedRef(it, snapshot) && it.stage == P0ElementStage.CONTENT }
            .filter { it.bounds.centerY in (snapshot.screenHeight * 0.12).toInt()..(snapshot.screenHeight * 0.85).toInt() }
            .filterNot { element ->
                val w = snapshot.screenWidth
                val h = snapshot.screenHeight
                w > 0 && h > 0 && element.bounds.centerY <= h * 0.22 &&
                    element.bounds.centerX in (w * 0.3).toInt()..(w * 0.7).toInt()
            }
            .minByOrNull { it.bounds.centerY }

    /**
     * 点击目标用的严格标签匹配：原文必须完全等于目标文本，不接受任何近似——唯一调用方
     * [findTargetConversation] 是 knowledge #14 里"点击安全"决定所保护的对象，改这个函数
     * 本身需要重新征得同意。
     */
    private fun isTargetLabel(element: P0MacroElement): Boolean =
        normalized(element.text) == P0_FILE_TRANSFER_ASSISTANT ||
            normalized(element.description) == P0_FILE_TRANSFER_ASSISTANT

    /**
     * 纯识别用途的宽松标签匹配：只要求包含目标文本。2026-07-24 真机实锤：OCR 把标题识别成
     * "文件传输助手8"（尾随多识别出一个字符，confidence 完全正常，不是置信度问题），严格
     * 相等在这类场景下永远漏判。唯一调用方 [conversationTitle] 只用于"这是不是会话页"的
     * 识别判断，从不是点击目标——点击目标的严格匹配（[isTargetLabel]）不受影响。
     */
    private fun isTargetLabelLoosely(element: P0MacroElement): Boolean =
        normalized(element.text).contains(P0_FILE_TRANSFER_ASSISTANT) ||
            normalized(element.description).contains(P0_FILE_TRANSFER_ASSISTANT)

    private fun findInput(snapshot: P0MacroSnapshot): P0MacroElement? =
        snapshot.elements
            .filter { element ->
                val signal = normalized(element.text + element.description)
                element.role == "input" || signal.contains("输入消息") || signal.contains("说点什么")
            }
            .filter { trustedRef(it, snapshot) && it.stage == P0ElementStage.BOTTOM_INPUT }
            .filter { it.bounds.centerY in (snapshot.screenHeight * 0.75).toInt()..(snapshot.screenHeight * 0.98).toInt() }
            .minByOrNull { it.bounds.centerY }

    private fun trustedRef(element: P0MacroElement, snapshot: P0MacroSnapshot): Boolean =
        trustedVisualEvidence(element) &&
            validBounds(element.bounds, snapshot.screenWidth, snapshot.screenHeight)

    private fun buildFocusProbe(snapshot: P0MacroSnapshot): P0FocusProbe? {
        return P0FocusProbeValidator.build(snapshot, config.sensitiveSurfaceWords)
    }

    /**
     * 还没有任何盲点尝试，纯粹是"能不能构建出探针"——重试安全，重新截屏给 OCR 抖动
     * 翻盘机会。一旦拿到探针进入 [P0FocusProbeValidator.revalidateForAction]/实际
     * `probeFocus` 调用，"故意不重试"继续有效，不受这里影响。
     */
    private fun buildFocusProbeWithRetry(initial: P0MacroSnapshot): P0FocusProbe? {
        var snapshot = initial
        repeat(config.perceptionRetryAttempts) { attempt ->
            buildFocusProbe(snapshot)?.let { return it }
            if (attempt < config.perceptionRetryAttempts - 1) {
                adapter.sleep(config.perceptionRetryDelayMs)
                snapshot = adapter.forceFreshVision()
            }
        }
        return null
    }

    private fun trustedVisualEvidence(element: P0MacroElement): Boolean = when (element.source) {
        "a11y" -> true
        "ocr", "fused" -> element.confidence?.let {
            it.isFinite() && it >= MIN_ACTION_OCR_CONFIDENCE
        } == true
        else -> false
    }

    private fun hasSensitiveOrBlockingSurface(snapshot: P0MacroSnapshot): Boolean =
        P0FocusProbeValidator.hasSensitiveOrBlockingSurface(snapshot, config.sensitiveSurfaceWords)

    private fun validBounds(bounds: P0MacroRect, screenWidth: Int, screenHeight: Int): Boolean =
        bounds.left >= 0 && bounds.top >= 0 && bounds.right <= screenWidth &&
            bounds.bottom <= screenHeight && bounds.width > 0 && bounds.height > 0

    private fun normalized(value: String): String = value
        .replace(Regex("[\\s：:·•]+"), "")
        .trim()

    private fun macroError(code: ErrorCode, message: String, stage: String): GatewayError = GatewayError(
        code = code,
        message = message,
        channel = "p0-wechat-prepare",
        retryable = false,
        fallback = "停止本测试腿；不要盲点或手工补步骤",
        extra = JSONObject().put("stage", stage),
    )
}

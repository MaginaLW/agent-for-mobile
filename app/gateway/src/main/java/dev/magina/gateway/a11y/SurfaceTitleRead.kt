package dev.magina.gateway.a11y

import org.json.JSONObject

/**
 * 「执行前重读会话标题」这一步的**可观测性**（2026-08-08 批次 4 第三跑逼出来的）。
 *
 * 真机连撞三次，终态**逐字相同**：「目标会话标题读不回来（channel=ocr）」。
 * 而当时能拿到的全部信息就是这一句——因为 [GatewayA11yService.readSurfaceTitle] 返回
 * `SurfaceElement?`，把四种完全不同的处境统统折成了一个 `null`：
 *
 * 1. 感知本身抛错（截图/快照失败），连屏幕都没拿到；
 * 2. 拿到了快照，但**这一帧根本没跑 OCR**——`snapshot()` 的融合是有闸门的
 *    （`fgCount < FUSE_FG_THRESHOLD`），而且融合失败会被 `catch` 成一句 `note` 后**静默降级**；
 * 3. OCR 跑了，但标题带里一个元素都没有；
 * 4. 标题带里有元素，但没有一个过得了识别门槛（置信度/几何）。
 *
 * 这四种里，只有 3、4 与"页面还没渲染稳"有关，1、2 是通道问题——**而它们在台账上长得一模一样**。
 * 本仓的老规矩是「修不动的时候先加可观测性，别加假设」（Allow 腿卡五轮那次的最大收获）：
 * 所以这里先把"读了几次、每次读到什么、等了多久"变成机械可读的事实，再谈改法。
 *
 * 另外那句 `channel=ocr` **本身就有误导性**：`surfaceChannel` 是按 `title?.source` 算的，
 * 而 `title` 为 null 时它必然落进 `else` 分支印成 `ocr`。它读起来像"OCR 试过了没读到"，
 * 实际含义只是"没有标题对象"——连 OCR 有没有跑过都不知道。
 *
 * 纯数据 + 纯函数，不碰任何 Android 对象，离线可测。
 */
internal enum class SurfaceTitleOutcome {
    /** 读到了标题带上的字（**不含"是不是目标会话"的判断**，那条判据在 `EvidenceRebuildPolicy`）。 */
    RESOLVED,

    /** 感知抛错，这一帧连屏幕都没拿到。 */
    NO_SNAPSHOT,

    /** 拿到了快照，但这一帧**没有识别结果可用**：融合闸门没放行，或融合抛错被降级了。 */
    NO_OCR,

    /** 识别跑过了，标题带里一个元素都没有。 */
    NO_CANDIDATE,

    /** 标题带里有元素，但没有一个过得了识别门槛。 */
    ALL_REJECTED,
    ;

    /** 审计 note 里用的短名。**不含 `;` `,` `=`**——它要拼进 `safetyNote` 那条分号串。 */
    val wireName: String get() = name.lowercase()
}

/**
 * 一次读取尝试的全部事实。字段选择的标准是「能不能把上面四种处境分开」，
 * 不是「好不好看」——[fusion] / [fgElements] 直接对应 `snapshot()` 那道融合闸门，
 * [bandElements] / [bestRejectedConfidence] 直接对应几何与置信度两道门槛。
 */
internal data class SurfaceTitleAttempt(
    val outcome: SurfaceTitleOutcome,
    val elapsedMs: Long,
    /** `snapshot()` 自报的融合状态：`ocr` = 这一帧跑过识别；`none` = 没跑。 */
    val fusion: String,
    /** 前台窗口的 a11y 元素数。**≥ `FUSE_FG_THRESHOLD` 就是融合闸门没放行的直接证据。** */
    val fgElements: Int,
    /** 落在标题带几何里的元素数（门槛之前）。 */
    val bandElements: Int,
    /** 标题带里被门槛挡掉的元素中最高的那个置信度；没有被挡掉的就是 null。 */
    val bestRejectedConfidence: Double?,
    /** `snapshot()` 自己写的降级说明（融合失败原因）。**可能含任意异常文本，不进 note。** */
    val note: String,
    val title: SurfaceElement?,
)

/**
 * 标题读取的完整记录：**每一次尝试都留痕**。
 *
 * 只留最后一次的话，"第一次就读到了"与"重试三次才读到"分不开，而这两者对
 * 「到底是时机问题还是通道问题」给出的是相反的结论。
 */
internal data class SurfaceTitleRead(
    val attempts: List<SurfaceTitleAttempt>,
    val waitedMs: Long,
) {
    val title: SurfaceElement? get() = attempts.lastOrNull()?.title

    /** 第几次读到的（1 起）；没读到是 0。 */
    val resolvedAt: Int get() = attempts.indexOfFirst { it.outcome == SurfaceTitleOutcome.RESOLVED } + 1

    /**
     * 拼进审计 note 的那一段。**格式与 `ForegroundWaitTrace.describe` 同族**：
     * 逗号分字段、不出现 `;`，好让 runner 一条正则解出来落进 manifest。
     */
    fun describe(): String = buildString {
        append("attempts=").append(attempts.size)
        append(",waited_ms=").append(waitedMs)
        append(",result=").append(if (title != null) "resolved" else "unresolved")
        append(",resolved_at=").append(resolvedAt)
        append(",trail=").append(attempts.joinToString("+") { it.outcome.wireName })
        append(",fg=").append(attempts.joinToString("+") { it.fgElements.toString() })
        append(",band=").append(attempts.joinToString("+") { it.bandElements.toString() })
    }

    /**
     * 给人看的那一段，只在**读不回来**时拼进错误信息。
     *
     * 与 [describe] 分开是因为它含 [SurfaceTitleAttempt.note]——那是异常原文，
     * 里面什么字符都可能有，混进分号串会把 runner 的解析打乱。
     */
    fun detail(): String {
        val last = attempts.lastOrNull() ?: return "一次都没读"
        val sameAll = attempts.all { it.outcome == last.outcome }
        val head = when (last.outcome) {
            SurfaceTitleOutcome.NO_SNAPSHOT -> "感知没拿到屏幕"
            SurfaceTitleOutcome.NO_OCR ->
                "这一帧没有识别结果可用（fusion=${last.fusion}，前台 a11y 元素 ${last.fgElements} 个" +
                    "，融合闸门是「少于 $OCR_FUSION_FG_THRESHOLD 个才跑」）"
            SurfaceTitleOutcome.NO_CANDIDATE -> "识别跑过了，但标题带里一个元素都没有"
            SurfaceTitleOutcome.ALL_REJECTED ->
                "标题带里有 ${last.bandElements} 个元素，但都没过识别门槛" +
                    (last.bestRejectedConfidence?.let { "（最高置信度 $it）" } ?: "")
            SurfaceTitleOutcome.RESOLVED -> "读到了"
        }
        val trend = if (sameAll) "${attempts.size} 次尝试结论相同，不是时机问题" else "各次结论不同，像时机问题"
        val note = last.note.takeIf { it.isNotBlank() }?.let { "；快照自报：$it" }.orEmpty()
        return "$head（$trend，共等 ${waitedMs}ms）$note"
    }
}

/**
 * 分因与重试节奏的**纯判据**。
 *
 * 重试是有界的，而且**只重试"读"，一个字都不放宽比对**——主会话 2026-08-08 定的方向：
 * 「过一会儿就读到 → 加有界重试，判据一个字不动；一直读不到 → 才谈通道」。
 * 逐次留痕让这两条在**同一跑**里就能分开：结论各次不同 = 时机，逐次相同 = 通道。
 */
internal object SurfaceTitleReadPolicy {

    /**
     * 最多读几次。整屏 OCR 缓存 TTL 是 2s、每次强制新截图 + 全屏识别本身要几百毫秒，
     * 4 次跨过 4 秒足够覆盖"刚回到前台、标题带还没渲染稳"。
     */
    const val MAX_ATTEMPTS = 4

    /** 两次之间的间隔。比 OCR 缓存 TTL 略小没关系——读取走的是 `forceFreshVision`，不吃缓存。 */
    const val RETRY_INTERVAL_MS = 700L

    /**
     * 总预算。这段发生在一次工具调用**内部**，而该调用本来就要阻塞 80~100 秒
     * （真人决策 + 停留），再多等 4 秒不改变任何天花板；预算给大了才是问题——
     * 它会把一条本该快速终态的失败拖成"像是卡住了"。
     */
    const val BUDGET_MS = 4_000L

    init {
        // 预算必须装得下最后一次尝试之前的所有间隔，否则 MAX_ATTEMPTS 是个骗人的数：
        // 现场看到 attempts=2 会以为"只读了两次就放弃"，实际是预算根本不允许读满。
        require((MAX_ATTEMPTS - 1) * RETRY_INTERVAL_MS < BUDGET_MS) {
            "标题读取预算装不下 MAX_ATTEMPTS 次尝试，attempts 数会误导现场"
        }
    }

    fun shouldRetry(attempt: SurfaceTitleAttempt, attemptsSoFar: Int, elapsedMs: Long): Boolean =
        attempt.outcome != SurfaceTitleOutcome.RESOLVED &&
            attemptsSoFar < MAX_ATTEMPTS &&
            elapsedMs + RETRY_INTERVAL_MS < BUDGET_MS

    /**
     * 把一帧快照判成一次尝试。[raw] 为 null 表示感知抛错。
     *
     * **标题元素仍由 [ConversationSurfacePolicy.toolbarTitle] 选，这里不另写一份**——
     * 判据有两份迟早只改一份，本仓已经付过多次这个学费。这里只负责"没选出来时说清为什么"。
     */
    fun classify(
        raw: JSONObject?,
        screenWidth: Int,
        screenHeight: Int,
        elapsedMs: Long,
    ): SurfaceTitleAttempt {
        if (raw == null) return SurfaceTitleAttempt(
            outcome = SurfaceTitleOutcome.NO_SNAPSHOT,
            elapsedMs = elapsedMs,
            fusion = "",
            fgElements = -1,
            bandElements = 0,
            bestRejectedConfidence = null,
            note = "",
            title = null,
        )
        val elements = ConversationSurfacePolicy.decodeElements(raw, screenHeight)
        val title = ConversationSurfacePolicy.toolbarTitle(elements, screenWidth, screenHeight)
        val band = elements.filter {
            it.stage == SurfaceStage.TOOLBAR &&
                ConversationSurfacePolicy.inTitleBand(it, screenWidth, screenHeight)
        }
        val fusion = raw.optString("fusion")
        val rejected = band.filterNot {
            ConversationSurfacePolicy.trustedForRecognition(it, screenWidth, screenHeight)
        }
        val outcome = when {
            title != null -> SurfaceTitleOutcome.RESOLVED
            band.isEmpty() && fusion != FUSION_OCR -> SurfaceTitleOutcome.NO_OCR
            band.isEmpty() -> SurfaceTitleOutcome.NO_CANDIDATE
            else -> SurfaceTitleOutcome.ALL_REJECTED
        }
        return SurfaceTitleAttempt(
            outcome = outcome,
            elapsedMs = elapsedMs,
            fusion = fusion,
            fgElements = raw.optInt("fg_elements", -1),
            bandElements = band.size,
            bestRejectedConfidence = rejected.mapNotNull { it.confidence }.maxOrNull(),
            note = raw.optString("note"),
            title = title,
        )
    }

    /** `snapshot()` 里那个 `fusion` 字段表示"这一帧跑过识别"的取值。 */
    const val FUSION_OCR = "ocr"
}

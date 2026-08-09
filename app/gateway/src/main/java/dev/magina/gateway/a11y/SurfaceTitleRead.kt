package dev.magina.gateway.a11y

import dev.magina.gateway.core.TextNorm
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

    /** fresh snapshot 明确报告有遮挡；遮挡上的 OCR 即使命中也不能证明底层会话。 */
    BLOCKING_OVERLAY,

    /** 截图 revision / 窗口 / 前台包 / vision generation 任一 proof 缺失或自相矛盾。 */
    INVALID_PROOF,
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
    /** 这一帧的完整 fresh identity；即使无效/有遮挡也保留给诊断，不能只把标题文字拿走。 */
    val capture: FreshEvidenceCapture?,
    /** 与 [capture] 同一 active fresh-capture 临界区内读取的 focused input proof。 */
    val inputProof: FreshPreparedInputProof? = null,
    /** 同一张 capture Bitmap 上的输入栏 OCR；a11y 文本可读时不需要，保持 null。 */
    val inputOcrReadback: String? = null,
    val title: SurfaceElement?,
    /**
     * 标题带里的全部候选，逐个带"为什么"。**含界面文本，只进错误信息，不进审计 note。**
     * 存在的理由见 [ConversationSurfacePolicy.titleBandCandidates]。
     */
    val candidates: List<SurfaceCandidate> = emptyList(),
    /**
     * 被状态栏下沿切掉的那些（见 [ConversationSurfacePolicy.topCutCandidates]）。
     * **它们不在 [candidates] 里**——几何那一刀发生在候选枚举之前。
     */
    val topCut: List<SurfaceCandidate> = emptyList(),
) {
    /**
     * 带内**因为不属于前台应用窗口**而被挡掉的候选数——也就是"状态栏挤进标题带了吗"。
     *
     * 这是个纯数字，所以它能进审计 note。2026-08-09 第四跑那一帧上它会是 6：
     * **一眼就能看出问题不在识别质量，而在带里混进了别的窗口。**
     */
    val systemWindowRejects: Int
        get() = candidates.count { it.rejectedBy == SurfaceCandidate.REJECT_WINDOW }

    /**
     * **上面本来有东西、被状态栏那一刀切掉了**的个数。
     *
     * 这一栏与 [systemWindowRejects] 各自对应一道闸门，**而它解决的是另一种分不开**：
     * `band` 少一个时，`topcut>0` = 切掉了，`topcut=0` = 这一帧根本没产出它。
     * 2026-08-09 第五跑就卡在这个分不开上——**判据以"跑绿了"的姿态挂着，却从没被考到**。
     */
    val topCutRejects: Int get() = topCut.size
}

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

    /** 只有完整 RESOLVED 才产出不可拆开的「标题 + capture proof」束。 */
    val surface: FreshEvidenceSurface?
        get() {
            val last = attempts.lastOrNull()?.takeIf { it.outcome == SurfaceTitleOutcome.RESOLVED } ?: return null
            val title = last.title ?: return null
            val capture = last.capture ?: return null
            val canonical = TextNorm.label(title.text).ifEmpty { TextNorm.label(title.description) }
            return FreshEvidenceSurface(capture, canonical, title.source)
        }

    val bundle: FreshEvidenceReadBundle?
        get() {
            val surface = surface ?: return null
            val last = attempts.lastOrNull() ?: return null
            val input = last.inputProof ?: return null
            return FreshEvidenceReadBundle(surface, input, last.inputOcrReadback)
        }

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
        // "带里混进了几个别的窗口的元素"。纯数字，可以进 note；而它正是第四跑那一帧
        // 唯一需要看的数——**问题不在识别质量，在带里站着状态栏**。
        append(",sysrej=").append(attempts.joinToString("+") { it.systemWindowRejects.toString() })
        // "上面本来有东西、被状态栏那一刀切掉了几个"。**它与 sysrej 分别对应两道闸门**，
        // 而它解决的是另一种分不开：band 少一个时，切掉了 vs 这一帧根本没产出它。
        append(",topcut=").append(attempts.joinToString("+") { it.topCutRejects.toString() })
        // 最后被选中的那个来自哪条通道。它决定后面按 a11y 严格比还是按 OCR 宽松比，
        // 而这两档在现场读起来完全不同，不落盘就只能猜。
        append(",picked=").append(title?.source?.ifBlank { "-" } ?: "-")
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
            SurfaceTitleOutcome.BLOCKING_OVERLAY -> "fresh 截图存在遮挡浮层，标题不可用于重建"
            SurfaceTitleOutcome.INVALID_PROOF -> "fresh 截图的 revision、窗口、前台包或截图世代 proof 无效"
            SurfaceTitleOutcome.RESOLVED -> "读到了"
        }
        val trend = if (sameAll) "${attempts.size} 次尝试结论相同，不是时机问题" else "各次结论不同，像时机问题"
        val note = last.note.takeIf { it.isNotBlank() }?.let { "；快照自报：$it" }.orEmpty()
        return "$head（$trend，共等 ${waitedMs}ms）$note${candidateDump()}"
    }

    /**
     * 标题带候选清单。**这是把"推断"变成"观测"的那一段**：2026-08-09 第四跑现场只知道
     * 读成了 `7.70KB/s`，"标题带把状态栏圈进去了"当时只是推断，而 `uiautomator dump`
     * 看不见状态栏（它只抓前台应用窗口）——**跨窗口的东西只有网关自己看得见**。
     */
    fun candidateDump(): String {
        val last = attempts.lastOrNull() ?: return ""
        // **被切掉的那些也要列出来**：它们不在候选表里，而"上面有没有东西"恰恰是要看的。
        val all = last.candidates + last.topCut
        if (all.isEmpty()) return "｜标题带候选 0 个，状态栏下沿之上也没有"
        return all.joinToString(
            prefix = "｜标题带候选 ${last.candidates.size} 个" +
                (if (last.topCut.isEmpty()) "" else "、切掉 ${last.topCut.size} 个") + "：",
            separator = "；",
        ) { it.describe() }
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
        attempt.outcome !in setOf(
            SurfaceTitleOutcome.RESOLVED,
            SurfaceTitleOutcome.BLOCKING_OVERLAY,
            SurfaceTitleOutcome.INVALID_PROOF,
        ) &&
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
            capture = null,
            title = null,
        )
        val capture = captureOf(raw)
        val proofProblems = FreshEvidenceRebuildGuard.captureProblems(capture)
        if (capture.blockingOverlay || proofProblems.isNotEmpty()) return SurfaceTitleAttempt(
            outcome = if (capture.blockingOverlay) {
                SurfaceTitleOutcome.BLOCKING_OVERLAY
            } else {
                SurfaceTitleOutcome.INVALID_PROOF
            },
            elapsedMs = elapsedMs,
            fusion = raw.optString("fusion"),
            fgElements = raw.optInt("fg_elements", -1),
            bandElements = 0,
            bestRejectedConfidence = null,
            note = raw.optString("note"),
            capture = capture,
            // 遮挡上的文字既不参与标题选择，也不进候选日志，避免它给底层会话背书。
            title = null,
        )
        val frame = SurfaceFrame.of(raw, screenWidth, screenHeight)
        val elements = ConversationSurfacePolicy.decodeElements(raw, screenHeight)
        val title = ConversationSurfacePolicy.toolbarTitle(elements, frame)
        val candidates = ConversationSurfacePolicy.titleBandCandidates(elements, frame)
        val fusion = raw.optString("fusion")
        val rejectedConfidence = elements
            .filter { it.stage == SurfaceStage.TOOLBAR && ConversationSurfacePolicy.inTitleBand(it, frame) }
            .filterNot { ConversationSurfacePolicy.trustedForRecognition(it, frame) }
            .mapNotNull { it.confidence }
            .maxOrNull()
        val outcome = when {
            title != null -> SurfaceTitleOutcome.RESOLVED
            candidates.isEmpty() && fusion != FUSION_OCR -> SurfaceTitleOutcome.NO_OCR
            candidates.isEmpty() -> SurfaceTitleOutcome.NO_CANDIDATE
            else -> SurfaceTitleOutcome.ALL_REJECTED
        }
        return SurfaceTitleAttempt(
            outcome = outcome,
            elapsedMs = elapsedMs,
            fusion = fusion,
            fgElements = raw.optInt("fg_elements", -1),
            bandElements = candidates.size,
            bestRejectedConfidence = rejectedConfidence,
            note = raw.optString("note"),
            capture = capture,
            title = title,
            candidates = candidates,
            topCut = ConversationSurfacePolicy.topCutCandidates(elements, frame),
        )
    }

    fun captureOf(raw: JSONObject): FreshEvidenceCapture = FreshEvidenceCapture(
        revision = raw.optLong("revision", Long.MIN_VALUE),
        captureRevision = raw.optLong("capture_revision", Long.MIN_VALUE),
        visionGeneration = raw.optLong("vision_generation", 0),
        foregroundWindowId = raw.optInt("foreground_window_id", -1),
        foregroundKnown = raw.optBoolean("foreground_known", false),
        foregroundPackage = raw.optString("foreground_package"),
        // 字段缺失也必须 fail closed；旧快照不能冒充「明确没有遮挡」。
        blockingOverlay = raw.optBoolean("blocking_overlay", true),
    )

    /** `snapshot()` 里那个 `fusion` 字段表示"这一帧跑过识别"的取值。 */
    const val FUSION_OCR = "ocr"
}

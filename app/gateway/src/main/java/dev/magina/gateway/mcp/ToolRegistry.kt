package dev.magina.gateway.mcp

import android.graphics.Bitmap
import android.os.SystemClock
import dev.magina.gateway.Gateway
import dev.magina.gateway.a11y.GatewayA11yService
import dev.magina.gateway.core.ApprovalChannel
import dev.magina.gateway.core.ApprovalIntent
import dev.magina.gateway.core.EvidenceRebuild
import dev.magina.gateway.core.EvidenceRebuildPolicy
import dev.magina.gateway.core.FocusIdentity
import dev.magina.gateway.core.ForegroundWaitTrace
import dev.magina.gateway.core.IntentApproval
import dev.magina.gateway.core.IntentApprovalClocks
import dev.magina.gateway.core.Envelope
import dev.magina.gateway.core.ErrorCode
import dev.magina.gateway.core.GatewayError
import dev.magina.gateway.core.Level
import dev.magina.gateway.core.SafetyContext
import dev.magina.gateway.core.ConfirmApprovalArbiter
import dev.magina.gateway.core.RiskTier
import dev.magina.gateway.core.SafetyDecision
import dev.magina.gateway.core.StaleReconfirmGuard
import dev.magina.gateway.overlay.ConfirmNotificationRequest
import dev.magina.gateway.core.SafetyGate
import dev.magina.gateway.core.SafetyPolicy
import dev.magina.gateway.core.SafetyTarget
import dev.magina.gateway.core.sanitizeAuditArgs
import dev.magina.gateway.core.invalidateInputEvidenceForMutation
import dev.magina.gateway.core.invalidatePreparedTargetForMutation
import dev.magina.gateway.core.shouldSerializeUiCall
import dev.magina.gateway.core.preparedTargetSurvivesTypeText
import dev.magina.gateway.core.guardPreparedTargetTypeTextArgs
import dev.magina.gateway.overlay.ConfirmCardTarget
import dev.magina.gateway.overlay.ConfirmOverlay
import dev.magina.gateway.overlay.confirmCardVisibleInCapture
import dev.magina.gateway.ocr.OcrEngine
import dev.magina.gateway.tools.IntentTools
import dev.magina.gateway.tools.SystemTools
import dev.magina.gateway.tools.UiTools
import dev.magina.gateway.testing.InactiveTestControlSession
import dev.magina.gateway.testing.ConfirmationIdGenerator
import dev.magina.gateway.testing.TestConfirmationAttempt
import dev.magina.gateway.testing.TestConfirmationCapture
import dev.magina.gateway.testing.TestControlSession
import dev.magina.gateway.testing.TestForeground
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream

class ToolSpec(
    val name: String,
    val description: String,
    val level: Level,
    val inputSchema: JSONObject,
    val handler: (JSONObject) -> JSONObject,
)

/** 调用结果：文本信封 + 可选图片（screen_capture 用 MCP image content 回图，不塞 JSON）。 */
class ToolResult(val envelope: JSONObject, val imageBase64: String? = null, val imageMime: String = "image/png")

object ToolRegistry {

    // ---- schema 构造小工具 ----
    private fun prop(type: String, desc: String, enum: List<String>? = null): JSONObject =
        JSONObject().put("type", type).put("description", desc)
            .apply { enum?.let { put("enum", JSONArray(it)) } }

    private fun schema(required: List<String>, vararg props: Pair<String, JSONObject>): JSONObject =
        JSONObject()
            .put("type", "object")
            .put("properties", JSONObject().apply { props.forEach { (k, v) -> put(k, v) } })
            .put("required", JSONArray(required))

    private fun stub(msg: String, fallback: String): (JSONObject) -> JSONObject = {
        throw GatewayError(ErrorCode.E_CHANNEL_DOWN, msg, fallback = fallback)
    }

    private fun gatedOnly(name: String): (JSONObject) -> JSONObject = {
        throw GatewayError(ErrorCode.E_INTERNAL, "$name 只能由统一安全门执行")
    }

    val tools: List<ToolSpec> = listOf(
        // ---------- L1 系统层 ----------
        ToolSpec(
            "device_info", "设备与网关能力概览（分辨率/系统/电量/能力位）。任务开场调用一次。",
            Level.R, schema(emptyList()),
        ) { SystemTools.deviceInfo() },
        ToolSpec(
            "system_get_state", "读系统状态（白名单 key）。返回值带真值源 source。",
            Level.R,
            schema(
                listOf("key"),
                "key" to prop("string", "状态键", listOf("bluetooth", "wifi", "airplane", "battery", "network", "screen", "volume", "brightness")),
            ),
        ) { SystemTools.getState(it.getString("key")) },
        ToolSpec(
            "system_set_state", "改系统状态。M1a 仅 volume 可写；蓝牙/WiFi 等待 Shizuku 通道（M1b），当前会返回 UI 兜底路径。",
            Level.W,
            schema(
                listOf("key", "value"),
                "key" to prop("string", "状态键"),
                "value" to prop("string", "目标值，如 on/off/整数"),
            ),
        ) { SystemTools.setState(it.getString("key"), it.getString("value")) },
        ToolSpec(
            "system_verify_state", "用独立真值源复核状态（M0 教训：单一返回不可信）。",
            Level.R,
            schema(
                listOf("key", "expected"),
                "key" to prop("string", "状态键"),
                "expected" to prop("string", "期望值"),
            ),
        ) { SystemTools.verifyState(it.getString("key"), it.getString("expected")) },
        ToolSpec(
            "foreground_app",
            "当前前台 app 与 Activity，并附前台身份诊断：foreground_reason、窗口列表（含 root_package）、最近窗口事件处置。" +
                "任何工具返回 foreground_known=false 时先调它取证。",
            Level.R, schema(emptyList()),
        ) {
            SystemTools.foregroundApp()
        },
        ToolSpec("keyboard_state", "软键盘可见性与高度（坐标错位主因的感知面）。", Level.R, schema(emptyList())) {
            SystemTools.keyboardState()
        },
        ToolSpec(
            "app_launch", "按别名或包名启动 app，执行后验前台。",
            Level.W, schema(listOf("name"), "name" to prop("string", "app 别名（微信/京东…）或包名")),
        ) { SystemTools.appLaunch(it.getString("name")) },
        ToolSpec(
            "app_stop", "强停 app（Shizuku 通道，M1b）。",
            Level.W, schema(listOf("package"), "package" to prop("string", "包名")),
        ) { SystemTools.appStop(it.getString("package")) },
        ToolSpec(
            "clipboard", "剪贴板读写。读取需本 app 为默认 IME（Android 10+ 限制）。",
            Level.W,
            schema(
                listOf("op"),
                "op" to prop("string", "get 或 set", listOf("get", "set")),
                "text" to prop("string", "set 时的内容"),
            ),
        ) { SystemTools.clipboard(it.getString("op"), it.optString("text")) },
        ToolSpec(
            "media_query", "查媒体库（MediaStore 直读，跳过相册 UI 导航——任务 4 捷径）。",
            Level.R,
            schema(
                listOf("type"),
                "type" to prop("string", "image 或 screenshot", listOf("image", "screenshot")),
                "album" to prop("string", "相册名（可选）"),
                "limit" to prop("integer", "条数，默认 5"),
            ),
        ) { SystemTools.mediaQuery(it.getString("type"), it.optString("album").ifEmpty { null }, it.optInt("limit", 5)) },

        // ---------- L2 意图层 ----------
        ToolSpec(
            "open_uri", "打开深链/URL。命中技能包注册表时执行后验前台，验不上报 E_VERIFY_FAIL（附 UI 兜底路径）。",
            Level.W, schema(listOf("uri"), "uri" to prop("string", "深链或 https URL，参数自行 urlencode")),
        ) { IntentTools.openUri(it.getString("uri")) },
        ToolSpec(
            "intent_send", "发送白名单 Intent（VIEW/SEND/SENDTO/MAIN/android.settings.*）。组件只接受技能包注册项。",
            Level.W,
            schema(
                listOf("action"),
                "action" to prop("string", "Intent action 全名"),
                "uri" to prop("string", "data URI（可选）"),
                "extras" to prop("object", "字符串 extras（可选）"),
                "package" to prop("string", "定向包名/别名（可选）"),
                "component" to prop("string", "显式组件类名（须已注册，可选）"),
            ),
        ) {
            IntentTools.intentSend(
                it.getString("action"), it.optString("uri").ifEmpty { null },
                it.optJSONObject("extras"), it.optString("package").ifEmpty { null },
                it.optString("component").ifEmpty { null },
            )
        },
        ToolSpec(
            "share_text", "系统分享文本。target 给包名/别名可定向。",
            Level.W,
            schema(
                listOf("text"),
                "text" to prop("string", "要分享的文本"),
                "target" to prop("string", "目标 app（可选）"),
            ),
        ) { IntentTools.shareText(it.getString("text"), it.optString("target").ifEmpty { null }) },
        ToolSpec(
            "share_file", "系统分享文件（uri 来自 media_query）。三级降级：直达组件→定向→系统面板。",
            Level.W,
            schema(
                listOf("uri", "mime"),
                "uri" to prop("string", "content:// URI"),
                "mime" to prop("string", "如 image/*"),
                "target" to prop("string", "目标 app（可选）"),
            ),
        ) { IntentTools.shareFile(it.getString("uri"), it.getString("mime"), it.optString("target").ifEmpty { null }) },

        // ---------- L3 通知层（M1b 占位） ----------
        ToolSpec(
            "notifications_list", "列当前通知（M1b：NotificationListener）。",
            Level.R, schema(emptyList()),
            handler = stub("通知层在 M1b 实现", "打开目标 app 走 UI 读取"),
        ),
        ToolSpec(
            "notification_reply", "通知内直接回复（M1b；危险级=对外发送）。",
            Level.D,
            schema(listOf("id", "text"), "id" to prop("string", "通知 id"), "text" to prop("string", "回复内容")),
            handler = stub("通知层在 M1b 实现", "打开目标 app 走 UI 回复"),
        ),

        // ---------- L4 UI 层 ----------
        ToolSpec(
            "ui_snapshot", "当前页面语义元素列表（带 revision；树空/稀疏自动融合 OCR，source=a11y|ocr|fused；ref 供后续操作寻址）。首选感知工具。",
            Level.R,
            schema(
                emptyList(),
                "scope" to prop("string", "interactive=可交互+短文本（默认）；full=含长文本供阅读", listOf("interactive", "full")),
            ),
        ) { UiTools.uiSnapshot(it.optString("scope", "interactive")) },
        ToolSpec(
            "ui_diff", "自某 revision 以来的元素增删改（M1b）。",
            Level.R, schema(listOf("since_revision"), "since_revision" to prop("integer", "上次 snapshot 的 revision")),
        ) { UiTools.uiDiff(it.getLong("since_revision")) },
        ToolSpec(
            "ui_find", "按文本/角色/描述找元素；scroll_search=true 时网关自行滚动查找（≤3 屏）。",
            Level.R,
            schema(
                emptyList(),
                "text" to prop("string", "文本包含匹配"),
                "role" to prop("string", "button/input/text/list/switch/icon_button"),
                "desc" to prop("string", "contentDescription 包含匹配"),
                "scroll_search" to prop("boolean", "找不到时自动滚动，默认 false"),
            ),
        ) {
            UiTools.uiFind(
                it.optString("text").ifEmpty { null }, it.optString("role").ifEmpty { null },
                it.optString("desc").ifEmpty { null }, it.optBoolean("scroll_search", false),
            )
        },
        ToolSpec(
            "ui_action", "对 ref 执行动作。点击前二次校验；OCR 元素 click/long_click 走坐标手势；危险目标由统一安全门确认。不接受裸坐标。",
            Level.W,
            schema(
                listOf("ref", "action"),
                "ref" to prop("string", "来自最近一次 ui_snapshot/ui_find"),
                "action" to prop("string", "动作", listOf("click", "long_click", "set_text", "scroll", "focus", "dismiss")),
                "text" to prop("string", "set_text 用"),
                "direction" to prop("string", "scroll 用：forward/backward"),
            ),
            handler = gatedOnly("ui_action"),
        ),
        ToolSpec(
            "type_text", "输入文本（中文关键路径）：SET_TEXT→自有 IME 字面注入，内置读回验证（树空场景 OCR 读回）。永不使用剪贴板机制。",
            Level.W,
            schema(
                listOf("text"),
                "text" to prop("string", "字面文本（空格/换行/标点原样注入）"),
                "ref" to prop("string", "目标输入框 ref；缺省=当前焦点"),
                "mode" to prop("string", "append（默认）或 replace（精确覆盖）", listOf("append", "replace")),
            ),
        ) { UiTools.typeText(it.getString("text"), it.optString("ref").ifEmpty { null }, it.optString("mode", "append")) },
        ToolSpec(
            "press_key", "全局键/编辑键。",
            Level.W,
            schema(
                listOf("key"),
                "key" to prop("string", "按键", listOf("back", "home", "recents", "notifications", "enter", "del")),
            ),
            handler = gatedOnly("press_key"),
        ),
        ToolSpec(
            "wait_for", "等待条件（网关内轮询，不烧大脑轮次）。",
            Level.R,
            schema(
                listOf("condition"),
                "condition" to prop(
                    "string", "条件",
                    listOf("text_appears", "text_gone", "app_foreground", "keyboard_shown", "keyboard_hidden", "idle"),
                ),
                "text" to prop("string", "text_* 条件的文本"),
                "package" to prop("string", "app_foreground 的包名"),
                "quiet_ms" to prop("integer", "idle 的静默阈值，默认 800"),
                "timeout_ms" to prop("integer", "超时，默认 8000，上限 30000"),
            ),
        ) {
            UiTools.waitFor(it.getString("condition"), it, it.optLong("timeout_ms", 8000))
        },

        // ---------- L6 受控兜底 ----------
        ToolSpec(
            "screen_capture", "受控原图（最后兜底）：reason 必填进审计；给 ref/region 只回裁剪图。结构化通道能用时禁止调用。",
            Level.R,
            schema(
                listOf("reason"),
                "reason" to prop(
                    "string", "调用理由",
                    listOf("low_confidence", "unknown_page", "icon_unrecognized", "layout_changed", "risk_review"),
                ),
                "ref" to prop("string", "只截该元素区域（优先）"),
                "region" to prop("array", "[l,t,r,b] 物理像素裁剪区"),
            ),
        ) { UiTools.screenCapture(it.getString("reason"), it.optString("ref").ifEmpty { null }, it.optJSONArray("region")) },
    ) + MacroToolCatalog.tools

    private val byName = tools.associateBy { it.name }

    /** 敏感 app 前台时仍放行的工具（撤离与纯感知）；press_key 另限安全撤离键。 */
    private val BLOCKED_APP_ALLOWED = setOf(
        "device_info", "foreground_app", "keyboard_state", "press_key", "app_launch", "wait_for",
    )

    fun listToolsJson(): JSONArray {
        val arr = JSONArray()
        tools.forEach {
            arr.put(
                JSONObject()
                    .put("name", it.name)
                    .put("description", "[${it.level}] ${it.description}")
                    .put("inputSchema", it.inputSchema)
            )
        }
        return arr
    }

    fun call(name: String, args: JSONObject): ToolResult {
        val spec = byName[name]
        val mutatesUi = shouldSerializeUiCall(
            spec?.level,
            name,
            args.optBoolean("scroll_search", false),
        )
        return if (mutatesUi) {
            Gateway.uiMutationCoordinator.runExclusive { callInternal(name, args) }
        } else {
            callInternal(name, args)
        }
    }

    /**
     * 一次工具调用期间、安全门几个回调之间共享的可变状态。
     *
     * 提出来只为把 `callInternal` 里那段 78 行的 [SafetyGate] 构造搬进 [newSafetyGate]——
     * 原来这些是局部 `var`，闭包直接捕获；换成字段后捕获的是同一个对象，可见性与写入顺序
     * 与之前逐字相同。**字段语义一个都没改。**
     */
    private class CallScope(val toolName: String, val argsFingerprint: String) {
        /** 进审计 note 的安全轨迹；确认、复核、重试记录失败都往这上面追加。 */
        var safetyNote: String = ""

        /** 上下文读了几次；>1 即确认后复核发生过。 */
        var contextReads: Int = 0
        var testSession: TestControlSession = InactiveTestControlSession
        var testAttempt: TestConfirmationAttempt? = null

        /**
         * 限次守卫的计数键，以及推通知要用的两项内容，都在**第一次读上下文时**定下来。
         *
         * 必须取自初始上下文：确认后复核那一次的上下文正是"已经变了"的那份，
         * 拿它算键会让每次重试落到不同的键上，限次直接形同虚设。
         */
        var staleKey: String = ""
        var targetLabel: String = ""
        var inputPreview: String? = null

        fun captureApprovalScope(context: SafetyContext, riskTier: RiskTier?) {
            if (staleKey.isNotEmpty()) return
            targetLabel = context.target?.preparedTargetEvidence?.label.orEmpty()
            inputPreview = context.target?.inputCommitEvidence?.preview
            staleKey = StaleReconfirmGuard.key(
                toolName = toolName,
                riskTier = riskTier ?: RiskTier.IRREVERSIBLE,
                targetLabel = targetLabel,
                contentKey = StaleReconfirmGuard.contentKeyOf(toolName, context),
            )
        }
    }

    /**
     * 生产那组时钟（用户 2026-08-02 题五拍板的 5 分钟就在里面）。**构造在这里做一次**，
     * 是为了让 `IntentApprovalClocks` 的构造断言与 `IntentApproval` 的"预算超过证据 TTL
     * 就必须装配重建通道"那条断言在**装配路径上**被执行到，而不是只在用例里。
     */
    private val intentClocks = IntentApprovalClocks()

    /** 等前台恢复的轮询间隔（spec §9.1 要求 ≤200ms）。 */
    private const val FOREGROUND_POLL_INTERVAL_MS = 200L

    /**
     * 语义意图审批的装配（spec §9.1 四处）。**这就是那个开关**：不传 `intentApproval`
     * 就是 2026-08-02 之前的行为。
     */
    private fun newIntentApproval(call: CallScope): IntentApproval = IntentApproval(
        intentIdFactory = { ConfirmationIdGenerator.next() },
        awaitForeground = { targetPackage, budgetMs ->
            // 只许缩短，不许延长——延长会让用户拍板的"5 分钟"被测试脚手架悄悄改掉。
            // `withShorterForegroundWait` 已经拦一道，这里再夹一道：这条不对称一旦破了，
            // 现场看到的是一条**通过**的腿，而不是一条失败的腿。
            val budget = Gateway.testControl
                .intentClocks(call.testSession, intentClocks)
                .foregroundWaitBudgetMs
                .coerceAtMost(budgetMs)
            val trace = awaitForegroundPackage(targetPackage, budget)
            // **这段等待必须自己说话**：只回 true/false 的话，"人在外面待了 90 秒再回来"
            // 与"根本没等就成了"在台账上完全分不开，而前者正是新腿要证明的东西。
            call.safetyNote += ";foreground_wait=${trace.describe()}"
            trace.reached
        },
        clocks = intentClocks,
        rebuildEvidence = ::rebuildApprovedEvidence,
    )

    /**
     * 批准之后有界等待前台恢复到目标包。
     *
     * 这段等待发生在**一次工具调用内部**，不是大脑重试——站规「安全失败即终态」一字未动。
     * 拿不到 a11y、读不出前台都不算"到了"，用完预算返回 false（fail-closed）。
     */
    private fun awaitForegroundPackage(targetPackage: String, budgetMs: Long): ForegroundWaitTrace {
        val started = SystemClock.elapsedRealtime()
        val deadline = started + budgetMs
        var reads = 0
        var last = ""
        while (true) {
            val ctx = GatewayA11yService.instance?.let { runCatching { it.ctx(Gateway.caps()) }.getOrNull() }
            reads += 1
            if (ctx != null) last = ctx.optString("app")
            if (
                ctx != null && ctx.optBoolean("foreground_known", false) &&
                ctx.optString("app") == targetPackage
            ) return ForegroundWaitTrace(true, reads, SystemClock.elapsedRealtime() - started, last)
            val remaining = deadline - SystemClock.elapsedRealtime()
            if (remaining <= 0) {
                return ForegroundWaitTrace(false, reads, SystemClock.elapsedRealtime() - started, last)
            }
            Thread.sleep(minOf(FOREGROUND_POLL_INTERVAL_MS, remaining))
        }
    }

    /**
     * 批准之后重建两处短时证据（spec §9.2）。
     *
     * **装配方只负责"读"与"读到之后按当前身份重新落证据"，判定一律走
     * [EvidenceRebuildPolicy.judge]**——判据在这里另写一份，就是本仓付过多次学费的那一族。
     *
     * 两处证据都要重建：目标会话证据与输入证据的 TTL 都是 120s，而预算是 5 分钟；
     * 只重建输入证据的话，回来时会以「执行前没有短时目标会话证据」失败，
     * 而那条失败与今天长得一模一样，最难发现。
     */
    private fun rebuildApprovedEvidence(intent: ApprovalIntent): EvidenceRebuild {
        val a11y = GatewayA11yService.instance
            ?: return EvidenceRebuild.Unverified("a11y 未开启，证据重建通道不可用")
        val title = a11y.readSurfaceTitle()
        val focused = UiTools.focusedInputSnapshot(a11y)
        val identity = focused.identity
            ?: return EvidenceRebuild.Unverified("重建时拿不到焦点输入身份，无法把证据落回")
        // 内容通道：a11y 能读到精确文本就按精确文本比；微信这条链读不到，退 OCR 输入栏读回。
        val a11yText = focused.readableText
        val contentChannel = if (a11yText != null) {
            EvidenceRebuildPolicy.CHANNEL_A11Y
        } else {
            EvidenceRebuildPolicy.CHANNEL_OCR
        }
        val readback = a11yText ?: runCatching {
            a11y.ocrReadInputBarRegion(focused.bounds).text
        }.getOrNull()
        // 标题通道：`fused` 一律按 OCR 算——它的文字有可能来自识别侧，按 a11y 的逐位相等去要求
        // 它会诬告；反过来只是把这一项比得松一点，而"是不是同一个会话"还有包名与内容两道。
        val surfaceChannel = if (title?.source == "a11y") {
            EvidenceRebuildPolicy.CHANNEL_A11Y
        } else {
            EvidenceRebuildPolicy.CHANNEL_OCR
        }
        val verdict = EvidenceRebuildPolicy.judge(
            intent = intent,
            readback = readback,
            channel = contentChannel,
            surfaceLabel = title?.let { it.text.ifBlank { it.description } },
            normalize = OcrEngine::norm,
            surfaceChannel = surfaceChannel,
        )
        if (verdict !is EvidenceRebuild.Rebuilt) return verdict

        val sha256 = intent.contentSha256
            ?: return EvidenceRebuild.Unverified("意图没有锁定内容，无从落回输入证据")
        val bounds = focused.bounds?.let(::boundsString)
        if (!FocusIdentity.boundsConsistent(identity.source, bounds)) {
            return EvidenceRebuild.Unverified(
                "重建时几何与身份来源不一致（${identity.describe()}），拒绝落证据",
            )
        }
        return runCatching {
            Gateway.preparedTargetEvidence.record(
                label = intent.targetLabel,
                packageName = intent.targetPackage,
                identity = identity,
                bounds = bounds,
            )
            Gateway.inputCommitEvidence.rebindApproved(
                sha256 = sha256,
                length = intent.contentLength ?: verdict.length,
                preview = intent.contentPreview.orEmpty(),
                normalizedText = intent.contentNormalized.orEmpty(),
                identity = identity,
            )
            verdict
        }.getOrElse { error ->
            EvidenceRebuild.Unverified("重建判过了但证据落不回去：${error.message.orEmpty()}")
        }
    }

    /** 锁屏那一行里的动作短语；不含任何输入内容。 */
    private fun confirmActionPhrase(decision: SafetyDecision.ConfirmationRequired): String = when {
        decision.toolName == "press_key" && decision.action.equals("enter", ignoreCase = true) -> "发送消息"
        decision.toolName == "press_key" -> "按键 ${decision.action}"
        decision.action.isNotBlank() -> "${decision.action} 危险目标"
        else -> decision.toolName
    }

    /**
     * 装配这一次调用的安全门。纯搬运：策略、五个回调的内容与顺序与拆分前逐字一致，
     * 只是把捕获局部 `var` 换成读写 [CallScope] 的字段。
     */
    private fun newSafetyGate(call: CallScope): SafetyGate = SafetyGate(
        policy = SafetyPolicy(
            // 技能包资产的 danger_words 即 I 级、send_words 即 II 级（见 SafetyPolicy 类注释）。
            irreversibleWords = Gateway.skills.dangerWords,
            retractableWords = Gateway.skills.sendWords,
            sensitiveTargets = Gateway.skills.sensitiveTargets,
        ),
        confirmer = { decision ->
            // 纵深防御，**当前站规下走不到**：站规 §4「安全失败就是终态」要求大脑在第一次
            // stale 就停下报告失败、不得重试同一危险动作，所以计数器连 1 都到不了
            // （2026-08-02 用户重新拍板：维持站规，不开有界重试口子）。留着是因为上限本身没错，
            // 将来若真有路径能重试，上限仍该是 2。详见 StaleReconfirmGuard 的类注释。
            if (Gateway.staleReconfirmGuard.isExhausted(call.staleKey)) {
                Gateway.staleReconfirmGuard.clear(call.staleKey)
                call.safetyNote += ";reconfirm=exhausted"
                throw GatewayError(
                    ErrorCode.E_CONFIRM_REQUIRED,
                    StaleReconfirmGuard.EXHAUSTED_MESSAGE,
                    channel = "safety",
                    // 原来这里写的是"输出 [AWAIT_CONFIRM] 暂停报告"——与站规正面矛盾，
                    // 等于代码反过来教大脑违规。
                    fallback = StaleReconfirmGuard.EXHAUSTED_FALLBACK,
                )
            }
            call.safetyNote = "risk=confirmation_required;args_fp=${decision.argsFingerprint};confirmation=requested"
            val attempt = TestConfirmationAttempt(
                confirmationId = ConfirmationIdGenerator.next(),
                toolName = decision.toolName,
                action = decision.action,
                initialPackage = decision.initialPackage,
                inputLength = decision.inputLength,
                inputSha256 = decision.inputSha256,
            )
            call.testAttempt = attempt
            // 决定来自哪条通道。审计里也记一份：状态文件是 debug 专有的，审计三腿都在，
            // 两处独立记录同一件事——只有一处时它坏了没人看得出来。
            var decidedVia: ApprovalChannel? = null
            try {
                ConfirmOverlay.ask(
                    context = Gateway.appContext,
                    actionDesc = decision.cardText(attempt.confirmationId),
                    // 卡的默认 60s **比决定预算还短，本来就自相矛盾**（spec §9.1 第 2 行）。
                    // 通知的存活时长跟着它走（ConfirmNotifier 加 15s slack = 105s）。
                    timeoutMs = intentClocks.decisionTimeoutMs,
                    onShownBeforeButtonsEnabled = { cardTarget ->
                        call.testSession = Gateway.testControl.onConfirmationShown(attempt) {
                            captureConfirmCardEvidence(cardTarget)
                        }
                    },
                    onDecisionObserved = { observed, channel ->
                        decidedVia = channel
                        Gateway.testControl.onConfirmationDecision(call.testSession, observed, channel)
                    },
                    notification = ConfirmNotificationRequest(
                        confirmationId = attempt.confirmationId,
                        nonce = ConfirmApprovalArbiter.newNonce(),
                        riskTier = decision.riskTier,
                        action = confirmActionPhrase(decision),
                        target = call.targetLabel.ifBlank { decision.initialPackage },
                        targetPackage = decision.initialPackage,
                        preview = call.inputPreview,
                    ),
                ).also { confirmed ->
                    call.safetyNote += ";confirmation=${if (confirmed) "allowed" else "denied"}"
                    decidedVia?.let { call.safetyNote += ";decided_via=${it.wireName}" }
                }
            } catch (error: Throwable) {
                call.safetyNote += ";confirmation=error:${(error as? GatewayError)?.code ?: error.javaClass.simpleName}"
                throw error
            }
        },
        contextProvider = { frozenArgs ->
            call.contextReads += 1
            safetyContext(call.toolName, frozenArgs).also { resolved ->
                if (call.contextReads == 1) {
                    // 档位此刻还没算出来（policy.assess 在这之后），按同一条 fail-safe 规则先按 I 级
                    // 定键：键只用于把"同一个语义动作的多次重试"串起来，档位在重试之间不会变。
                    call.captureApprovalScope(resolved, null)
                }
                if (call.contextReads > 1) call.safetyNote += ";context=rechecked"
            }
        },
        onExecutionFailure = { error ->
            if (error !is GatewayError || error.code != ErrorCode.E_RETRY_EXHAUSTED) {
                Gateway.retryGuard.recordFailure(call.toolName, call.argsFingerprint)
            }
        },
        afterConfirmationAllowed = { confirmedTool, confirmedArgs, initialContext ->
            val attempt = call.testAttempt ?: throw GatewayError(
                ErrorCode.E_INTERNAL,
                "确认完成但缺少同一次确认编号",
                channel = "safety",
            )
            val a11y = GatewayA11yService.require()
            Gateway.testControl.afterAllowed(
                session = call.testSession,
                attempt = attempt,
                performHome = { a11y.globalKey("home") },
                foreground = {
                    val current = a11y.ctx(Gateway.caps())
                    TestForeground(
                        known = current.optBoolean("foreground_known", false),
                        packageName = current.optString("app"),
                        // 等不到目标前台时，"读到的是什么"比"没等到"值钱得多——
                        // 2026-08-02 真机上这一条超时，事后只知道它失败了，不知道它看见了什么。
                        reason = current.optString("foreground_reason"),
                    )
                },
            )
        },
        afterExecutionSuccess = { executedTool, executedContext ->
            // 这一串重试有结果了，计数清零，别拖累下一个语义动作。
            if (call.staleKey.isNotEmpty()) Gateway.staleReconfirmGuard.clear(call.staleKey)
            if (
                executedTool == "press_key" &&
                executedContext.target?.preparedTargetEvidence != null
            ) {
                Gateway.preparedTargetEvidence.clear()
            }
        },
        onStaleAfterApproval = { _, _ ->
            // 只有"真人批准过、随后复核判 stale"才走到这里；门前阻断、被拒、超时都不算。
            if (call.staleKey.isNotEmpty()) {
                Gateway.staleReconfirmGuard.recordStaleAfterApproval(call.staleKey)
                call.safetyNote += ";reconfirm=${Gateway.staleReconfirmGuard.reconfirmCount(call.staleKey)}"
            }
        },
        // 语义意图审批（spec `2026-08-02-语义意图审批`）。**批次 4 打开的就是这一行**：
        // 传了它，"批准之后拿什么去比"就从「与批准那一瞬逐字节相同」换成「同一时刻的语义相等
        // + 证据自洽」，既有三腿也一并改走新判据。这是安全姿态变更，由真机验收批次收口。
        intentApproval = newIntentApproval(call),
    )

    /**
     * a11y 不在时的降级 ctx。与正常 ctx 一样恒定带上 `audit_write_failures`——
     * 审计写不进去而动作照常执行，是比动作失败更坏的状态（事后回看会以为这些动作从没发生过）。
     *
     * **恒定上报，不做"仅 >0 才带"**：字段缺席时大脑分不清"没失败"与"装的是旧 APK"，
     * 与本仓 card_visible 用 unknown 而非省略的 fail-closed 惯例一致。
     *
     * 已知局限：本次调用自己的审计行是在这之后才写的，所以这一次的失败要到**下一次**调用
     * 才出现在信封里；若这是本轮最后一次调用就看不到。跑测侧另有 audit.jsonl 的独立采集兜底，
     * 不依赖这个字段做最终判定。
     */
    private fun ctxSnapshot(): JSONObject {
        val ctx = GatewayA11yService.instance?.ctx(Gateway.caps())
            ?: JSONObject().put("app", "").put("activity", "")
                .put("foreground_known", false).put("revision", -1)
                .put("keyboard", JSONObject().put("visible", false).put("height", 0))
                .put("caps", JSONArray(Gateway.caps()))
                .put("note", "a11y 未开启，ctx 降级")
        ctx.put("audit_write_failures", Gateway.audit.writeFailures)
        return ctx
    }

    private fun callInternal(name: String, args: JSONObject): ToolResult {
        val spec = byName[name]
        invalidateInputEvidenceForMutation(
            store = Gateway.inputCommitEvidence,
            level = spec?.level,
            toolName = name,
            key = args.optString("key").ifEmpty { null },
            action = args.optString("action").ifEmpty { null },
            scrollSearch = args.optBoolean("scroll_search", false),
        )
        invalidatePreparedTargetForMutation(
            store = Gateway.preparedTargetEvidence,
            level = spec?.level,
            toolName = name,
            key = args.optString("key").ifEmpty { null },
            scrollSearch = args.optBoolean("scroll_search", false),
        )
        val auditId = Gateway.audit.nextId()
        val start = SystemClock.elapsedRealtime()
        val call = CallScope(toolName = name, argsFingerprint = SafetyPolicy.fingerprint(args))
        val auditArgs = sanitizeAuditArgs(name, args)

        fun finish(env: JSONObject, code: String, channel: String, image: String? = null): ToolResult {
            Gateway.audit.write(
                auditId, name, auditArgs, code, channel, SystemClock.elapsedRealtime() - start,
                note = call.safetyNote,
            )
            return ToolResult(env, image)
        }

        if (spec == null) {
            val e = GatewayError(ErrorCode.E_INVALID_ARG, "未知工具：$name")
            return finish(Envelope.err(e, ctxSnapshot(), auditId), e.code.name, "")
        }

        return try {
            if (name == "type_text") {
                guardPreparedTargetTypeTextArgs(
                    args = args,
                    preparedStore = Gateway.preparedTargetEvidence,
                    inputStore = Gateway.inputCommitEvidence,
                )
            }
            // 敏感 app 黑名单闸（spec §10）：银行类前台时只许感知与撤离
            val fg = GatewayA11yService.instance?.foregroundPackage()
            if (Gateway.skills.isBlockedApp(fg) && !blockedAppAllows(name, args)) {
                throw GatewayError(
                    ErrorCode.E_BLOCKED, "前台是敏感 app（$fg），默认拒绝一切读写",
                    fallback = "press_key(home) 离开后继续任务，并在报告中说明",
                )
            }
            val gate = newSafetyGate(call)
            val data = gate.execute(name, spec.level, args) { frozenArgs, validatedContext ->
                Gateway.retryGuard.checkAllowed(name, call.argsFingerprint)
                val result = executeValidated(spec, frozenArgs, validatedContext)
                runCatching { Gateway.retryGuard.recordSuccess(name, call.argsFingerprint) }
                    .onFailure { error ->
                        call.safetyNote += ";retry_success_record=error:${error.javaClass.simpleName}"
                    }
                result
            }

            // screen_capture 的图走 MCP image content，不塞 JSON 信封（token 考量）
            var image: String? = null
            if (name == "screen_capture") {
                image = data.optString("base64").ifEmpty { null }
                data.remove("base64")
            }
            finish(Envelope.ok(data, ctxSnapshot(), auditId), "OK", channelOf(name), image)
        } catch (e: GatewayError) {
            if (name == "type_text") Gateway.preparedTargetEvidence.clear()
            finish(Envelope.err(e, runCatching { ctxSnapshot() }.getOrElse { JSONObject() }, auditId), e.code.name, e.channel)
        } catch (e: Exception) {
            if (name == "type_text") Gateway.preparedTargetEvidence.clear()
            val ge = GatewayError(ErrorCode.E_INTERNAL, "${e.javaClass.simpleName}: ${e.message}")
            finish(Envelope.err(ge, runCatching { ctxSnapshot() }.getOrElse { JSONObject() }, auditId), "E_INTERNAL", "")
        }
    }

    private fun channelOf(name: String): String = when {
        name.startsWith("ui_") || name in setOf("type_text", "press_key", "wait_for") -> "a11y"
        name.startsWith("system_") || name in setOf("device_info", "clipboard", "media_query", "foreground_app", "keyboard_state") -> "api"
        name in setOf("open_uri", "intent_send", "share_text", "share_file", "app_launch") -> "intent"
        name == "screen_capture" -> "vision"
        // 受控宏走 a11y + IME 复合通道；此前落到空串，写出的审计行 channel 为空，
        // 而审计契约要求每行都有非空通道（2026-07-26：审计一能读到就立刻被这条卡住）。
        name == "macro_run" -> "a11y"
        else -> "tool"
    }

    private fun blockedAppAllows(name: String, args: JSONObject): Boolean = when {
        name !in BLOCKED_APP_ALLOWED -> false
        name == "press_key" -> args.optString("key") in setOf("back", "home", "recents")
        else -> true
    }

    /** 每次调用都重新读取；确认前后分别解析 ref/焦点，不依赖 revision 硬相等。 */
    /**
     * 确认卡取证截图。frame commit 只保证本进程这一帧提交进渲染管线，SurfaceFlinger
     * 合成/latch 还可能差一两个 vsync——2026-07-26 Allow 腿实锤拍出来的是纯微信会话页，
     * 卡完全不在图里，而这张 PNG 是监督式跑测唯一的现场证据。所以拍完先按卡的真实
     * 位置与底色核一遍，没拍到就短暂等一下重拍；重拍间隔要躲开 a11y 截图节流
     * （knowledge：<300ms 连发会硬报 INTERVAL_TIME_SHORT）。
     *
     * 仍然拍不到时**照样返回 PNG，但如实标 cardVisible=false**：这条路径是取证，
     * 静默交出一张证明不了任何事的图，比明说"没拍到"危险得多。
     */
    private fun captureConfirmCardEvidence(target: ConfirmCardTarget?): TestConfirmationCapture {
        val service = GatewayA11yService.require()
        var attempts = 0
        var latest: Bitmap? = null
        var visible = false
        while (attempts < CONFIRM_CARD_CAPTURE_ATTEMPTS) {
            attempts += 1
            if (attempts > 1) SystemClock.sleep(CONFIRM_CARD_RECAPTURE_DELAY_MS)
            val bitmap = try {
                service.captureBitmap()
            } catch (error: GatewayError) {
                if (error.code == ErrorCode.E_RATE_LIMITED && attempts < CONFIRM_CARD_CAPTURE_ATTEMPTS) {
                    SystemClock.sleep(CONFIRM_CARD_THROTTLE_BACKOFF_MS)
                    continue
                }
                if (latest == null) throw error
                break
            }
            latest?.recycle()
            latest = bitmap
            visible = target != null && confirmCardVisibleInCapture(
                target = target,
                width = bitmap.width,
                height = bitmap.height,
                pixelAt = bitmap::getPixel,
            )
            // 几何未知时无从核对，拍一张就走，由 cardVisible=false 如实反映。
            if (visible || target == null) break
        }
        val bitmap = latest ?: throw GatewayError(
            ErrorCode.E_CHANNEL_DOWN, "确认卡取证未取得任何截图", channel = "overlay",
        )
        val png = ByteArrayOutputStream().use { output ->
            if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)) {
                throw GatewayError(ErrorCode.E_CHANNEL_DOWN, "确认卡 PNG 编码失败", channel = "overlay")
            }
            output.toByteArray()
        }
        return TestConfirmationCapture(png = png, cardVisible = visible, attempts = attempts)
    }

    private fun safetyContext(name: String, args: JSONObject): SafetyContext {
        val a11y = GatewayA11yService.instance
            ?: return SafetyContext("", "", -1, foregroundKnown = false)
        val ctx = a11y.ctx(Gateway.caps())
        val packageName = ctx.optString("app")
        val activityName = ctx.optString("activity")
        val revision = ctx.optLong("revision", -1)
        val foregroundKnown = ctx.optBoolean("foreground_known", false)
        val identityBootstrapped = ctx.optString("foreground_identity_source") == "bootstrap"
        if (!foregroundKnown) return SafetyContext(
            packageName = packageName,
            activityName = activityName,
            revision = revision,
            foregroundKnown = false,
            target = null,
        )
        val target = when {
            name == "ui_action" -> {
                val ref = args.getString("ref")
                val resolved = a11y.resolve(ref)
                SafetyTarget(
                    ref = ref,
                    text = resolved.text,
                    description = resolved.desc,
                    bounds = "[${resolved.bounds.left},${resolved.bounds.top}][${resolved.bounds.right},${resolved.bounds.bottom}]",
                    source = resolved.source,
                )
            }
            name == "press_key" && args.optString("key").equals("enter", ignoreCase = true) ->
                UiTools.focusedInputSnapshot(a11y).let { focused ->
                    val bounds = focused.bounds?.let(::boundsString)
                    SafetyTarget(
                        focusIdentity = focused.identity,
                        focusedInputBounds = bounds,
                        inputCommitEvidence = Gateway.inputCommitEvidence.current(
                            focused.identity,
                            focused.readableText,
                        ),
                        preparedTargetEvidence = Gateway.preparedTargetEvidence.current(
                            packageName,
                            focused.identity,
                            bounds,
                        ),
                    )
                }
            else -> null
        }
        return SafetyContext(
            packageName = packageName,
            activityName = activityName,
            revision = revision,
            foregroundKnown = true,
            identityBootstrapped = identityBootstrapped,
            target = target,
        )
    }

    private fun executeValidated(
        spec: ToolSpec,
        args: JSONObject,
        validatedContext: SafetyContext,
    ): JSONObject = when (spec.name) {
        "ui_action" -> {
            val params = JSONObject()
                .put("text", args.optString("text"))
                .put("direction", args.optString("direction", "forward"))
            val expected = validatedContext.target ?: throw GatewayError(
                ErrorCode.E_STALE_REF, "安全门未提供已复核的 UI 目标", channel = "safety",
            )
            UiTools.uiAction(args.getString("ref"), args.getString("action"), params, expected)
        }
        "press_key" -> UiTools.pressKey(
            args.getString("key"),
            validatedContext.target?.focusIdentity,
            validatedContext.target?.inputCommitEvidence,
            validatedContext.target?.focusedInputBounds,
            validatedContext.target?.preparedTargetEvidence,
        )
        "type_text" -> executeTypeTextWithPreparedTargetValidation(spec, args)
        else -> spec.handler(args)
    }

    private fun executeTypeTextWithPreparedTargetValidation(
        spec: ToolSpec,
        args: JSONObject,
    ): JSONObject {
        val expected = Gateway.preparedTargetEvidence.peekActive()
        if (expected == null) return spec.handler(args)
        val before = currentPreparedTarget()
        if (before != expected) {
            // 逐条点名差异：合并成一句四选一时，真机排查每次都要额外烧一轮派单才能定位。
            val why = preparedTargetDrift(expected)
            Gateway.preparedTargetEvidence.clear()
            Gateway.inputCommitEvidence.clear()
            throw GatewayError(
                ErrorCode.E_STALE_REF,
                "type_text 前已准备目标已变化：$why",
                channel = "safety",
                retryable = false,
            )
        }
        return try {
            val result = spec.handler(args)
            val after = currentPreparedTarget()
            val input = after?.let { Gateway.inputCommitEvidence.current(it.identity) }
            if (!preparedTargetSurvivesTypeText(before, after, input, succeeded = true)) {
                // 同样逐条点名：只输出身份类元数据与读回结论，不输出输入内容本身。
                val why = when {
                    after == null || after != before ->
                        "已准备目标在输入后变化：${preparedTargetDrift(before)}"
                    input == null && before.identity.degraded ->
                        "IME-only 降级链没有形成输入提交证据：输入栏 OCR 读回" +
                            "verified=${result.optBoolean("verified", false)}" +
                            "，实际读回「${result.optString("readback").take(24)}」" +
                            "，${result.optString("readback_geometry")}" +
                            "（读回不过就不记证据，见 design §3.5）"
                    input == null -> "输入后没有形成可用的输入提交证据"
                    else -> "输入证据身份与已准备目标不一致"
                }
                Gateway.preparedTargetEvidence.clear()
                Gateway.inputCommitEvidence.clear()
                throw GatewayError(
                    ErrorCode.E_STALE_REF,
                    "type_text 后复核失败：$why",
                    channel = "safety",
                    retryable = false,
                )
            }
            result
        } catch (error: Throwable) {
            Gateway.preparedTargetEvidence.clear()
            Gateway.inputCommitEvidence.clear()
            throw error
        }
    }

    /**
     * 只用于**失败时**说明哪一项对不上；不参与放行判定（放行仍由
     * [currentPreparedTarget] 的严格相等决定）。不输出输入内容，只输出身份类元数据。
     */
    private fun preparedTargetDrift(
        expected: dev.magina.gateway.core.PreparedTargetEvidence,
    ): String {
        val a11y = GatewayA11yService.instance ?: return "无障碍服务不可用"
        val ctx = runCatching { a11y.ctx(Gateway.caps()) }.getOrNull()
            ?: return "无法读取前台上下文"
        if (!ctx.optBoolean("foreground_known", false)) return "前台身份未知"
        val focused = UiTools.focusedInputSnapshot(a11y)
        val bounds = focused.bounds?.let(::boundsString)
        return buildList {
            val pkg = ctx.optString("app")
            if (pkg != expected.packageName) add("前台包 ${expected.packageName} → $pkg")
            val identity = focused.identity
            when {
                identity == null -> add("当前取不到任何焦点输入身份（IME 会话可能已结束）")
                identity.source != expected.identity.source ->
                    add("身份来源 ${expected.identity.source} → ${identity.source}")
                identity.imeSessionId != expected.identity.imeSessionId ->
                    add("IME 会话 ${expected.identity.imeSessionId} → ${identity.imeSessionId}")
                identity.a11yInputId != expected.identity.a11yInputId ->
                    add("a11y 节点 ${expected.identity.a11yInputId} → ${identity.a11yInputId}")
            }
            if (bounds != expected.bounds) add("焦点位置 ${expected.bounds} → $bounds")
        }.ifEmpty { listOf("身份逐项一致但短时目标已过期（TTL）") }.joinToString("；")
    }

    private fun currentPreparedTarget(): dev.magina.gateway.core.PreparedTargetEvidence? {
        val a11y = GatewayA11yService.instance ?: run {
            Gateway.preparedTargetEvidence.clear()
            return null
        }
        val ctx = a11y.ctx(Gateway.caps())
        if (!ctx.optBoolean("foreground_known", false)) {
            Gateway.preparedTargetEvidence.clear()
            return null
        }
        val focused = UiTools.focusedInputSnapshot(a11y)
        val bounds = focused.bounds?.let(::boundsString)
        return Gateway.preparedTargetEvidence.current(
            ctx.optString("app"),
            focused.identity,
            bounds,
        )
    }

    private fun boundsString(bounds: android.graphics.Rect): String =
        "[${bounds.left},${bounds.top}][${bounds.right},${bounds.bottom}]"

    /** 合成落后一两个 vsync 是常态，多给几次机会；总延迟仍远小于人抬手看卡的时间。 */
    private const val CONFIRM_CARD_CAPTURE_ATTEMPTS = 4
    private const val CONFIRM_CARD_RECAPTURE_DELAY_MS = 400L
    private const val CONFIRM_CARD_THROTTLE_BACKOFF_MS = 900L
}

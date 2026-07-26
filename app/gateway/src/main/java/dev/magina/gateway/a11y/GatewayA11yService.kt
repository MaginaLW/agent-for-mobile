package dev.magina.gateway.a11y

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Bitmap
import android.graphics.Path
import android.graphics.Rect
import android.os.Bundle
import android.os.SystemClock
import android.util.Base64
import android.util.Log
import android.view.Display
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import dev.magina.gateway.core.ErrorCode
import dev.magina.gateway.core.GatewayError
import dev.magina.gateway.ocr.OcrEngine
import dev.magina.gateway.overlay.ConfirmOverlay
import dev.magina.gateway.ime.ImeBridge
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.util.concurrent.CompletableFuture
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

/** Gateway 自有非应用窗口（确认 overlay）和 IME 不进入 agent 的感知/ref 面。 */
internal fun shouldExposeWindow(
    windowType: Int,
    applicationWindowType: Int,
    inputMethodWindowType: Int,
    rootPackage: String?,
    ownPackage: String,
    confirmationAwaiting: Boolean,
): Boolean = windowType != inputMethodWindowType &&
    !(confirmationAwaiting && windowType != applicationWindowType) &&
    !(windowType != applicationWindowType && rootPackage == ownPackage)

/**
 * L4 UI 通道：事件驱动语义树（spec §3/§5.4）。
 * - revision：窗口/内容每次变化 +1；ref 绑定产生它的 snapshot revision，过期即 E_STALE_REF。
 * - snapshot 是「读实时树 + 编号缓存」，不做 uiautomator 式 idle 等待（京东实锤）。
 * - 键盘态/前台 app 从事件流与 windows 列表感知（坐标错位与 UsageStats 授权都绕开）。
 */
class GatewayA11yService : AccessibilityService() {

    companion object {
        private const val TAG = "gateway-a11y"

        /** 前台 app 贡献可读元素低于此数 → 视为树空/稀疏，snapshot 自动融合 OCR（spec §5.4，S1 微信实锤）。 */
        private const val FUSE_FG_THRESHOLD = 5

        /** 覆盖自家确认卡收起后系统重新激活 App 窗口的那几帧；总上限 ~320ms，只在没有活动应用窗口时才付。 */
        private const val FOREGROUND_SETTLE_ATTEMPTS = 5
        private const val FOREGROUND_SETTLE_INTERVAL_MS = 80L

        @Volatile var instance: GatewayA11yService? = null

        fun require(): GatewayA11yService = instance ?: throw GatewayError(
            ErrorCode.E_CHANNEL_DOWN, "无障碍服务未开启",
            channel = "a11y", fallback = "设置→无障碍→开启「执行网关」后重试",
        )
    }

    private val rev = AtomicLong(0)
    private val foregroundWindowTracker = ForegroundWindowTracker()

    /**
     * 系统装饰栏（状态栏/导航栏，[AccessibilityWindowInfo.TYPE_SYSTEM]）的窗口 id 快照。
     * 只在窗口增删事件里刷新，让高频的内容变化事件走 O(1) 查表而不是每次 `getWindows()`。
     * 初始为空 = 一律按"未知"处理照常递增 revision，故障方向偏向多失效而非漏失效。
     */
    @Volatile private var systemChromeWindowIds: Set<Int> = emptySet()

    /**
     * ref 表项。node=null 表示 OCR 来源（无节点，坐标手势操作）。
     * text 是 a11y 节点当时的文本（staleness 指纹；OCR/挂载条目留空），label 是展示与危险词判定文本。
     */
    private data class RefEntry(
        val node: AccessibilityNodeInfo?,
        val text: String,
        val label: String,
        val desc: String,
        val bounds: Rect,
        val snapRev: Long,
        val source: String,
    )

    private val refs = HashMap<String, RefEntry>()
    @Volatile private var lastSnapshotRev = -1L
    private val shotExecutor = Executors.newSingleThreadExecutor()
    private val freshVisionSession = FreshVisionSession(
        capture = ::captureBitmapRetry,
        currentRevision = { revision },
    )
    private var forceFreshOcrOnce = false

    val revision: Long get() = rev.get()

    override fun onServiceConnected() {
        instance = this
        Log.i(TAG, "a11y connected")
    }

    override fun onDestroy() {
        instance = null
        shotExecutor.shutdown()
        super.onDestroy()
    }

    override fun onInterrupt() {}

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        event ?: return
        when (event.eventType) {
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED -> {
                rev.incrementAndGet()
                refreshSystemChromeWindowIds()
                foregroundWindowTracker.onWindowStateChanged(
                    eventWindowId = event.windowId,
                    packageName = event.packageName?.toString(),
                    activityName = event.className?.toString(),
                    windows = foregroundWindows(),
                )
            }
            // 状态栏时钟/网速这类系统装饰栏文本每秒都在刷新并发出内容变化事件，若照单全收，
            // 全局 revision 在完全静默的屏幕上也会持续上涨（2026-07-25 真机实测：无任何操作
            // 时每约 2 秒 +3~4），导致所有"动作前后 revision 必须一致"的新鲜度校验几乎必败
            // （实测 `P0FocusProbeValidator.revalidateForAction` 因此永远过不去）。装饰栏内容
            // 与被操作的 App 界面无关，不该被当成"我要点的东西变了"。同 knowledge #11
            // （`hasBlockingOverlay` 未排除 TYPE_SYSTEM 导致恒判有遮挡）是同一病根的另一处发作。
            AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED ->
                if (event.windowId !in systemChromeWindowIds) rev.incrementAndGet()
            AccessibilityEvent.TYPE_WINDOWS_CHANGED -> {
                rev.incrementAndGet()
                refreshSystemChromeWindowIds()
                foregroundWindowTracker.onWindowsChanged(foregroundWindows())
            }
        }
    }

    /** 只认明确为 [AccessibilityWindowInfo.TYPE_SYSTEM] 的窗口；取不到窗口列表时清空（回到全部照常递增）。 */
    private fun refreshSystemChromeWindowIds() {
        systemChromeWindowIds = runCatching {
            windows.filter { it.type == AccessibilityWindowInfo.TYPE_SYSTEM }.map { it.id }.toSet()
        }.getOrDefault(emptySet())
    }

    // ---------- ctx ----------

    fun foregroundPackage(): String = currentForeground().packageName

    fun keyboardState(): JSONObject {
        val ime = windows.firstOrNull { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD }
        val b = Rect()
        ime?.getBoundsInScreen(b)
        return JSONObject()
            .put("visible", ime != null)
            .put("height", if (ime != null) b.height() else 0)
    }

    fun ctx(caps: List<String>): JSONObject {
        // 同一次已接受事件原子地产生 package/activity，避免 ctx 拼出跨窗口身份。
        val foreground = currentForeground()
        return JSONObject()
            .put("app", foreground.packageName)
            .put("activity", foreground.activityName)
            .put("foreground_known", foreground.known)
            // 前台身份判不出来时，让失败的那次调用自己带上原因，不必事后另起一次诊断。
            .put("foreground_reason", foreground.reason.name.lowercase())
            .put("revision", revision)
            .put("keyboard", keyboardState())
            .put("screen", "on") // 服务在收事件即亮屏；灭屏感知 M1b 接 PowerManager
            .put("caps", JSONArray(caps))
    }

    /**
     * 冷启动仅从活动应用窗口取 package-only 后备；overlay/IME root 不参与，root 为空则保持未知。
     */
    private fun currentForeground(): ResolvedForeground {
        val currentWindow = applicationWindow(settledWindows())
        return resolveForeground(
            identity = foregroundWindowTracker.current(),
            applicationWindowId = currentWindow?.id,
            applicationWindowPackageName = currentWindow?.root?.packageName?.toString(),
        )
    }

    /**
     * 只读前台身份诊断：解析结论 + 已接受身份 + 实时窗口列表 + 最近事件处置记录。
     * R 级，`foreground_known=false` 时也可调用——正是为了查清"为什么 unknown"而存在。
     * `windows[].root_package` 同时回答"服务冷启动能否直接从窗口自举身份"。
     */
    fun foregroundDiagnostics(): JSONObject {
        val currentWindows = windows
        val selected = applicationWindow(currentWindows)
        val identity = foregroundWindowTracker.current()
        val resolved = resolveForeground(
            identity = identity,
            applicationWindowId = selected?.id,
            applicationWindowPackageName = runCatching { selected?.root?.packageName?.toString() }.getOrNull(),
        )
        val windowsJson = JSONArray()
        for (window in currentWindows) {
            val b = Rect().also(window::getBoundsInScreen)
            windowsJson.put(
                JSONObject()
                    .put("id", window.id)
                    .put("type", windowTypeName(window.type))
                    .put("active", window.isActive)
                    .put("focused", window.isFocused)
                    .put("root_package", runCatching { window.root?.packageName?.toString() }.getOrNull() ?: JSONObject.NULL)
                    .put("title", window.title?.toString().orEmpty())
                    .put("bounds", JSONArray(listOf(b.left, b.top, b.right, b.bottom)))
            )
        }
        val eventsJson = JSONArray()
        for (record in foregroundWindowTracker.recentEvents()) {
            eventsJson.put(
                JSONObject()
                    .put("seq", record.seq)
                    .put("at_ms", record.atMillis)
                    .put("kind", record.kind)
                    .put("window_id", record.eventWindowId)
                    .put("package", record.packageName)
                    .put("activity", record.activityName)
                    .put("decision", record.decision.name.lowercase())
                    .put("selected_window_id", record.selectedApplicationWindowId ?: JSONObject.NULL)
                    .put("windows", record.windows.joinToString(",") {
                        "${it.id}:${it.type.name}:${if (it.isActive) "a" else "-"}${if (it.isFocused) "f" else "-"}"
                    })
            )
        }
        return JSONObject()
            .put("package", resolved.packageName)
            .put("activity", resolved.activityName)
            .put("foreground_known", resolved.known)
            .put("foreground_reason", resolved.reason.name.lowercase())
            .put("selected_window_id", selected?.id ?: JSONObject.NULL)
            .put(
                "tracked_identity",
                (identity as? ForegroundIdentity.Known)?.let {
                    JSONObject()
                        .put("window_id", it.windowId)
                        .put("package", it.packageName)
                        .put("activity", it.activityName)
                } ?: JSONObject.NULL,
            )
            .put("now_ms", System.currentTimeMillis())
            .put("revision", revision)
            .put("windows", windowsJson)
            .put("recent_events", eventsJson)
    }

    private fun windowTypeName(type: Int): String = when (type) {
        AccessibilityWindowInfo.TYPE_APPLICATION -> "application"
        AccessibilityWindowInfo.TYPE_INPUT_METHOD -> "input_method"
        AccessibilityWindowInfo.TYPE_SYSTEM -> "system"
        AccessibilityWindowInfo.TYPE_ACCESSIBILITY_OVERLAY -> "a11y_overlay"
        AccessibilityWindowInfo.TYPE_SPLIT_SCREEN_DIVIDER -> "split_divider"
        else -> "other_$type"
    }

    private fun foregroundWindows(): List<ForegroundWindow> = windows.map { window ->
        ForegroundWindow(
            id = window.id,
            type = when (window.type) {
                AccessibilityWindowInfo.TYPE_APPLICATION -> ForegroundWindowType.APPLICATION
                AccessibilityWindowInfo.TYPE_INPUT_METHOD -> ForegroundWindowType.INPUT_METHOD
                else -> ForegroundWindowType.OTHER
            },
            isActive = window.isActive,
            isFocused = window.isFocused,
        )
    }

    /**
     * 取窗口列表；只在"当前一个活动应用窗口都没有"这种**瞬时**形态下有限重读。
     *
     * 自家确认卡是可获焦的 `TYPE_APPLICATION_OVERLAY`：它在时 App 窗口既非 active 也非
     * focused，收起后系统重新激活 App 窗口还要几帧。单次采样正好撞上这几帧，前台身份就
     * 会被判成 unknown——2026-07-26 Allow 腿实锤：人点完「允许本次」，紧接着的确认后复核
     * （[SafetyGate] 的第二次 requireKnownForeground）直接 E_BLOCKED，而此前同为 W 级的
     * `type_text` 一路正常。
     *
     * 只重读、不放宽判据：窗口真的没了（切走、灭屏）就照旧解析为 unknown，D1 的
     * "身份必须归属到活动 APPLICATION 窗口"一字未动。
     */
    private fun settledWindows(): List<AccessibilityWindowInfo> {
        var current = windows
        var attempts = 1
        while (applicationWindow(current) == null && attempts < FOREGROUND_SETTLE_ATTEMPTS) {
            SystemClock.sleep(FOREGROUND_SETTLE_INTERVAL_MS)
            attempts += 1
            current = windows
        }
        return current
    }

    private fun applicationWindow(currentWindows: List<AccessibilityWindowInfo> = windows): AccessibilityWindowInfo? {
        return currentWindows.firstOrNull {
            it.type == AccessibilityWindowInfo.TYPE_APPLICATION && it.isActive
        } ?: currentWindows.firstOrNull {
            it.type == AccessibilityWindowInfo.TYPE_APPLICATION && it.isFocused
        }
    }

    private fun exposedWindows(currentWindows: List<AccessibilityWindowInfo> = windows): List<AccessibilityWindowInfo> =
        currentWindows.filter { window ->
        val rootPackage = runCatching { window.root?.packageName?.toString() }.getOrNull()
        shouldExposeWindow(
            windowType = window.type,
            applicationWindowType = AccessibilityWindowInfo.TYPE_APPLICATION,
            inputMethodWindowType = AccessibilityWindowInfo.TYPE_INPUT_METHOD,
            rootPackage = rootPackage,
            ownPackage = packageName,
            confirmationAwaiting = ConfirmOverlay.isAwaitingDecision,
        )
    }

    private fun isGatewayOverlayRoot(root: AccessibilityNodeInfo): Boolean =
        root.packageName?.toString() == packageName && root.windowId != appWindowId()

    private fun rejectWhileConfirming() {
        if (ConfirmOverlay.isAwaitingDecision) throw GatewayError(
            ErrorCode.E_BLOCKED,
            "真人确认卡显示期间拒绝 agent UI 动作",
            channel = "safety",
            fallback = "等待真人完成本次允许或拒绝决定",
        )
    }

    // ---------- snapshot / find ----------

    /** scope: interactive(默认，可交互 + 带文本) / full(全部有信号节点)。上限截断防 token 爆炸。 */
    @Synchronized
    fun snapshot(scope: String, maxElements: Int = 200): JSONObject {
        refs.clear()
        lastSnapshotRev = revision
        val elements = JSONArray()
        val jsonByRef = HashMap<String, JSONObject>()
        // interactive 与 full 的差异在文本截断长度：interactive 面向操作（短），full 面向阅读（长）
        val cap = if (scope == "full") 500 else 80
        // 前台归属按「活动应用窗口」判定，不用包名比对——vivo 系统窗口事件会污染前台包名跟踪
        //（实测：设置页 43 节点却被误判 fg=0 触发 OCR）；WeChat 类 root=null 的应用窗口自然贡献 0。
        val fgWinId = appWindowId()
        var fgCount = 0
        var count = 0
        var truncated = false

        fun visit(node: AccessibilityNodeInfo, depth: Int, inFgWin: Boolean) {
            if (depth > 60 || truncated) return
            val text = node.text?.toString().orEmpty()
            val desc = node.contentDescription?.toString().orEmpty()
            val interactive = node.isClickable || node.isLongClickable || node.isEditable ||
                node.isScrollable || node.isCheckable
            val hasSignal = text.isNotEmpty() || desc.isNotEmpty()
            val include = when (scope) {
                "full" -> interactive || hasSignal
                else -> interactive || hasSignal
            }
            if (include && node.isVisibleToUser) {
                if (count >= maxElements) { truncated = true; return }
                count += 1
                val ref = "e$count"
                val b = Rect().also { node.getBoundsInScreen(it) }
                refs[ref] = RefEntry(node, text, text, desc, b, lastSnapshotRev, "a11y")
                if (inFgWin) fgCount += 1
                val json = JSONObject()
                    .put("ref", ref)
                    .put("role", roleOf(node))
                    .put("text", text.take(cap))
                    .put("desc", desc.take(cap))
                    .put("bounds", JSONArray(listOf(b.left, b.top, b.right, b.bottom)))
                    .put("flags", flagsOf(node))
                    .put("source", "a11y")
                jsonByRef[ref] = json
                elements.put(json)
            }
            for (i in 0 until node.childCount) node.getChild(i)?.let { visit(it, depth + 1, inFgWin) }
        }

        // 遍历全部交互窗口（含弹窗/对话框），跳过 IME 窗口
        val ws = exposedWindows()
        for (w in ws) w.root?.let { visit(it, 0, w.id == fgWinId) }
        if (count == 0) rootInActiveWindow?.takeUnless(::isGatewayOverlayRoot)?.let { visit(it, 0, true) }

        // ---- L5 OCR 融合：前台 app 树空/稀疏时自动触发（spec §5.4/§9）----
        // 骨架规则：OCR 行中心落在最小且大小同量级的 a11y 元素内 → 无语义则挂载(fused)、有语义视为重复丢弃；
        // 挂不上的落为独立 ocr 元素（无节点，click 走坐标手势）。
        var fusion = "none"
        var fusionNote: String? = null
        var usedVisionGeneration = freshVisionSession.current()?.generation ?: 0L
        var usedCaptureRevision = freshVisionSession.current()?.revision ?: lastSnapshotRev
        if (fgCount < FUSE_FG_THRESHOLD && !ConfirmOverlay.isAwaitingDecision) {
            try {
                val shot = ocrScreen()
                usedVisionGeneration = shot.generation
                usedCaptureRevision = shot.revision
                var ocrIdx = 0
                for (line in shot.lines) {
                    if (truncated) break
                    val lineArea = line.bounds.width().toLong() * line.bounds.height()
                    val host = refs.entries
                        .filter {
                            it.value.node != null &&
                                it.value.bounds.contains(line.bounds.centerX(), line.bounds.centerY())
                        }
                        .minByOrNull { it.value.bounds.width().toLong() * it.value.bounds.height() }
                        ?.takeIf {
                            it.value.bounds.width().toLong() * it.value.bounds.height() <= 12 * lineArea
                        }
                    if (host != null) {
                        val he = host.value
                        val hostHasText = he.label.isNotEmpty() || he.desc.isNotEmpty()
                        if (he.source == "a11y" && !hostHasText) {
                            refs[host.key] = he.copy(label = line.text, source = "fused")
                            jsonByRef[host.key]
                                ?.put("text", line.text.take(cap))
                                ?.put("source", "fused")
                                ?.put("confidence", conf2(line.conf))
                            continue
                        }
                        if (he.source == "a11y" && hostHasText) {
                            // 仅当内容确实相同才算重复丢弃——vivo 充电胶囊等带文本大悬浮节点
                            // 罩住页面文字时（实锤：选择聊天/搜索被误吞），必须落为独立 OCR 元素
                            val hn = OcrEngine.norm(he.label + he.desc)
                            val ln = OcrEngine.norm(line.text)
                            if (hn.contains(ln) || (ln.contains(hn) && hn.length >= 2)) continue
                        }
                        // host 已被先前的行挂载（fused）/ 内容不同 → 本行落为独立 OCR 元素
                    }
                    if (count >= maxElements) { truncated = true; break }
                    count += 1
                    ocrIdx += 1
                    val ref = "o$ocrIdx"
                    val b = Rect(line.bounds)
                    refs[ref] = RefEntry(null, "", line.text, "", b, lastSnapshotRev, "ocr")
                    elements.put(
                        JSONObject()
                            .put("ref", ref)
                            .put("role", "text")
                            .put("text", line.text.take(cap))
                            .put("desc", "")
                            .put("bounds", JSONArray(listOf(b.left, b.top, b.right, b.bottom)))
                            .put("flags", "")
                            .put("source", "ocr")
                            .put("confidence", conf2(line.conf))
                    )
                }
                fusion = "ocr"
            } catch (e: Exception) {
                fusionNote = "OCR 融合失败，降级纯 a11y：${e.message}"
                Log.w(TAG, "ocr fuse failed", e)
            }
        }

        val out = JSONObject()
            .put("revision", lastSnapshotRev)
            .put("count", count)
            .put("truncated", truncated)
            .put("tree_empty", count == 0)
            .put("fg_elements", fgCount)
            .put("fusion", fusion)
            .put("vision_generation", usedVisionGeneration)
            .put("capture_revision", usedCaptureRevision)
            .put("foreground_window_id", fgWinId)
            .put("blocking_overlay", hasBlockingOverlay(ws, fgWinId))
            .put("ime_visible", windows.any { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD })
            .put("system_bottom_inset", systemBottomInset())
            .put("elements", elements)
        fusionNote?.let { out.put("note", it) }
        return out
    }

    /** debug 受控宏内部使用：无论 a11y 树是否稠密，都先取得独立世代的真实新截图。 */
    @Synchronized
    internal fun forceFreshVision(scope: String = "interactive", maxElements: Int = 400): JSONObject {
        forceFreshOcrOnce = true
        return try {
            freshVisionSession.withFreshCapture { snapshot(scope, maxElements) }
        } finally {
            forceFreshOcrOnce = false
        }
    }

    /** debug 受控阶段点击：fresh proof → resolve（可含慢 OCR）→ 最终状态闸门 → 立即 perform。 */
    @Synchronized
    internal fun performFreshVisionClick(
        expectedPackage: String,
        imeMustBeHidden: Boolean,
        selectValidatedRef: (JSONObject) -> FreshValidatedRef,
    ): Boolean {
        rejectWhileConfirming()
        val fresh = forceFreshVision("interactive", maxElements = 400)
        val proof = selectValidatedRef(fresh)
        val captureRevision = fresh.getLong("capture_revision")
        val visionGeneration = fresh.optLong("vision_generation", 0)
        val foregroundWindowId = fresh.getInt("foreground_window_id")
        if (
            proof.captureRevision != captureRevision || proof.visionGeneration != visionGeneration ||
            proof.foregroundWindowId != foregroundWindowId || captureRevision != fresh.getLong("revision") ||
            visionGeneration <= 0
        ) {
            throw GatewayError(
                ErrorCode.E_STALE_REF,
                "点击 proof 未绑定同一 capture revision 与 vision generation",
                channel = "vision",
                retryable = true,
            )
        }
        val expectation = FreshClickExpectation(
            revision = captureRevision,
            expectedWindowId = foregroundWindowId,
            expectedPackage = expectedPackage,
            imeMustBeHidden = imeMustBeHidden,
        )
        return FreshClickActionExecutor.resolveGuardPerform(
            expected = expectation,
            resolve = { resolve(proof.ref) },
            readCurrent = ::readFreshActionState,
            perform = { target -> perform(target, "click", JSONObject()); true },
        )
    }

    /**
     * debug 目标准备写证据的最终临界区：强制新截图，写入前后都复核同一 revision/window/package/IME。
     * 调用方若 post-check 失败必须回滚其进程内记录。
     */
    @Synchronized
    internal fun <T> withFreshPreparedTargetGuard(
        expectedPackage: String,
        validateAndRecord: (JSONObject, FreshPreparedInputProof) -> T,
    ): T {
        rejectWhileConfirming()
        val fresh = forceFreshVision("interactive", maxElements = 400)
        val captureRevision = fresh.getLong("capture_revision")
        val windowId = fresh.getInt("foreground_window_id")
        // 逐条命名失败原因：合并成一句话时，真机上排查要额外烧一整轮派单才能定位。
        val proofProblems = buildList {
            if (captureRevision != fresh.getLong("revision")) add("capture_revision 与 revision 不一致")
            if (fresh.optLong("vision_generation", 0) <= 0) add("vision_generation 无效")
            if (windowId < 0) add("前台窗口 id 无效")
            if (fresh.optBoolean("blocking_overlay", true)) add("存在遮挡浮层")
            // 不能用 ime_visible 当活性证据：自有 IME 零 UI，该值恒假（knowledge）。
            // 改用会话身份本身——活的连接 + 会话属于目标 App。
            val session = ImeBridge.session()
            if (session == null) add("没有活的 IME 输入会话")
            else if (!session.belongsTo(expectedPackage)) {
                add("IME 输入会话不属于目标 App（session=${session.packageName ?: "未知"}）")
            }
        }
        if (proofProblems.isNotEmpty()) throw GatewayError(
            ErrorCode.E_STALE_REF,
            "准备目标的 fresh proof 无效：${proofProblems.joinToString("、")}",
            channel = "vision",
            retryable = false,
        )
        fun requireCurrent() {
            val current = readFreshActionState()
            FreshClickFinalGuard.requireCurrent(
                FreshClickExpectation(
                    revision = captureRevision,
                    expectedWindowId = windowId,
                    expectedPackage = expectedPackage,
                    imeMustBeHidden = false,
                ),
                current,
            )
            // 同上：终验也改看会话身份，不看键盘可见性。
            if (ImeBridge.session()?.belongsTo(expectedPackage) != true) throw GatewayError(
                ErrorCode.E_STALE_REF,
                "准备目标终验时 IME 输入会话已失效或不属于目标 App",
                channel = "vision",
                retryable = false,
            )
        }
        requireCurrent()
        fun readInputProof(): FreshPreparedInputProof {
            val node = focusedEditable()
            val present = node?.let { runCatching { it.refresh() }.getOrDefault(false) } == true
            // 与 UiTools.focusedInputSnapshot 同一判据：不可编辑的节点不产出 a11y 身份与几何，
            // 否则两处对"有没有可用节点"的判断会打架，验证器必然误判错配。
            val usable = present && node?.isEditable == true
            val bounds = node?.takeIf { usable }?.let { Rect().also(it::getBoundsInScreen) } ?: Rect()
            return FreshPreparedInputProof(
                captureRevision = captureRevision,
                foregroundWindowId = windowId,
                nodePresent = present,
                nodeId = node?.takeIf { usable }?.let(FocusedInputIdentity::fromRefreshedNode),
                imeSessionId = ImeBridge.focusedInputId,
                focused = present && node?.isFocused == true,
                editable = present && node?.isEditable == true,
                left = bounds.left,
                top = bounds.top,
                right = bounds.right,
                bottom = bounds.bottom,
            )
        }
        val inputProof = readInputProof()
        val result = validateAndRecord(fresh, inputProof)
        requireCurrent()
        if (readInputProof() != inputProof) throw GatewayError(
            ErrorCode.E_STALE_REF,
            "准备目标记录期间 focused input proof 已变化",
            channel = "vision",
            retryable = false,
        )
        return result
    }

    /** IME 会话锁内可调用的快速最终校验；不截图、不 OCR、无 UI 副作用。 */
    internal fun isFreshActionStateCurrent(
        expectedRevision: Long,
        expectedWindowId: Int,
        expectedPackage: String,
        imeMustBeHidden: Boolean,
    ): Boolean = runCatching {
        requireFreshActionState(expectedRevision, expectedWindowId, expectedPackage, imeMustBeHidden)
    }.isSuccess

    /** 固定查询提交的锁内快检：页面 proof 不变之外，真实 editable 焦点仍须位于 SEARCH 区。 */
    internal fun isFreshSearchCommitStateCurrent(
        expectedRevision: Long,
        expectedWindowId: Int,
        expectedPackage: String,
    ): Boolean {
        if (!isFreshActionStateCurrent(expectedRevision, expectedWindowId, expectedPackage, imeMustBeHidden = false)) return false
        val metrics = resources.displayMetrics
        val node = focusedEditable()
        val refreshed = node?.let { runCatching { it.refresh() }.getOrDefault(false) } == true
        val bounds = node?.let { Rect().also(it::getBoundsInScreen) } ?: Rect()
        val focusValid = FreshSearchFocusGuard.isValid(
            FreshSearchFocusCurrent(
                nodePresent = refreshed,
                focused = refreshed && node?.isFocused == true,
                editable = refreshed && node?.isEditable == true,
                screenWidth = metrics.widthPixels,
                screenHeight = metrics.heightPixels,
                left = bounds.left,
                top = bounds.top,
                right = bounds.right,
                bottom = bounds.bottom,
            ),
        )
        return focusValid && isFreshActionStateCurrent(
            expectedRevision,
            expectedWindowId,
            expectedPackage,
            imeMustBeHidden = false,
        )
    }

    private fun requireFreshActionState(
        expectedRevision: Long,
        expectedWindowId: Int,
        expectedPackage: String,
        imeMustBeHidden: Boolean,
    ) {
        FreshClickFinalGuard.requireCurrent(
            FreshClickExpectation(expectedRevision, expectedWindowId, expectedPackage, imeMustBeHidden),
            readFreshActionState(),
        )
    }

    private fun readFreshActionState(): FreshClickCurrent {
        // 先让窗口稳定（见 settledWindows），再开始这段"期间不得有事件"的原子读取——
        // 否则重读期间的自然事件会把新鲜度校验直接顶成 fail-closed。
        settledWindows()
        val revisionBefore = rev.get()
        val currentWindows = windows
        val applicationWindow = applicationWindow(currentWindows)
        val resolved = resolveForeground(
            identity = foregroundWindowTracker.current(),
            applicationWindowId = applicationWindow?.id,
            applicationWindowPackageName = applicationWindow?.root?.packageName?.toString(),
        )
        val exposed = exposedWindows(currentWindows)
        val blockingOverlay = hasBlockingOverlay(exposed, applicationWindow?.id)
        val imeVisible = currentWindows.any { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD }
        val revisionAfter = rev.get()
        return FreshClickCurrent(
                // 状态读取期间发生任何 a11y 事件，也必须 fail closed。
                revision = if (revisionBefore == revisionAfter) revisionAfter else Long.MIN_VALUE,
                foregroundKnown = resolved.known,
                windowId = if (resolved.known) applicationWindow?.id ?: -1 else -1,
                packageName = resolved.packageName,
                blockingOverlay = blockingOverlay,
                imeVisible = imeVisible,
        )
    }

    private fun hasBlockingOverlay(
        exposed: List<AccessibilityWindowInfo>,
        primaryId: Int? = applicationWindow()?.id,
    ): Boolean {
        val metrics = resources.displayMetrics
        val w = metrics.widthPixels
        val h = metrics.heightPixels
        if (w <= 0 || h <= 0) return true
        val titleBand = Rect((w * 0.25).toInt(), (h * 0.04).toInt(), (w * 0.75).toInt(), (h * 0.22).toInt())
        val probeBand = Rect((w * 0.24).toInt(), (h * 0.84).toInt(), (w * 0.76).toInt(), (h * 0.94).toInt())
        return exposed.any { window ->
            // 状态栏/导航栏是常驻 TYPE_SYSTEM 窗口：状态栏满宽、y 落在 0..~系统栏高度，
            // 与 titleBand（y 4%~22%）必然几何相交——不排除会让本判定在任意前台 App 上恒为
            // true（2026-07-23 真机实锤，本设备 1260x2800，状态栏 bounds=(0,0)-(1260,133)
            // 与 titleBand=(315,112)-(945,616) 相交）。TYPE_SYSTEM 从不代表遮挡内容的对话框。
            if (window.id == primaryId ||
                window.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD ||
                window.type == AccessibilityWindowInfo.TYPE_SYSTEM
            ) return@any false
            val bounds = Rect().also(window::getBoundsInScreen)
            bounds.width() > 0 && bounds.height() > 0 &&
                (Rect.intersects(bounds, titleBand) || Rect.intersects(bounds, probeBand))
        }
    }

    private fun systemBottomInset(): Int {
        val metrics = resources.displayMetrics
        val w = metrics.widthPixels
        val h = metrics.heightPixels
        return windows.asSequence()
            .filter { it.type != AccessibilityWindowInfo.TYPE_APPLICATION && it.type != AccessibilityWindowInfo.TYPE_INPUT_METHOD }
            .map { Rect().also(it::getBoundsInScreen) }
            .filter { it.bottom == h && it.width() >= (w * 0.8).toInt() }
            .map { h - it.top }
            .filter { it in 0..(h * 0.20).toInt() }
            .maxOrNull() ?: 0
    }

    private fun conf2(c: Float): Double = Math.round(c * 100.0) / 100.0

    fun find(text: String?, role: String?, desc: String?): JSONArray {
        val snap = snapshot("interactive", maxElements = 400)
        val out = JSONArray()
        val arr = snap.getJSONArray("elements")
        for (i in 0 until arr.length()) {
            val e = arr.getJSONObject(i)
            val et = e.getString("text")
            // OCR 来源文本额外做归一匹配（全角/大小写/0O 形近，S3 实锤），a11y 文本保持精确 contains
            val ocrSourced = e.optString("source") != "a11y"
            val tOk = text.isNullOrEmpty() || et.contains(text) || e.getString("desc").contains(text) ||
                (ocrSourced && OcrEngine.norm(et).contains(OcrEngine.norm(text)))
            val rOk = role.isNullOrEmpty() || e.getString("role") == role
            val dOk = desc.isNullOrEmpty() || e.getString("desc").contains(desc)
            if (tOk && rOk && dOk) out.put(e)
        }
        return out
    }

    /** 供安全层做白名单上下文判断。 */
    fun visibleTexts(withOcr: Boolean = false): List<String> {
        val out = ArrayList<String>()
        fun visit(node: AccessibilityNodeInfo, depth: Int) {
            if (depth > 60 || out.size > 300) return
            node.text?.toString()?.takeIf { it.isNotEmpty() }?.let { out.add(it) }
            node.contentDescription?.toString()?.takeIf { it.isNotEmpty() }?.let { out.add(it) }
            for (i in 0 until node.childCount) node.getChild(i)?.let { visit(it, depth + 1) }
        }
        exposedWindows()
            .forEach { w -> w.root?.let { visit(it, 0) } }
        if (withOcr && !ConfirmOverlay.isAwaitingDecision) {
            runCatching { ocrScreen() }.getOrNull()?.lines?.forEach { out.add(it.text) }
        }
        return out
    }

    /** 屏上全部文本：a11y 为主，前台树稀疏时并入 OCR（危险词上下文 / wait_for 文本条件的感知面）。 */
    fun screenTexts(): List<String> = visibleTexts(withOcr = fgSparse())

    /** 活动应用窗口 id（type=APPLICATION 且 active/focused；vivo 灵动岛等悬浮窗不算前台归属）。 */
    private fun appWindowId(): Int = applicationWindow()?.id ?: -1

    /** 活动应用窗口的可读节点是否稀疏（达到阈值即提前返回，代价仅一次浅遍历）。 */
    private fun fgSparse(): Boolean {
        val winId = appWindowId()
        val root = windows.firstOrNull { it.id == winId }?.root ?: rootInActiveWindow ?: return true
        var n = 0
        fun visit(node: AccessibilityNodeInfo, depth: Int) {
            if (depth > 60 || n >= FUSE_FG_THRESHOLD) return
            val signal = node.isClickable || node.isEditable || node.isScrollable ||
                !node.text.isNullOrEmpty() || !node.contentDescription.isNullOrEmpty()
            if (signal && node.isVisibleToUser) n += 1
            for (i in 0 until node.childCount) {
                if (n >= FUSE_FG_THRESHOLD) return
                node.getChild(i)?.let { visit(it, depth + 1) }
            }
        }
        visit(root, 0)
        return n < FUSE_FG_THRESHOLD
    }

    // ---------- ref 解析与动作 ----------

    data class Target(
        val node: AccessibilityNodeInfo?, // null = OCR 元素（坐标手势通道）
        val text: String,
        val desc: String,
        val bounds: Rect,
        val source: String = "a11y",
    )

    /** ref → 目标；节点刷新失败/指纹不符 → E_STALE_REF（点击前二次校验，M0 误触对策）。 */
    fun resolve(ref: String): Target {
        rejectWhileConfirming()
        val e = refs[ref] ?: throw GatewayError(
            ErrorCode.E_NOT_FOUND, "ref $ref 不存在（可能来自旧 snapshot）",
            channel = "a11y", fallback = "先 ui_snapshot 再按新 ref 操作",
        )
        if (e.node == null) return resolveOcr(ref, e)
        if (!e.node.refresh()) throw GatewayError(
            ErrorCode.E_STALE_REF, "ref $ref 的节点已失效（页面已变化）",
            channel = "a11y", fallback = "先 ui_snapshot 再按新 ref 操作",
        )
        val nowText = e.node.text?.toString().orEmpty()
        val nowDesc = e.node.contentDescription?.toString().orEmpty()
        if (e.text.isNotEmpty() && nowText != e.text) throw GatewayError(
            ErrorCode.E_STALE_REF,
            "ref $ref 文本已从「${e.text.take(30)}」变为「${nowText.take(30)}」，拒绝操作",
            channel = "a11y", fallback = "先 ui_snapshot 确认目标再操作",
        )
        val b = Rect().also { e.node.getBoundsInScreen(it) }
        return Target(e.node, nowText.ifEmpty { e.label }, nowDesc, b, e.source)
    }

    /**
     * OCR ref 的点击前二次校验（spec §5.4：文本/位置与缓存一致才出手）：
     * 微信类 app 内容变化不发事件，revision 不可作过期依据 → 每次操作前对目标邻域重截重识，
     * 文本仍在才返回目标，bbox 随最新命中微调（容忍轻微滚动/重排）。
     */
    private fun resolveOcr(ref: String, e: RefEntry): Target {
        val m = e.bounds.height().coerceAtLeast(24)
        val full = captureBitmapRetry()
        // 裁剪区给足上下文（最小 620×220）：过小的图 ML Kit 识别质量塌方（实锤：372×147 零行）
        val wantW = (e.bounds.width() + m * 6).coerceAtLeast(620)
        val wantH = (e.bounds.height() + m * 3).coerceAtLeast(220)
        val ccx = e.bounds.centerX()
        val ccy = e.bounds.centerY()
        val crop = Rect(
            (ccx - wantW / 2).coerceAtLeast(0),
            (ccy - wantH / 2).coerceAtLeast(0),
            (ccx + wantW / 2).coerceAtMost(full.width),
            (ccy + wantH / 2).coerceAtMost(full.height),
        )
        if (crop.width() <= 0 || crop.height() <= 0) throw GatewayError(
            ErrorCode.E_STALE_REF, "OCR ref $ref 的区域已出屏", channel = "vision",
            fallback = "ui_snapshot 重新定位",
        )
        val piece = Bitmap.createBitmap(full, crop.left, crop.top, crop.width(), crop.height())
        val want = OcrEngine.norm(e.label)
        // 动作前二次识别不得接收零置信结果；低于通用区域读回阈值直接 stale。
        val lines = OcrEngine.recognize(piece, MIN_ACTION_OCR_CONFIDENCE)
        // 匹配容忍两级：① 归一 contains（任意位置）；② 位置稳定（中心漂移 ≤1.2 行高）+ 字符袋
        // 相似度 ≥0.4——CJK 形近字抖动实锤（索↔素、图标误识 Q 时有时无），纯 contains 会误报 STALE
        val cx0 = e.bounds.centerX() - crop.left
        val cy0 = e.bounds.centerY() - crop.top
        val tol = 1.2f * e.bounds.height()
        val hit = lines
            .map { l ->
                val got = OcrEngine.norm(l.text)
                val contains = got.contains(want) || (want.contains(got) && got.length >= 2)
                val drift = kotlin.math.hypot(
                    (l.bounds.centerX() - cx0).toDouble(), (l.bounds.centerY() - cy0).toDouble(),
                ).toFloat()
                val s = charBagSim(want, got)
                Triple(l, if (contains) 2f + l.conf else s + l.conf * 0.1f, contains || (drift <= tol && s >= 0.4f))
            }
            .filter { it.third }
            .maxByOrNull { it.second }?.first
            ?: throw GatewayError(
                ErrorCode.E_STALE_REF,
                "OCR 目标「${e.label.take(30)}」二次校验未命中（页面可能已变化；邻域实读:「${
                    lines.joinToString(" / ") { it.text }.take(60)
                }」）",
                channel = "vision", fallback = "ui_snapshot 重新定位后再操作",
            )
        val b = Rect(hit.bounds).apply { offset(crop.left, crop.top) }
        refs[ref] = e.copy(bounds = b)
        return Target(null, e.label, e.desc, b, "ocr")
    }

    /** 字符袋相似度（0~1）：多重集交集 ×2 / 总长。短文本 OCR 抖动下比编辑距离更稳。 */
    private fun charBagSim(a: String, b: String): Float {
        if (a.isEmpty() || b.isEmpty()) return 0f
        val bag = HashMap<Char, Int>()
        for (c in a) bag[c] = (bag[c] ?: 0) + 1
        var common = 0
        for (c in b) {
            val n = bag[c] ?: 0
            if (n > 0) { bag[c] = n - 1; common++ }
        }
        return 2f * common / (a.length + b.length)
    }

    fun perform(target: Target, action: String, params: JSONObject): JSONObject {
        rejectWhileConfirming()
        val node = target.node ?: return performGesture(target, action, params)
        val ok = when (action) {
            "click" -> clickNode(node, target.bounds)
            "long_click" -> node.performAction(AccessibilityNodeInfo.ACTION_LONG_CLICK)
            "focus" -> node.performAction(AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS)
            "scroll" -> {
                val dir = params.optString("direction", "forward")
                val act = if (dir == "backward") AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD
                else AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
                scrollable(node).performAction(act)
            }
            "set_text" -> {
                val args = Bundle().apply {
                    putCharSequence(
                        AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                        params.optString("text"),
                    )
                }
                node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
            }
            "dismiss" -> node.performAction(AccessibilityNodeInfo.ACTION_DISMISS)
            else -> throw GatewayError(ErrorCode.E_INVALID_ARG, "未知 action: $action")
        }
        if (!ok) throw GatewayError(
            ErrorCode.E_VERIFY_FAIL, "动作 $action 执行返回 false（节点可能不响应该动作）",
            channel = "a11y", retryable = true,
            fallback = "换目标 ref（如可点击父节点）或 ui_snapshot 重看",
        )
        return JSONObject().put("done", true).put("revision_after", revision)
    }

    /** OCR 元素动作：无 a11y 节点，坐标手势通道（spec §5.4：ocr 来源 ref 用 bounds 中心 dispatchGesture）。 */
    private fun performGesture(target: Target, action: String, params: JSONObject): JSONObject {
        val ok = when (action) {
            "click" -> tapGesture(target.bounds.exactCenterX(), target.bounds.exactCenterY())
            "long_click" -> tapGesture(target.bounds.exactCenterX(), target.bounds.exactCenterY(), 700L)
            "scroll" -> gestureScroll(params.optString("direction", "forward") != "backward")
            else -> throw GatewayError(
                ErrorCode.E_INVALID_ARG, "OCR 元素仅支持 click/long_click/scroll（无 a11y 节点通道）",
                fallback = "输入用 type_text(ref=本元素)；其余动作先 ui_snapshot 找 a11y 元素",
            )
        }
        if (!ok) throw GatewayError(
            ErrorCode.E_VERIFY_FAIL, "坐标手势 $action 派发失败", channel = "vision", retryable = true,
            fallback = "重试一次；仍失败 screen_capture(reason=layout_changed) 复核",
        )
        return JSONObject().put("done", true).put("revision_after", revision)
    }

    /**
     * 点击：
     * - 开关/勾选类（isCheckable，如 vivo 系统设置的蓝牙/WiFi Switch）用**坐标手势**点 bounds 中心——
     *   这类节点对 ACTION_CLICK 返回 true 却不 toggle（vivo 真机实锤：a11y click 无效、input tap 有效），
     *   dispatchGesture 模拟真实触摸方可切换。
     * - 其余节点自身不可点时向上找最近可点祖先（微信列表条目常见结构）→ ACTION_CLICK。
     */
    private fun clickNode(node: AccessibilityNodeInfo, bounds: Rect): Boolean {
        if (node.isCheckable) {
            // 开关滑块通常在行右侧；点整行中心会落在文字标签上（vivo 实锤：中心无效、滑块坐标有效）
            // → 宽行（width > 2*height）点右侧滑块估计位，近方形（滑块本体）点中心。
            val b = bounds
            val x = if (b.width() > b.height() * 2) b.right - b.height() / 2f else b.exactCenterX()
            return tapGesture(x, b.exactCenterY())
        }
        var n: AccessibilityNodeInfo? = node
        var hops = 0
        while (n != null && hops < 5) {
            if (n.isClickable) return n.performAction(AccessibilityNodeInfo.ACTION_CLICK)
            n = n.parent; hops++
        }
        return node.performAction(AccessibilityNodeInfo.ACTION_CLICK)
    }

    /** 坐标手势点击（dispatchGesture）：ACTION_CLICK 对某些 ROM 定制控件无效时的兜底。同步等结果。 */
    private fun tapGesture(
        cx: Float,
        cy: Float,
        durationMs: Long = 60L,
        preDispatch: () -> Unit = {},
    ): Boolean {
        val path = Path().apply { moveTo(cx, cy) }
        return dispatchStroke(path, durationMs, preDispatch)
    }

    /** 手势滚动：OCR 页（无 a11y 列表节点）的翻页通道。活动应用窗口内竖直滑约 1/4 屏。 */
    fun gestureScroll(forward: Boolean): Boolean {
        val winId = appWindowId()
        val b = windows.firstOrNull { it.id == winId }
            ?.let { w -> Rect().also { w.getBoundsInScreen(it) } }
            ?: Rect(0, 0, resources.displayMetrics.widthPixels, resources.displayMetrics.heightPixels)
        val cx = b.exactCenterX()
        val y1 = b.top + b.height() * (if (forward) 0.62f else 0.38f)
        val y2 = b.top + b.height() * (if (forward) 0.38f else 0.62f)
        val path = Path().apply { moveTo(cx, y1); lineTo(cx, y2) }
        return dispatchStroke(path, 400L)
    }

    /**
     * 派发单笔手势并同步等结果。成功后失效 OCR 缓存——事件静默 app（微信类）的页面变化
     * 不产生 revision 增量，不失效会读到旧屏。
     */
    private fun dispatchStroke(path: Path, durationMs: Long, preDispatch: () -> Unit = {}): Boolean {
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0L, durationMs))
            .build()
        val done = CompletableFuture<Boolean>()
        preDispatch()
        val dispatched = dispatchGesture(
            gesture,
            object : GestureResultCallback() {
                override fun onCompleted(d: GestureDescription?) { done.complete(true) }
                override fun onCancelled(d: GestureDescription?) { done.complete(false) }
            },
            null,
        )
        if (!dispatched) return false
        val ok = runCatching { done.get(2, TimeUnit.SECONDS) }.getOrDefault(false)
        if (ok) ocrCache.invalidate()
        return ok
    }

    private fun scrollable(node: AccessibilityNodeInfo): AccessibilityNodeInfo {
        var n: AccessibilityNodeInfo? = node
        var hops = 0
        while (n != null && hops < 8) {
            if (n.isScrollable) return n
            n = n.parent; hops++
        }
        return node
    }

    fun focusedEditable(): AccessibilityNodeInfo? = findFocus(AccessibilityNodeInfo.FOCUS_INPUT)

    /**
     * 输入法窗口是否真的弹起（纯窗口判定，不截图不 OCR）。
     * IME 单命名空间降级链下没有"焦点可编辑节点"这条活性证据，键盘确实在屏上
     * 是仅剩的"输入会话是活的而非残留 InputConnection"证据。
     */
    internal fun imeWindowVisible(): Boolean =
        windows.any { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD }

    /**
     * 仅供 debug 验收 adapter 使用的受约束聚焦探针。完整 proof 已由动作 adapter
     * 用第二份 fresh OCR 重算；这里在 gesture 前再核前台、窗口遮挡、标题带与固定安全区。
     */
    internal fun performValidatedFocusProbe(
        screenWidth: Int,
        screenHeight: Int,
        region: Rect,
        x: Int,
        y: Int,
        snapshotRevision: Long,
        captureRevision: Long,
        expectedWindowId: Int,
        expectedPackage: String,
        titleBounds: Rect,
        titleConfidence: Double,
        visionGeneration: Long,
        proofSafe: Boolean,
    ): Boolean {
        rejectWhileConfirming()
        if (captureRevision != snapshotRevision) throw GatewayError(
            ErrorCode.E_STALE_REF,
            "输入框聚焦 proof 未绑定 capture revision",
            channel = "a11y",
            retryable = false,
        )
        requireFreshActionState(captureRevision, expectedWindowId, expectedPackage, imeMustBeHidden = true)
        val metrics = resources.displayMetrics
        // inset 在此独立重算（不取调用方传入值），与宏侧共用 [p0FocusProbeRegion] 同一几何算法：
        // 算法一致保证两侧结论可比，输入独立保证这道纵深校验不退化成"信调用方"。
        val expectedBox = p0FocusProbeRegion(screenWidth, screenHeight, systemBottomInset())
        val expectedRegion = Rect(expectedBox[0], expectedBox[1], expectedBox[2], expectedBox[3])
        val geometryMatches = screenWidth == metrics.widthPixels &&
            screenHeight == metrics.heightPixels && region == expectedRegion &&
            x == expectedRegion.centerX() && y == expectedRegion.centerY()
        val titleInBand = titleBounds.left >= 0 && titleBounds.top >= 0 &&
            titleBounds.right <= screenWidth && titleBounds.bottom <= screenHeight &&
            titleBounds.width() > 0 && titleBounds.height() > 0 &&
            titleBounds.centerY() in (screenHeight * 0.02).toInt()..(screenHeight * 0.12).toInt() &&
            titleBounds.centerX() in (screenWidth * 0.30).toInt()..(screenWidth * 0.70).toInt()
        // 这里的标题只用于"证明身处文件传输助手会话"，从不是点击目标（真正落点是上面按屏幕
        // 几何独立算出并已由 geometryMatches 复核的 expectedRegion），故与宏侧同名校验
        // P0FocusProbeValidator 一样使用识别级门槛。2026-07-24 已就宏侧改动取得项目所有者同意，
        // 但这处 Android 侧的纵深防御镜像当时漏改，导致宏侧放宽实际不生效——真机实测标题
        // 置信度 0.59，宏侧放行后仍在此被 0.65 挡回（2026-07-25 实锤）。属 knowledge #15 同类
        // 的"改动遗漏"，非新的设计取舍。
        val proofValid = titleConfidence.isFinite() &&
            titleConfidence >= MIN_RECOGNITION_OCR_CONFIDENCE && visionGeneration > 0 && proofSafe && titleInBand &&
            !hasBlockingOverlay(exposedWindows())
        if (!geometryMatches || !proofValid || revision != snapshotRevision) throw GatewayError(
            if (revision != snapshotRevision) ErrorCode.E_STALE_REF else ErrorCode.E_BLOCKED,
            if (revision != snapshotRevision) "输入框聚焦探针的快照 revision 已过期"
            else "输入框聚焦探针的屏幕或候选区校验失败",
            channel = "a11y",
            retryable = false,
        )
        // 若真实输入节点已出现，就不再发手势；状态机随后仍会校验 IME 与 session fingerprint。
        if (focusedEditable()?.let { it.refresh() } == true) return true
        return tapGesture(x.toFloat(), y.toFloat()) {
            requireFreshActionState(captureRevision, expectedWindowId, expectedPackage, imeMustBeHidden = true)
        }
    }

    fun globalKey(key: String): Boolean = when (key) {
        "back" -> performGlobalAction(GLOBAL_ACTION_BACK)
        "home" -> performGlobalAction(GLOBAL_ACTION_HOME)
        "recents" -> performGlobalAction(GLOBAL_ACTION_RECENTS)
        "notifications" -> performGlobalAction(GLOBAL_ACTION_NOTIFICATIONS)
        else -> throw GatewayError(ErrorCode.E_INVALID_ARG, "未知按键: $key（enter/del 走 IME 通道）")
    }

    // ---------- wait_for（事件驱动的轮询实现，M1a 版；不占大脑轮次） ----------

    fun waitFor(condition: String, args: JSONObject, timeoutMs: Long): JSONObject {
        val start = SystemClock.elapsedRealtime()
        var lastRev = revision
        var quietSince = start
        while (SystemClock.elapsedRealtime() - start < timeoutMs) {
            val met = when (condition) {
                "text_appears" -> textOnScreen(args.optString("text"))
                "text_gone" -> !textOnScreen(args.optString("text"))
                "app_foreground" -> foregroundPackage() == args.optString("package")
                "keyboard_shown" -> keyboardState().getBoolean("visible")
                "keyboard_hidden" -> !keyboardState().getBoolean("visible")
                "idle" -> {
                    val now = SystemClock.elapsedRealtime()
                    if (revision != lastRev) { lastRev = revision; quietSince = now }
                    now - quietSince >= args.optLong("quiet_ms", 800)
                }
                else -> throw GatewayError(ErrorCode.E_INVALID_ARG, "未知条件: $condition")
            }
            if (met) return JSONObject()
                .put("met", true)
                .put("elapsed_ms", SystemClock.elapsedRealtime() - start)
                .put("revision", revision)
            SystemClock.sleep(250)
        }
        throw GatewayError(
            ErrorCode.E_TIMEOUT, "wait_for($condition) 超时 ${timeoutMs}ms",
            channel = "a11y", retryable = false,
            fallback = "ui_snapshot 看当前实况再决策",
        )
    }

    /** 文本是否在屏（a11y + 稀疏时 OCR）；OCR 感知面额外做归一匹配。 */
    private fun textOnScreen(t: String): Boolean {
        if (t.isEmpty()) return false
        val texts = screenTexts()
        if (texts.any { it.contains(t) }) return true
        val want = OcrEngine.norm(t)
        return want.isNotEmpty() && texts.any { OcrEngine.norm(it).contains(want) }
    }

    // ---------- 截图（L6 受控兜底 + L5 OCR 的采集端） ----------

    /** 整屏截图 → 软件位图（物理像素）。节流由系统层软执行（S4：连发拖延 ~750ms 非硬失败）。 */
    fun captureBitmap(): Bitmap {
        val fut = CompletableFuture<Bitmap>()
        takeScreenshot(
            Display.DEFAULT_DISPLAY, shotExecutor,
            object : TakeScreenshotCallback {
                override fun onSuccess(result: ScreenshotResult) {
                    val hw = result.hardwareBuffer
                    val bmp = Bitmap.wrapHardwareBuffer(hw, result.colorSpace)
                        ?.copy(Bitmap.Config.ARGB_8888, false)
                    hw.close()
                    if (bmp == null) fut.completeExceptionally(
                        GatewayError(ErrorCode.E_INTERNAL, "截图 buffer 转换失败", channel = "a11y")
                    ) else fut.complete(bmp)
                }

                override fun onFailure(errorCode: Int) {
                    val e = if (errorCode == ERROR_TAKE_SCREENSHOT_INTERVAL_TIME_SHORT)
                        GatewayError(
                            ErrorCode.E_RATE_LIMITED, "截图节流中",
                            channel = "a11y", retryable = true,
                            fallback = "等 1–2s 再试（冷却窗口以 Spike S4 实测为准）",
                        )
                    else GatewayError(ErrorCode.E_INTERNAL, "takeScreenshot 失败 code=$errorCode", channel = "a11y")
                    fut.completeExceptionally(e)
                }
            },
        )
        return try {
            fut.get(6, TimeUnit.SECONDS)
        } catch (e: java.util.concurrent.ExecutionException) {
            throw e.cause as? GatewayError
                ?: GatewayError(ErrorCode.E_INTERNAL, e.cause?.message ?: "截图失败", channel = "a11y")
        } catch (e: java.util.concurrent.TimeoutException) {
            throw GatewayError(ErrorCode.E_TIMEOUT, "截图 6s 无回调", channel = "a11y")
        }
    }

    /**
     * 内部视觉通道用截图（带节流吸收）：S4 记录连发是软拖延，但实测也会硬报
     * ERROR_INTERVAL_TIME_SHORT → 等冷却窗（~800ms）重试一次再抛。
     * screen_capture 工具仍用裸 captureBitmap，让大脑看到 E_RATE_LIMITED 语义。
     */
    private fun captureBitmapRetry(): Bitmap = try {
        captureBitmap()
    } catch (e: GatewayError) {
        if (e.code != ErrorCode.E_RATE_LIMITED) throw e
        SystemClock.sleep(900)
        captureBitmap()
    }

    // ---------- L5 OCR：整屏识别缓存与区域直读 ----------

    private data class OcrShot(
        val revision: Long,
        val at: Long,
        val generation: Long,
        val lines: List<OcrEngine.OcrLine>,
    )

    private val ocrCache = FreshVisionCache<OcrShot>()

    /**
     * 整屏 OCR，按 revision 缓存 + 2s TTL（spec §9：页面不变不重跑）。
     * TTL 的必要性：微信类 app 不发内容事件、revision 长期不动，纯 revision 缓存会把
     * 单次漏识（深色模式灰字临界抖动实锤）永久钉死；短 TTL 给抖动翻盘机会。
     */
    @Synchronized
    private fun ocrScreen(): OcrShot {
        val r = revision
        return ocrCache.getOrLoad(
            forceFresh = forceFreshOcrOnce,
            reusable = { it.revision == r && SystemClock.elapsedRealtime() - it.at < 2_000 },
            loader = {
                // 键盘弹出时只识键盘上方：按键/候选词不是页面内容，顺带省识别时间
                val imeTop = windows.firstOrNull { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD }
                    ?.let { w -> Rect().also { w.getBoundsInScreen(it) }.top } ?: Int.MAX_VALUE
                val capture = freshVisionSession.captureForOcr()
                if (capture.revision != r) throw GatewayError(
                    ErrorCode.E_STALE_REF,
                    "OCR 截图与请求 revision 不一致",
                    channel = "vision",
                    retryable = true,
                )
                val full = capture.payload
                val page = if (imeTop in 1 until full.height)
                    Bitmap.createBitmap(full, 0, 0, full.width, imeTop) else full
                val lines = OcrEngine.recognize(page)
                OcrShot(capture.revision, SystemClock.elapsedRealtime(), capture.generation, lines)
            },
        )
    }

    /** 已有位图时直接裁剪识别，不再重复截图（读回重试时省掉一次截图与节流风险）。 */
    private fun ocrReadRegionOf(full: Bitmap, r: Rect): String? {
        if (r.width() <= 0 || r.height() <= 0) return null
        val clipped = Rect(
            r.left.coerceAtLeast(0), r.top.coerceAtLeast(0),
            r.right.coerceAtMost(full.width), r.bottom.coerceAtMost(full.height),
        )
        if (clipped.width() <= 0 || clipped.height() <= 0) return null
        val piece = Bitmap.createBitmap(full, clipped.left, clipped.top, clipped.width(), clipped.height())
        val lines = OcrEngine.recognize(piece, 0.25f)
        if (lines.isEmpty()) return null
        return lines.sortedWith(compareBy({ it.bounds.top }, { it.bounds.left }))
            .joinToString(" ") { it.text }
    }

    /** 任意区域 OCR 直读（type_text 树空读回验证用）：返回区域邻域内按位置拼接的文本，无文字 → null。 */
    fun ocrReadRegion(bounds: Rect): String? {
        val full = captureBitmapRetry()
        val m = bounds.height().coerceAtLeast(16)
        val r = Rect(
            (bounds.left - m).coerceAtLeast(0),
            (bounds.top - m).coerceAtLeast(0),
            (bounds.right + m).coerceAtMost(full.width),
            (bounds.bottom + m).coerceAtMost(full.height),
        )
        if (r.width() <= 0 || r.height() <= 0) return null
        val piece = Bitmap.createBitmap(full, r.left, r.top, r.width(), r.height())
        val lines = OcrEngine.recognize(piece, 0.25f)
        if (lines.isEmpty()) return null
        return lines.sortedWith(compareBy({ it.bounds.top }, { it.bounds.left }))
            .joinToString(" ") { it.text }
    }

    /** 读回结果连同实际使用的几何一起返回——2026-07-26 排查实测：字明明在框里却读回 null，
     *  没有几何就只能靠猜。region/screen 只是尺寸数字，不含任何屏幕内容。 */
    internal data class InputBarReadback(
        val text: String?,
        val region: Rect,
        val screenWidth: Int,
        val screenHeight: Int,
        val metricsWidth: Int,
        val metricsHeight: Int,
        val bottomInset: Int,
        /** 区域是怎么来的：`focused_bounds`（已知焦点几何）或 `bottom_band`（写死的兜底带）。 */
        val regionSource: String = "bottom_band",
    )

    /**
     * IME 单命名空间降级链的读回区域：a11y 拿不到焦点节点时没有 bounds 可用，改用锚定
     * 系统底部 inset 的输入栏带。这是"打进去的字确实落到框里"的唯一剩余机械证据，不能省。
     *
     * **几何以截图位图自身尺寸为准**，不用 `displayMetrics`：两者在本机不一定相等，
     * 而裁剪发生在位图坐标系里，用错坐标系会把整条输入栏裁掉。
     * 读回带比盲点带更高（[INPUT_BAR_READBACK_HEIGHT_PX]）：盲点只需要一个可点的中心，
     * 读回要覆盖整条输入栏，包括基线落在 inset 之下的文字。
     *
     * [preferredBounds] 是**已知的焦点输入框几何**：有它就按它裁，那条写死的底部带只是兜底。
     * 底部带隐含了"竖屏 + 输入栏贴底 + 左右各留 6%"三条假设，全是这台机器上微信会话页的样子；
     * 换 App 或换姿势就不成立，所以但凡有真几何就别用它。
     */
    internal fun ocrReadInputBarRegion(preferredBounds: Rect? = null): InputBarReadback {
        val metrics = resources.displayMetrics
        val inset = systemBottomInset()
        val full = captureBitmapRetry()
        val preferred = preferredBounds?.let { wanted ->
            Rect(
                wanted.left.coerceIn(0, full.width - 1),
                wanted.top.coerceIn(0, full.height - 1),
                wanted.right.coerceIn(1, full.width),
                wanted.bottom.coerceIn(1, full.height),
            ).takeIf { it.width() > 0 && it.height() > 0 }
        }
        val bottom = full.height
        val top = (bottom - INPUT_BAR_READBACK_HEIGHT_PX).coerceAtLeast(0)
        val region = preferred ?: Rect(
            (full.width * 0.06).toInt(),
            top,
            (full.width * 0.94).toInt(),
            bottom,
        )
        val text = runCatching { ocrReadRegionOf(full, region) }.getOrNull()
        return InputBarReadback(
            text = text,
            region = region,
            screenWidth = full.width,
            screenHeight = full.height,
            metricsWidth = metrics.widthPixels,
            metricsHeight = metrics.heightPixels,
            bottomInset = inset,
            regionSource = if (preferred != null) "focused_bounds" else "bottom_band",
        )
    }

    fun screenshotPngBase64(region: Rect?): JSONObject {
        val full = captureBitmap()
        val cropped = if (region != null) {
            val r = Rect(
                region.left.coerceIn(0, full.width - 1),
                region.top.coerceIn(0, full.height - 1),
                region.right.coerceIn(1, full.width),
                region.bottom.coerceIn(1, full.height),
            )
            Bitmap.createBitmap(full, r.left, r.top, r.width(), r.height())
        } else full

        val bos = ByteArrayOutputStream()
        cropped.compress(Bitmap.CompressFormat.PNG, 90, bos)
        return JSONObject()
            .put("mime", "image/png")
            .put("base64", Base64.encodeToString(bos.toByteArray(), Base64.NO_WRAP))
            .put("width", cropped.width)
            .put("height", cropped.height)
            .put("offset", JSONArray(listOf(region?.left ?: 0, region?.top ?: 0)))
            .put("scale", 1.0) // 网关坐标主权：始终物理像素，无缩放
            .put("revision", revision)
    }

    private fun roleOf(n: AccessibilityNodeInfo): String {
        val cls = n.className?.toString().orEmpty()
        return when {
            n.isEditable -> "input"
            n.isCheckable -> "switch"
            n.isScrollable -> "list"
            n.isClickable && cls.contains("Image") -> "icon_button"
            n.isClickable -> "button"
            cls.contains("TextView") -> "text"
            else -> cls.substringAfterLast('.').ifEmpty { "node" }
        }
    }

    private fun flagsOf(n: AccessibilityNodeInfo): String = buildString {
        if (n.isClickable) append("C")
        if (n.isLongClickable) append("L")
        if (n.isEditable) append("E")
        if (n.isScrollable) append("S")
        if (n.isCheckable) append("K")
        if (n.isChecked) append("k")
        if (n.isFocused) append("F")
        if (!n.isEnabled) append("x")
    }
}

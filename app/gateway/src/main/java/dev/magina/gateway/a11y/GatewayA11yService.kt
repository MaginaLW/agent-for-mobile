package dev.magina.gateway.a11y

import android.accessibilityservice.AccessibilityService
import android.graphics.Bitmap
import android.graphics.Rect
import android.os.Bundle
import android.os.SystemClock
import android.util.Log
import android.view.Display
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import dev.magina.gateway.core.ErrorCode
import dev.magina.gateway.core.GatewayError
import dev.magina.gateway.ime.ImeBridge
import dev.magina.gateway.ocr.OcrEngine
import dev.magina.gateway.overlay.ConfirmOverlay
import dev.magina.gateway.vision.appWindowElementCap
import dev.magina.gateway.vision.sparseWindowIds
import org.json.JSONArray
import org.json.JSONObject
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
        val windowId: Int = -1,
        val pane: String = "full",
    )

    private val refs = SnapshotRefRegistry<RefEntry>()
    @Volatile private var lastSnapshotRev = -1L
    private val shotExecutor = Executors.newSingleThreadExecutor()
    private val freshVisionSession = FreshVisionSession(
        capture = ::captureBitmapRetry,
        currentRevision = { revision },
    )
    private val ocrCoordinator = A11yOcrCoordinator(
        freshVisionSession = freshVisionSession,
        captureRawBitmap = ::captureBitmap,
        captureRetriedBitmap = ::captureBitmapRetry,
        currentRevision = { revision },
        currentImeTop = {
            windows.firstOrNull { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD }
                ?.let { w -> Rect().also { w.getBoundsInScreen(it) }.top } ?: Int.MAX_VALUE
        },
        currentBottomInset = ::systemBottomInset,
        displayMetrics = { resources.displayMetrics },
    )
    private val gestureController = A11yGestureController(
        service = this,
        onGestureCompleted = { ocrCoordinator.invalidateCache() },
    )

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

    /**
     * 前台 activity 全类名；判不出来时为空串。
     *
     * **只可用作"落地信号"，不可用作跨时间相等判据**——自举来的身份天生没有 activity，
     * 语义意图 spec §2.3 正是因此把 `activityName` 从跨时间比较里摘掉的。
     * 这里的用法不同：等一个**正向**的可接受落地页出现（见 `IntentTools` 的分享落地白名单），
     * 等不到就 fail-closed，不涉及"两个时刻的 activity 必须相等"。
     */
    fun foregroundActivity(): String = currentForeground().activityName.orEmpty()

    fun keyboardState(): JSONObject {
        val ime = windows.firstOrNull { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD }
        val b = Rect()
        ime?.getBoundsInScreen(b)
        return JSONObject()
            .put("visible", ime != null)
            .put("height", if (ime != null) b.height() else 0)
    }

    fun ctx(caps: List<String>): JSONObject {
        // 同一次已接受事件与拓扑判定共用当前稳定窗口，避免 ctx 拼出跨窗口身份。
        val currentWindows = settledWindows()
        val appSlices = appWindowSlices(currentWindows)
        val topology = classifyWindowTopology(appSlices)
        val foreground = resolveForegroundOf(currentWindows, appSlices, topology)
        return JSONObject()
            .put("app", foreground.packageName)
            .put("activity", foreground.activityName)
            .put("foreground_known", foreground.known)
            // 前台身份判不出来时，让失败的那次调用自己带上原因，不必事后另起一次诊断。
            .put("foreground_reason", foreground.reason.name.lowercase())
            // known=true 还不够：自举来的身份没有 Activity，安全门要据此在确认卡上说明白。
            .put("foreground_identity_source", A11yDiagnosticsFormatter.identitySourceName(foreground))
            .put("window_topology", topology.wireName)
            .put("revision", revision)
            .put("keyboard", keyboardState())
            .put("screen", "on") // 服务在收事件即亮屏；灭屏感知 M1b 接 PowerManager
            .put("caps", JSONArray(caps))
    }

    /**
     * 冷启动仅从活动应用窗口取 package 级身份；overlay/IME root 不参与，root 为空则保持未知。
     */
    private fun currentForeground(): ResolvedForeground = resolveForegroundOf(settledWindows())

    private fun appWindowSlices(
        currentWindows: List<AccessibilityWindowInfo> = windows,
    ): List<AppWindowSlice> = currentWindows.mapNotNull { w ->
        if (w.type != AccessibilityWindowInfo.TYPE_APPLICATION) return@mapNotNull null
        val b = Rect().also(w::getBoundsInScreen)
        val rootPackage = runCatching { w.root?.packageName?.toString() }.getOrNull()
        AppWindowSlice(w.id, rootPackage, b.left, b.top, b.right, b.bottom)
            .takeIf { it.hasPositiveArea }
    }

    fun paneForBounds(bounds: Rect?): String? {
        bounds ?: return null
        val slices = appWindowSlices()
        if (classifyWindowTopology(slices) != WindowTopology.SAME_APP_MULTI) return null
        val slice = matchSliceForPoint(slices, bounds.centerX(), bounds.centerY()) ?: return null
        return assignWindowPanes(slices)[slice.windowId]
    }

    /**
     * 解析前台身份；异包/未知多窗直接 fail-closed；单窗或同应用多窗时按需执行冷启动自举或同包切窗延续。
     */
    private fun resolveForegroundOf(
        currentWindows: List<AccessibilityWindowInfo>,
        appSlices: List<AppWindowSlice> = appWindowSlices(currentWindows),
        topology: WindowTopology = classifyWindowTopology(appSlices),
    ): ResolvedForeground {
        if (topology == WindowTopology.CROSS_OR_UNKNOWN_MULTI) {
            return ResolvedForeground(
                known = false,
                packageName = "",
                activityName = "",
                reason = ForegroundUnknownReason.CROSS_APP_MULTI_WINDOW,
            )
        }
        val currentWindow = applicationWindow(currentWindows)
        val rootPackage = appSlices.firstOrNull { it.windowId == currentWindow?.id }?.rootPackage
        if (currentWindow != null && !rootPackage.isNullOrEmpty()) {
            val fgWindows = foregroundWindows(currentWindows)
            val bootstrapped = foregroundWindowTracker.bootstrapFromWindow(
                applicationWindowId = currentWindow.id,
                packageName = rootPackage,
                windows = fgWindows,
            )
            if (!bootstrapped && topology == WindowTopology.SAME_APP_MULTI) {
                foregroundWindowTracker.continueSamePackageWindow(
                    applicationWindowId = currentWindow.id,
                    packageName = rootPackage,
                    windows = fgWindows.filter { w -> appSlices.any { it.windowId == w.id } },
                )
            }
        }
        return resolveForeground(
            identity = foregroundWindowTracker.current(),
            applicationWindowId = currentWindow?.id,
            applicationWindowPackageName = rootPackage,
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
        val appSlices = appWindowSlices(currentWindows)
        val topology = classifyWindowTopology(appSlices)
        val resolved = resolveForegroundOf(currentWindows, appSlices, topology)
        return A11yDiagnosticsFormatter.buildForegroundDiagnosticsJson(
            currentWindows = currentWindows,
            selected = selected,
            topology = topology,
            resolved = resolved,
            identity = foregroundWindowTracker.current(),
            recentEvents = foregroundWindowTracker.recentEvents(),
            revision = revision,
        )
    }

    private fun foregroundWindows(
        source: List<AccessibilityWindowInfo> = windows,
    ): List<ForegroundWindow> = source.map { window ->
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
        val currentWindows = windows
        val appSlices = appWindowSlices(currentWindows)
        val topology = classifyWindowTopology(appSlices)
        if (topology == WindowTopology.CROSS_OR_UNKNOWN_MULTI) {
            throw GatewayError(
                ErrorCode.E_BLOCKED,
                "检测到跨应用或归属未知的多窗口（分屏/悬浮窗），已拒绝混采快照",
                channel = "a11y",
                fallback = "关闭无关分屏或悬浮小窗，保留单应用全屏或同应用平行视界后重试",
            )
        }
        val paneByWinId = assignWindowPanes(appSlices)
        lastSnapshotRev = revision
        // 每次快照都切换命名空间；不能让上一屏的 e1/o1 在下一屏静默绑定到另一个目标。
        val refBatch = refs.beginSnapshot(lastSnapshotRev)
        val elements = JSONArray()
        val jsonByRef = HashMap<String, JSONObject>()
        // interactive 与 full 的差异在文本截断长度：interactive 面向操作（短），full 面向阅读（长）
        val cap = if (scope == "full") 500 else 80
        // 前台归属按「活动应用窗口」判定；同应用平行视界下逐窗统计 fgCountByWin，任一应用窗稀疏即触发分窗 OCR。
        val perAppWinCap = appWindowElementCap(topology, appSlices.size, maxElements)
        val fgWinId = applicationWindow(currentWindows)?.id ?: -1
        var fgCount = 0
        val fgCountByWin = HashMap<Int, Int>()
        var count = 0
        var truncated = false

        fun visitWindow(
            root: AccessibilityNodeInfo,
            inFgWin: Boolean,
            windowId: Int,
            pane: String,
            winCap: Int,
        ) {
            if (count >= maxElements && truncated) return
            var winCount = 0
            var winTruncated = false
            fun visit(node: AccessibilityNodeInfo, depth: Int) {
                if (depth > 60 || winTruncated) return
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
                    if (winCount >= winCap || count >= maxElements) {
                        winTruncated = true
                        truncated = true
                        return
                    }
                    count += 1
                    winCount += 1
                    val b = Rect().also { node.getBoundsInScreen(it) }
                    val ref = refs.bind(
                        refBatch,
                        UiRefSource.A11Y,
                        count,
                        RefEntry(node, text, text, desc, b, lastSnapshotRev, "a11y", windowId, pane),
                    )
                    if (inFgWin) {
                        fgCount += 1
                        fgCountByWin[windowId] = (fgCountByWin[windowId] ?: 0) + 1
                    }
                    val json = JSONObject()
                        .put("ref", ref)
                        .put("role", A11yDiagnosticsFormatter.roleOf(node))
                        .put("text", text.take(cap))
                        .put("desc", desc.take(cap))
                        .put("bounds", JSONArray(listOf(b.left, b.top, b.right, b.bottom)))
                        .put("flags", A11yDiagnosticsFormatter.flagsOf(node))
                        .put("source", "a11y")
                        .put("window_id", windowId)
                        .put("pane", pane)
                    jsonByRef[ref] = json
                    elements.put(json)
                }
                for (i in 0 until node.childCount) {
                    if (winTruncated) return
                    node.getChild(i)?.let { visit(it, depth + 1) }
                }
            }
            visit(root, 0)
        }

        // 遍历全部交互窗口（含弹窗/对话框/同应用平行视界），跳过 IME 窗口
        val ws = exposedWindows(currentWindows)
        for (w in ws) {
            val winId = w.id
            val isAppWin = w.type == AccessibilityWindowInfo.TYPE_APPLICATION
            val inFgWin = winId == fgWinId || (topology == WindowTopology.SAME_APP_MULTI && isAppWin)
            val pane = paneByWinId[winId] ?: "full"
            val winCap = if (isAppWin) perAppWinCap else maxElements
            w.root?.let { visitWindow(it, inFgWin, winId, pane, winCap) }
        }
        if (count == 0) {
            rootInActiveWindow?.takeUnless(::isGatewayOverlayRoot)?.let { root ->
                val winId = root.windowId
                visitWindow(root, true, winId, paneByWinId[winId] ?: "full", maxElements)
            }
        }

        // ---- L5 OCR 融合：前台 app 树空/稀疏时自动触发（spec §5.4/§9）----
        // 骨架规则：OCR 行中心落在最小且大小同量级的 a11y 元素内 → 无语义则挂载(fused)、有语义视为重复丢弃；
        // 挂不上的落为独立 ocr 元素（无节点，click 走坐标手势）。
        var fusion = "none"
        var fusionNote: String? = null
        var usedVisionGeneration = freshVisionSession.current()?.generation ?: 0L
        var usedCaptureRevision = freshVisionSession.current()?.revision ?: lastSnapshotRev
        val sparseSlices = if (topology == WindowTopology.SAME_APP_MULTI) {
            val sparseIds = sparseWindowIds(appSlices, fgCountByWin, FUSE_FG_THRESHOLD)
            appSlices.filter { it.windowId in sparseIds }
        } else {
            emptyList()
        }
        val needOcr = if (topology == WindowTopology.SAME_APP_MULTI) {
            sparseSlices.isNotEmpty()
        } else {
            fgCount < FUSE_FG_THRESHOLD
        }
        if (needOcr && count < maxElements && !ConfirmOverlay.isAwaitingDecision) {
            try {
                val shot = ocrCoordinator.ocrScreen(topology, sparseSlices)
                usedVisionGeneration = shot.generation
                usedCaptureRevision = shot.revision
                var ocrIdx = 0
                for (line in shot.lines) {
                    // 每行都重新取候选：上一行可能刚把某个宿主变成 fused，它就不该再参与了。
                    val hosts = refs.currentEntries()
                        .filter { it.second.node != null }
                        .map { (ref, entry) ->
                            FusionHost(ref, entry.bounds.toOcrBox(), entry.label, entry.desc, entry.source)
                        }
                    when (val decision = OcrFusionPolicy.decide(
                        lineBox = line.bounds.toOcrBox(),
                        lineText = line.text,
                        hosts = hosts,
                        normalize = OcrEngine::norm,
                    )) {
                        is FusionDecision.Fuse -> {
                            val he = checkNotNull(refs.current(decision.hostRef))
                            check(refs.replace(decision.hostRef, he.copy(label = line.text, source = "fused")))
                            jsonByRef[decision.hostRef]
                                ?.put("text", line.text.take(cap))
                                ?.put("source", "fused")
                                ?.put("confidence", ocrCoordinator.conf2(line.conf))
                            continue
                        }
                        FusionDecision.DropDuplicate -> continue
                        FusionDecision.Standalone -> Unit
                    }
                    if (count >= maxElements) { truncated = true; break }
                    count += 1
                    ocrIdx += 1
                    val b = Rect(line.bounds)
                    val slice = matchSliceForPoint(appSlices, b.centerX(), b.centerY())
                    val ocrWinId = slice?.windowId ?: -1
                    val ocrPane = slice?.let { paneByWinId[it.windowId] } ?: "full"
                    val ref = refs.bind(
                        refBatch,
                        UiRefSource.OCR,
                        ocrIdx,
                        RefEntry(null, "", line.text, "", b, lastSnapshotRev, "ocr", ocrWinId, ocrPane),
                    )
                    elements.put(
                        JSONObject()
                            .put("ref", ref)
                            .put("role", "text")
                            .put("text", line.text.take(cap))
                            .put("desc", "")
                            .put("bounds", JSONArray(listOf(b.left, b.top, b.right, b.bottom)))
                            .put("flags", "")
                            .put("source", "ocr")
                            .put("window_id", ocrWinId)
                            .put("pane", ocrPane)
                            .put("confidence", ocrCoordinator.conf2(line.conf))
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
            .put("window_topology", topology.wireName)
            .put("blocking_overlay", hasBlockingOverlay(ws, fgWinId.takeIf { it >= 0 }))
            .put("ime_visible", windows.any { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD })
            .put("system_bottom_inset", systemBottomInset())
            .put("elements", elements)
        fusionNote?.let { out.put("note", it) }
        return out
    }

    /** debug 受控宏内部使用：无论 a11y 树是否稠密，都先取得独立世代的真实新截图。 */
    @Synchronized
    internal fun forceFreshVision(scope: String = "interactive", maxElements: Int = 400): JSONObject {
        ocrCoordinator.forceFreshOcrOnce = true
        return try {
            freshVisionSession.withFreshCapture { snapshot(scope, maxElements) }
        } finally {
            ocrCoordinator.forceFreshOcrOnce = false
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
        // 与 ctx 走同一条解析（含冷启动自举）：否则服务重启后 ctx 已能给出身份、这里却仍报
        // unknown，动作会在最后一道新鲜度守卫上莫名其妙地失败。自举不改 revision，不影响
        // 本段"期间不得有事件"的原子性。
        val resolved = resolveForegroundOf(currentWindows)
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
        val primaryBounds = primaryId?.let { id ->
            exposed.firstOrNull { it.id == id }?.let { Rect().also(it::getBoundsInScreen) }
                ?.takeIf { it.width() > 0 && it.height() > 0 }
        }
        return exposed.any { window ->
            // 状态栏/导航栏/分屏条是系统常驻装饰窗口，从不代表遮挡内容的对话框。
            if (window.id == primaryId ||
                window.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD ||
                window.type == AccessibilityWindowInfo.TYPE_SYSTEM ||
                window.type == AccessibilityWindowInfo.TYPE_SPLIT_SCREEN_DIVIDER
            ) return@any false
            val bounds = Rect().also(window::getBoundsInScreen)
            if (bounds.width() <= 0 || bounds.height() <= 0) return@any false
            // 并排分栏的另一个同应用窗口与主窗口互不相交，不视为遮挡浮层。
            if (window.type == AccessibilityWindowInfo.TYPE_APPLICATION &&
                primaryBounds != null &&
                !Rect.intersects(primaryBounds, bounds)
            ) return@any false
            Rect.intersects(bounds, titleBand) || Rect.intersects(bounds, probeBand)
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

    /**
     * 本次感知里视觉通道的失败原因；null 表示上一次并入 OCR 时是正常的。
     * 由调用方在自己的判定开始前清空，以免把陈旧的失败算到这一次头上。
     */
    @Volatile
    private var lastVisionSenseError: String? = null

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
            // 失败必须留痕。微信屏蔽 a11y 树时 OCR 是屏上文字的**唯一**来源，静默吞掉它会让
            // wait_for 只报"超时"，把排查引向"文字没出现"，而真相是"我们根本看不见"。
            val (topology, sparseSlices) = sparseSlicesForCurrentWindows()
            val targetSlices = if (topology == WindowTopology.SAME_APP_MULTI && sparseSlices.isEmpty()) {
                appWindowSlices()
            } else {
                sparseSlices
            }
            runCatching { ocrCoordinator.ocrScreen(topology, targetSlices) }
                .onSuccess { shot ->
                    lastVisionSenseError = null
                    shot.lines.forEach { out.add(it.text) }
                }
                .onFailure {
                    lastVisionSenseError = "${it.javaClass.simpleName}: ${it.message.orEmpty().take(80)}"
                }
        }
        return out
    }

    /** 屏上全部文本：a11y 为主，前台树稀疏时并入 OCR（危险词上下文 / wait_for 文本条件的感知面）。 */
    fun screenTexts(): List<String> = visibleTexts(withOcr = fgSparse())

    /** 活动应用窗口 id（type=APPLICATION 且 active/focused；vivo 灵动岛等悬浮窗不算前台归属）。 */
    private fun appWindowId(): Int = applicationWindow()?.id ?: -1

    private fun countSignalNodes(root: AccessibilityNodeInfo, limit: Int): Int {
        var n = 0
        fun visit(node: AccessibilityNodeInfo, depth: Int) {
            if (depth > 60 || n >= limit) return
            val signal = node.isClickable || node.isEditable || node.isScrollable ||
                !node.text.isNullOrEmpty() || !node.contentDescription.isNullOrEmpty()
            if (signal && node.isVisibleToUser) n += 1
            for (i in 0 until node.childCount) {
                if (n >= limit) return
                node.getChild(i)?.let { visit(it, depth + 1) }
            }
        }
        visit(root, 0)
        return n
    }

    private fun sparseSlicesForCurrentWindows(): Pair<WindowTopology, List<AppWindowSlice>> {
        val currentWindows = windows
        val appSlices = appWindowSlices(currentWindows)
        val topology = classifyWindowTopology(appSlices)
        if (topology != WindowTopology.SAME_APP_MULTI) return topology to emptyList()
        val fgCountByWin = HashMap<Int, Int>()
        for (w in currentWindows) {
            if (w.type != AccessibilityWindowInfo.TYPE_APPLICATION) continue
            val root = w.root ?: continue
            fgCountByWin[w.id] = countSignalNodes(root, FUSE_FG_THRESHOLD)
        }
        val sparseIds = sparseWindowIds(appSlices, fgCountByWin, FUSE_FG_THRESHOLD)
        return topology to appSlices.filter { it.windowId in sparseIds }
    }

    /** 活动应用窗口（同应用多窗时逐窗判定，任一应用窗稀疏即为 true）的可读节点是否稀疏。 */
    private fun fgSparse(): Boolean {
        val currentWindows = windows
        val appSlices = appWindowSlices(currentWindows)
        val topology = classifyWindowTopology(appSlices)
        if (topology == WindowTopology.SAME_APP_MULTI) {
            val fgCountByWin = HashMap<Int, Int>()
            for (w in currentWindows) {
                if (w.type != AccessibilityWindowInfo.TYPE_APPLICATION) continue
                val root = w.root ?: continue
                fgCountByWin[w.id] = countSignalNodes(root, FUSE_FG_THRESHOLD)
            }
            return sparseWindowIds(appSlices, fgCountByWin, FUSE_FG_THRESHOLD).isNotEmpty()
        }
        val winId = applicationWindow(currentWindows)?.id ?: -1
        val root = currentWindows.firstOrNull { it.id == winId }?.root ?: rootInActiveWindow ?: return true
        return countSignalNodes(root, FUSE_FG_THRESHOLD) < FUSE_FG_THRESHOLD
    }

    // ---------- ref 解析与动作 ----------

    data class Target(
        val node: AccessibilityNodeInfo?, // null = OCR 元素（坐标手势通道）
        val text: String,
        val desc: String,
        val bounds: Rect,
        val source: String = "a11y",
        val windowId: Int = -1,
        val pane: String = "full",
        val usedExactNavFallback: Boolean = false,
    )

    internal data class CachedRefSummary(
        val isOcrOnly: Boolean,
        val label: String,
        val desc: String,
        val bounds: Rect,
        val source: String,
        val pane: String,
    )

    /** 只读窥视当前 snapshot 内的缓存 ref 摘要（零 OCR/零副作用），供安全门预判方案 A 兜底资格。 */
    @Synchronized
    internal fun peekCachedRef(ref: String): CachedRefSummary? {
        val lookup = refs.lookup(ref)
        if (lookup.state != UiRefLookupState.CURRENT) return null
        val e = lookup.value ?: return null
        if (e.snapRev != lastSnapshotRev) return null
        return CachedRefSummary(
            isOcrOnly = e.node == null && e.source == "ocr",
            label = e.label,
            desc = e.desc,
            bounds = Rect(e.bounds),
            source = e.source,
            pane = e.pane,
        )
    }

    /** ref → 目标；节点刷新失败/指纹不符 → E_STALE_REF（点击前二次校验，M0 误触对策）。 */
    @Synchronized
    fun resolve(
        ref: String,
        allowExactNavFallback: Boolean = false,
        hasProtectedKeyword: (String) -> Boolean = { true },
    ): Target {
        rejectWhileConfirming()
        val lookup = refs.lookup(ref)
        val e = when (lookup.state) {
            UiRefLookupState.CURRENT -> checkNotNull(lookup.value)
            UiRefLookupState.STALE -> throw GatewayError(
                ErrorCode.E_STALE_REF, "ref $ref 来自旧 snapshot，拒绝重新绑定",
                channel = "a11y", fallback = "先 ui_snapshot 再按新 ref 操作",
            )
            UiRefLookupState.MISSING -> throw GatewayError(
                ErrorCode.E_NOT_FOUND, "ref $ref 不存在",
                channel = "a11y", fallback = "先 ui_snapshot 再按新 ref 操作",
            )
        }
        // 不把 live revision 与 snapRev 硬比较：确认卡自身的 add/remove window 会推进全局
        // revision，若在这里比较，所有需要真人确认的 click 都会在确认后必然 stale。
        // 跨快照/跨进程重绑定由 ref 的 session + generation 拒绝；同一快照内的真实目标漂移
        // 继续由下面的 node.refresh 与文本/描述/几何指纹复核 fail-closed。
        if (e.snapRev != lastSnapshotRev) throw GatewayError(
            ErrorCode.E_STALE_REF, "ref $ref 不属于当前 snapshot revision",
            channel = "a11y", retryable = true,
            fallback = "先 ui_snapshot 再按新 ref 操作",
        )
        if (e.node == null) return resolveOcr(ref, e, allowExactNavFallback, hasProtectedKeyword)
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
        return Target(e.node, nowText.ifEmpty { e.label }, nowDesc, b, e.source, e.windowId, e.pane)
    }

    /**
     * OCR ref 的点击前二次校验（spec §5.4：文本/位置与缓存一致才出手）：
     * 微信类 app 内容变化不发事件，revision 不可作过期依据 → 每次操作前对目标邻域重截重识，
     * 文本仍在才返回目标，bbox 随最新命中微调（容忍轻微滚动/重排）。
     */
    private fun resolveOcr(
        ref: String,
        e: RefEntry,
        allowExactNavFallback: Boolean = false,
        hasProtectedKeyword: (String) -> Boolean = { true },
    ): Target {
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
        val exactNavConfig = if (allowExactNavFallback && e.source == "ocr" && isExactNavLabelEligible(e.label)) {
            ExactNavFallbackConfig(
                expectedLabel = e.label,
                expectedScreenBox = OcrCropBox(e.bounds.left, e.bounds.top, e.bounds.right, e.bounds.bottom),
                cropLeft = crop.left,
                cropTop = crop.top,
                minConf = OcrEngine.MIN_CONF,
                hasProtectedKeyword = hasProtectedKeyword,
            )
        } else {
            null
        }
        val outcome = try {
            val want = OcrEngine.norm(e.label)
            val cx0 = e.bounds.centerX() - crop.left
            val cy0 = e.bounds.centerY() - crop.top
            // 动作前二次识别保持 MIN_ACTION_OCR_CONFIDENCE=0.65f 不变（先 1x，小字号 <60px 再 2x）；
            // 仅当调用方已证实普通具名导航 click（SafetyDecision.Allowed, len>=4）且 0.65f 零命中时，
            // 才走方案 A 精确全字相等 + IoU>=0.75 + 裁区唯一 + 零危险词重叠兜底。
            resolveOcrWithSmallTextUpsample(
                wantNorm = want,
                expectedCenterXInPiece = cx0,
                expectedCenterYInPiece = cy0,
                expectedHeightPx = e.bounds.height(),
                pieceWidth = piece.width,
                pieceHeight = piece.height,
                recognize1x = {
                    OcrEngine.recognize(piece, MIN_ACTION_OCR_CONFIDENCE).map { l ->
                        OcrCandidateLine(
                            l.text,
                            l.conf,
                            OcrCropBox(l.bounds.left, l.bounds.top, l.bounds.right, l.bounds.bottom),
                        )
                    }
                },
                recognize2x = {
                    val scaled = Bitmap.createScaledBitmap(piece, piece.width * 2, piece.height * 2, true)
                    try {
                        OcrEngine.recognize(scaled, MIN_ACTION_OCR_CONFIDENCE).map { l ->
                            OcrCandidateLine(
                                l.text,
                                l.conf,
                                OcrCropBox(l.bounds.left, l.bounds.top, l.bounds.right, l.bounds.bottom),
                            )
                        }
                    } finally {
                        if (scaled !== piece && !scaled.isRecycled) scaled.recycle()
                    }
                },
                exactNavConfig = exactNavConfig,
                recognize1xExactNav = exactNavConfig?.let {
                    {
                        OcrEngine.recognize(piece, OcrEngine.MIN_CONF).map { l ->
                            OcrCandidateLine(
                                l.text,
                                l.conf,
                                OcrCropBox(l.bounds.left, l.bounds.top, l.bounds.right, l.bounds.bottom),
                            )
                        }
                    }
                },
            )
        } finally {
            if (!piece.isRecycled) piece.recycle()
        }
        val hit = outcome.hit ?: throw GatewayError(
            ErrorCode.E_STALE_REF,
            "OCR 目标「${e.label.take(30)}」二次校验未命中（页面可能已变化；邻域实读:「${
                outcome.observedLines.joinToString(" / ") { it.text }.take(60)
            }」）",
            channel = "vision", fallback = "ui_snapshot 重新定位后再操作",
        )
        val b = Rect(hit.box.left, hit.box.top, hit.box.right, hit.box.bottom).apply {
            offset(crop.left, crop.top)
        }
        // 同一 ref 始终以快照框裁图。每次返回本帧实测的框，供确认前后和落点复核比较。
        if (refs.current(ref) !== e) throw GatewayError(
            ErrorCode.E_STALE_REF, "OCR ref $ref 已被新 snapshot 取代",
            channel = "vision", fallback = "ui_snapshot 重新定位",
        )
        return Target(
            node = null,
            text = e.label,
            desc = e.desc,
            bounds = b,
            source = "ocr",
            windowId = e.windowId,
            pane = e.pane,
            usedExactNavFallback = outcome.usedExactNavFallback,
        )
    }

    fun perform(target: Target, action: String, params: JSONObject): JSONObject {
        rejectWhileConfirming()
        val node = target.node ?: return gestureController.performOcrGesture(
            target = target,
            action = action,
            params = params,
            gestureScrollBounds = ::currentAppScrollBounds,
            currentRevision = { revision },
        )
        val ok = when (action) {
            "click" -> gestureController.clickNode(node, target.bounds)
            "long_click" -> node.performAction(AccessibilityNodeInfo.ACTION_LONG_CLICK)
            "focus" -> node.performAction(AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS)
            "scroll" -> {
                val dir = params.optString("direction", "forward")
                val act = if (dir == "backward") AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD
                else AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
                gestureController.scrollable(node).performAction(act)
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

    private fun currentAppScrollBounds(): Rect {
        val winId = appWindowId()
        return windows.firstOrNull { it.id == winId }
            ?.let { w -> Rect().also { w.getBoundsInScreen(it) } }
            ?: Rect(0, 0, resources.displayMetrics.widthPixels, resources.displayMetrics.heightPixels)
    }

    /** 手势滚动：OCR 页（无 a11y 列表节点）的翻页通道。活动应用窗口内竖直滑约 1/4 屏。 */
    fun gestureScroll(forward: Boolean): Boolean =
        gestureController.gestureScroll(currentAppScrollBounds(), forward)

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
        return gestureController.tapGesture(x.toFloat(), y.toFloat()) {
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
        // 清空后再等：超时时报出来的视觉失败必须是**这一次**发生的，不能把上一次的旧账算进来。
        lastVisionSenseError = null
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
        // 视觉通道在等待期间失败过，就必须说出来：否则"超时"会把排查引向"目标文字没出现"，
        // 而真相是这段时间里我们根本看不见屏幕（微信这类屏蔽 a11y 树的 App 上尤其致命）。
        val visionError = lastVisionSenseError
        throw GatewayError(
            ErrorCode.E_TIMEOUT,
            "wait_for($condition) 超时 ${timeoutMs}ms" +
                (visionError?.let { "；期间视觉通道失败（$it），本次很可能不是'没出现'而是'看不见'" } ?: ""),
            channel = "a11y", retryable = false,
            fallback = if (visionError != null) {
                "先 screen_capture(reason=low_confidence) 确认视觉通道，再决定是否重等"
            } else {
                "ui_snapshot 看当前实况再决策"
            },
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

    internal data class InputBarReadback(
        val text: String?,
        val region: Rect,
        val screenWidth: Int,
        val screenHeight: Int,
        val metricsWidth: Int,
        val metricsHeight: Int,
        val bottomInset: Int,
        val regionSource: String = "bottom_band",
    )

    fun ocrReadRegion(bounds: Rect): String? = ocrCoordinator.ocrReadRegion(bounds)

    internal fun ocrReadInputBarRegion(preferredBounds: Rect? = null): InputBarReadback =
        ocrCoordinator.ocrReadInputBarRegion(preferredBounds)

    fun screenshotPngBase64(region: Rect?): JSONObject = ocrCoordinator.screenshotPngBase64(region)
}

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
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.util.concurrent.CompletableFuture
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

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

        @Volatile var instance: GatewayA11yService? = null

        fun require(): GatewayA11yService = instance ?: throw GatewayError(
            ErrorCode.E_CHANNEL_DOWN, "无障碍服务未开启",
            channel = "a11y", fallback = "设置→无障碍→开启「执行网关」后重试",
        )
    }

    private val rev = AtomicLong(0)
    @Volatile private var fgPackage: String = ""
    @Volatile private var fgActivity: String = ""

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
                event.packageName?.toString()?.let { pkg ->
                    // IME/系统窗口不算前台 app 切换
                    if (windows.none { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD && it.root?.packageName == event.packageName }) {
                        fgPackage = pkg
                        fgActivity = event.className?.toString() ?: ""
                    }
                }
            }
            AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED,
            AccessibilityEvent.TYPE_WINDOWS_CHANGED -> rev.incrementAndGet()
        }
    }

    // ---------- ctx ----------

    fun foregroundPackage(): String =
        fgPackage.ifEmpty { rootInActiveWindow?.packageName?.toString() ?: "" }

    fun keyboardState(): JSONObject {
        val ime = windows.firstOrNull { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD }
        val b = Rect()
        ime?.getBoundsInScreen(b)
        return JSONObject()
            .put("visible", ime != null)
            .put("height", if (ime != null) b.height() else 0)
    }

    fun ctx(caps: List<String>): JSONObject = JSONObject()
        .put("app", foregroundPackage())
        .put("activity", fgActivity)
        .put("revision", revision)
        .put("keyboard", keyboardState())
        .put("screen", "on") // 服务在收事件即亮屏；灭屏感知 M1b 接 PowerManager
        .put("caps", JSONArray(caps))

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
        val ws = windows.filter { it.type != AccessibilityWindowInfo.TYPE_INPUT_METHOD }
        for (w in ws) w.root?.let { visit(it, 0, w.id == fgWinId) }
        if (count == 0) rootInActiveWindow?.let { visit(it, 0, true) }

        // ---- L5 OCR 融合：前台 app 树空/稀疏时自动触发（spec §5.4/§9）----
        // 骨架规则：OCR 行中心落在最小且大小同量级的 a11y 元素内 → 无语义则挂载(fused)、有语义视为重复丢弃；
        // 挂不上的落为独立 ocr 元素（无节点，click 走坐标手势）。
        var fusion = "none"
        var fusionNote: String? = null
        if (fgCount < FUSE_FG_THRESHOLD) {
            try {
                val shot = ocrScreen()
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
            .put("elements", elements)
        fusionNote?.let { out.put("note", it) }
        return out
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

    /** 供安全层做白名单上下文判断（如「文件传输助手」是否在当前屏上）。 */
    fun visibleTexts(withOcr: Boolean = false): List<String> {
        val out = ArrayList<String>()
        fun visit(node: AccessibilityNodeInfo, depth: Int) {
            if (depth > 60 || out.size > 300) return
            node.text?.toString()?.takeIf { it.isNotEmpty() }?.let { out.add(it) }
            node.contentDescription?.toString()?.takeIf { it.isNotEmpty() }?.let { out.add(it) }
            for (i in 0 until node.childCount) node.getChild(i)?.let { visit(it, depth + 1) }
        }
        windows.filter { it.type != AccessibilityWindowInfo.TYPE_INPUT_METHOD }
            .forEach { w -> w.root?.let { visit(it, 0) } }
        if (withOcr) runCatching { ocrScreen() }.getOrNull()?.lines?.forEach { out.add(it.text) }
        return out
    }

    /** 屏上全部文本：a11y 为主，前台树稀疏时并入 OCR（危险词上下文 / wait_for 文本条件的感知面）。 */
    fun screenTexts(): List<String> = visibleTexts(withOcr = fgSparse())

    /** 活动应用窗口 id（type=APPLICATION 且 active/focused；vivo 灵动岛等悬浮窗不算前台归属）。 */
    private fun appWindowId(): Int =
        windows.firstOrNull { it.type == AccessibilityWindowInfo.TYPE_APPLICATION && it.isActive }?.id
            ?: windows.firstOrNull { it.type == AccessibilityWindowInfo.TYPE_APPLICATION && it.isFocused }?.id
            ?: -1

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
        if (e.text.isNotEmpty() && nowText != e.text) throw GatewayError(
            ErrorCode.E_STALE_REF,
            "ref $ref 文本已从「${e.text.take(30)}」变为「${nowText.take(30)}」，拒绝操作",
            channel = "a11y", fallback = "先 ui_snapshot 确认目标再操作",
        )
        val b = Rect().also { e.node.getBoundsInScreen(it) }
        return Target(e.node, nowText.ifEmpty { e.label }, e.desc, b, e.source)
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
        // 校验图用零 conf 阈值：小图置信度普遍偏低，位置稳定 + 相似度分支已把关
        val lines = OcrEngine.recognize(piece, 0f)
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
    private fun tapGesture(cx: Float, cy: Float, durationMs: Long = 60L): Boolean {
        val path = Path().apply { moveTo(cx, cy) }
        return dispatchStroke(path, durationMs)
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
    private fun dispatchStroke(path: Path, durationMs: Long): Boolean {
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0L, durationMs))
            .build()
        val done = CompletableFuture<Boolean>()
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
        if (ok) ocrShot = null
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

    private data class OcrShot(val revision: Long, val at: Long, val lines: List<OcrEngine.OcrLine>)

    @Volatile private var ocrShot: OcrShot? = null

    /**
     * 整屏 OCR，按 revision 缓存 + 2s TTL（spec §9：页面不变不重跑）。
     * TTL 的必要性：微信类 app 不发内容事件、revision 长期不动，纯 revision 缓存会把
     * 单次漏识（深色模式灰字临界抖动实锤）永久钉死；短 TTL 给抖动翻盘机会。
     */
    @Synchronized
    private fun ocrScreen(): OcrShot {
        val r = revision
        ocrShot?.let {
            if (it.revision == r && SystemClock.elapsedRealtime() - it.at < 2_000) return it
        }
        // 键盘弹出时只识键盘上方：按键/候选词不是页面内容，顺带省识别时间
        val imeTop = windows.firstOrNull { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD }
            ?.let { w -> Rect().also { w.getBoundsInScreen(it) }.top } ?: Int.MAX_VALUE
        val full = captureBitmapRetry()
        val page = if (imeTop in 1 until full.height)
            Bitmap.createBitmap(full, 0, 0, full.width, imeTop) else full
        val lines = OcrEngine.recognize(page)
        return OcrShot(r, SystemClock.elapsedRealtime(), lines).also { ocrShot = it }
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

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
        @Volatile var instance: GatewayA11yService? = null

        fun require(): GatewayA11yService = instance ?: throw GatewayError(
            ErrorCode.E_CHANNEL_DOWN, "无障碍服务未开启",
            channel = "a11y", fallback = "设置→无障碍→开启「执行网关」后重试",
        )
    }

    private val rev = AtomicLong(0)
    @Volatile private var fgPackage: String = ""
    @Volatile private var fgActivity: String = ""

    private data class RefEntry(
        val node: AccessibilityNodeInfo,
        val text: String,
        val desc: String,
        val bounds: Rect,
        val snapRev: Long,
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
        var count = 0
        var truncated = false

        fun visit(node: AccessibilityNodeInfo, depth: Int) {
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
            // interactive 与 full 的差异在文本截断长度：interactive 面向操作（短），full 面向阅读（长）
            if (include && node.isVisibleToUser) {
                if (count >= maxElements) { truncated = true; return }
                count += 1
                val ref = "e$count"
                val b = Rect().also { node.getBoundsInScreen(it) }
                refs[ref] = RefEntry(node, text, desc, b, lastSnapshotRev)
                val cap = if (scope == "full") 500 else 80
                elements.put(
                    JSONObject()
                        .put("ref", ref)
                        .put("role", roleOf(node))
                        .put("text", text.take(cap))
                        .put("desc", desc.take(cap))
                        .put("bounds", JSONArray(listOf(b.left, b.top, b.right, b.bottom)))
                        .put("flags", flagsOf(node))
                        .put("source", "a11y")
                )
            }
            for (i in 0 until node.childCount) node.getChild(i)?.let { visit(it, depth + 1) }
        }

        // 遍历全部交互窗口（含弹窗/对话框），跳过 IME 窗口
        val ws = windows.filter { it.type != AccessibilityWindowInfo.TYPE_INPUT_METHOD }
        for (w in ws) w.root?.let { visit(it, 0) }
        if (count == 0) rootInActiveWindow?.let { visit(it, 0) }

        return JSONObject()
            .put("revision", lastSnapshotRev)
            .put("count", count)
            .put("truncated", truncated)
            .put("tree_empty", count == 0)
            .put("elements", elements)
    }

    fun find(text: String?, role: String?, desc: String?): JSONArray {
        val snap = snapshot("interactive", maxElements = 400)
        val out = JSONArray()
        val arr = snap.getJSONArray("elements")
        for (i in 0 until arr.length()) {
            val e = arr.getJSONObject(i)
            val tOk = text.isNullOrEmpty() || e.getString("text").contains(text) || e.getString("desc").contains(text)
            val rOk = role.isNullOrEmpty() || e.getString("role") == role
            val dOk = desc.isNullOrEmpty() || e.getString("desc").contains(desc)
            if (tOk && rOk && dOk) out.put(e)
        }
        return out
    }

    /** 供安全层做白名单上下文判断（如「文件传输助手」是否在当前屏上）。 */
    fun visibleTexts(): List<String> {
        val out = ArrayList<String>()
        fun visit(node: AccessibilityNodeInfo, depth: Int) {
            if (depth > 60 || out.size > 300) return
            node.text?.toString()?.takeIf { it.isNotEmpty() }?.let { out.add(it) }
            node.contentDescription?.toString()?.takeIf { it.isNotEmpty() }?.let { out.add(it) }
            for (i in 0 until node.childCount) node.getChild(i)?.let { visit(it, depth + 1) }
        }
        windows.filter { it.type != AccessibilityWindowInfo.TYPE_INPUT_METHOD }
            .forEach { w -> w.root?.let { visit(it, 0) } }
        return out
    }

    // ---------- ref 解析与动作 ----------

    data class Target(val node: AccessibilityNodeInfo, val text: String, val desc: String, val bounds: Rect)

    /** ref → 节点；revision 变了或节点刷新失败/指纹不符 → E_STALE_REF（点击前二次校验，M0 误触对策）。 */
    fun resolve(ref: String): Target {
        val e = refs[ref] ?: throw GatewayError(
            ErrorCode.E_NOT_FOUND, "ref $ref 不存在（可能来自旧 snapshot）",
            channel = "a11y", fallback = "先 ui_snapshot 再按新 ref 操作",
        )
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
        return Target(e.node, nowText.ifEmpty { e.text }, e.desc, b)
    }

    fun perform(target: Target, action: String, params: JSONObject): JSONObject {
        val ok = when (action) {
            "click" -> clickNode(target)
            "long_click" -> target.node.performAction(AccessibilityNodeInfo.ACTION_LONG_CLICK)
            "focus" -> target.node.performAction(AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS)
            "scroll" -> {
                val dir = params.optString("direction", "forward")
                val act = if (dir == "backward") AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD
                else AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
                scrollable(target.node).performAction(act)
            }
            "set_text" -> {
                val args = Bundle().apply {
                    putCharSequence(
                        AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                        params.optString("text"),
                    )
                }
                target.node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
            }
            "dismiss" -> target.node.performAction(AccessibilityNodeInfo.ACTION_DISMISS)
            else -> throw GatewayError(ErrorCode.E_INVALID_ARG, "未知 action: $action")
        }
        if (!ok) throw GatewayError(
            ErrorCode.E_VERIFY_FAIL, "动作 $action 执行返回 false（节点可能不响应该动作）",
            channel = "a11y", retryable = true,
            fallback = "换目标 ref（如可点击父节点）或 ui_snapshot 重看",
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
    private fun clickNode(target: Target): Boolean {
        if (target.node.isCheckable) {
            // 开关滑块通常在行右侧；点整行中心会落在文字标签上（vivo 实锤：中心无效、滑块坐标有效）
            // → 宽行（width > 2*height）点右侧滑块估计位，近方形（滑块本体）点中心。
            val b = target.bounds
            val x = if (b.width() > b.height() * 2) b.right - b.height() / 2f else b.exactCenterX()
            return tapGesture(x, b.exactCenterY())
        }
        var n: AccessibilityNodeInfo? = target.node
        var hops = 0
        while (n != null && hops < 5) {
            if (n.isClickable) return n.performAction(AccessibilityNodeInfo.ACTION_CLICK)
            n = n.parent; hops++
        }
        return target.node.performAction(AccessibilityNodeInfo.ACTION_CLICK)
    }

    /** 坐标手势点击（dispatchGesture）：ACTION_CLICK 对某些 ROM 定制控件无效时的兜底。同步等结果。 */
    private fun tapGesture(cx: Float, cy: Float): Boolean {
        val path = Path().apply { moveTo(cx, cy) }
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0L, 60L))
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
        return runCatching { done.get(2, TimeUnit.SECONDS) }.getOrDefault(false)
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
                "text_appears" -> visibleTexts().any { it.contains(args.optString("text")) }
                "text_gone" -> visibleTexts().none { it.contains(args.optString("text")) }
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

    // ---------- 截图（L6 受控兜底的采集端） ----------

    fun screenshotPngBase64(region: Rect?): JSONObject {
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
        val full = try {
            fut.get(6, TimeUnit.SECONDS)
        } catch (e: java.util.concurrent.ExecutionException) {
            throw e.cause as? GatewayError
                ?: GatewayError(ErrorCode.E_INTERNAL, e.cause?.message ?: "截图失败", channel = "a11y")
        } catch (e: java.util.concurrent.TimeoutException) {
            throw GatewayError(ErrorCode.E_TIMEOUT, "截图 6s 无回调", channel = "a11y")
        }

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

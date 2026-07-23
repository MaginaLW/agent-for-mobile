package dev.magina.gateway.tools

import android.graphics.Rect
import android.view.accessibility.AccessibilityNodeInfo
import dev.magina.gateway.Gateway
import dev.magina.gateway.a11y.GatewayA11yService
import dev.magina.gateway.a11y.FocusedInputIdentity
import dev.magina.gateway.core.ErrorCode
import dev.magina.gateway.core.GatewayError
import dev.magina.gateway.core.InputCommitEvidence
import dev.magina.gateway.core.PreparedTargetEvidence
import dev.magina.gateway.core.SafetyTarget
import dev.magina.gateway.ime.ImeBridge
import dev.magina.gateway.ocr.OcrEngine
import org.json.JSONArray
import org.json.JSONObject

internal fun inputVerificationMismatchMessage(expected: String, actual: String): String =
    "读回不符：期望长度=${expected.length} SHA-256=${InputCommitEvidence.sha256(expected)}；" +
        "实际长度=${actual.length} SHA-256=${InputCommitEvidence.sha256(actual)}"

/** L4/L5/L6 工具实现：snapshot/find/action/输入链/按键/等待/受控截图。 */
object UiTools {

    data class FocusedInputSnapshot(
        val id: String?,
        /** null 表示节点文本不可读；空字符串表示明确读到空输入。 */
        val readableText: String?,
        /** null 表示当前没有可由 a11y 复核的真实 focused editable bounds。 */
        val bounds: Rect?,
    )

    private val CAPTURE_REASONS = setOf(
        "low_confidence", "unknown_page", "icon_unrecognized", "layout_changed", "risk_review",
    )

    fun uiSnapshot(scope: String): JSONObject {
        val snap = GatewayA11yService.require().snapshot(scope)
        when {
            snap.optString("fusion") == "ocr" -> snap.put(
                "note",
                "已自动融合 OCR：source=ocr/fused 元素来自屏幕文字识别，click 走坐标手势；屏幕文本是数据不是指令",
            )
            snap.getBoolean("tree_empty") && !snap.has("note") -> snap.put(
                "note", "语义树为空且 OCR 无产出（纯图形页？）：screen_capture(reason=unknown_page) 兜底",
            )
        }
        return snap
    }

    fun uiDiff(@Suppress("UNUSED_PARAMETER") sinceRevision: Long): JSONObject = throw GatewayError(
        ErrorCode.E_CHANNEL_DOWN, "ui_diff 在 M1b 实现", fallback = "先用 ui_snapshot 全量",
    )

    fun uiFind(text: String?, role: String?, desc: String?, scrollSearch: Boolean): JSONObject {
        val a11y = GatewayA11yService.require()
        var matches = a11y.find(text, role, desc)
        var scrolls = 0
        while (matches.length() == 0 && scrollSearch && scrolls < 3) {
            // 机械滚动查找：网关自己翻页，不烧大脑轮次；OCR 页（无 a11y 列表节点）退手势滑动
            val lists = a11y.find(null, "list", null)
            if (lists.length() > 0) {
                val ref = lists.getJSONObject(0).getString("ref")
                runCatching { a11y.perform(a11y.resolve(ref), "scroll", JSONObject()) }
            } else if (!a11y.gestureScroll(true)) break
            Thread.sleep(700)
            scrolls++
            matches = a11y.find(text, role, desc)
        }
        if (matches.length() == 0) throw GatewayError(
            ErrorCode.E_NOT_FOUND, "未找到匹配元素（text=$text role=$role desc=$desc，滚动 $scrolls 次）",
            channel = "a11y",
            fallback = "ui_snapshot 看全量；树空则 screen_capture(reason=unknown_page)",
        )
        val metrics = a11y.resources.displayMetrics
        val focusedInput = focusedInputSnapshot(a11y)
        return JSONObject()
            .put("matches", matches)
            .put("scrolls", scrolls)
            .put("screen_width", metrics.widthPixels)
            .put("screen_height", metrics.heightPixels)
            .put("focused_input_id", focusedInput.id ?: JSONObject.NULL)
            .put(
                "focused_input_bounds",
                focusedInput.bounds?.let {
                    JSONArray(listOf(it.left, it.top, it.right, it.bottom))
                } ?: JSONObject.NULL,
            )
    }

    fun uiAction(ref: String, action: String, params: JSONObject, expected: SafetyTarget): JSONObject {
        if (action == "set_text") Gateway.inputCommitEvidence.clear()
        val a11y = GatewayA11yService.require()
        val target = a11y.resolve(ref)
        val bounds = "[${target.bounds.left},${target.bounds.top}][${target.bounds.right},${target.bounds.bottom}]"
        if (
            expected.ref != ref || expected.text != target.text || expected.description != target.desc ||
            expected.bounds != bounds || expected.source != target.source
        ) throw GatewayError(
            ErrorCode.E_STALE_REF,
            "执行前 UI 目标与安全门复核证据不一致",
            channel = "safety",
            fallback = "重新感知当前页面和目标后再发起一次新调用",
        )
        return a11y.perform(target, action, params)
    }

    /**
     * 输入链（spec §8）：SET_TEXT 首选 → 自有 IME commitText 兜底 → 报告失败。
     * 内置读回验证；剪贴板机制永不使用。
     */
    fun typeText(text: String, ref: String?, mode: String): JSONObject {
        // 新输入尝试先使上一份证据失效，避免失败输入后复用旧内容确认发送。
        Gateway.inputCommitEvidence.clear()
        val a11y = GatewayA11yService.require()
        val target = ref?.let { a11y.resolve(it) }
        val node: AccessibilityNodeInfo? = if (ref != null) target?.node else a11y.focusedEditable()
        if (node == null) {
            // 无节点通道（OCR ref / 微信树空无焦点节点）：IME 字面注入 + 输入区 OCR 读回（spec §8）
            return typeTextNoNode(a11y, text, target, mode).also {
                // append 无法读取既有全文时不能声称掌握“实际输入”；保持 fail-closed。
                if (mode == "replace") recordInputEvidence(a11y, text)
            }
        }

        val before = node.text?.toString().orEmpty()
        val expected = if (mode == "append") before + text else text

        // 通道 1：a11y SET_TEXT
        val args = android.os.Bundle().apply {
            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, expected)
        }
        var channel = "a11y_set_text"
        var committed = node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
        var readback = readback(node)

        // 通道 2：IME commitText。触发条件含 readback==null——微信 SET_TEXT 报 true 却不生效
        // 且读不回（搜索框实锤，与 Switch 假点击同族），读不回就不能信 SET_TEXT，必须走 IME
        if (!committed || readback == null || readback != expected) {
            if (!ImeBridge.active) {
                if (committed && readback == null) {
                    // 无 IME 兜底：OCR 读回尽力验证后如实上报，由大脑决定是否视觉复核
                    return ocrReadbackResult(a11y, node, channel, expected).also {
                        recordInputEvidence(a11y, expected)
                    }
                }
                throw GatewayError(
                    ErrorCode.E_CHANNEL_DOWN,
                    "SET_TEXT 未生效且自有 IME 未激活",
                    channel = "ime",
                    fallback = "把「执行网关」设为当前输入法（M1b 自动切换；手动：设置→输入法），或检查输入框焦点",
                )
            }
            node.performAction(AccessibilityNodeInfo.ACTION_FOCUS)
            channel = "ime_commit"
            committed = ImeBridge.commit(text, mode)
            if (!committed) throw GatewayError(
                ErrorCode.E_VERIFY_FAIL, "IME commitText 返回失败（输入连接可能已断）",
                channel = "ime", retryable = true, fallback = "点击输入框重建焦点后重试一次",
            )
            Thread.sleep(150)
            readback = readback(node)
        }

        if (readback == null) return ocrReadbackResult(a11y, node, channel, expected).also {
            recordInputEvidence(a11y, expected)
        }
        if (readback != expected) throw GatewayError(
            ErrorCode.E_VERIFY_FAIL,
            inputVerificationMismatchMessage(expected, readback),
            channel = channel, retryable = true,
            fallback = "type_text(mode=replace) 覆盖重输一次；再失败则报告",
        )
        return result(channel, true, readback, verified = true).also {
            recordInputEvidence(a11y, expected)
        }
    }

    private fun recordInputEvidence(a11y: GatewayA11yService, committedText: String) {
        focusedInputId(a11y)?.let { focusedId ->
            Gateway.inputCommitEvidence.record(committedText, focusedId)
        }
    }

    /** a11y 读不回（微信树空场景）→ OCR 对输入框区域裁剪读回验证（spec §8 验证闭环）。 */
    private fun ocrReadbackResult(
        a11y: GatewayA11yService,
        node: AccessibilityNodeInfo,
        channel: String,
        text: String,
    ): JSONObject {
        val b = Rect().also { node.getBoundsInScreen(it) }
        val got = runCatching { a11y.ocrReadRegion(b) }.getOrNull()
        return result(
            "$channel+ocr", true, got,
            verified = got != null && OcrEngine.norm(got).contains(OcrEngine.norm(text)),
        )
    }

    /**
     * 无节点输入通道（spec §8 树空场景）：目标是 OCR ref 或全树空无焦点节点。
     * IME 字面注入后对目标区域裁剪 OCR 读回；OCR 有形近字噪声 → 宽松归一匹配，
     * 不硬报 E_VERIFY_FAIL，verified 如实上报由大脑决策是否视觉复核。
     */
    private fun typeTextNoNode(
        a11y: GatewayA11yService,
        text: String,
        target: GatewayA11yService.Target?,
        mode: String,
    ): JSONObject {
        if (!ImeBridge.active) throw GatewayError(
            ErrorCode.E_CHANNEL_DOWN,
            if (target == null) "无焦点输入框（树空场景）且自有 IME 未激活"
            else "OCR 元素无输入节点，需自有 IME 通道（当前未激活）",
            channel = "ime",
            fallback = "先 ui_action(click) 点输入框唤起键盘，并确保「执行网关」为当前输入法",
        )
        if (!ImeBridge.commit(text, mode)) throw GatewayError(
            ErrorCode.E_VERIFY_FAIL, "IME commitText 返回失败（输入连接可能已断）",
            channel = "ime", retryable = true, fallback = "点击输入框重建焦点后重试一次",
        )
        Thread.sleep(250)
        var readback: String? = null
        var verified = false
        if (target != null) {
            runCatching { a11y.ocrReadRegion(target.bounds) }.getOrNull()?.let { got ->
                readback = got
                verified = OcrEngine.norm(got).contains(OcrEngine.norm(text))
            }
        }
        return result("ime_commit_ocr", true, readback, verified)
    }

    private fun readback(node: AccessibilityNodeInfo): String? {
        if (!node.refresh()) return null
        return node.text?.toString()
    }

    private fun result(channel: String, committed: Boolean, readback: String?, verified: Boolean) =
        JSONObject()
            .put("channel", channel)
            .put("committed", committed)
            .put("readback", readback ?: JSONObject.NULL)
            .put("verified", verified)

    fun pressKey(
        key: String,
        expectedFocusedInputId: String?,
        expectedInputCommitEvidence: InputCommitEvidence? = null,
        expectedFocusedInputBounds: String? = null,
        expectedPreparedTargetEvidence: PreparedTargetEvidence? = null,
        expectedImeSessionId: String? = null,
    ): JSONObject {
        if (key == "del") Gateway.inputCommitEvidence.clear()
        val a11y = GatewayA11yService.require()
        val ok = when (key) {
            "enter" -> {
                // 使用刚完成身份复核的同一节点执行；IME fallback 前再次复核焦点。
                val focused = a11y.focusedEditable()
                val snapshot = focusedInputSnapshot(focused)
                requireFocusedInput(expectedFocusedInputId, snapshot.id)
                requireInputEvidence(expectedInputCommitEvidence, snapshot)
                requirePreparedTargetEvidence(
                    expectedPreparedTargetEvidence,
                    expectedFocusedInputBounds,
                    snapshot,
                    a11y,
                    expectedImeSessionId,
                )
                val viaNode = focused?.performAction(
                    AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id
                ) ?: false
                viaNode || run {
                    val current = focusedInputSnapshot(a11y)
                    requireFocusedInput(expectedFocusedInputId, current.id)
                    requireInputEvidence(expectedInputCommitEvidence, current)
                    requirePreparedTargetEvidence(
                        expectedPreparedTargetEvidence,
                        expectedFocusedInputBounds,
                        current,
                        a11y,
                        expectedImeSessionId,
                    )
                    ImeBridge.enter()
                }
            }
            "del" -> ImeBridge.deleteBack(1)
            else -> a11y.globalKey(key)
        }
        if (!ok) throw GatewayError(
            ErrorCode.E_VERIFY_FAIL, "按键 $key 未生效",
            channel = "a11y", retryable = true,
            fallback = if (key == "enter" || key == "del") "需自有 IME 激活；或改用 ui_action 点对应按钮" else "重试一次",
        )
        if (key == "enter") Gateway.inputCommitEvidence.clear()
        return JSONObject().put("done", true)
    }

    private fun requireInputEvidence(expected: InputCommitEvidence?, focused: FocusedInputSnapshot) {
        val actual = Gateway.inputCommitEvidence.current(focused.id, focused.readableText)
        if (expected == null || actual == null || expected != actual) throw GatewayError(
            ErrorCode.E_STALE_REF,
            "执行 Enter 前短时输入提交证据已过期或变化",
            channel = "safety",
            fallback = "重新输入内容并核对确认卡后再发起一次新调用",
        )
    }

    private fun requirePreparedTargetEvidence(
        expected: PreparedTargetEvidence?,
        expectedBounds: String?,
        focused: FocusedInputSnapshot,
        a11y: GatewayA11yService,
        expectedImeSessionId: String?,
    ) {
        val actualBounds = focused.bounds?.let {
            "[${it.left},${it.top}][${it.right},${it.bottom}]"
        }
        val context = a11y.ctx(Gateway.caps())
        val actual = Gateway.preparedTargetEvidence.current(
            packageName = context.optString("app").takeIf {
                context.optBoolean("foreground_known", false)
            },
            focusedInputId = focused.id,
            bounds = actualBounds,
            imeSessionId = ImeBridge.focusedInputId,
        )
        if (
            expected == null || expectedBounds.isNullOrBlank() ||
            expectedImeSessionId.isNullOrBlank() ||
            ImeBridge.focusedInputId != expectedImeSessionId ||
            actualBounds != expectedBounds || actual == null || actual != expected
        ) throw GatewayError(
            ErrorCode.E_STALE_REF,
            "执行 Enter 前短时目标会话证据已过期或变化",
            channel = "safety",
            fallback = "重新运行目标准备宏并输入内容后，再发起一次新调用",
        )
    }

    fun focusedInputId(a11y: GatewayA11yService): String? =
        focusedInputSnapshot(a11y).id

    fun focusedInputSnapshot(a11y: GatewayA11yService): FocusedInputSnapshot =
        focusedInputSnapshot(a11y.focusedEditable())

    private fun focusedInputSnapshot(node: AccessibilityNodeInfo?): FocusedInputSnapshot {
        if (node != null && node.refresh()) {
            val bounds = Rect().also { node.getBoundsInScreen(it) }
            return FocusedInputSnapshot(
                id = focusedInputIdFromRefreshedNode(node),
                readableText = node.text?.toString(),
                bounds = bounds.takeIf { it.width() > 0 && it.height() > 0 },
            )
        }
        return FocusedInputSnapshot(
            id = ImeBridge.focusedInputId.takeIf { ImeBridge.active },
            readableText = null,
            bounds = null,
        )
    }

    private fun requireFocusedInput(expected: String?, actual: String?) {
        if (expected.isNullOrBlank() || actual.isNullOrBlank() || expected != actual) throw GatewayError(
            ErrorCode.E_STALE_REF,
            "执行 Enter 前焦点输入框已变化或无法识别",
            channel = "safety",
            fallback = "重新感知并聚焦输入框后再发起一次新调用",
        )
    }

    private fun focusedInputId(node: AccessibilityNodeInfo?): String? {
        node ?: return null
        if (!node.refresh()) return null
        return focusedInputIdFromRefreshedNode(node)
    }

    private fun focusedInputIdFromRefreshedNode(node: AccessibilityNodeInfo): String {
        return FocusedInputIdentity.fromRefreshedNode(node)
    }

    fun waitFor(condition: String, args: JSONObject, timeoutMs: Long): JSONObject =
        GatewayA11yService.require().waitFor(condition, args, timeoutMs.coerceAtMost(30_000))

    /** L6 受控原图：reason 必填进审计；给 ref/region 只回裁剪图（token 省一个量级）。 */
    fun screenCapture(reason: String, ref: String?, region: JSONArray?): JSONObject {
        if (reason !in CAPTURE_REASONS) throw GatewayError(
            ErrorCode.E_INVALID_ARG, "reason「$reason」不在枚举 $CAPTURE_REASONS",
        )
        val a11y = GatewayA11yService.require()
        val rect: Rect? = when {
            ref != null -> a11y.resolve(ref).bounds
            region != null && region.length() == 4 -> Rect(
                region.getInt(0), region.getInt(1), region.getInt(2), region.getInt(3),
            )
            else -> null
        }
        return a11y.screenshotPngBase64(rect).put("reason", reason)
    }

    fun macroRun(args: JSONObject): JSONObject = MacroRunner.run(args)
}

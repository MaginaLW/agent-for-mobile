package dev.magina.gateway.tools

import android.graphics.Rect
import android.view.accessibility.AccessibilityNodeInfo
import dev.magina.gateway.Gateway
import dev.magina.gateway.a11y.GatewayA11yService
import dev.magina.gateway.core.ErrorCode
import dev.magina.gateway.core.GatewayError
import dev.magina.gateway.ime.ImeBridge
import dev.magina.gateway.overlay.ConfirmOverlay
import org.json.JSONArray
import org.json.JSONObject

/** L4/L5/L6 工具实现：snapshot/find/action/输入链/按键/等待/受控截图/确认。 */
object UiTools {

    private val CAPTURE_REASONS = setOf(
        "low_confidence", "unknown_page", "icon_unrecognized", "layout_changed", "risk_review",
    )

    fun uiSnapshot(scope: String): JSONObject {
        val snap = GatewayA11yService.require().snapshot(scope)
        if (snap.getBoolean("tree_empty")) {
            snap.put(
                "note",
                "语义树为空：OCR 融合层在 M1b（Spike S1 定排期）；当前可 screen_capture(reason=unknown_page) 兜底",
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
            // 机械滚动查找：网关自己翻页，不烧大脑轮次
            val lists = a11y.find(null, "list", null)
            if (lists.length() == 0) break
            val ref = lists.getJSONObject(0).getString("ref")
            runCatching { a11y.perform(a11y.resolve(ref), "scroll", JSONObject()) }
            Thread.sleep(500)
            scrolls++
            matches = a11y.find(text, role, desc)
        }
        if (matches.length() == 0) throw GatewayError(
            ErrorCode.E_NOT_FOUND, "未找到匹配元素（text=$text role=$role desc=$desc，滚动 $scrolls 次）",
            channel = "a11y",
            fallback = "ui_snapshot 看全量；树空则 screen_capture(reason=unknown_page)",
        )
        return JSONObject().put("matches", matches).put("scrolls", scrolls)
    }

    fun uiAction(ref: String, action: String, params: JSONObject): JSONObject {
        val a11y = GatewayA11yService.require()
        val target = a11y.resolve(ref)

        // 危险控件动态升级（spec §5 分级 + safety.json 词表；覆盖弹出菜单场景）
        if (action == "click" || action == "long_click") {
            val label = "${target.text} ${target.desc}".trim()
            val hit = Gateway.skills.dangerHit(label) { a11y.visibleTexts() }
            if (hit != null) {
                val okd = ConfirmOverlay.ask(
                    Gateway.appContext,
                    "点击「${label.take(40)}」（命中危险词「$hit」）\n前台：${a11y.foregroundPackage()}",
                )
                if (!okd) throw GatewayError(
                    ErrorCode.E_BLOCKED, "用户拒绝了危险操作：$label",
                    channel = "overlay", fallback = "按站规输出报告收尾，不要换路重试同一危险动作",
                )
            }
        }
        return a11y.perform(target, action, params)
    }

    /**
     * 输入链（spec §8）：SET_TEXT 首选 → 自有 IME commitText 兜底 → 报告失败。
     * 内置读回验证；剪贴板机制永不使用。
     */
    fun typeText(text: String, ref: String?, mode: String): JSONObject {
        val a11y = GatewayA11yService.require()
        val node: AccessibilityNodeInfo = if (ref != null) {
            a11y.resolve(ref).node
        } else {
            a11y.focusedEditable() ?: throw GatewayError(
                ErrorCode.E_NOT_FOUND, "无焦点输入框且未指定 ref",
                channel = "a11y", fallback = "先 ui_action(输入框ref, click) 取得焦点",
            )
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

        // 通道 2：IME commitText（SET_TEXT 不生效或读回不符时）
        if (!committed || (readback != null && readback != expected)) {
            if (!ImeBridge.active) {
                if (committed && readback == null) {
                    // SET_TEXT 报成功但读不回（微信树空场景）：如实上报 verified=false，由大脑决定是否视觉复核
                    return result(channel, true, null, verified = false)
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

        val match = readback == null || readback == expected
        if (!match) throw GatewayError(
            ErrorCode.E_VERIFY_FAIL,
            "读回不符：期望「${expected.take(40)}」实际「${readback?.take(40)}」",
            channel = channel, retryable = true,
            fallback = "type_text(mode=replace) 覆盖重输一次；再失败则报告",
        )
        return result(channel, true, readback, verified = readback != null)
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

    fun pressKey(key: String): JSONObject {
        val a11y = GatewayA11yService.require()
        val ok = when (key) {
            "enter" -> {
                // 焦点节点 IME_ENTER 动作优先，IME 桥兜底
                val focused = a11y.focusedEditable()
                val viaNode = focused?.performAction(
                    AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id
                ) ?: false
                viaNode || ImeBridge.enter()
            }
            "del" -> ImeBridge.deleteBack(1)
            else -> a11y.globalKey(key)
        }
        if (!ok) throw GatewayError(
            ErrorCode.E_VERIFY_FAIL, "按键 $key 未生效",
            channel = "a11y", retryable = true,
            fallback = if (key == "enter" || key == "del") "需自有 IME 激活；或改用 ui_action 点对应按钮" else "重试一次",
        )
        return JSONObject().put("done", true)
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

    fun confirm(actionDesc: String): JSONObject {
        val ok = ConfirmOverlay.ask(Gateway.appContext, actionDesc)
        return JSONObject().put("confirmed", ok)
    }

    fun macroRun(@Suppress("UNUSED_PARAMETER") name: String): JSONObject = throw GatewayError(
        ErrorCode.E_CHANNEL_DOWN, "宏系统按主设计排期 M3", fallback = "走常规工具链",
    )
}

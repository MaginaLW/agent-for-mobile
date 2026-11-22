package dev.magina.gateway.tools

import android.graphics.Rect
import dev.magina.gateway.core.FocusIdentity
import dev.magina.gateway.core.IdentitySource
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 「这个节点能不能拿去执行 a11y 动作」必须与输入路径同一把尺子。
 *
 * 背景：微信会话页 `findFocus(FOCUS_INPUT)` 返回的残留节点既不 focused 也不 editable，
 * 却**接受 `ACTION_IME_ENTER` 并返回 true**（假成功）。`press_key` 早先直接用未过滤的节点，
 * 于是 `viaNode || ImeBridge.enter()` 当场短路，IME 通道永远走不到。
 *
 * 2026-07-31 三轮真机实锤：同一次调用序列里 `type_text` 报 `ime_commit_ocr`（无节点通道），
 * `press_key` 却报 `a11y_ime_enter`——两个工具对同一件事的判断互相矛盾。
 * 这是 knowledge《那个残留焦点节点会连累三处》的第四处。
 */
class NodeUsableForActionTest {

    private val nodeId =
        "7|com.tencent.mm:id/chat_input|android.widget.EditText|com.tencent.mm|10,20,100,80"
    private val imeSessionId = "ime|0123456789abcdef01234567"

    private fun snapshot(identity: FocusIdentity?) = UiTools.FocusedInputSnapshot(
        a11yId = identity?.a11yInputId,
        readableText = null,
        bounds = null,
        identity = identity,
    )

    @Test
    fun `a11y 身份合法时允许走节点通道`() {
        val identity = FocusIdentity.of(nodeId, imeSessionId)
        assertTrue(identity?.source == IdentitySource.A11Y)
        assertTrue(snapshot(identity).nodeUsableForAction)
    }

    /** 微信这条链：a11y 侧结构性缺失 → IME-only。此时节点不可信，必须走 IME 通道。 */
    @Test
    fun `IME-only 降级时不得走节点通道`() {
        val identity = FocusIdentity.of(null, imeSessionId)
        assertTrue(identity?.source == IdentitySource.IME_ONLY)
        assertFalse(snapshot(identity).nodeUsableForAction)
    }

    /** 微信横屏光标锚点链：无障碍节点仍为空壳，绝不短路到假成功的 a11y ACTION_IME_ENTER。 */
    @Test
    fun `IME_CURSOR_ANCHOR 身份不得走节点通道`() {
        val identity = FocusIdentity.ofCursorAnchor(20, imeSessionId)
        assertTrue(identity?.source == IdentitySource.IME_CURSOR_ANCHOR)
        assertFalse(snapshot(identity).nodeUsableForAction)
    }

    /** 两侧都取不到身份 → fail-closed，同样不许走节点通道。 */
    @Test
    fun `没有身份时不得走节点通道`() {
        assertFalse(snapshot(null).nodeUsableForAction)
    }

    @Test
    fun `chooseFocusedInputSnapshot 严格优先 A11Y，其次 IME_CURSOR_ANCHOR，否则退回 IME_ONLY`() {
        // 1) 有效 A11Y 时绝不调用光标锚点解析，保持 strict a11y
        var anchorCalls = 0
        val a11ySnap = UiTools.chooseFocusedInputSnapshot(
            a11yId = nodeId,
            readableText = "hello",
            a11yBounds = Rect(),
            imeSessionId = imeSessionId,
            allowCursorAnchor = true,
            resolveAnchor = {
                anchorCalls++
                CursorAnchorFocus(imeSessionId, 20, "right", Rect())
            },
        )
        assertEquals(0, anchorCalls)
        assertEquals(IdentitySource.A11Y, a11ySnap.identity?.source)
        assertEquals(nodeId, a11ySnap.a11yId)
        assertNull(a11ySnap.windowId)
        assertNull(a11ySnap.windowPane)
        assertTrue(a11ySnap.nodeUsableForAction)

        // 2) a11y 缺失且 allowCursorAnchor=true 时提升为 IME_CURSOR_ANCHOR（不伪造 a11yId）
        val anchorSnap = UiTools.chooseFocusedInputSnapshot(
            a11yId = null,
            readableText = null,
            a11yBounds = null,
            imeSessionId = imeSessionId,
            allowCursorAnchor = true,
            resolveAnchor = {
                anchorCalls++
                CursorAnchorFocus(imeSessionId, 20, "right", Rect())
            },
        )
        assertEquals(1, anchorCalls)
        assertEquals(IdentitySource.IME_CURSOR_ANCHOR, anchorSnap.identity?.source)
        assertNull(anchorSnap.a11yId)
        assertNull(anchorSnap.readableText)
        assertEquals(20, anchorSnap.windowId)
        assertEquals("right", anchorSnap.windowPane)
        assertEquals(20, anchorSnap.identity?.cursorAnchorWindowId)
        assertFalse(anchorSnap.nodeUsableForAction)

        // 3) allowCursorAnchor=false（readEnterVerdict / DebugMacroRunner）：绝不触发锚点 IPC，直接 IME_ONLY
        val disabledSnap = UiTools.chooseFocusedInputSnapshot(
            a11yId = null,
            readableText = null,
            a11yBounds = null,
            imeSessionId = imeSessionId,
            allowCursorAnchor = false,
            resolveAnchor = {
                anchorCalls++
                CursorAnchorFocus(imeSessionId, 20, "right", Rect())
            },
        )
        assertEquals(1, anchorCalls)
        assertEquals(IdentitySource.IME_ONLY, disabledSnap.identity?.source)
        assertNull(disabledSnap.bounds)
        assertNull(disabledSnap.windowId)
        assertNull(disabledSnap.windowPane)

        // 4) 锚点解析返回 null（单窗/重叠/TYPE_NULL）→ 退回 IME_ONLY 且 bounds=null
        val fallbackSnap = UiTools.chooseFocusedInputSnapshot(
            a11yId = null,
            readableText = null,
            a11yBounds = null,
            imeSessionId = imeSessionId,
            allowCursorAnchor = true,
            resolveAnchor = { null },
        )
        assertEquals(IdentitySource.IME_ONLY, fallbackSnap.identity?.source)
        assertNull(fallbackSnap.bounds)
        assertNull(fallbackSnap.windowId)
        assertNull(fallbackSnap.windowPane)
    }

    @Test
    fun `attachFocusedInputMetadata 准确透出 IME_CURSOR_ANCHOR 与 IME_ONLY 的 JSON 契约`() {
        val anchorIdentity = FocusIdentity.ofCursorAnchor(20, imeSessionId)!!
        val anchorJson = UiTools.attachFocusedInputMetadata(
            target = JSONObject(),
            a11yId = null,
            identity = anchorIdentity,
            bounds = IntBounds(1048, 1834, 2578, 1946),
            windowId = 20,
            windowPane = "right",
        )
        assertEquals("ime_cursor_anchor", anchorJson.getString("focused_identity_source"))
        assertTrue(anchorJson.isNull("focused_input_id"))
        val arr = anchorJson.getJSONArray("focused_input_bounds")
        assertEquals(listOf(1048, 1834, 2578, 1946), List(4) { arr.getInt(it) })
        assertEquals(20, anchorJson.getInt("focused_input_window_id"))
        assertEquals("right", anchorJson.getString("focused_input_pane"))

        val imeOnlyIdentity = FocusIdentity.of(null, imeSessionId)!!
        val imeOnlyJson = UiTools.attachFocusedInputMetadata(
            target = JSONObject(),
            a11yId = null,
            identity = imeOnlyIdentity,
            bounds = null,
            windowId = null,
            windowPane = null,
        )
        assertEquals("ime_only", imeOnlyJson.getString("focused_identity_source"))
        assertTrue(imeOnlyJson.isNull("focused_input_id"))
        assertTrue(imeOnlyJson.isNull("focused_input_bounds"))
        assertTrue(imeOnlyJson.isNull("focused_input_window_id"))
        assertTrue(imeOnlyJson.isNull("focused_input_pane"))
    }
}

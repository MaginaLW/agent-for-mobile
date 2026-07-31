package dev.magina.gateway.tools

import dev.magina.gateway.core.FocusIdentity
import dev.magina.gateway.core.IdentitySource
import org.junit.Assert.assertFalse
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

    /** 两侧都取不到身份 → fail-closed，同样不许走节点通道。 */
    @Test
    fun `没有身份时不得走节点通道`() {
        assertFalse(snapshot(null).nodeUsableForAction)
    }
}

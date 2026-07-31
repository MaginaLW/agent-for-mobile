package dev.magina.gateway.ime

import android.view.inputmethod.EditorInfo
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Enter 送法的选择规则。
 *
 * 旧实现按「是不是多行」二选一，接反了：多行走 `performEditorAction`、单行发裸按键。
 * 安卓的约定正相反——单行框声明 `IME_ACTION_SEND` 时，软键盘那颗回车键就是发送键；
 * 回车要不要退化成换行由 `IME_FLAG_NO_ENTER_ACTION` 表达。
 */
class EnterStrategyTest {

    private fun contract(inputType: Int, imeOptions: Int) =
        ImeEditorContract(inputType = inputType, imeOptions = imeOptions, actionId = 0, actionLabel = null)

    /**
     * 2026-07-22 由 `ime_editor_info` 实测的微信聊天输入框契约，2026-07-31 真机复现发送失败。
     * 它明确宣告了"回车即发送"，旧实现却因为它是单行框而绕开了这条路。
     */
    @Test
    fun `微信聊天框（单行 + IME_ACTION_SEND）必须走编辑器动作`() {
        val wechat = contract(inputType = 0x00004001, imeOptions = 0x00000004)
        assertEquals(false, wechat.multiLine)
        assertEquals(false, wechat.noEnterAction)
        assertEquals(EditorInfo.IME_ACTION_SEND, wechat.actionCode)
        assertEquals(EnterStrategy.EDITOR_ACTION, wechat.enterStrategy)
    }

    @Test
    fun `置了 NO_ENTER_ACTION 就退回裸按键`() {
        val c = contract(
            inputType = 0x00004001,
            imeOptions = EditorInfo.IME_ACTION_SEND or EditorInfo.IME_FLAG_NO_ENTER_ACTION,
        )
        assertEquals(EnterStrategy.KEY_EVENT, c.enterStrategy)
    }

    @Test
    fun `没有可用动作时走裸按键`() {
        assertEquals(
            EnterStrategy.KEY_EVENT,
            contract(0x00004001, EditorInfo.IME_ACTION_NONE).enterStrategy,
        )
        assertEquals(
            EnterStrategy.KEY_EVENT,
            contract(0x00004001, EditorInfo.IME_ACTION_UNSPECIFIED).enterStrategy,
        )
    }

    /** multiLine 不是决策位：多行框只要宣告了可用动作，仍走动作。 */
    @Test
    fun `多行但宣告了动作仍走编辑器动作`() {
        val c = contract(
            inputType = 0x00004001 or android.text.InputType.TYPE_TEXT_FLAG_MULTI_LINE,
            imeOptions = EditorInfo.IME_ACTION_SEND,
        )
        assertEquals(true, c.multiLine)
        assertEquals(EnterStrategy.EDITOR_ACTION, c.enterStrategy)
    }

    /** 多行且未宣告动作——最典型的"回车即换行"，必须发真按键。 */
    @Test
    fun `多行且无动作走裸按键`() {
        val c = contract(
            inputType = 0x00004001 or android.text.InputType.TYPE_TEXT_FLAG_MULTI_LINE,
            imeOptions = EditorInfo.IME_ACTION_UNSPECIFIED,
        )
        assertEquals(EnterStrategy.KEY_EVENT, c.enterStrategy)
    }

    @Test
    fun `搜索框走动作而不是按键`() {
        assertEquals(
            EnterStrategy.EDITOR_ACTION,
            contract(0x00000001, EditorInfo.IME_ACTION_SEARCH).enterStrategy,
        )
    }
}

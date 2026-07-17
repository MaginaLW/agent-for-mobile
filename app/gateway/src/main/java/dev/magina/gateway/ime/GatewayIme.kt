package dev.magina.gateway.ime

import android.inputmethodservice.InputMethodService
import android.view.KeyEvent
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection

/**
 * 自有 IME（spec §8）：commitText 字面注入——中文/空格/换行/标点一律字面值，
 * 绕开预测引擎（vivo 吞空格、篡改大小写两条实锤的根治方案）。零 UI（不弹自绘键盘）。
 * 切换：pm grant WRITE_SECURE_SETTINGS 后由网关 settings put secure default_input_method，
 * 或 Shizuku `ime set`（M1b）；M1a 手动切换也可用。
 */
class GatewayIme : InputMethodService() {

    override fun onStartInput(attribute: EditorInfo?, restarting: Boolean) {
        super.onStartInput(attribute, restarting)
        ImeBridge.connection = { currentInputConnection }
        ImeBridge.active = true
    }

    override fun onFinishInput() {
        ImeBridge.active = false
        super.onFinishInput()
    }

    // 不显示输入视图：注入通道不需要可见键盘（也避免键盘弹出高度扰动布局）
    override fun onEvaluateInputViewShown(): Boolean = false
}

/** 网关进程内的 IME 桥：工具实现经它注入文本。 */
object ImeBridge {
    @Volatile var active: Boolean = false
    @Volatile var connection: (() -> InputConnection?)? = null

    private fun ic(): InputConnection? = if (active) connection?.invoke() else null

    /** mode=append 追加；mode=replace 全选后覆盖。返回是否注入成功（不含内容验证——由调用方读回）。 */
    fun commit(text: String, mode: String): Boolean {
        val c = ic() ?: return false
        c.beginBatchEdit()
        try {
            if (mode == "replace") {
                c.performContextMenuAction(android.R.id.selectAll)
            }
            return c.commitText(text, 1)
        } finally {
            c.endBatchEdit()
        }
    }

    fun enter(): Boolean {
        val c = ic() ?: return false
        // 优先编辑器动作（微信发送键等注册了 IME_ACTION 的场景），退回物理回车键事件
        if (c.performEditorAction(EditorInfo.IME_ACTION_SEND)) return true
        return c.sendKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ENTER)) &&
            c.sendKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_ENTER))
    }

    fun deleteBack(count: Int): Boolean {
        val c = ic() ?: return false
        return c.deleteSurroundingText(count, 0)
    }
}

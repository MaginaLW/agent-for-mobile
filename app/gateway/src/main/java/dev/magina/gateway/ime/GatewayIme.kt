package dev.magina.gateway.ime

import android.inputmethodservice.InputMethodService
import android.view.KeyEvent
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicLong

internal class ImeSessionIdGenerator {
    private val generation = AtomicLong()

    fun next(
        packageName: String?,
        fieldId: Int,
        fieldName: String?,
        inputType: Int,
        imeOptions: Int,
    ): String? {
        val sessionGeneration = generation.incrementAndGet()
        if (packageName.isNullOrBlank()) return null
        val canonical = listOf(
            packageName,
            fieldId,
            fieldName.orEmpty(),
            inputType,
            imeOptions,
            sessionGeneration,
        ).joinToString("|")
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(canonical.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
        return "ime|${digest.take(24)}"
    }
}

private val processImeSessionIds = ImeSessionIdGenerator()

/**
 * 自有 IME（spec §8）：commitText 字面注入——中文/空格/换行/标点一律字面值，
 * 绕开预测引擎（vivo 吞空格、篡改大小写两条实锤的根治方案）。零 UI（不弹自绘键盘）。
 * 切换：pm grant WRITE_SECURE_SETTINGS 后由网关 settings put secure default_input_method，
 * 或 Shizuku `ime set`（M1b）；M1a 手动切换也可用。
 */
class GatewayIme : InputMethodService() {

    override fun onStartInput(attribute: EditorInfo?, restarting: Boolean) {
        super.onStartInput(attribute, restarting)
        val focusedInputId = attribute?.let {
            processImeSessionIds.next(it.packageName, it.fieldId, it.fieldName, it.inputType, it.imeOptions)
        }
        // 会话包名单独留存：它被哈希进 focusedInputId 后就取不回来了，而"这个输入会话
        // 属于哪个 App"是零 UI IME 下判断会话归属的唯一可用证据（见 knowledge：ime_visible
        // 在自有 IME 下恒假，不能当活性代理）。只保留包名，不留字段内容。
        ImeBridge.startSession(
            focusedInputId,
            attribute?.packageName?.toString(),
        ) { currentInputConnection }
    }

    override fun onFinishInput() {
        ImeBridge.finishSession()
        super.onFinishInput()
    }

    // 不显示输入视图：注入通道不需要可见键盘（也避免键盘弹出高度扰动布局）
    override fun onEvaluateInputViewShown(): Boolean = false
}

/**
 * 一次输入会话的身份快照。
 *
 * 自有 IME 零 UI（`onEvaluateInputViewShown=false`），因此**永远不会有可见键盘窗口**，
 * `ime_visible` 不能当作"输入会话是活的"的代理。会话身份本身才是可用证据：
 * 活性（[connected]）、归属（[packageName]）、以及跨聚焦动作的[id]变化（新鲜度）。
 */
data class ImeSessionIdentity(
    val id: String,
    val packageName: String?,
    val connected: Boolean,
) {
    fun belongsTo(expectedPackage: String): Boolean =
        connected && packageName == expectedPackage
}

/** 网关进程内的 IME 桥：工具实现经它注入文本。 */
object ImeBridge {
    private val sessionLock = Any()
    @Volatile var active: Boolean = false
        private set
    @Volatile private var connection: (() -> InputConnection?)? = null
    @Volatile var focusedInputId: String? = null
        private set

    /** 当前输入会话所属的 App 包名（来自 `EditorInfo.packageName`）。 */
    @Volatile var sessionPackage: String? = null
        private set

    internal fun startSession(
        focusedInputId: String?,
        sessionPackage: String?,
        connection: () -> InputConnection?,
    ) {
        synchronized(sessionLock) {
            this.connection = connection
            this.focusedInputId = focusedInputId
            this.sessionPackage = sessionPackage
            active = true
        }
    }

    internal fun finishSession() {
        synchronized(sessionLock) {
            active = false
            focusedInputId = null
            sessionPackage = null
            connection = null
        }
    }

    /**
     * 原子读取会话身份，避免 active/id/package 三个字段被分别读到不同世代。
     * 返回 null 表示当前没有活的输入会话。
     */
    fun session(): ImeSessionIdentity? = synchronized(sessionLock) {
        if (!active) return null
        val id = focusedInputId ?: return null
        ImeSessionIdentity(id, sessionPackage, connection?.invoke() != null)
    }

    private fun ic(): InputConnection? = if (active) connection?.invoke() else null

    /** 只暴露连接是否仍可用，不暴露 InputConnection 给宏状态机执行任意编辑动作。 */
    fun hasInputConnection(): Boolean = ic() != null

    /** mode=append 追加；mode=replace 全选后覆盖。返回是否注入成功（不含内容验证——由调用方读回）。 */
    fun commit(text: String, mode: String): Boolean {
        synchronized(sessionLock) {
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
    }

    /** 仅供固定文本宏：会话身份与快速页面 proof 在同一把锁内最终确认后才提交。 */
    internal fun commitIfCurrentSession(
        expectedFocusedId: String,
        text: String,
        fastPrecondition: () -> Boolean,
    ): Boolean = synchronized(sessionLock) {
        if (!active || focusedInputId != expectedFocusedId || !fastPrecondition()) return false
        val c = connection?.invoke() ?: return false
        c.beginBatchEdit()
        try {
            c.performContextMenuAction(android.R.id.selectAll)
            c.commitText(text, 1)
        } finally {
            c.endBatchEdit()
        }
    }

    fun enter(): Boolean {
        synchronized(sessionLock) {
            val c = ic() ?: return false
            // 优先编辑器动作（微信发送键等注册了 IME_ACTION 的场景），退回物理回车键事件
            if (c.performEditorAction(EditorInfo.IME_ACTION_SEND)) return true
            return c.sendKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ENTER)) &&
                c.sendKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_ENTER))
        }
    }

    fun deleteBack(count: Int): Boolean {
        synchronized(sessionLock) {
            val c = ic() ?: return false
            return c.deleteSurroundingText(count, 0)
        }
    }
}

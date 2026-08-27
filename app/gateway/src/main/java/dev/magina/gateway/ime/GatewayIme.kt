package dev.magina.gateway.ime

import android.inputmethodservice.InputMethodService
import android.os.SystemClock
import android.view.KeyCharacterMap
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
            attribute?.let {
                // 只留输入框的 IME 契约（决定 Enter 该怎么送），不留 hintText/initialText
                // 这类可能含用户内容的字段。
                ImeEditorContract(
                    inputType = it.inputType,
                    imeOptions = it.imeOptions,
                    actionId = it.actionId,
                    actionLabel = it.actionLabel?.toString(),
                )
            },
        ) { currentInputConnection }
    }

    override fun onFinishInput() {
        ImeBridge.finishSession()
        super.onFinishInput()
    }

    // 不显示输入视图：注入通道不需要可见键盘（也避免键盘弹出高度扰动布局）。
    // InputMethodService 要求调用父实现；这里只执行其框架评估，最终结果仍固定为 false。
    override fun onEvaluateInputViewShown(): Boolean {
        super.onEvaluateInputViewShown()
        return false
    }
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

/**
 * 当前输入框对 IME 声明的契约——**它决定 Enter 到底该怎么送**。
 *
 * 2026-07-26 真机：`performEditorAction(IME_ACTION_SEND)` 只要连接活着就返回 true，
 * App 完全可以不理会；要判断"这个框能不能靠 Enter 发送"，必须看它自己声明的
 * imeOptions/inputType，而不是看调用返回值。只保留契约字段，不含任何内容。
 */
/** Enter 的送法。**一次调用只走一条**——两条都试等于冒重复发送。 */
enum class EnterStrategy { EDITOR_ACTION, KEY_EVENT }

data class ImeEditorContract(
    val inputType: Int,
    val imeOptions: Int,
    val actionId: Int,
    val actionLabel: String?,
) {
    /** `EditorInfo.IME_MASK_ACTION` 取出的动作码。 */
    val actionCode: Int get() = imeOptions and EditorInfo.IME_MASK_ACTION

    /** 置位后 IME 不该提供"回车动作"，此时 `performEditorAction` 基本等于空转。 */
    val noEnterAction: Boolean get() = (imeOptions and EditorInfo.IME_FLAG_NO_ENTER_ACTION) != 0

    /** 多行输入框上的物理回车是换行，不是提交。 */
    val multiLine: Boolean
        get() = (inputType and android.text.InputType.TYPE_TEXT_FLAG_MULTI_LINE) != 0 ||
            (inputType and android.text.InputType.TYPE_TEXT_FLAG_IME_MULTI_LINE) != 0

    /**
     * 这一次 Enter 该怎么送。
     *
     * **判据是「编辑器有没有宣告可用的回车动作」，不是「是不是多行」**——安卓的约定里，
     * 单行框声明 `IME_ACTION_SEND` 时软键盘那颗回车键**就是**发送键，正确做法是
     * `performEditorAction(actionCode)`；回车要不要退化成换行由 `IME_FLAG_NO_ENTER_ACTION`
     * 表达（多行框通常由框架顺带置上该位），multiLine 本身不是决策位。
     *
     * 旧实现把两者接反了：多行才走动作、单行一律发裸按键。后果实锤于 2026-07-31 真机——
     * 微信聊天框 `imeOptions=0x4`（SEND）、`inputType=0x4001`（单行）、`no_enter_action=false`，
     * 也就是它**明确宣告了"回车即发送"，而我们恰恰因为它是单行框绕开了这条路**，
     * 去发了个 KeyEvent，于是消息发不出去（后验正确判 not_sent）。
     */
    val enterStrategy: EnterStrategy
        get() = when {
            noEnterAction -> EnterStrategy.KEY_EVENT
            actionCode == EditorInfo.IME_ACTION_NONE ||
                actionCode == EditorInfo.IME_ACTION_UNSPECIFIED -> EnterStrategy.KEY_EVENT
            else -> EnterStrategy.EDITOR_ACTION
        }

    /** 一行诊断摘要，只含契约标志位，不含 hintText/initialText 这类可能带内容的字段。 */
    fun describe(): String =
        "action=${actionName()},multiLine=$multiLine,noEnterAction=$noEnterAction," +
            "inputType=0x%08x,imeOptions=0x%08x".format(inputType, imeOptions)

    fun actionName(): String = when (actionCode) {
        EditorInfo.IME_ACTION_UNSPECIFIED -> "unspecified"
        EditorInfo.IME_ACTION_NONE -> "none"
        EditorInfo.IME_ACTION_GO -> "go"
        EditorInfo.IME_ACTION_SEARCH -> "search"
        EditorInfo.IME_ACTION_SEND -> "send"
        EditorInfo.IME_ACTION_NEXT -> "next"
        EditorInfo.IME_ACTION_DONE -> "done"
        EditorInfo.IME_ACTION_PREVIOUS -> "previous"
        else -> "unknown($actionCode)"
    }
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

    /** 当前输入框声明的 IME 契约；只读诊断用，决定 Enter 通道该怎么选。 */
    @Volatile var editorContract: ImeEditorContract? = null
        private set

    internal fun startSession(
        focusedInputId: String?,
        sessionPackage: String?,
        editorContract: ImeEditorContract?,
        connection: () -> InputConnection?,
    ) {
        synchronized(sessionLock) {
            this.connection = connection
            this.focusedInputId = focusedInputId
            this.sessionPackage = sessionPackage
            this.editorContract = editorContract
            active = true
        }
    }

    internal fun finishSession() {
        synchronized(sessionLock) {
            active = false
            focusedInputId = null
            sessionPackage = null
            editorContract = null
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

    /**
     * 送出一次"回车"。**按输入框自己声明的契约选通道，且只送一次**。
     *
     * 不再"先 performEditorAction 失败再退回按键"：`performEditorAction` 只要连接活着就
     * 返回 true（2026-07-26 真机实锤，微信不理会该动作时照样 true），那条链等于永远走
     * 第一条、兜底成死代码；而在发送这种危险动作上"换条通道再来一次"的代价是重复发送。
     *
     * 选择依据（本机实测微信聊天框：`imeOptions=0x4`(SEND)、单行、未禁用回车动作）：
     * - 单行输入框：直接送物理回车键事件。单行 `TextView` 会自己把回车转成它声明的
     *   editor action，这与真实键盘上按 Enter 的路径完全一致，比我们代劳更可靠。
     * - 多行输入框：回车在框里是换行而不是提交，只能显式调 editor action。
     *
     * 返回值只表示"这次投递被受理"，**不代表 App 真的发送了**——是否发出由调用方后验。
     */
    /**
     * 上一次 `enter()` 实际走的通道。危险动作失败时必须能说出"我按哪条路送的"，
     * 否则只能靠猜——2026-07-31 两轮真机都卡在发送，而返回里没有这个信息，
     * 第二轮结束时依然分不清是走了 editor_action 还是退回了 key_event。
     */
    @Volatile
    var lastEnterChannel: String? = null
        private set

    fun enter(): Boolean {
        synchronized(sessionLock) {
            val c = ic() ?: run { lastEnterChannel = "no_input_connection"; return false }
            val contract = editorContract
            // 契约缺失时只能退到裸按键；有契约就按它的宣告走（见 ImeEditorContract.enterStrategy）。
            if (contract != null && contract.enterStrategy == EnterStrategy.EDITOR_ACTION) {
                lastEnterChannel = "editor_action:${contract.actionName()}"
                return c.performEditorAction(contract.actionCode)
            }
            lastEnterChannel = if (contract == null) "key_event:no_contract" else "key_event"
            // 规范的**软键盘**按键事件：deviceId 用 VIRTUAL_KEYBOARD，并置 FLAG_SOFT_KEYBOARD |
            // FLAG_KEEP_TOUCH_MODE。旧实现用 5 参构造，deviceId=0、flags=0、source 未知——
            // 那不是软键盘该有的形态，接收方按 flags 或来源过滤时会当噪声丢掉。
            // 这是 AOSP 输入法（LatinIME.sendDownUpKeyEvent）的标准写法。
            val now = SystemClock.uptimeMillis()
            fun enterKey(action: Int) = KeyEvent(
                now, now, action, KeyEvent.KEYCODE_ENTER, 0, 0,
                KeyCharacterMap.VIRTUAL_KEYBOARD, 0,
                KeyEvent.FLAG_SOFT_KEYBOARD or KeyEvent.FLAG_KEEP_TOUCH_MODE,
            )
            return c.sendKeyEvent(enterKey(KeyEvent.ACTION_DOWN)) &&
                c.sendKeyEvent(enterKey(KeyEvent.ACTION_UP))
        }
    }

    /** 当前输入框契约的一行摘要；无会话时为 null。供危险动作的失败信封带诊断位。 */
    fun editorContractSummary(): String? = editorContract?.describe()

    fun deleteBack(count: Int): Boolean {
        synchronized(sessionLock) {
            val c = ic() ?: return false
            return c.deleteSurroundingText(count, 0)
        }
    }
}

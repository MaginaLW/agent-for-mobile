package dev.magina.gateway.core

/**
 * 焦点输入身份的来源。
 *
 * - [A11Y]：无障碍节点身份与 IME 会话双命名空间齐备（最严）。
 * - [IME_CURSOR_ANCHOR]：同应用多窗口下 a11y 焦点被应用屏蔽时，由 `InputConnection.requestCursorUpdates`
 *   屏幕几何严格归属到唯一互不重叠窗口（仍属显式降级，须配 OCR 读回验证，绝不伪造 a11y 节点 id）。
 * - [IME_ONLY]：单窗降级，只有当目标 App 对无障碍树不透明、a11y 侧身份结构性缺失时才允许，
 *   绝不能由"两边都是空值、比较恒真"平凡产生（见 IME 单命名空间降级门 design §3.1）。
 */
enum class IdentitySource { A11Y, IME_CURSOR_ANCHOR, IME_ONLY }

/**
 * 焦点输入身份：a11y 节点 id 与 IME 会话 id 是两个独立命名空间，永不互相顶替
 * （knowledge #43）。这里把"哪套命名空间在生效"显式记进值本身，让降级不可隐式发生。
 */
data class FocusIdentity(
    val source: IdentitySource,
    /** [IdentitySource.A11Y] 时为节点 producer 格式；[IdentitySource.IME_CURSOR_ANCHOR] 与 [IdentitySource.IME_ONLY] 时必须为 null。 */
    val a11yInputId: String?,
    /** 三种模式都必须具备的 IME 会话身份。 */
    val imeSessionId: String,
    /** [IdentitySource.IME_CURSOR_ANCHOR] 时必须为非负归属窗口 id；其余模式必须为 null。 */
    val cursorAnchorWindowId: Int? = null,
) {
    init {
        require(isImeSessionId(imeSessionId)) { "imeSessionId 必须是 IME producer 格式" }
        when (source) {
            IdentitySource.A11Y -> {
                require(isA11yNodeId(a11yInputId)) { "A11Y 身份必须携带节点 producer 格式的 id" }
                require(cursorAnchorWindowId == null) { "A11Y 身份不得携带光标锚点窗口 id" }
            }
            IdentitySource.IME_CURSOR_ANCHOR -> {
                require(a11yInputId == null) { "IME 光标锚点身份不得携带 a11y 节点 id" }
                require(cursorAnchorWindowId != null && cursorAnchorWindowId >= 0) {
                    "IME 光标锚点身份必须携带非负窗口 id"
                }
            }
            IdentitySource.IME_ONLY -> {
                require(a11yInputId == null) { "IME-only 身份不得携带 a11y 节点 id" }
                require(cursorAnchorWindowId == null) { "IME-only 身份不得携带光标锚点窗口 id" }
            }
        }
    }

    val degraded: Boolean get() = source != IdentitySource.A11Y

    /**
     * 供 fail-closed 信息逐条点名用的短描述。各项都已在确认卡与 ctx 里公开展示过，
     * 不引入新的信息暴露；不带这个，"身份已变化"这句话在真机上要多烧一轮派单才知道差在哪。
     */
    fun describe(): String = "source=${source.name.lowercase()}" +
        ",a11y=${a11yInputId ?: "-"},ime=$imeSessionId" +
        (cursorAnchorWindowId?.let { ",win=$it" }.orEmpty())

    companion object {
        private val IME_SESSION_PATTERN = Regex("^ime\\|[0-9a-f]{24}$")

        fun isImeSessionId(value: String?): Boolean =
            value != null && value.matches(IME_SESSION_PATTERN)

        fun isA11yNodeId(value: String?): Boolean =
            !value.isNullOrBlank() && value.count { it == '|' } == 4

        /**
         * 唯一的 a11y / IME-only 降级决策点。
         *
         * - a11y 侧一旦给出合法节点身份，必须走 [IdentitySource.A11Y]（能严则严，禁止降级）；
         * - 只有 a11y 侧**结构性缺失**（null/空）才产出 [IdentitySource.IME_ONLY]；
         * - 任何一侧存在但格式非法（含把 IME id 塞进 a11y 位）一律返回 null，fail-closed。
         */
        fun of(a11yInputId: String?, imeSessionId: String?): FocusIdentity? {
            if (!isImeSessionId(imeSessionId)) return null
            return when {
                isA11yNodeId(a11yInputId) ->
                    FocusIdentity(IdentitySource.A11Y, a11yInputId, imeSessionId!!)
                a11yInputId.isNullOrBlank() ->
                    FocusIdentity(IdentitySource.IME_ONLY, null, imeSessionId!!)
                else -> null
            }
        }

        /**
         * 同应用多窗口下经 `CursorAnchorInfo` 互不重叠归属后的显式身份工厂。
         * 不伪造 a11y 节点 id，只绑定已核实的非负窗口 id 与 IME 会话 id。
         */
        fun ofCursorAnchor(windowId: Int, imeSessionId: String?): FocusIdentity? {
            if (windowId < 0 || !isImeSessionId(imeSessionId)) return null
            return FocusIdentity(
                source = IdentitySource.IME_CURSOR_ANCHOR,
                a11yInputId = null,
                imeSessionId = imeSessionId!!,
                cursorAnchorWindowId = windowId,
            )
        }

        /** 几何证据与身份来源必须一致地存在或一致地缺失，不允许错配。 */
        fun boundsConsistent(source: IdentitySource, bounds: String?): Boolean = when (source) {
            IdentitySource.A11Y -> !bounds.isNullOrBlank()
            IdentitySource.IME_CURSOR_ANCHOR -> !bounds.isNullOrBlank()
            IdentitySource.IME_ONLY -> bounds == null
        }
    }
}

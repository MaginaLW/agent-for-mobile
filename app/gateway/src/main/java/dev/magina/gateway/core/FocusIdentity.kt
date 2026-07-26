package dev.magina.gateway.core

/**
 * 焦点输入身份的来源。
 *
 * [IME_ONLY] 是**显式降级**：只有当目标 App 对无障碍树不透明、a11y 侧身份结构性缺失时才允许，
 * 绝不能由"两边都是空值、比较恒真"平凡产生（见 IME 单命名空间降级门 design §3.1）。
 */
enum class IdentitySource { A11Y, IME_ONLY }

/**
 * 焦点输入身份：a11y 节点 id 与 IME 会话 id 是两个独立命名空间，永不互相顶替
 * （knowledge #43）。这里把"哪套命名空间在生效"显式记进值本身，让降级不可隐式发生。
 */
data class FocusIdentity(
    val source: IdentitySource,
    /** [IdentitySource.A11Y] 时为节点 producer 格式；[IdentitySource.IME_ONLY] 时必须为 null。 */
    val a11yInputId: String?,
    /** 两种模式都必须具备的 IME 会话身份。 */
    val imeSessionId: String,
) {
    init {
        require(isImeSessionId(imeSessionId)) { "imeSessionId 必须是 IME producer 格式" }
        when (source) {
            IdentitySource.A11Y ->
                require(isA11yNodeId(a11yInputId)) { "A11Y 身份必须携带节点 producer 格式的 id" }
            IdentitySource.IME_ONLY ->
                require(a11yInputId == null) { "IME-only 身份不得携带 a11y 节点 id" }
        }
    }

    val degraded: Boolean get() = source == IdentitySource.IME_ONLY

    /**
     * 供 fail-closed 信息逐条点名用的短描述。两项都已在确认卡与 ctx 里公开展示过，
     * 不引入新的信息暴露；不带这个，"身份已变化"这句话在真机上要多烧一轮派单才知道差在哪。
     */
    fun describe(): String = "source=${source.name.lowercase()}" +
        ",a11y=${a11yInputId ?: "-"},ime=$imeSessionId"

    companion object {
        private val IME_SESSION_PATTERN = Regex("^ime\\|[0-9a-f]{24}$")

        fun isImeSessionId(value: String?): Boolean =
            value != null && value.matches(IME_SESSION_PATTERN)

        fun isA11yNodeId(value: String?): Boolean =
            !value.isNullOrBlank() && value.count { it == '|' } == 4

        /**
         * 唯一的降级决策点。
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

        /** 几何证据与身份来源必须一致地存在或一致地缺失，不允许错配。 */
        fun boundsConsistent(source: IdentitySource, bounds: String?): Boolean = when (source) {
            IdentitySource.A11Y -> !bounds.isNullOrBlank()
            IdentitySource.IME_ONLY -> bounds == null
        }
    }
}

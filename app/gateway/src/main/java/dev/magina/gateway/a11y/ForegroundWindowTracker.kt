package dev.magina.gateway.a11y

internal enum class ForegroundWindowType {
    APPLICATION,
    INPUT_METHOD,
    OTHER,
}

internal data class ForegroundWindow(
    val id: Int,
    val type: ForegroundWindowType,
    val isActive: Boolean = false,
    val isFocused: Boolean = false,
)

internal sealed interface ForegroundIdentity {
    data object Unknown : ForegroundIdentity

    data class Known(
        val windowId: Int,
        val packageName: String,
        val activityName: String,
    ) : ForegroundIdentity
}

internal data class ResolvedForeground(
    val known: Boolean,
    val packageName: String,
    val activityName: String,
)

/** 将事件身份与当前应用窗口绑定；窗口不一致时只暴露 package-only 尽力后备。 */
internal fun resolveForeground(
    identity: ForegroundIdentity,
    applicationWindowId: Int?,
    applicationWindowPackageName: String?,
): ResolvedForeground = when {
    identity is ForegroundIdentity.Known && identity.windowId == applicationWindowId ->
        ResolvedForeground(
            known = true,
            packageName = identity.packageName,
            activityName = identity.activityName,
        )

    else -> ResolvedForeground(
        known = false,
        packageName = if (applicationWindowId != null) applicationWindowPackageName.orEmpty() else "",
        activityName = "",
    )
}

/** 保存通过窗口归属校验的 package/activity 原子身份。 */
internal class ForegroundWindowTracker {
    @Volatile
    private var identity: ForegroundIdentity = ForegroundIdentity.Unknown
    private val pendingCandidates = LinkedHashMap<Int, ForegroundIdentity.Known>()

    fun current(): ForegroundIdentity = identity

    fun onWindowStateChanged(
        eventWindowId: Int,
        packageName: String?,
        activityName: String?,
        windows: List<ForegroundWindow>,
    ): Boolean {
        val pkg = packageName?.takeIf { it.isNotEmpty() }
        if (pkg == null) {
            pendingCandidates.remove(eventWindowId)
            return false
        }

        val candidate = ForegroundIdentity.Known(
            windowId = eventWindowId,
            packageName = pkg,
            activityName = activityName.orEmpty(),
        )
        if (applicationWindow(windows)?.id == eventWindowId) {
            pendingCandidates.clear()
            identity = candidate
            return true
        }

        // 只有列表尚未出现该 windowId 才可能是事件先于 windows 更新；已知非活动/非应用窗口绝不暂存。
        if (windows.none { it.id == eventWindowId }) {
            pendingCandidates[eventWindowId] = candidate
            return false
        }

        pendingCandidates.remove(eventWindowId)
        return false
    }

    /**
     * 窗口状态事件可能早于 windows 列表刷新；候选只允许由紧随其后的列表变化确认一次。
     * 未成为活动应用窗口便立即消费，防止 windowId 后续复用时发布过期身份。
     */
    fun onWindowsChanged(windows: List<ForegroundWindow>): Boolean {
        val applicationWindowId = applicationWindow(windows)?.id
        val candidate = applicationWindowId?.let { pendingCandidates[it] }
        pendingCandidates.clear()
        if (candidate == null) return false

        identity = candidate
        return true
    }

    private fun applicationWindow(windows: List<ForegroundWindow>): ForegroundWindow? =
        windows.firstOrNull { it.type == ForegroundWindowType.APPLICATION && it.isActive }
            ?: windows.firstOrNull {
                it.type == ForegroundWindowType.APPLICATION && it.isFocused
            }
}

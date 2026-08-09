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

    /**
     * 已接受身份被同一 windowId 的实时非空 root 包名证伪。这个状态不能退回 [Unknown]：
     * [Unknown] 允许冷启动自举，而冲突后的任何自举都会把刚被证伪的旧身份重新放行。
     */
    data class Invalidated(
        val windowId: Int,
        val acceptedPackageName: String,
        val conflictingPackageName: String,
    ) : ForegroundIdentity

    data class Known(
        val windowId: Int,
        val packageName: String,
        val activityName: String,
        /**
         * true = 冷启动自举得来的 **package 级**身份（见 [ForegroundWindowTracker.bootstrapFromWindow]）。
         * 此时 [activityName] 必为空——窗口列表里没有 Activity 类名可取。
         */
        val bootstrapped: Boolean = false,
    ) : ForegroundIdentity
}

/** 前台身份判不出来时的具体原因；只用于诊断与日志，不参与任何放行判断。 */
internal enum class ForegroundUnknownReason {
    /** 身份成立。 */
    NONE,

    /** 从未接受过任何窗口状态事件（服务冷启动/重启后无人切窗口）。 */
    IDENTITY_UNSET,

    /** 当前窗口列表里没有 active/focused 的 APPLICATION 窗口。 */
    NO_APPLICATION_WINDOW,

    /** 已接受身份的 windowId 与当前活动应用窗口不一致（窗口换了但没等到可接受的事件）。 */
    WINDOW_ID_MISMATCH,

    /** windowId 相同，但当前活动应用窗口 root 自报的非空包名与已接受身份不一致。 */
    PACKAGE_MISMATCH,
}

internal data class ResolvedForeground(
    val known: Boolean,
    val packageName: String,
    val activityName: String,
    val reason: ForegroundUnknownReason = ForegroundUnknownReason.NONE,
    /** 身份是自举来的（package 级、无 Activity）；确认卡与 ctx 都要如实说出这件事。 */
    val bootstrapped: Boolean = false,
)

/** 将事件身份与当前应用窗口绑定；窗口或可用 root 包名不一致时只暴露 package-only 诊断。 */
internal fun resolveForeground(
    identity: ForegroundIdentity,
    applicationWindowId: Int?,
    applicationWindowPackageName: String?,
): ResolvedForeground {
    val observedPackage = applicationWindowPackageName.orEmpty()
    val packageMismatch = identity is ForegroundIdentity.Known &&
        identity.windowId == applicationWindowId &&
        observedPackage.isNotEmpty() &&
        observedPackage != identity.packageName
    return when {
        identity is ForegroundIdentity.Known &&
            identity.windowId == applicationWindowId &&
            !packageMismatch ->
            ResolvedForeground(
                known = true,
                packageName = identity.packageName,
                activityName = identity.activityName,
                bootstrapped = identity.bootstrapped,
            )

        else -> ResolvedForeground(
            known = false,
            packageName = if (applicationWindowId != null) observedPackage else "",
            activityName = "",
            reason = when {
                applicationWindowId == null -> ForegroundUnknownReason.NO_APPLICATION_WINDOW
                packageMismatch -> ForegroundUnknownReason.PACKAGE_MISMATCH
                identity is ForegroundIdentity.Invalidated &&
                    identity.windowId == applicationWindowId -> ForegroundUnknownReason.PACKAGE_MISMATCH
                identity is ForegroundIdentity.Invalidated -> ForegroundUnknownReason.WINDOW_ID_MISMATCH
                identity is ForegroundIdentity.Known -> ForegroundUnknownReason.WINDOW_ID_MISMATCH
                else -> ForegroundUnknownReason.IDENTITY_UNSET
            },
        )
    }
}

/** 单条前台事件的处置结果；进环形缓冲供 `foreground_app` 只读取证。 */
internal enum class ForegroundEventDecision {
    /** 事件窗口就是当前活动应用窗口，身份直接发布。 */
    ACCEPTED,

    /** 事件窗口尚未出现在列表里，暂存为候选等下一次列表复核。 */
    PENDING,

    /** 列表刷新确认了候选，身份发布。 */
    PUBLISHED_PENDING,

    /** 事件没带包名，无法构成身份。 */
    DROPPED_NO_PACKAGE,

    /** 事件窗口已在列表里但不是活动应用窗口（overlay/IME/非活动应用）。 */
    DROPPED_NOT_SELECTED,

    /** 列表刷新时没有与活动应用窗口对应的候选。 */
    DROPPED_NO_CANDIDATE,

    /** 冷启动自举：从未收到任何事件，直接用活动应用窗口自报的包名建立 package 级身份。 */
    BOOTSTRAPPED,
}

/** 一条前台事件的处置记录。时间与序号让"两次工具调用之间发生了什么"可事后复盘。 */
internal data class ForegroundEventRecord(
    val seq: Long,
    val atMillis: Long,
    val kind: String,
    val eventWindowId: Int,
    val packageName: String,
    val activityName: String,
    val decision: ForegroundEventDecision,
    val selectedApplicationWindowId: Int?,
    val windows: List<ForegroundWindow>,
)

/** 保存通过窗口归属校验的 package/activity 原子身份。 */
internal class ForegroundWindowTracker(
    private val clock: () -> Long = System::currentTimeMillis,
) {
    @Volatile
    private var identity: ForegroundIdentity = ForegroundIdentity.Unknown
    private val pendingCandidates = LinkedHashMap<Int, ForegroundIdentity.Known>()
    private val recent = ArrayDeque<ForegroundEventRecord>()
    private var seq = 0L

    fun current(): ForegroundIdentity = identity

    /**
     * 用实时活动应用窗口解析 tracker 当前身份。包名冲突的返回值与 invalidation 在同一把锁内
     * 原子发布，避免调用方拿到 unknown、tracker 却仍保存旧 [ForegroundIdentity.Known]。
     */
    @Synchronized
    fun resolveForeground(
        applicationWindowId: Int?,
        applicationWindowPackageName: String?,
    ): ResolvedForeground = resolveForegroundLocked(
        applicationWindowId = applicationWindowId,
        applicationWindowPackageName = applicationWindowPackageName,
    )

    /**
     * 服务读路径的原子入口：仅真正的 [ForegroundIdentity.Unknown] 可以冷启动自举；随后在同一
     * 临界区完成 root-package 复核。已 invalidated 的身份不会被 bootstrap 复活。
     */
    @Synchronized
    fun resolveForegroundOrBootstrap(
        applicationWindowId: Int?,
        applicationWindowPackageName: String?,
        windows: List<ForegroundWindow>,
    ): ResolvedForeground {
        if (applicationWindowId != null && !applicationWindowPackageName.isNullOrEmpty()) {
            bootstrapFromWindowLocked(
                applicationWindowId = applicationWindowId,
                packageName = applicationWindowPackageName,
                windows = windows,
            )
        }
        return resolveForegroundLocked(
            applicationWindowId = applicationWindowId,
            applicationWindowPackageName = applicationWindowPackageName,
        )
    }

    /** 最近若干条前台事件处置记录，旧在前。 */
    @Synchronized
    fun recentEvents(): List<ForegroundEventRecord> = recent.toList()

    @Synchronized
    fun onWindowStateChanged(
        eventWindowId: Int,
        packageName: String?,
        activityName: String?,
        windows: List<ForegroundWindow>,
    ): Boolean {
        val selectedId = applicationWindow(windows)?.id
        fun note(decision: ForegroundEventDecision) = record(
            kind = "window_state",
            eventWindowId = eventWindowId,
            packageName = packageName.orEmpty(),
            activityName = activityName.orEmpty(),
            decision = decision,
            selectedApplicationWindowId = selectedId,
            windows = windows,
        )

        val pkg = packageName?.takeIf { it.isNotEmpty() }
        if (pkg == null) {
            pendingCandidates.remove(eventWindowId)
            note(ForegroundEventDecision.DROPPED_NO_PACKAGE)
            return false
        }

        val candidate = ForegroundIdentity.Known(
            windowId = eventWindowId,
            packageName = pkg,
            activityName = activityName.orEmpty(),
        )
        if (selectedId == eventWindowId) {
            pendingCandidates.clear()
            identity = candidate
            note(ForegroundEventDecision.ACCEPTED)
            return true
        }

        // 只有列表尚未出现该 windowId 才可能是事件先于 windows 更新；已知非活动/非应用窗口绝不暂存。
        if (windows.none { it.id == eventWindowId }) {
            pendingCandidates[eventWindowId] = candidate
            note(ForegroundEventDecision.PENDING)
            return false
        }

        pendingCandidates.remove(eventWindowId)
        note(ForegroundEventDecision.DROPPED_NOT_SELECTED)
        return false
    }

    /**
     * 冷启动自举：从未收到过任何窗口状态事件时，直接用当前活动应用窗口自报的包名建立身份。
     *
     * 无障碍服务重启后 [identity] 恒为 [ForegroundIdentity.Unknown]，而窗口事件只在窗口
     * **发生变化**时才来——用户不切窗口就永远等不到。于是 `foreground_reason:identity_unset`
     * 会把所有 W/D 级工具挡死（`SafetyGate.requireKnownForeground`），此前只能靠人手动切一次
     * 窗口绕过。自举补的就是这缺失的第一次。
     *
     * 三条约束把它限制成"只补第一次"，既有判据一字未动：
     * 1. **只在从未建立过身份时生效。** 身份已建立却与当前活动窗口对不上
     *    （[ForegroundUnknownReason.WINDOW_ID_MISMATCH]）是"窗口换了却没等到可接受事件"的
     *    真实信号；自举若在那时接管，等于把这条判据抹掉。
     * 2. **只给 package 级身份，[ForegroundIdentity.Known.activityName] 留空。** 窗口列表里
     *    没有 Activity 类名可取；拿 `window.title` 之类冒充会让确认前后的逐字段相等比较
     *    拿到一条**编造的**证据，比空着危险得多。
     * 3. 必须确有活动应用窗口、且传入包名非空。
     *
     * 失败方向是安全的：自举之后真切了窗口或换了 Activity，事件会以真实 activityName 覆盖
     * 身份，于是确认前后比较立刻不等 → `E_STALE_REF`（宁可多失效，不可假通过）。
     */
    @Synchronized
    fun bootstrapFromWindow(
        applicationWindowId: Int,
        packageName: String,
        windows: List<ForegroundWindow>,
    ): Boolean = bootstrapFromWindowLocked(applicationWindowId, packageName, windows)

    private fun bootstrapFromWindowLocked(
        applicationWindowId: Int,
        packageName: String,
        windows: List<ForegroundWindow>,
    ): Boolean {
        if (identity !is ForegroundIdentity.Unknown) return false
        if (packageName.isEmpty()) return false
        if (applicationWindow(windows)?.id != applicationWindowId) return false

        identity = ForegroundIdentity.Known(
            windowId = applicationWindowId,
            packageName = packageName,
            activityName = "",
            bootstrapped = true,
        )
        record(
            kind = "bootstrap",
            eventWindowId = applicationWindowId,
            packageName = packageName,
            activityName = "",
            decision = ForegroundEventDecision.BOOTSTRAPPED,
            selectedApplicationWindowId = applicationWindowId,
            windows = windows,
        )
        return true
    }

    private fun resolveForegroundLocked(
        applicationWindowId: Int?,
        applicationWindowPackageName: String?,
    ): ResolvedForeground {
        val before = identity
        val resolved = resolveForeground(
            identity = before,
            applicationWindowId = applicationWindowId,
            applicationWindowPackageName = applicationWindowPackageName,
        )
        if (before is ForegroundIdentity.Known &&
            resolved.reason == ForegroundUnknownReason.PACKAGE_MISMATCH
        ) {
            identity = ForegroundIdentity.Invalidated(
                windowId = before.windowId,
                acceptedPackageName = before.packageName,
                conflictingPackageName = applicationWindowPackageName.orEmpty(),
            )
            // 冲突意味着 windowId/包身份世代已不可信；冲突前缓存的候选也不能跨世代发布。
            pendingCandidates.clear()
        }
        return resolved
    }

    /**
     * 窗口状态事件可能早于 windows 列表刷新；候选只允许由紧随其后的列表变化确认一次。
     * 未成为活动应用窗口便立即消费，防止 windowId 后续复用时发布过期身份。
     */
    @Synchronized
    fun onWindowsChanged(windows: List<ForegroundWindow>): Boolean {
        val applicationWindowId = applicationWindow(windows)?.id
        val candidate = applicationWindowId?.let { pendingCandidates[it] }
        pendingCandidates.clear()
        fun note(decision: ForegroundEventDecision) = record(
            kind = "windows_changed",
            eventWindowId = applicationWindowId ?: -1,
            packageName = candidate?.packageName.orEmpty(),
            activityName = candidate?.activityName.orEmpty(),
            decision = decision,
            selectedApplicationWindowId = applicationWindowId,
            windows = windows,
        )
        if (candidate == null) {
            note(ForegroundEventDecision.DROPPED_NO_CANDIDATE)
            return false
        }

        identity = candidate
        note(ForegroundEventDecision.PUBLISHED_PENDING)
        return true
    }

    private fun record(
        kind: String,
        eventWindowId: Int,
        packageName: String,
        activityName: String,
        decision: ForegroundEventDecision,
        selectedApplicationWindowId: Int?,
        windows: List<ForegroundWindow>,
    ) {
        seq += 1
        recent.addLast(
            ForegroundEventRecord(
                seq = seq,
                atMillis = clock(),
                kind = kind,
                eventWindowId = eventWindowId,
                packageName = packageName,
                activityName = activityName,
                decision = decision,
                selectedApplicationWindowId = selectedApplicationWindowId,
                windows = windows,
            )
        )
        while (recent.size > RECENT_CAPACITY) recent.removeFirst()
    }

    private fun applicationWindow(windows: List<ForegroundWindow>): ForegroundWindow? =
        windows.firstOrNull { it.type == ForegroundWindowType.APPLICATION && it.isActive }
            ?: windows.firstOrNull {
                it.type == ForegroundWindowType.APPLICATION && it.isFocused
            }

    private companion object {
        /** 够覆盖一次工具调用间隔内的窗口抖动，又不至于让诊断输出撑爆返回体。 */
        const val RECENT_CAPACITY = 24
    }
}

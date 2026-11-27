package dev.magina.gateway.overlay

import android.content.Intent

/**
 * 设备锁屏与亮屏交互快照（纯值对象，JVM 可测）。
 *
 * `TYPE_ACCESSIBILITY_OVERLAY` 的窗口层级高于 keyguard；只要处于锁屏（含无密码滑动锁屏、
 * 人脸解锁后停留锁屏界面）或息屏/熄屏显示态，就必须隐藏确认卡，仅保留 `VISIBILITY_PRIVATE`
 * 脱敏通知，防止锁屏明文泄漏与免解锁交互。
 */
internal data class ConfirmOverlayDeviceState(
    val isKeyguardLocked: Boolean,
    val isDeviceLocked: Boolean,
    val isInteractive: Boolean,
) {
    val shouldHideOverlay: Boolean
        get() = isKeyguardLocked || isDeviceLocked || !isInteractive
}

internal val CONFIRM_OVERLAY_LOCK_BROADCAST_ACTIONS: Set<String> = setOf(
    Intent.ACTION_SCREEN_OFF,
    Intent.ACTION_SCREEN_ON,
    Intent.ACTION_USER_PRESENT,
)

internal fun isConfirmOverlayLockBroadcastAction(action: String?): Boolean =
    action != null && action in CONFIRM_OVERLAY_LOCK_BROADCAST_ACTIONS

/**
 * 是否允许该次状态同步触发「解锁后重挂」：
 * - `ACTION_SCREEN_OFF` 永不重挂；
 * - `ACTION_SCREEN_ON` 仅允许立即隐藏，重挂推迟到 `ACTION_USER_PRESENT` 或下一次轮询复核，
 *   防止亮屏进锁屏时 OEM 略微滞后翻转 `isKeyguardLocked` 造成单帧明文闪烁；
 * - `ACTION_USER_PRESENT` 与轮询复核（`null`）在实时未锁屏且亮屏交互时允许重挂。
 */
internal fun shouldAllowOverlayReattachOnBroadcast(action: String?): Boolean =
    action != Intent.ACTION_SCREEN_OFF && action != Intent.ACTION_SCREEN_ON

/**
 * 将系统服务与广播信号归约为 fail-closed 的设备锁屏态。
 *
 * - 任一系统服务不可读（`null`）时按已锁屏/非交互处理，绝不把明文确认卡盲目挂到锁屏上；
 * - 收到 `ACTION_SCREEN_OFF` 时立即按非交互处理，避免亮屏进锁屏前的单帧闪烁；
 * - 收到 `ACTION_SCREEN_ON` 或 `ACTION_USER_PRESENT` 仍严格依赖实时 `KeyguardManager`/`PowerManager`
 *   读数，不盲信广播本身。
 */
internal fun resolveConfirmOverlayDeviceState(
    isKeyguardLocked: Boolean?,
    isDeviceLocked: Boolean?,
    isInteractive: Boolean?,
    broadcastAction: String? = null,
): ConfirmOverlayDeviceState {
    val effectiveInteractive = when {
        broadcastAction == Intent.ACTION_SCREEN_OFF -> false
        else -> isInteractive ?: false
    }
    return ConfirmOverlayDeviceState(
        isKeyguardLocked = isKeyguardLocked ?: true,
        isDeviceLocked = isDeviceLocked ?: true,
        isInteractive = effectiveInteractive,
    )
}

/**
 * 确认卡锁屏隐私与可见性状态机（纯 Kotlin，JVM 可测）。
 *
 * 约束：
 * 1. 首次绘制前设备已锁屏/息屏 → 直接 fail-closed，绝不挂载 `TYPE_ACCESSIBILITY_OVERLAY`；
 * 2. 首次绘制提交帧后发生息屏/锁屏 → 立即卸载悬浮窗（仅保留 `VISIBILITY_PRIVATE` 通知），
 *    同时保持本次确认请求存活（通知拒绝与超时继续有效）；
 * 3. 解锁恢复亮屏交互后，若本次确认仍未结束 → 以新 generation 重新挂载确认卡，并等待新窗口
 *    同时观察到 draw 与 frame commit 后才重新启用按钮；
 * 4. 任何确认卡按钮点击都必须校验当前未锁屏、窗口已挂载、帧已提交、已过证据门且 generation 匹配。
 */
internal class ConfirmOverlayVisibilityController {

    enum class Phase {
        NOT_STARTED,
        INITIAL_ATTACHING,
        EVIDENCE_PENDING,
        ARMED,
        CLOSED,
    }

    sealed class Action {
        data object NoOp : Action()
        data class AttachInitial(val generation: Int) : Action()
        data object FailLockedBeforeShown : Action()
        data class DetachAndFailLocked(val generation: Int) : Action()
        data class DetachForLock(val generation: Int) : Action()
        data class ReattachAfterUnlock(val generation: Int) : Action()
        data class EnableButtons(val generation: Int) : Action()
    }

    private var phase: Phase = Phase.NOT_STARTED
    private var attached: Boolean = false
    private var attachedGeneration: Int = 0
    private var locked: Boolean = false
    private var reattachCommitRegistered: Boolean = false
    private var reattachDrawObserved: Boolean = false
    private var reattachCommitObserved: Boolean = false

    @Synchronized
    fun phase(): Phase = phase

    @Synchronized
    fun isAttached(): Boolean = attached

    @Synchronized
    fun currentGeneration(): Int = attachedGeneration

    @Synchronized
    fun isLocked(): Boolean = locked

    @Synchronized
    fun beginInitialAttach(deviceState: ConfirmOverlayDeviceState): Action {
        if (phase != Phase.NOT_STARTED) return Action.NoOp
        locked = deviceState.shouldHideOverlay
        if (locked) {
            phase = Phase.CLOSED
            return Action.FailLockedBeforeShown
        }
        phase = Phase.INITIAL_ATTACHING
        attached = true
        attachedGeneration += 1
        resetReattachFence()
        return Action.AttachInitial(attachedGeneration)
    }

    @Synchronized
    fun onInitialFrameCommitted(generation: Int): Boolean {
        if (phase != Phase.INITIAL_ATTACHING || !attached || locked || generation != attachedGeneration) {
            return false
        }
        phase = Phase.EVIDENCE_PENDING
        // 初始首帧已通过 ConfirmationReadinessGate 的 draw + frame commit 门。
        reattachCommitRegistered = true
        reattachDrawObserved = true
        reattachCommitObserved = true
        return true
    }

    @Synchronized
    fun onEvidenceReady(): Action {
        if (phase != Phase.EVIDENCE_PENDING) return Action.NoOp
        phase = Phase.ARMED
        return if (attached && !locked && isCurrentFrameCommitted()) {
            Action.EnableButtons(attachedGeneration)
        } else {
            Action.NoOp
        }
    }

    @Synchronized
    fun onDeviceStateChanged(
        deviceState: ConfirmOverlayDeviceState,
        allowReattach: Boolean = true,
    ): Action {
        if (phase == Phase.CLOSED || phase == Phase.NOT_STARTED) return Action.NoOp
        if (deviceState.shouldHideOverlay) {
            locked = true
            if (phase == Phase.INITIAL_ATTACHING) {
                val prevGen = attachedGeneration
                val wasAttached = attached
                phase = Phase.CLOSED
                attached = false
                attachedGeneration += 1
                resetReattachFence()
                return if (wasAttached) Action.DetachAndFailLocked(prevGen) else Action.FailLockedBeforeShown
            }
            if (!attached) return Action.NoOp
            val prevGen = attachedGeneration
            attached = false
            attachedGeneration += 1
            resetReattachFence()
            return Action.DetachForLock(prevGen)
        } else {
            if (attached) {
                locked = false
                return Action.NoOp
            }
            if (!allowReattach) return Action.NoOp
            locked = false
            attached = true
            attachedGeneration += 1
            resetReattachFence()
            return Action.ReattachAfterUnlock(attachedGeneration)
        }
    }

    @Synchronized
    fun registerReattachFrameCommit(generation: Int): Boolean {
        if (!isAwaitingReattachFence(generation) || reattachCommitRegistered) return false
        reattachCommitRegistered = true
        return true
    }

    @Synchronized
    fun observeReattachDraw(generation: Int): Action {
        if (!isAwaitingReattachFence(generation) || !reattachCommitRegistered || reattachDrawObserved) {
            return Action.NoOp
        }
        reattachDrawObserved = true
        return maybeEnableAfterReattach(generation)
    }

    @Synchronized
    fun observeReattachFrameCommitted(generation: Int): Action {
        if (!isAwaitingReattachFence(generation) || !reattachCommitRegistered || reattachCommitObserved) {
            return Action.NoOp
        }
        reattachCommitObserved = true
        return maybeEnableAfterReattach(generation)
    }

    @Synchronized
    fun canAcceptOverlayDecision(
        generation: Int,
        deviceState: ConfirmOverlayDeviceState,
    ): Boolean {
        if (deviceState.shouldHideOverlay) return false
        return phase == Phase.ARMED &&
            attached &&
            !locked &&
            generation == attachedGeneration &&
            isCurrentFrameCommitted()
    }

    @Synchronized
    fun close(): Boolean {
        val wasAttached = attached
        phase = Phase.CLOSED
        attached = false
        attachedGeneration += 1
        resetReattachFence()
        return wasAttached
    }

    private fun isAwaitingReattachFence(generation: Int): Boolean =
        (phase == Phase.EVIDENCE_PENDING || phase == Phase.ARMED) &&
            attached &&
            !locked &&
            generation == attachedGeneration

    private fun isCurrentFrameCommitted(): Boolean =
        reattachCommitRegistered && reattachDrawObserved && reattachCommitObserved

    private fun maybeEnableAfterReattach(generation: Int): Action =
        if (phase == Phase.ARMED && isCurrentFrameCommitted()) {
            Action.EnableButtons(generation)
        } else {
            Action.NoOp
        }

    private fun resetReattachFence() {
        reattachCommitRegistered = false
        reattachDrawObserved = false
        reattachCommitObserved = false
    }
}

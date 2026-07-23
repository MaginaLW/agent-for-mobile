package dev.magina.gateway.overlay

/**
 * 确认卡首帧与按钮启用之间的纯状态门。Android 层必须先收到真实 onDraw，
 * 硬件渲染层提交该帧后才调用 [frameCommitted]。
 */
class ConfirmationReadinessGate {
    enum class State {
        ATTACHED,
        COMMIT_REGISTERED,
        DRAW_OBSERVED,
        COMMIT_OBSERVED,
        FRAME_COMMITTED,
        EVIDENCE_PENDING,
        EVIDENCE_READY,
        BUTTONS_ENABLED,
        FAILED,
    }

    private var current = State.ATTACHED

    @Synchronized
    fun registerFrameCommit(): Boolean {
        if (current != State.ATTACHED) return false
        current = State.COMMIT_REGISTERED
        return true
    }

    @Synchronized
    fun observeDraw(): Boolean = when (current) {
        State.COMMIT_REGISTERED -> {
            current = State.DRAW_OBSERVED
            true
        }
        State.COMMIT_OBSERVED -> {
            current = State.FRAME_COMMITTED
            true
        }
        else -> false
    }

    @Synchronized
    fun frameCommitted(): Boolean = when (current) {
        State.COMMIT_REGISTERED -> {
            current = State.COMMIT_OBSERVED
            false
        }
        State.DRAW_OBSERVED -> {
            current = State.FRAME_COMMITTED
            true
        }
        State.FAILED -> throw IllegalStateException("confirmation readiness already failed")
        else -> false
    }

    @Synchronized
    fun beginEvidence() {
        requireState(State.FRAME_COMMITTED)
        current = State.EVIDENCE_PENDING
    }

    @Synchronized
    fun evidenceReady() {
        requireState(State.EVIDENCE_PENDING)
        current = State.EVIDENCE_READY
    }

    @Synchronized
    fun enableButtons() {
        requireState(State.EVIDENCE_READY)
        current = State.BUTTONS_ENABLED
    }

    @Synchronized
    fun fail() {
        current = State.FAILED
    }

    @Synchronized
    fun state(): State = current

    private fun requireState(expected: State) {
        if (current != expected) throw IllegalStateException(
            "confirmation readiness expected=$expected actual=$current",
        )
    }
}

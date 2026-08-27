package dev.magina.gateway.core

/**
 * 真人这一次的决定是从哪条 surface 送进来的。
 *
 * 批次 2 之后同一次确认有**两条并联 surface**（悬浮卡 / 通知栏），而此前所有取证都只记
 * 「有没有决定」，记不出「决定来自哪一条」。现行安全边界是：悬浮卡可允许或拒绝，通知栏
 * 只能拒绝；这个枚举把最终生效决定的来源补成机械证据。
 */
enum class ApprovalChannel(val wireName: String) {
    /** 屏幕上的确认悬浮卡。 */
    OVERLAY("overlay"),

    /** 通知栏拒绝（heads-up 浮窗或下拉通知栏里的 deny action）。 */
    NOTIFICATION("notification"),
}

/**
 * 「哪条通道的决定生效了」的唯一记录点。
 *
 * 胜负判定仍然只有一个：[complete]（生产上是 `CompletableFuture::complete`）**只会成功一次**。
 * 这里不新增任何裁决逻辑，只是把那唯一一次成功**归属**到通道上——记录跟着胜负走，
 * 而不是各通道自己往一个变量里写（那样后到的失败者会覆盖赢家，取证就说了谎）。
 *
 * 纯 Kotlin，可离线单测。
 */
class ApprovalChannelRecorder(private val complete: (Boolean) -> Boolean) {

    @Volatile
    private var winner: ApprovalChannel? = null

    private val lock = Any()

    /** 送进一个决定；返回它是不是**生效**的那一个。只有生效的那次才会被记成通道。 */
    fun decide(channel: ApprovalChannel, allowed: Boolean): Boolean = synchronized(lock) {
        val won = complete(allowed)
        if (won && winner == null) winner = channel
        won
    }

    /** 生效决定的来源通道；无人决定（超时/异常）时为 null——**不给默认值**，null 就是"没人点”。 */
    fun winner(): ApprovalChannel? = winner
}

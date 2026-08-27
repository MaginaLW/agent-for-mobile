package dev.magina.gateway.core

import java.security.SecureRandom

/** 一次审批回执的处置结果；只用于诊断与审计，不参与放行判定之外的任何逻辑。 */
enum class ApprovalOutcome {
    /** 本次回执被接受，决定已落到唯一的那个 future 上。 */
    ACCEPTED,

    /** 当前没有待决审批（卡已收起 / 已超时）。 */
    NO_PENDING,

    /** 确认编号对不上：这张回执属于**另一次**确认。 */
    ID_MISMATCH,

    /** 一次性凭据对不上：伪造或重放。 */
    NONCE_MISMATCH,

    /** 已经有人先做出决定了——先到者赢，后到者一律丢弃。 */
    ALREADY_DECIDED,
}

/**
 * 危险动作审批的**唯一裁决点**（批次 2 接缝 1 + 2）。
 *
 * 同一次确认有两条 surface 能送进决定：可见悬浮卡可允许或拒绝，通知栏只能拒绝。
 * 两件事必须机械保证：
 *
 * 1. **先到者赢，且只有一个决定生效。** 否则会出现卡片决定与通知拒绝互相覆盖的状态。
 *    这里的 CAS 就是那唯一的胜负判定：[decide] 把决定交给 [Pending.complete]，
 *    而后者的实现（`CompletableFuture.complete`）本身只会成功一次。
 * 2. **回执必须带一次性凭据。** 通知的 action 走 PendingIntent，任何能构造 Intent 的第三方
 *    都可能把它打回来；只认确认编号不够，编号会出现在卡面上、可被肉眼抄走。所以每次确认
 *    另发一个随机 nonce，**只存在于本进程内存与 PendingIntent 的 extras 里**：不进 MCP 信封、
 *    不进 trace、不进审计、不进台账，**大脑没有任何路径能拿到它**——这正是批次 2 红线
 *    「审批通道必须让大脑碰不到」的机械实现，也是它与 gateway token 分离的地方
 *    （gateway token 是大脑用来调工具的，两者从不共用）。
 *
 * 纯 Kotlin，不持有任何 Android 对象，可直接离线单测。
 */
object ConfirmApprovalArbiter {

    private class Pending(
        val confirmationId: String,
        val nonce: String,
        val complete: (Boolean) -> Boolean,
    ) {
        var decided: Boolean = false
    }

    private val random = SecureRandom()

    @Volatile
    private var pending: Pending? = null

    /** 当前是否有待决审批；只读，供诊断。 */
    val isPending: Boolean get() = pending?.decided == false

    /** 新的一次性审批凭据。128 位随机，够长到不可猜，且不携带任何可推断的内容。 */
    fun newNonce(): String {
        val bytes = ByteArray(16)
        random.nextBytes(bytes)
        return bytes.joinToString("") { "%02x".format(it) }
    }

    /**
     * 开一次审批窗口。[complete] 必须是**只会成功一次**的操作（`CompletableFuture::complete`）。
     *
     * 同一时刻只允许一个待决审批：旧的若还在，直接被替换掉——它对应的那次确认要么已经超时、
     * 要么调用方自己没收干净，无论哪种都不该继续接受回执。
     */
    @Synchronized
    fun open(confirmationId: String, nonce: String, complete: (Boolean) -> Boolean) {
        require(confirmationId.isNotBlank()) { "confirmationId 不能为空" }
        require(nonce.isNotBlank()) { "nonce 不能为空" }
        pending = Pending(confirmationId, nonce, complete)
    }

    /** 关闭审批窗口（卡收起、超时、异常）。只关自己那一次，不误关别人后开的。 */
    @Synchronized
    fun close(confirmationId: String) {
        if (pending?.confirmationId == confirmationId) pending = null
    }

    /**
     * 送进一个决定。**这是通知通道唯一能触达安全门的入口**，且只做三件事：
     * 校验编号、校验一次性凭据、把决定交给那个只会成功一次的 complete。
     *
     * 它**不**能设置、伪造或跳过真人决定。通知接收器在进入本方法前拒绝 `allowed=true`；
     * 唯一允许路径由可见确认卡直接完成。本方法自身也没有任何"默认允许"路径。
     */
    @Synchronized
    fun decide(confirmationId: String, nonce: String, allowed: Boolean): ApprovalOutcome {
        val current = pending ?: return ApprovalOutcome.NO_PENDING
        if (current.confirmationId != confirmationId) return ApprovalOutcome.ID_MISMATCH
        // 常量时间比较：nonce 是凭据，逐字符早退的比较会泄漏前缀。
        if (!constantTimeEquals(current.nonce, nonce)) return ApprovalOutcome.NONCE_MISMATCH
        if (current.decided) return ApprovalOutcome.ALREADY_DECIDED
        // complete 自身就是 CAS：两条通道同时到达时，只有一个能返回 true。
        if (!current.complete(allowed)) {
            current.decided = true
            return ApprovalOutcome.ALREADY_DECIDED
        }
        current.decided = true
        return ApprovalOutcome.ACCEPTED
    }

    /** 仅供离线用例复位；生产路径不调用。 */
    @Synchronized
    fun resetForTest() {
        pending = null
    }

    private fun constantTimeEquals(a: String, b: String): Boolean {
        if (a.length != b.length) return false
        var diff = 0
        for (i in a.indices) diff = diff or (a[i].code xor b[i].code)
        return diff == 0
    }
}

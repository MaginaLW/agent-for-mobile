package dev.magina.gateway.testing

import android.content.Context
import dev.magina.gateway.core.ApprovalChannel
import dev.magina.gateway.core.IntentApprovalClocks
import java.util.UUID

/** 危险确认的只读测试观察上下文；不携带、也不能设置真人决定。 */
data class TestConfirmationAttempt(
    val confirmationId: String,
    val toolName: String,
    val action: String,
    val initialPackage: String,
    val inputLength: Int? = null,
    val inputSha256: String? = null,
)

/** 每次危险确认在卡片展示前生成；只含 12 位随机十六进制，不承载业务内容。 */
object ConfirmationIdGenerator {
    fun next(): String = UUID.randomUUID().toString().replace("-", "").take(12)
}

enum class TestConfirmationDecision {
    ALLOWED,
    DENIED,
    TIMED_OUT,
}

data class TestForeground(
    val known: Boolean,
    val packageName: String,
    /**
     * 前台身份判不出来时的原因（`foreground_reason`，如 `no_application_window`）。
     * 只进诊断消息，不参与任何判定；默认空串是"调用方没提供"，不是"没有原因"。
     */
    val reason: String = "",
)

/**
 * 确认卡取证结果。[cardVisible] 为 false 表示这张 PNG 里**没有**卡本身
 * （2026-07-26 Allow 腿实锤过一次），它就证明不了"人当时看到了什么"，
 * 必须如实标记进状态文件，不能让它冒充有效证据。
 */
data class TestConfirmationCapture(
    val png: ByteArray,
    val cardVisible: Boolean,
    val attempts: Int,
) {
    override fun equals(other: Any?): Boolean = this === other
    override fun hashCode(): Int = System.identityHashCode(this)
}

/** source set 实现持有的不透明会话；生产 no-op 会话永远不武装。 */
interface TestControlSession {
    val armed: Boolean
    val confirmId: String?
}

data object InactiveTestControlSession : TestControlSession {
    override val armed: Boolean = false
    override val confirmId: String? = null
}

/**
 * 主源码只知道这组进程内回调。接口没有控制文件、故障类型或确认决定写入口；
 * debug/release 能力由对应 source set 的 TestControlFactory 决定。
 */
interface TestControl {
    fun onConfirmationShown(
        attempt: TestConfirmationAttempt,
        capture: () -> TestConfirmationCapture,
    ): TestControlSession

    /**
     * [decidedVia] 是**生效**决定的来源通道（批次 2 起有悬浮卡与通知栏两条）；无人决定
     * （超时）时为 null。只落进取证状态文件，不参与任何放行判定。
     */
    fun onConfirmationDecision(
        session: TestControlSession,
        decision: TestConfirmationDecision,
        decidedVia: ApprovalChannel?,
    )

    fun afterAllowed(
        session: TestControlSession,
        attempt: TestConfirmationAttempt,
        performHome: () -> Boolean,
        foreground: () -> TestForeground,
    )

    /**
     * 监督式跑测按腿调整语义意图的三个时钟（spec §9.4）。**默认原样返回**——release 与
     * 未武装的会话拿到的永远是生产那组数。
     *
     * 存在的理由只有一个：Stale 腿按定义**永不把目标 App 切回来**，用满 5 分钟预算只是
     * 让人在手机旁干等。所以这条只许**缩短**等前台预算
     * （由 [dev.magina.gateway.core.IntentApprovalClocks.withShorterForegroundWait] 强制），
     * 而装配侧还会再夹一次 `coerceAtMost`：延长会让用户拍板的行为被测试脚手架悄悄改掉。
     */
    fun intentClocks(
        session: TestControlSession,
        defaults: IntentApprovalClocks,
    ): IntentApprovalClocks = defaults
}

/** release 装配与 JVM 契约测试共享的恒 no-op 实现。 */
open class NoopTestControl : TestControl {
    override fun onConfirmationShown(
        attempt: TestConfirmationAttempt,
        capture: () -> TestConfirmationCapture,
    ): TestControlSession = InactiveTestControlSession

    override fun onConfirmationDecision(
        session: TestControlSession,
        decision: TestConfirmationDecision,
        decidedVia: ApprovalChannel?,
    ) = Unit

    override fun afterAllowed(
        session: TestControlSession,
        attempt: TestConfirmationAttempt,
        performHome: () -> Boolean,
        foreground: () -> TestForeground,
    ) = Unit
}

/** 由 debug/release source set 分别提供实现。 */
object TestControlProvider {
    fun create(context: Context): TestControl = TestControlFactory.create(context)
}

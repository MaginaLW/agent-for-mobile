package dev.magina.gateway.testing

import android.content.Context
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
)

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
        capturePng: () -> ByteArray,
    ): TestControlSession

    fun onConfirmationDecision(
        session: TestControlSession,
        decision: TestConfirmationDecision,
    )

    fun afterAllowed(
        session: TestControlSession,
        attempt: TestConfirmationAttempt,
        performHome: () -> Boolean,
        foreground: () -> TestForeground,
    )
}

/** release 装配与 JVM 契约测试共享的恒 no-op 实现。 */
open class NoopTestControl : TestControl {
    override fun onConfirmationShown(
        attempt: TestConfirmationAttempt,
        capturePng: () -> ByteArray,
    ): TestControlSession = InactiveTestControlSession

    override fun onConfirmationDecision(
        session: TestControlSession,
        decision: TestConfirmationDecision,
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

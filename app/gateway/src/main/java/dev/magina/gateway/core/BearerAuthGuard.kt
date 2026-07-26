package dev.magina.gateway.core

/**
 * MCP 的 Bearer 校验：常量时间比较 + 失败退避。
 *
 * 绑 127.0.0.1 挡住了外网，但**同机任意 app 都能打这个端口**，token 是唯一一道门，
 * 所以这道门自己不能漏信息、也不该让人无成本地猜。
 *
 * 退避选的是"失败后延迟应答"而不是"锁死端口"：后者会让同机任何一个乱打的进程
 * 把我们自己的大脑一起挡在外面（自我 DoS），而前者只拖慢猜测，不影响持有正确 token 的调用。
 * 128 bit 的 token 本来就猜不动，这层是纵深防御。
 */
class BearerAuthGuard(
    private val expected: String,
    private val freeAttempts: Int = 3,
    private val stepDelayMs: Long = 250,
    private val maxDelayMs: Long = 2_000,
) {
    data class Verdict(val allowed: Boolean, val delayMs: Long)

    private var consecutiveFailures = 0

    @Synchronized
    fun check(authorizationHeader: String?): Verdict {
        val presented = authorizationHeader?.removePrefix("Bearer ")?.takeIf {
            authorizationHeader.startsWith("Bearer ")
        }
        if (presented != null && constantTimeEquals(presented, expected)) {
            consecutiveFailures = 0
            return Verdict(allowed = true, delayMs = 0)
        }
        consecutiveFailures++
        val over = (consecutiveFailures - freeAttempts).coerceAtLeast(0)
        return Verdict(allowed = false, delayMs = (over * stepDelayMs).coerceAtMost(maxDelayMs))
    }

    companion object {
        /**
         * 不用 `==`：字符串比较会在第一个不同的字节上提前返回，逐字节计时可以把 token 问出来。
         * 长度本身不保密（形态是固定的 32 位十六进制），但内容必须等时比较。
         */
        fun constantTimeEquals(a: String, b: String): Boolean {
            val left = a.toByteArray(Charsets.UTF_8)
            val right = b.toByteArray(Charsets.UTF_8)
            var diff = left.size xor right.size
            val len = maxOf(left.size, right.size)
            for (i in 0 until len) {
                val l = if (i < left.size) left[i].toInt() else 0
                val r = if (i < right.size) right[i].toInt() else 0
                diff = diff or (l xor r)
            }
            return diff == 0
        }
    }
}

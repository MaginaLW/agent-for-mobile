package dev.magina.gateway.core

import android.os.SystemClock

/**
 * 同法重试守卫（spec §3）：同一「工具+参数指纹」失败满 2 次后，第 3 次调用直接拒绝
 * （E_RETRY_EXHAUSTED），从机械上终结 $6.44 式磨损。成功或 10 分钟冷却后清零。
 */
class RetryGuard(
    private val maxFailures: Int = 2,
    private val coolDownMs: Long = 10 * 60_000L,
) {
    private data class Entry(var failures: Int, var lastTs: Long)

    private val entries = HashMap<String, Entry>()

    private fun key(tool: String, argsFingerprint: String) = "$tool#$argsFingerprint"

    @Synchronized
    fun checkAllowed(tool: String, argsFingerprint: String) {
        val e = entries[key(tool, argsFingerprint)] ?: return
        if (SystemClock.elapsedRealtime() - e.lastTs > coolDownMs) {
            entries.remove(key(tool, argsFingerprint)); return
        }
        if (e.failures >= maxFailures) {
            throw GatewayError(
                ErrorCode.E_RETRY_EXHAUSTED,
                "同一调用已连续失败 ${e.failures} 次，拒绝第 ${e.failures + 1} 次相同尝试",
                retryable = false,
                fallback = "换通道/换参数，或按站规输出失败报告收尾",
            )
        }
    }

    @Synchronized
    fun recordFailure(tool: String, argsFingerprint: String) {
        val k = key(tool, argsFingerprint)
        val e = entries.getOrPut(k) { Entry(0, 0) }
        e.failures += 1
        e.lastTs = SystemClock.elapsedRealtime()
    }

    @Synchronized
    fun recordSuccess(tool: String, argsFingerprint: String) {
        entries.remove(key(tool, argsFingerprint))
    }
}

package dev.magina.gateway.core

import org.json.JSONObject
import java.util.concurrent.atomic.AtomicLong

/**
 * debug 准备宏刚刚验证过的业务目标。
 *
 * 只含非敏感的目标标签和 UI 身份元数据；纯进程内、单条、短时，不持久化。
 * [identity] 显式记录身份来源；IME-only 降级下 [bounds] 一致地缺失（design §3.1/§3.3）。
 */
data class PreparedTargetEvidence(
    val preparedId: Long,
    val label: String,
    val packageName: String,
    val identity: FocusIdentity,
    val bounds: String?,
    val preparedAtMs: Long,
    val expiresAtMs: Long,
)

class PreparedTargetEvidenceStore(
    private val ttlMs: Long = DEFAULT_TTL_MS,
    private val clock: () -> Long = { System.nanoTime() / 1_000_000L },
) {
    private val sequence = AtomicLong()

    @Volatile
    private var latest: PreparedTargetEvidence? = null

    init {
        require(ttlMs > 0) { "ttlMs 必须大于 0" }
    }

    @Synchronized
    fun record(
        label: String,
        packageName: String,
        identity: FocusIdentity,
        bounds: String?,
    ): PreparedTargetEvidence {
        require(label.isNotBlank()) { "label 不能为空" }
        require(packageName.isNotBlank()) { "packageName 不能为空" }
        require(FocusIdentity.boundsConsistent(identity.source, bounds)) {
            "bounds 必须与身份来源一致地存在或缺失"
        }
        val now = clock()
        return PreparedTargetEvidence(
            preparedId = sequence.incrementAndGet(),
            label = label,
            packageName = packageName,
            identity = identity,
            bounds = bounds,
            preparedAtMs = now,
            expiresAtMs = now + ttlMs,
        ).also { latest = it }
    }

    /**
     * 读取必须同时证明 package、身份（含来源）与几何仍相同；任何不匹配都会销毁旧目标，
     * 避免稍后复活。身份来源不同一律视为不匹配——严格链与降级链是两条独立的链。
     */
    @Synchronized
    fun current(
        packageName: String?,
        identity: FocusIdentity?,
        bounds: String?,
    ): PreparedTargetEvidence? {
        val evidence = latest ?: return null
        if (
            clock() >= evidence.expiresAtMs ||
            packageName.isNullOrBlank() || evidence.packageName != packageName ||
            identity == null || evidence.identity != identity ||
            !FocusIdentity.boundsConsistent(identity.source, bounds) ||
            evidence.bounds != bounds
        ) {
            latest = null
            return null
        }
        return evidence
    }

    @Synchronized
    fun peekActive(): PreparedTargetEvidence? {
        val evidence = latest ?: return null
        if (clock() >= evidence.expiresAtMs) {
            latest = null
            return null
        }
        return evidence
    }

    @Synchronized
    fun clear() {
        latest = null
    }

    companion object {
        const val DEFAULT_TTL_MS = 120_000L
    }
}

/**
 * 已准备目标采用 focused input 单一寻址；显式 ref 会形成第二套目标主权，必须在 handler 前阻断。
 */
internal fun guardPreparedTargetTypeTextArgs(
    args: JSONObject,
    preparedStore: PreparedTargetEvidenceStore,
    inputStore: InputCommitEvidenceStore,
) {
    if (preparedStore.peekActive() == null || !args.has("ref")) return
    preparedStore.clear()
    inputStore.clear()
    throw GatewayError(
        ErrorCode.E_BLOCKED,
        "已准备目标的 type_text 只允许写当前焦点，禁止同时提供 ref",
        channel = "safety",
        retryable = false,
        fallback = "重新运行目标准备宏后，使用不含 ref 的 type_text",
    )
}

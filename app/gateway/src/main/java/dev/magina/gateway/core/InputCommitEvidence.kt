package dev.magina.gateway.core

import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicLong

/**
 * 一次成功输入提交的短时进程内证据。
 *
 * 不写磁盘；只保留一段有界预览供真人确认，完整内容仅以长度和 SHA-256 表示。
 * [readbackVerified] 记录"内容确实落进框里"是否被读回机械验证过；IME-only 降级链下
 * 这是仅剩的落框证据，Enter 门会硬性要求为真（design §3.5）。
 */
data class InputCommitEvidence(
    val commitId: Long,
    val preview: String,
    val length: Int,
    val sha256: String,
    val identity: FocusIdentity,
    val readbackVerified: Boolean,
    val committedAtMs: Long,
    val expiresAtMs: Long,
    /**
     * 已提交内容的**归一明文**（[TextNorm.ocr]），供批准后重建证据时按 OCR 通道比对。
     *
     * 为什么必须是全文而不是 [preview]：预览在 64 字截断并补省略号，拿它当基线，
     * **超过 64 字的内容即使一个字没改也必然判不匹配**——发送后验正是栽在这同一个坑里
     * （测试 marker 18 字恰好绕过，离线真机都测不到）。用户 2026-08-02 题六拍板
     * "把批准的全文留在内存里比对"。
     *
     * **进程内存、不落盘、不进信封/审计/trace**；[toString] 已连同 [preview] 一起脱敏，
     * 因为 data class 的默认 toString 会被异常与日志顺手带走。
     */
    val normalizedText: String = "",
) {
    override fun toString(): String =
        "InputCommitEvidence(commitId=$commitId, len=$length, sha=${sha256.take(12)}, " +
            "identity=$identity, readbackVerified=$readbackVerified, " +
            "preview=<${preview.length}字符>, normalized=<${normalizedText.length}字符>)"

    fun matchesReadableText(text: String): Boolean =
        length == text.length &&
            sha256 == InputCommitEvidence.sha256(text) &&
            preview == InputCommitEvidence.preview(text)

    companion object {
        const val PREVIEW_LIMIT = 64

        fun sha256(text: String): String = MessageDigest.getInstance("SHA-256")
            .digest(text.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }

        internal fun preview(text: String): String =
            if (text.length <= PREVIEW_LIMIT) text else text.take(PREVIEW_LIMIT) + "…"
    }
}

/** 仅持有最近一次提交；身份不匹配或 TTL 到期一律视为无证据。 */
class InputCommitEvidenceStore(
    private val ttlMs: Long = DEFAULT_TTL_MS,
    private val clock: () -> Long = { System.nanoTime() / 1_000_000L },
) {
    private val sequence = AtomicLong()

    @Volatile
    private var latest: InputCommitEvidence? = null

    init {
        require(ttlMs > 0) { "ttlMs 必须大于 0" }
    }

    @Synchronized
    fun record(
        text: String,
        identity: FocusIdentity,
        readbackVerified: Boolean,
    ): InputCommitEvidence {
        val now = clock()
        return InputCommitEvidence(
            commitId = sequence.incrementAndGet(),
            preview = InputCommitEvidence.preview(text),
            length = text.length,
            sha256 = InputCommitEvidence.sha256(text),
            identity = identity,
            readbackVerified = readbackVerified,
            normalizedText = TextNorm.ocr(text),
            committedAtMs = now,
            expiresAtMs = now + ttlMs,
        ).also { latest = it }
    }

    /**
     * 把**已经被人批准过的那份内容**按当前焦点身份重新落成证据（spec §2.4 选项 C）。
     *
     * 为什么需要它：输入证据按焦点身份取，而 IME 会话 id 每次 `onStartInput` 重新生成，
     * 切走再回来必然换身份 → 旧证据取不出来。**不是判据太严，是证据本身不在了。**
     *
     * 三条边界，缺一条这个方法就变成伪造内容的口子：
     * 1. **内容事实一律来自意图**（卡上给人看过的那份），调用方不许传别的；
     * 2. **只有 [EvidenceRebuildPolicy] 判 `Rebuilt` 之后才允许调**——也就是"现在框里的东西
     *    确实还是那份"已经被读回验证过；
     * 3. 它只换身份与新鲜度，**不新开批准、不重置意图的一次性**。
     */
    @Synchronized
    fun rebindApproved(
        sha256: String,
        length: Int,
        preview: String,
        normalizedText: String,
        identity: FocusIdentity,
    ): InputCommitEvidence {
        val now = clock()
        return InputCommitEvidence(
            commitId = sequence.incrementAndGet(),
            preview = preview,
            length = length,
            sha256 = sha256,
            identity = identity,
            // 重建走的正是"读回来确认过还在框里"这条路，与首次提交时 readback 通过是同一件事。
            readbackVerified = true,
            committedAtMs = now,
            expiresAtMs = now + ttlMs,
            normalizedText = normalizedText,
        ).also { latest = it }
    }

    @Synchronized
    fun current(
        identity: FocusIdentity?,
        readableText: String? = null,
    ): InputCommitEvidence? {
        val evidence = latest ?: return null
        if (clock() >= evidence.expiresAtMs) {
            latest = null
            return null
        }
        if (identity == null || evidence.identity != identity) return null
        if (readableText != null && !evidence.matchesReadableText(readableText)) return null
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

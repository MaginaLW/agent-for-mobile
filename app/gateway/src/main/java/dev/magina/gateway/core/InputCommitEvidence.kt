package dev.magina.gateway.core

import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicLong

/**
 * 一次成功输入提交的短时进程内证据。
 *
 * 不写磁盘；只保留一段有界预览供真人确认，完整内容仅以长度和 SHA-256 表示。
 */
data class InputCommitEvidence(
    val commitId: Long,
    val preview: String,
    val length: Int,
    val sha256: String,
    val focusedInputId: String,
    val committedAtMs: Long,
    val expiresAtMs: Long,
) {
    fun matchesReadableText(text: String): Boolean =
        length == text.length &&
            sha256 == InputCommitEvidence.sha256(text) &&
            preview == InputCommitEvidence.preview(text)

    companion object {
        internal const val PREVIEW_LIMIT = 64

        fun sha256(text: String): String = MessageDigest.getInstance("SHA-256")
            .digest(text.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }

        internal fun preview(text: String): String =
            if (text.length <= PREVIEW_LIMIT) text else text.take(PREVIEW_LIMIT) + "…"
    }
}

/** 仅持有最近一次提交；焦点不匹配或 TTL 到期一律视为无证据。 */
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
    fun record(text: String, focusedInputId: String): InputCommitEvidence {
        require(focusedInputId.isNotBlank()) { "focusedInputId 不能为空" }
        val now = clock()
        return InputCommitEvidence(
            commitId = sequence.incrementAndGet(),
            preview = InputCommitEvidence.preview(text),
            length = text.length,
            sha256 = InputCommitEvidence.sha256(text),
            focusedInputId = focusedInputId,
            committedAtMs = now,
            expiresAtMs = now + ttlMs,
        ).also { latest = it }
    }

    @Synchronized
    fun current(
        focusedInputId: String?,
        readableText: String? = null,
    ): InputCommitEvidence? {
        val evidence = latest ?: return null
        if (clock() >= evidence.expiresAtMs) {
            latest = null
            return null
        }
        if (focusedInputId.isNullOrBlank() || evidence.focusedInputId != focusedInputId) return null
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

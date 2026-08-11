package dev.magina.gateway.a11y

import dev.magina.gateway.core.GatewayError
import dev.magina.gateway.core.TextNorm
import org.json.JSONArray
import org.json.JSONObject
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.util.Base64

/**
 * 最终 fresh title 读取的持久化摘要。
 *
 * 候选文字只留下归一后长度与 SHA-256；不保存 OCR 原文、截图或输入内容。几何、来源、候选
 * 序号和选择结果足以回答“哪个框被选中、为什么其余框没被选中”，同时不会把整屏文字复制进
 * trace/audit/manifest。候选数量有固定上限，避免异常 OCR 帧放大证据体积。
 */
internal class SurfaceTitleEvidence private constructor(
    private val payload: JSONObject,
) {
    val auditToken: String = Base64.getUrlEncoder().withoutPadding().encodeToString(
        payload.toString().toByteArray(StandardCharsets.UTF_8),
    )

    fun toJson(): JSONObject = JSONObject(payload.toString()).put("audit_token", auditToken)

    companion object {
        private const val SCHEMA_VERSION = 1
        private const val MAX_PERSISTED_CANDIDATES = 12
        private const val SANITIZED_FAILURE_MESSAGE =
            "最终 fresh 标题或内容无法机械验证；见 error.extra.title_read 脱敏证据"

        fun from(read: SurfaceTitleRead): SurfaceTitleEvidence {
            val last = read.attempts.lastOrNull()
            val all = (last?.candidates.orEmpty() + last?.topCut.orEmpty())
            val selectedOrdinal = selectedOrdinal(last)
            val keptOrdinals = all.indices.take(MAX_PERSISTED_CANDIDATES).toMutableList()
            if (selectedOrdinal != null && selectedOrdinal !in keptOrdinals) {
                if (keptOrdinals.isNotEmpty()) keptOrdinals[keptOrdinals.lastIndex] = selectedOrdinal
                else keptOrdinals += selectedOrdinal
            }
            val candidates = JSONArray()
            keptOrdinals.forEach { ordinal ->
                candidates.put(candidateJson(all[ordinal], ordinal, selectedOrdinal))
            }
            val selected = selectedOrdinal
                ?.takeIf { it in all.indices }
                ?.let { candidateJson(all[it], it, selectedOrdinal) }

            val payload = JSONObject()
                .put("schema_version", SCHEMA_VERSION)
                .put("summary", read.describe())
                .put("selection_reason", if (selected != null) "conversation_surface_policy" else "none")
                .put("candidate_count", all.size)
                .put("candidates_truncated", all.size > keptOrdinals.size)
                .put("selected", selected ?: JSONObject.NULL)
                .put("candidates", candidates)
            return SurfaceTitleEvidence(payload)
        }

        /** 保留既有诊断；若 message 带标题原文则改成固定提示，并只留下 hash/length。 */
        fun attach(error: GatewayError, read: SurfaceTitleRead): GatewayError = attach(error, from(read))

        fun attach(error: GatewayError, evidence: SurfaceTitleEvidence): GatewayError {
            val merged = JSONObject()
            error.extra?.keys()?.forEach { key -> merged.put(key, error.extra.get(key)) }
            merged.put("title_read", evidence.toJson())
            val rawMessage = error.message.orEmpty()
            val redactMessage = rawMessage.contains("标题读回「") || rawMessage.contains("标题只读回「")
            if (redactMessage) {
                merged.put(
                    "title_read_failure",
                    JSONObject()
                        .put("message_length", rawMessage.length)
                        .put("message_sha256", sha256(rawMessage)),
                )
            }
            return GatewayError(
                code = error.code,
                message = if (redactMessage) SANITIZED_FAILURE_MESSAGE else rawMessage,
                channel = error.channel,
                retryable = error.retryable,
                fallback = error.fallback,
                extra = merged,
            )
        }

        /** ToolRegistry 写 audit note 时复用错误信封里的同一份摘要，避免两份判据漂移。 */
        fun auditFields(error: GatewayError): List<String> {
            val title = error.extra?.optJSONObject("title_read") ?: return emptyList()
            return auditFields(title)
        }

        fun auditFields(title: JSONObject): List<String> {
            val summary = title.optString("summary")
            val token = title.optString("audit_token")
            return buildList {
                if (summary.isNotBlank()) add("final_title_read=$summary")
                if (token.matches(Regex("[A-Za-z0-9_-]+"))) add("title_evidence=$token")
            }
        }

        private fun selectedOrdinal(last: SurfaceTitleAttempt?): Int? {
            val title = last?.title ?: return null
            val index = last.candidates.indexOfFirst { candidate ->
                candidate.text == title.text.ifBlank { title.description } &&
                    candidate.bounds == title.bounds && candidate.source == title.source &&
                    candidate.windowId == title.windowId &&
                    candidate.foregroundWindow == title.foregroundWindow && candidate.rejectedBy == null
            }
            return index.takeIf { it >= 0 }
        }

        private fun candidateJson(
            candidate: SurfaceCandidate,
            ordinal: Int,
            selectedOrdinal: Int?,
        ): JSONObject {
            val normalized = TextNorm.label(candidate.text)
            val decision = when {
                ordinal == selectedOrdinal -> "selected"
                candidate.rejectedBy == null -> "eligible_not_selected"
                else -> "rejected_${rejectionCode(candidate.rejectedBy)}"
            }
            return JSONObject()
                .put("ordinal", ordinal)
                .put("source", sourceCode(candidate.source))
                .put(
                    "bounds",
                    "${candidate.bounds.left}:${candidate.bounds.top}:" +
                        "${candidate.bounds.right}:${candidate.bounds.bottom}",
                )
                .put("foreground_window", candidate.foregroundWindow)
                .put("window_id", candidate.windowId ?: JSONObject.NULL)
                .put("normalized_length", normalized.length)
                .put("text_sha256", sha256(normalized))
                .put("decision", decision)
        }

        private fun sourceCode(source: String): String = when (source) {
            ConversationSurfacePolicy.SOURCE_A11Y -> "a11y"
            ConversationSurfacePolicy.SOURCE_OCR -> "ocr"
            ConversationSurfacePolicy.SOURCE_FUSED -> "fused"
            else -> "unknown"
        }

        private fun rejectionCode(reason: String?): String = when (reason) {
            SurfaceCandidate.REJECT_WINDOW -> "window"
            SurfaceCandidate.REJECT_CONFIDENCE -> "confidence"
            SurfaceCandidate.REJECT_BOUNDS -> "bounds"
            SurfaceCandidate.REJECT_EMPTY -> "empty"
            SurfaceCandidate.REJECT_TOP_CUT -> "top_cut"
            else -> "other"
        }

        private fun sha256(value: String): String = MessageDigest.getInstance("SHA-256")
            .digest(value.toByteArray(StandardCharsets.UTF_8))
            .joinToString("") { byte -> "%02x".format(byte) }
    }
}

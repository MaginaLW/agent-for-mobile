package dev.magina.gateway.core

/** a11y 精确内容与 OCR 近似读回必须分开处理，不让 OCR 冒充精确内容。 */
enum class IntentReadbackChannel { A11Y, OCR }

/**
 * 一次新读取的目标与输入；null 表示不可读，不能拿旧证据或意图字段补齐。
 * 两个文本通道分开标注，因为标题与输入可能来自不同通道。仅在内存使用，toString 不输出内容。
 */
data class IntentEvidenceReadback(
    val packageName: String?,
    val targetLabel: String?,
    val content: String?,
    val targetChannel: IntentReadbackChannel,
    val contentChannel: IntentReadbackChannel,
) {
    override fun toString(): String =
        "IntentEvidenceReadback(targetChannel=$targetChannel, contentChannel=$contentChannel)"
}

/** 必须重读两处实际表面，不能写入输入框、导航回原会话或用批准内容覆盖用户后来输入。 */
fun interface IntentEvidenceReader {
    fun read(): IntentEvidenceReadback
}

/**
 * 读回三态；后两态一律不能执行。Rebuilt 也只是语义读回通过，未替代严格证据链或意图存活检查。
 * 此模块不刷新任何旧证据的 TTL，也不在证据仓内安装新记录。
 */
sealed interface EvidenceRebuild {
    data class Rebuilt(
        val packageName: String,
        val targetLabel: String,
        val sha256: String,
        val length: Int,
    ) : EvidenceRebuild

    data class Mismatch(val reason: String) : EvidenceRebuild
    data class Unverified(val reason: String) : EvidenceRebuild
}

/**
 * 基线只能取自人批准的意图，读回永远只能当被检验方。
 * a11y 严格摘要/长度；OCR 按现行决定归一包含并限最多多 4 字，漏识不冒充明确内容变更。
 * OCR 返回批准时的摘要，表示有界近似匹配，并不声称 OCR 逐位读回了原文。
 *
 * 适用范围仅是「送进会话」的动作：press_key(enter)/type_text 与 II 级 ui_action（spec §2.5）。
 * I 级 ui_action 不调用本模块、不制造合成会话，继续走其逐字段复核；档位本身不能代表动作种类。
 * 本结论不是执行授权；有效期仍由 IntentMatchPolicy.isIntentLive 与意图仓独立验证。
 */
object EvidenceRebuildPolicy {
    const val OCR_EXTRA_TOLERANCE = 4

    fun judge(intent: ApprovalIntent, readback: IntentEvidenceReadback): EvidenceRebuild {
        val approvedAt = intent.approvedAtMs ?: return EvidenceRebuild.Unverified("意图尚未获批")
        if (approvedAt < intent.createdAtMs) return EvidenceRebuild.Unverified("意图批准时间早于请求创建")
        if (readback.packageName.isNullOrBlank()) return EvidenceRebuild.Unverified("目标包读不回来")
        if (readback.packageName != intent.targetPackage) return EvidenceRebuild.Mismatch("目标包与批准的不符")
        if (readback.targetLabel.isNullOrBlank()) return EvidenceRebuild.Unverified("目标会话读不回来")
        // 标题带可能混入状态栏或其他候选，即使 a11y 字符串精确，也不能确证用户换了会话。
        when (readback.targetChannel) {
            IntentReadbackChannel.A11Y -> if (readback.targetLabel != intent.targetLabel) {
                return EvidenceRebuild.Unverified("标题读回与已批准会话对不上，无法确认目标会话")
            }
            IntentReadbackChannel.OCR -> when (LabelMatchPolicy.verdict(intent.targetLabel, readback.targetLabel)) {
                LabelMatchPolicy.Verdict.MATCH -> Unit
                LabelMatchPolicy.Verdict.PARTIAL -> return EvidenceRebuild.Unverified("会话标题像漏识，无法确认目标会话")
                LabelMatchPolicy.Verdict.DIFFERENT -> return EvidenceRebuild.Unverified("会话标题归一后不精确相同，无法确认目标会话")
            }
        }
        val content = readback.content
        if (content.isNullOrEmpty()) return EvidenceRebuild.Unverified("输入内容读不回来")
        if (readback.contentChannel == IntentReadbackChannel.OCR) return judgeOcrContent(intent, content)
        val sha256 = InputCommitEvidence.sha256(content)
        if (sha256 != intent.contentSha256 || content.length != intent.contentLength) {
            return EvidenceRebuild.Mismatch("输入内容摘要或长度与批准的不符")
        }
        return EvidenceRebuild.Rebuilt(intent.targetPackage, intent.targetLabel, sha256, content.length)
    }

    private fun judgeOcrContent(intent: ApprovalIntent, content: String): EvidenceRebuild {
        val baseline = intent.ocrBaseline ?: return EvidenceRebuild.Unverified("意图缺少 OCR 归一全文基线")
        if (baseline.sha256 != intent.contentSha256 || baseline.length != intent.contentLength) {
            return EvidenceRebuild.Unverified("意图缺少一致的 OCR 归一全文基线与内容摘要")
        }
        val approved = baseline.normalized
        if (approved.isEmpty()) return EvidenceRebuild.Unverified("批准内容归一后为空，无法比对 OCR")
        val got = TextNorm.ocr(content)
        if (got.isEmpty()) return EvidenceRebuild.Unverified("OCR 输入内容归一后为空")
        val extra = got.length - approved.length
        if (extra > OCR_EXTRA_TOLERANCE) {
            return EvidenceRebuild.Mismatch("OCR 内容多出 $extra 字，超过 $OCR_EXTRA_TOLERANCE 字噪声容差")
        }
        if (!got.contains(approved)) {
            return EvidenceRebuild.Unverified("OCR 内容与批准基线不匹配，可能漏识，读不准不敢放行")
        }
        return EvidenceRebuild.Rebuilt(intent.targetPackage, intent.targetLabel, intent.contentSha256, intent.contentLength)
    }

}

package dev.magina.gateway.core

/**
 * OCR 内容与收件人标题的纯字符规则；从已审候选提取，内容规则与原 OcrEngine.norm 逐字符相同。
 * OcrEngine 继续转发到同一实现，避免生产读回与离线重建分别维护一份归一逻辑。
 */
object TextNorm {
    /** 全角转半角、去空白、小写、o 转 0；保留当前 OCR 内容比对的既有行为。 */
    fun ocr(value: String): String = canonical(value, foldLetterOToZero = true)

    /**
     * 标题只容许明列字符等价；真实收件人 AO 与 A0 不能共享内容 OCR 的 O/0 容差。
     * 分隔符规则来自候选的 LabelMatchPolicy；不允许多字、少字或无界包含来替代标题相等。
     */
    fun label(value: String): String =
        canonical(value, foldLetterOToZero = false).replace(LABEL_PUNCTUATION, "")

    private fun canonical(value: String, foldLetterOToZero: Boolean): String {
        val result = StringBuilder(value.length)
        for (raw in value) {
            var c = raw
            if (c in '！'..'～') c -= 0xFEE0
            if (c == '　' || c.isWhitespace()) continue
            c = c.lowercaseChar()
            if (foldLetterOToZero && c == 'o') c = '0'
            result.append(c)
        }
        return result.toString()
    }

    private val LABEL_PUNCTUATION = Regex("[:·•]")
}

/** 标题归一后必须精确相同；不相同的两个状态只帮助说明读回不确定性，均不放行。 */
internal object LabelMatchPolicy {
    enum class Verdict { MATCH, PARTIAL, DIFFERENT }

    fun verdict(expected: String, got: String): Verdict {
        val want = TextNorm.label(expected)
        val have = TextNorm.label(got)
        if (want.isEmpty() || have.isEmpty()) return Verdict.PARTIAL
        if (want == have) return Verdict.MATCH
        if (want.contains(have)) return Verdict.PARTIAL
        return Verdict.DIFFERENT
    }
}

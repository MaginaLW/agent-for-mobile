package dev.magina.gateway.core

/**
 * 文本归一。**全仓只有这一份**——`OcrEngine.norm` 现在就是 [ocr] 的转发。
 *
 * 提到 `core` 有两个理由，都不是风格：
 *
 * 1. **原来那份归一在 `OcrEngine` 里，而 `OcrEngine` import 了 `android.graphics` 与 ML Kit**，
 *    JVM 离线用例根本加载不了那个类——于是全仓最常被依赖的一条字符规则**一条用例都没有**。
 * 2. 语义意图那条链要在 `core` 里做归一比对（`EvidenceRebuildPolicy` / [LabelMatchPolicy]），
 *    照抄一份就是"判据有两份，迟早只改一份"——归一化本身正是本仓栽过的那族（marker O→0）。
 */
object TextNorm {

    /**
     * OCR 读回比对用的归一：全角→半角、去掉所有空白、小写、`o`→`0`。
     *
     * 逐字符规则与 2026-07 起 `OcrEngine.norm` 的实现**逐字等价**，搬过来时没有改动任何一条。
     */
    fun ocr(value: String): String = canonical(value, foldLetterOToZero = true)

    /**
     * OCR marker 与收件人标签只共享无歧义的字符规则；`O`/`0` 折叠必须由调用域显式选择。
     * marker 有真机 OCR 误识证据，收件人则可能真的分别叫 `AO` 与 `A0`，不能共享该容差。
     */
    private fun canonical(value: String, foldLetterOToZero: Boolean): String {
        val sb = StringBuilder(value.length)
        for (raw in value) {
            var c = raw
            if (c in '！'..'～') c -= 0xFEE0
            if (c == '　' || c.isWhitespace()) continue
            c = c.lowercaseChar()
            if (foldLetterOToZero && c == 'o') c = '0'
            sb.append(c)
        }
        return sb.toString()
    }

    /**
     * 短标签（会话页标题这类）比对用的归一：全角→半角、去空白、小写、去分隔类标点。
     *
     * 多去掉的那几个字符来自 P0 宏原先的 `normalized`（`[\s：:·•]+`）——标题带里 OCR 常把
     * 分隔符识进来。合并之后对 `文件传输助手` 这个实际标签的结果与原实现**完全相同**，
     * 但这里故意不复用 marker 专属的 `O`→`0` 容差：真实收件人 `AO` 与 `A0` 必须不同。
     */
    fun label(value: String): String =
        canonical(value, foldLetterOToZero = false).replace(LABEL_PUNCTUATION, "")

    private val LABEL_PUNCTUATION = Regex("[:·•]")
}

/**
 * 短标签的 fail-closed 比对，**只有归一后精确相等才是正匹配**。
 *
 * 收件人标题不是普通搜索串：`张三` 既可能是单聊，也可能只是 `张三、李四群` 或
 * `张三备份` 的前缀。没有额外、可机械验证的会话身份时，任何无界 `contains` 都可能把另一个
 * 真实会话当成已批准会话。可容忍的边界只限 [TextNorm.label] 明列的字符等价（空白、全角、
 * 大小写与三种分隔符）；归一后多一个、少一个或 `O`/`0` 不同都不放行。
 *
 * 三态仍保留，只为让调用方区分“像漏识”与“其他不相等”，从而给出准确的 Unverified 原因；
 * [MATCH] 本身不再宽松。
 */
internal object LabelMatchPolicy {

    enum class Verdict {
        /** 归一后逐位相同。 */
        MATCH,

        /** 读回是已批准标签的严格子串——像漏识，但绝不构成正匹配。 */
        PARTIAL,

        /** 其他所有不相等（包括“已批准标签 + 尾缀”）；危险发送一律不匹配。 */
        DIFFERENT,
    }

    fun verdict(expected: String, got: String): Verdict {
        val want = TextNorm.label(expected)
        val have = TextNorm.label(got)
        // 空的一侧不构成任何正证据。调用方按"读不回来"处理，别在这里替它下结论。
        if (want.isEmpty() || have.isEmpty()) return Verdict.PARTIAL
        if (have == want) return Verdict.MATCH
        if (want.contains(have)) return Verdict.PARTIAL
        return Verdict.DIFFERENT
    }

    /** 识别用途的"是不是这个标签"，即 [Verdict.MATCH]。 */
    fun matches(expected: String, got: String): Boolean = verdict(expected, got) == Verdict.MATCH
}

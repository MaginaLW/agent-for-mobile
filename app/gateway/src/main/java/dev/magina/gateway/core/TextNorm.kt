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
    fun ocr(value: String): String {
        val sb = StringBuilder(value.length)
        for (raw in value) {
            var c = raw
            if (c in '！'..'～') c -= 0xFEE0
            if (c == '　' || c.isWhitespace()) continue
            c = c.lowercaseChar()
            if (c == 'o') c = '0'
            sb.append(c)
        }
        return sb.toString()
    }

    /**
     * 短标签（会话页标题这类）比对用的归一：[ocr] 之上再去掉分隔类标点。
     *
     * 多去掉的那几个字符来自 P0 宏原先的 `normalized`（`[\s：:·•]+`）——标题带里 OCR 常把
     * 分隔符识进来。合并之后对 `文件传输助手` 这个实际标签的结果与原实现**完全相同**，
     * 多出来的只是"更能容忍噪声"的方向。
     */
    fun label(value: String): String = ocr(value).replace(LABEL_PUNCTUATION, "")

    private val LABEL_PUNCTUATION = Regex("[:·•]")
}

/**
 * 短标签的宽松比对，**三态**。
 *
 * 为什么不是布尔：OCR 读回的标题与"人批准的那个会话"对不上时，有两种物理上分得开的处境——
 *
 * - **读回是批准标签的一部分**（`文件传输` ⊂ `文件传输助手`）：这是**漏识**。本仓实测
 *   「低对比度短文本漏识近四成」，把它判成"你换了会话"就是诬告。
 * - **读回与批准标签互不包含**（`微信` vs `文件传输助手`）：这是**能确证不同的正证据**。
 *
 * 与 `EvidenceRebuildPolicy` 里内容比对的形状刻意一致：`Mismatch` 只留给正证据，
 * 分不开的处境一律落到"判不了"。
 */
internal object LabelMatchPolicy {

    enum class Verdict {
        /** 读回包含已批准的标签（含逐位相同）。 */
        MATCH,

        /** 读回是已批准标签的一部分——像漏识，分不开，不许当成"不符"。 */
        PARTIAL,

        /** 互不包含：能确证是另一个标签。 */
        DIFFERENT,
    }

    fun verdict(expected: String, got: String): Verdict {
        val want = TextNorm.label(expected)
        val have = TextNorm.label(got)
        // 空的一侧不构成任何正证据。调用方按"读不回来"处理，别在这里替它下结论。
        if (want.isEmpty() || have.isEmpty()) return Verdict.PARTIAL
        if (have.contains(want)) return Verdict.MATCH
        if (want.contains(have)) return Verdict.PARTIAL
        return Verdict.DIFFERENT
    }

    /** 识别用途的"是不是这个标签"，即 [Verdict.MATCH]。 */
    fun matches(expected: String, got: String): Boolean = verdict(expected, got) == Verdict.MATCH
}

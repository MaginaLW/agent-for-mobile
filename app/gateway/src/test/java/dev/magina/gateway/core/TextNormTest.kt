package dev.magina.gateway.core

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * 归一化的离线用例。
 *
 * 这条字符规则是全仓最常被依赖的一条（marker 比对、OCR 读回、发送后验、批准后重建都用它），
 * 而在搬进 `core` 之前它住在 `OcrEngine` 里——那个类 import 了 `android.graphics` 与 ML Kit，
 * JVM 用例**加载不了**，于是它一条用例都没有。这个文件是它第一次被钉住。
 */
class TextNormTest {

    @Test
    fun `ocr normalization strips whitespace and folds fullwidth lowercase and letter O`() {
        assertEquals("ab", TextNorm.ocr("a b"))
        assertEquals("ab", TextNorm.ocr("a　b"))
        // 全角 ＡＢ → 半角并小写
        assertEquals("ab", TextNorm.ocr("ＡＢ"))
        // ML Kit 中文模型把数字 0 识成字母 O，两边一起折成 0（Spike S3 实锤）
        assertEquals("p0deny-0", TextNorm.ocr("P0DENY-O"))
    }

    @Test
    fun `label normalization additionally drops separator punctuation`() {
        assertEquals("文件传输助手", TextNorm.label("文件传输助手"))
        assertEquals("文件传输助手", TextNorm.label(" 文件·传输助手 "))
        assertEquals("文件传输助手", TextNorm.label("文件：传输助手"))
        assertEquals("文件传输助手", TextNorm.label("文件•传输 助手"))
    }

    @Test
    fun `label normalization never aliases letter O with digit zero`() {
        assertEquals("ao", TextNorm.label("ＡＯ"))
        assertEquals("a0", TextNorm.label("A0"))
    }

    @Test
    fun `label normalization agrees with ocr normalization on the P0 label`() {
        // 合并两套归一时唯一要保证的事：实际在用的那个标签结果不变。
        assertEquals(TextNorm.ocr("文件传输助手"), TextNorm.label("文件传输助手"))
    }

    @Test
    fun `a longer readback containing the approved label is not a positive match`() {
        // 尾噪「文件传输助手8」与真实会话「张三备份」在字符串层面同形；没有独立会话身份时
        // 不能机械证明前者只是 OCR 噪声，所以必须 fail-closed，而不是用 contains 放行。
        assertEquals(
            LabelMatchPolicy.Verdict.DIFFERENT,
            LabelMatchPolicy.verdict("文件传输助手", "文件传输助手8"),
        )
        // 正匹配的边界是归一后逐位相同。
        assertEquals(
            LabelMatchPolicy.Verdict.MATCH,
            LabelMatchPolicy.verdict("文件传输助手", "文 件·传输助手"),
        )
    }

    @Test
    fun `a readback that is only part of the approved label is partial not different`() {
        // 漏识的形态。判成 DIFFERENT 就是诬告用户"换了会话"。
        assertEquals(
            LabelMatchPolicy.Verdict.PARTIAL,
            LabelMatchPolicy.verdict("文件传输助手", "文件传输"),
        )
    }

    @Test
    fun `two labels that contain neither the other are different`() {
        assertEquals(
            LabelMatchPolicy.Verdict.DIFFERENT,
            LabelMatchPolicy.verdict("文件传输助手", "微信"),
        )
        assertEquals(
            LabelMatchPolicy.Verdict.DIFFERENT,
            LabelMatchPolicy.verdict("文件传输助手", "张三"),
        )
    }

    @Test
    fun `an empty side is never positive evidence of anything`() {
        assertEquals(LabelMatchPolicy.Verdict.PARTIAL, LabelMatchPolicy.verdict("文件传输助手", ""))
        assertEquals(LabelMatchPolicy.Verdict.PARTIAL, LabelMatchPolicy.verdict("", "微信"))
        // 空 contains 空会平凡为真——这条用例就是防它退化成"什么都匹配"。
        assertEquals(LabelMatchPolicy.Verdict.PARTIAL, LabelMatchPolicy.verdict("", ""))
    }
}

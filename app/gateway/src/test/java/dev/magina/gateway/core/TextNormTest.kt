package dev.magina.gateway.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class TextNormTest {
    @Test
    fun `OCR 内容保留现有全角空白大小写与 O 零规则`() {
        assertEquals("p0all0w-123!", TextNorm.ocr("　ＰＯＡＬＬＯＷ - １２３！\t\n"))
        assertEquals("中文🙂,句号。", TextNorm.ocr(" 中文🙂，句号。 "))
    }

    @Test
    fun `标题归一保留真实收件人 O 零差别`() {
        assertNotEquals(TextNorm.label("AO"), TextNorm.label("A0"))
        assertEquals("文件传输助手", TextNorm.label("文 件·传输：助手•"))
    }

    @Test
    fun `标题只有精确归一相同才匹配且空白不构成正证据`() {
        assertEquals(LabelMatchPolicy.Verdict.MATCH, LabelMatchPolicy.verdict("张三", " 张 三 "))
        assertEquals(LabelMatchPolicy.Verdict.PARTIAL, LabelMatchPolicy.verdict("张三", "张"))
        assertEquals(LabelMatchPolicy.Verdict.PARTIAL, LabelMatchPolicy.verdict("张三", " "))
        assertEquals(LabelMatchPolicy.Verdict.PARTIAL, LabelMatchPolicy.verdict("", ""))
        assertEquals(LabelMatchPolicy.Verdict.DIFFERENT, LabelMatchPolicy.verdict("张三", "张三、李四群"))
        assertEquals(LabelMatchPolicy.Verdict.DIFFERENT, LabelMatchPolicy.verdict("张三", "张三备份"))
    }
}

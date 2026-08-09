package dev.magina.gateway.core

import org.junit.Assert.assertEquals
import org.junit.Test

/** 危险发送的收件人标题只能按同一份归一结果精确确认。 */
class RecipientLabelMatchPolicyTest {

    @Test
    fun `exact normalized recipient is the only positive match`() {
        assertEquals(
            LabelMatchPolicy.Verdict.MATCH,
            LabelMatchPolicy.verdict("张三", " 张 三 "),
        )
    }

    @Test
    fun `approved recipient does not match a group whose title starts with that name`() {
        assertEquals(
            LabelMatchPolicy.Verdict.DIFFERENT,
            LabelMatchPolicy.verdict("张三", "张三、李四群"),
        )
    }

    @Test
    fun `approved recipient does not match a backup conversation with the same prefix`() {
        assertEquals(
            LabelMatchPolicy.Verdict.DIFFERENT,
            LabelMatchPolicy.verdict("张三", "张三备份"),
        )
    }

    @Test
    fun `letter O and digit zero remain different recipient identities`() {
        assertEquals(
            LabelMatchPolicy.Verdict.DIFFERENT,
            LabelMatchPolicy.verdict("AO", "A0"),
        )
        assertEquals(
            LabelMatchPolicy.Verdict.DIFFERENT,
            LabelMatchPolicy.verdict("A0", "AO"),
        )
    }
}

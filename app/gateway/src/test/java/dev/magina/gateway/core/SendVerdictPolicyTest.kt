package dev.magina.gateway.core

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * 发送后验判据的红线：
 * 1) 判不了绝不冒充判定——无论冒充成功（谎报已发）还是冒充失败（诱导重试→重复发送）；
 * 2) 超过预览上限的长文本在 OCR 腿必须落 UNVERIFIED，而不是像旧实现那样一律判失败。
 */
class SendVerdictPolicyTest {

    private val identity = FocusIdentity.of(
        "7|com.tencent.mm:id/chat_input|android.widget.EditText|com.tencent.mm|10,20,100,80",
        "ime|0123456789abcdef01234567",
    )!!

    private fun evidence(text: String) = InputCommitEvidence(
        commitId = 1,
        preview = InputCommitEvidence.preview(text),
        length = text.length,
        sha256 = InputCommitEvidence.sha256(text),
        identity = identity,
        readbackVerified = true,
        committedAtMs = 0,
        expiresAtMs = Long.MAX_VALUE,
    )

    @Test
    fun `a11y 读到空输入框判定已发送`() {
        val verdict = SendVerdictPolicy.fromAccessibilityText(evidence("你好世界"), "")
        assertEquals(SendVerification.SENT, verdict.state)
        assertEquals("a11y", verdict.channel)
    }

    @Test
    fun `a11y 读到逐字相同的内容判定未发送`() {
        val verdict = SendVerdictPolicy.fromAccessibilityText(evidence("你好世界"), "你好世界")
        assertEquals(SendVerification.NOT_SENT, verdict.state)
    }

    @Test
    fun `a11y 读到别的内容既不算发送也不算未发送`() {
        val verdict = SendVerdictPolicy.fromAccessibilityText(evidence("你好世界"), "换了别的字")
        assertEquals(SendVerification.UNVERIFIED, verdict.state)
    }

    @Test
    fun `没有已提交证据时两条腿都判不了`() {
        assertEquals(
            SendVerification.UNVERIFIED,
            SendVerdictPolicy.fromAccessibilityText(null, "").state,
        )
        assertEquals(
            SendVerification.UNVERIFIED,
            SendVerdictPolicy.fromOcrReadback(null, "任何东西") { it }.state,
        )
    }

    @Test
    fun `OCR 腿基线仍在输入栏里判定未发送`() {
        val verdict = SendVerdictPolicy.fromOcrReadback(
            evidence("P0ALLOW-ABCDEF"), "噪声 P0ALLOW-ABCDEF 更多噪声",
        ) { it }
        assertEquals(SendVerification.NOT_SENT, verdict.state)
        assertEquals("ocr", verdict.channel)
    }

    /**
     * 关键区分：读到了**非空**文本、其中不含基线，才说明这一轮 OCR 是有效的、而我们的字不在了。
     */
    @Test
    fun `OCR 腿读到其它文字且不含基线才判已发送`() {
        assertEquals(
            SendVerification.SENT,
            SendVerdictPolicy.fromOcrReadback(evidence("P0ALLOW-ABCDEF"), "说点什么...") { it }.state,
        )
    }

    /**
     * 这条曾经写反过：旧实现把 null/空串判成 SENT，理由是"基线不在读回里"。
     * 但这条腿上 null 表示**这一轮什么都没读到**——OCR 零行、ML Kit 抛错被吞、截图撞上过渡帧
     * 或系统节流后的空白帧，全都是 null。把它当成"内容消失了"，就是换了个触发条件的
     * 谎报发送成功，正是这套三态要防的那件事本身。
     */
    @Test
    fun `OCR 腿一个字都没读到必须判不了而不是已发送`() {
        assertEquals(
            SendVerification.UNVERIFIED,
            SendVerdictPolicy.fromOcrReadback(evidence("P0ALLOW-ABCDEF"), null) { it }.state,
        )
        assertEquals(
            SendVerification.UNVERIFIED,
            SendVerdictPolicy.fromOcrReadback(evidence("P0ALLOW-ABCDEF"), "") { it }.state,
        )
        assertEquals(
            SendVerification.UNVERIFIED,
            SendVerdictPolicy.fromOcrReadback(evidence("P0ALLOW-ABCDEF"), "   ") { it }.state,
        )
    }

    /**
     * 旧实现在这里报 E_VERIFY_FAIL 且不可重试：超过 PREVIEW_LIMIT 时证据里只有截断前缀，
     * 基线取不到 → 一律判失败。也就是**长消息即使真的发出去了也一定被判成发送失败**。
     */
    @Test
    fun `超过预览上限的长文本在 OCR 腿判不了而不是判失败`() {
        val long = "长".repeat(InputCommitEvidence.PREVIEW_LIMIT + 1)
        val verdict = SendVerdictPolicy.fromOcrReadback(evidence(long), "输入栏里空空如也") { it }
        assertEquals(SendVerification.UNVERIFIED, verdict.state)
    }

    @Test
    fun `恰好等于预览上限的文本仍可判定`() {
        val exact = "长".repeat(InputCommitEvidence.PREVIEW_LIMIT)
        assertEquals(
            SendVerification.SENT,
            SendVerdictPolicy.fromOcrReadback(evidence(exact), "说点什么...") { it }.state,
        )
    }

    /** 同样长度的文本走 a11y 腿不受影响：那条腿读的是原文，不吃预览截断。 */
    @Test
    fun `超长文本在 a11y 腿照常判定`() {
        val long = "长".repeat(InputCommitEvidence.PREVIEW_LIMIT + 20)
        assertEquals(
            SendVerification.SENT,
            SendVerdictPolicy.fromAccessibilityText(evidence(long), "").state,
        )
        assertEquals(
            SendVerification.NOT_SENT,
            SendVerdictPolicy.fromAccessibilityText(evidence(long), long).state,
        )
    }

    @Test
    fun `基线太短不足以判断内容是否消失`() {
        val verdict = SendVerdictPolicy.fromOcrReadback(evidence("ab"), "") { it }
        assertEquals(SendVerification.UNVERIFIED, verdict.state)
    }

    @Test
    fun `归一化后才比较，OCR 噪声不影响判定`() {
        val normalize: (String) -> String = { it.replace(" ", "").uppercase() }
        val verdict = SendVerdictPolicy.fromOcrReadback(
            evidence("p0allow-abcdef"), ") P0ALLOW - ABCDEF (", normalize,
        )
        assertEquals(SendVerification.NOT_SENT, verdict.state)
    }
}

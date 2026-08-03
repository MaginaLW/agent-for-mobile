package dev.magina.gateway.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 批准后重建证据的纯判据（spec §2.4 选项 C）。
 *
 * 这套用例守的是五条约束里的前三条：**三态分得开**、**基线是卡上那份**、**锚点只认语义**。
 */
class EvidenceRebuildPolicyTest {

    private val text = "P0ALLOW-3479AHKMPT"

    /** 只做大小写与空白归一，语义与 `OcrEngine.norm` 的相关部分一致；生产由调用方传真的那个。 */
    private val norm: (String) -> String = { raw -> raw.filterNot { it.isWhitespace() }.lowercase() }

    private fun intent(
        sha256: String? = InputCommitEvidence.sha256(text),
        length: Int? = text.length,
        normalized: String? = text.lowercase(),
    ) = ApprovalIntent(
        intentId = "intent-1",
        riskTier = RiskTier.RETRACTABLE,
        actionKind = "发送消息",
        targetPackage = "com.tencent.mm",
        targetLabel = "文件传输助手",
        contentSha256 = sha256,
        contentLength = length,
        contentNormalized = normalized,
        createdAtMs = 1_000,
    )

    private fun judge(
        intent: ApprovalIntent = intent(),
        readback: String?,
        channel: String = EvidenceRebuildPolicy.CHANNEL_A11Y,
        surfaceLabel: String? = "文件传输助手",
    ) = EvidenceRebuildPolicy.judge(intent, readback, channel, surfaceLabel, norm)

    private fun judgeOcr(readback: String?, intent: ApprovalIntent = intent()) =
        EvidenceRebuildPolicy.judge(intent, readback, EvidenceRebuildPolicy.CHANNEL_OCR, "文件传输助手", norm)

    // —— 目标会话那一半（2026-08-02 补：它的 TTL 同样是 120s，只重建输入证据等于没重建） ——

    @Test
    fun `unreadable conversation title is unverified not mismatch`() {
        // 读不出标题是通道问题；判成 Mismatch 等于诬告用户换了会话。
        val result = judge(readback = text, surfaceLabel = null)

        assertTrue(result is EvidenceRebuild.Unverified)
        assertTrue((result as EvidenceRebuild.Unverified).reason.contains("目标会话标题读不回来"))
    }

    @Test
    fun `empty conversation title is unverified`() {
        val result = judge(readback = text, surfaceLabel = "")

        assertTrue(result is EvidenceRebuild.Unverified)
    }

    @Test
    fun `a different conversation is a mismatch named in baseline order`() {
        val reason = (judge(readback = text, surfaceLabel = "张三") as EvidenceRebuild.Mismatch).reason

        assertTrue(reason, reason.contains("目标会话与已批准的不符"))
        assertTrue(reason, reason.indexOf("文件传输助手") < reason.indexOf("张三"))
    }

    @Test
    fun `conversation is checked before content`() {
        // 内容对不对，只有在"还在同一个会话"成立之后才有意义。会话都换了还去报内容摘要，
        // 会把现场引到错误的方向。
        val reason = (judge(readback = "别的内容", surfaceLabel = "张三") as EvidenceRebuild.Mismatch).reason

        assertTrue(reason, reason.contains("目标会话"))
        assertTrue(reason, !reason.contains("内容摘要"))
    }

    @Test
    fun `identical readback rebuilds the evidence`() {
        val result = judge(readback = text)

        assertEquals(EvidenceRebuild.Rebuilt(InputCommitEvidence.sha256(text), text.length), result)
    }

    @Test
    fun `unreadable input box is unverified not mismatch`() {
        // 通道故障与"内容被换掉"是两件事。折在一起会让一次 OCR 失败变成对用户的诬告，
        // 而现场只能靠猜到底发生了什么。
        val result = judge(readback = null)

        assertTrue(result is EvidenceRebuild.Unverified)
        assertTrue((result as EvidenceRebuild.Unverified).reason.contains("读不回来"))
    }

    @Test
    fun `empty readback is unverified not a silent pass and not a mismatch`() {
        // OCR 一个字没出，与"框里真没字"，在这条链上分不开。
        // 判成通过就是换了触发条件的谎报成功——`fromOcrReadback` 那次栽的就是这一下，
        // 而且被自己的用例固化成了预期行为。
        val result = judge(readback = "")

        assertTrue(result is EvidenceRebuild.Unverified)
        assertTrue((result as EvidenceRebuild.Unverified).reason.contains("为空"))
    }

    @Test
    fun `changed content is a mismatch that names both sides in baseline order`() {
        val result = judge(readback = "P0ALLOW-XXXXXXXXXX")

        val reason = (result as EvidenceRebuild.Mismatch).reason
        // 基线在前、读回来的在后：方向本身就是判据的一部分。
        val expectedPrefix = InputCommitEvidence.sha256(text).take(12)
        val actualPrefix = InputCommitEvidence.sha256("P0ALLOW-XXXXXXXXXX").take(12)
        assertTrue(reason, reason.indexOf(expectedPrefix) < reason.indexOf(actualPrefix))
    }

    @Test
    fun `readback can never become its own baseline`() {
        // 反例形态：假如实现把"读回来的串"当基线，下面这次比较会平凡成立。
        // 它必须失败——基线只能是卡上给人看过的那一份。
        val approved = intent(sha256 = InputCommitEvidence.sha256("卡上给人看过的内容"))

        val result = judge(intent = approved, readback = "现在框里的内容")

        assertTrue(result is EvidenceRebuild.Mismatch)
    }

    @Test
    fun `length mismatch is reported even when it cannot happen with a matching digest`() {
        // 摘要相同、长度不同在密码学上不该发生；写这条是因为"两项都比"是判据的定义，
        // 而不是因为它常见——判据的完整性不该靠"不会发生"来维持。
        val result = judge(intent = intent(length = text.length + 1), readback = text)

        assertTrue((result as EvidenceRebuild.Mismatch).reason.contains("长度"))
    }

    @Test
    fun `intent without locked content cannot be rebuilt`() {
        val result = judge(intent = intent(sha256 = null, length = null), readback = text)

        assertTrue(result is EvidenceRebuild.Unverified)
    }

    @Test
    fun `channel is carried into every verdict so the field can tell which link failed`() {
        val unverified = judge(readback = null, channel = "a11y")
        val mismatch = judge(readback = "别的内容", channel = "a11y")

        assertTrue((unverified as EvidenceRebuild.Unverified).reason.contains("a11y"))
        assertTrue((mismatch as EvidenceRebuild.Mismatch).reason.contains("a11y"))
    }

    // —— OCR 通道：判据必须与通道的物理特性相称（题六拍板后新增） ——

    @Test
    fun `ocr readback that differs only in case and spacing still rebuilds`() {
        // 这就是缺口本身：OCR 读回从来不逐位相同，拿 sha256 相等去要求它就是在诬告用户。
        val result = judgeOcr("p0allow - 3479AHKMPT".uppercase())

        assertTrue(result.toString(), result is EvidenceRebuild.Rebuilt)
    }

    @Test
    fun `ocr readback with extra content beyond noise is a mismatch`() {
        // contains 比 equals 弱，而弱的方向正好是"发得比批准的多"：微信发的是整框内容。
        val result = judgeOcr("$text 另外再说一句话")

        assertTrue((result as EvidenceRebuild.Mismatch).reason.contains("多出"))
    }

    @Test
    fun `ocr readback missing a character is unverified not mismatch`() {
        // 漏识与真被改过在 OCR-only 链上物理不可分，而分不开的两种处境不许长成同一个名字。
        // "我读不准，不敢放行" ≠ "我确认你改过"。
        val result = judgeOcr(text.replace("A", ""))

        assertTrue(result.toString(), result is EvidenceRebuild.Unverified)
        assertTrue((result as EvidenceRebuild.Unverified).reason.contains("读不准"))
    }

    @Test
    fun `ocr channel without normalized plaintext cannot rebuild`() {
        val result = judgeOcr(text, intent = intent(normalized = null))

        assertTrue((result as EvidenceRebuild.Unverified).reason.contains("归一明文"))
    }

    @Test
    fun `a11y channel still demands exact equality`() {
        // a11y 读到的是精确文本，逐位相等**可以满足**，也就还是最强的判据——不该跟着放宽。
        val result = judge(readback = text.replace("A", ""), channel = EvidenceRebuildPolicy.CHANNEL_A11Y)

        assertTrue(result is EvidenceRebuild.Mismatch)
    }

    @Test
    fun `approved plaintext never appears in the intent toString`() {
        // data class 默认 toString 会把每个字段打出来，而它会被异常与日志顺手带走。
        val rendered = intent(normalized = "这是一条不该出现在日志里的消息").toString()

        assertTrue(rendered, !rendered.contains("不该出现在日志里"))
        assertTrue(rendered, rendered.contains("字符>"))
    }
}

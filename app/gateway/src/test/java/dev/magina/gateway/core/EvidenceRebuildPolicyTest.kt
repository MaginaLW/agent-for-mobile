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

    private fun intent(
        sha256: String? = InputCommitEvidence.sha256(text),
        length: Int? = text.length,
    ) = ApprovalIntent(
        intentId = "intent-1",
        riskTier = RiskTier.RETRACTABLE,
        actionKind = "发送消息",
        targetPackage = "com.tencent.mm",
        targetLabel = "文件传输助手",
        contentSha256 = sha256,
        contentLength = length,
        createdAtMs = 1_000,
    )

    @Test
    fun `identical readback rebuilds the evidence`() {
        val result = EvidenceRebuildPolicy.judge(intent(), text, "ocr")

        assertEquals(EvidenceRebuild.Rebuilt(InputCommitEvidence.sha256(text), text.length), result)
    }

    @Test
    fun `unreadable input box is unverified not mismatch`() {
        // 通道故障与"内容被换掉"是两件事。折在一起会让一次 OCR 失败变成对用户的诬告，
        // 而现场只能靠猜到底发生了什么。
        val result = EvidenceRebuildPolicy.judge(intent(), null, "ocr")

        assertTrue(result is EvidenceRebuild.Unverified)
        assertTrue((result as EvidenceRebuild.Unverified).reason.contains("读不回来"))
    }

    @Test
    fun `empty readback is unverified not a silent pass and not a mismatch`() {
        // OCR 一个字没出，与"框里真没字"，在这条链上分不开。
        // 判成通过就是换了触发条件的谎报成功——`fromOcrReadback` 那次栽的就是这一下，
        // 而且被自己的用例固化成了预期行为。
        val result = EvidenceRebuildPolicy.judge(intent(), "", "ocr")

        assertTrue(result is EvidenceRebuild.Unverified)
        assertTrue((result as EvidenceRebuild.Unverified).reason.contains("为空"))
    }

    @Test
    fun `changed content is a mismatch that names both sides in baseline order`() {
        val result = EvidenceRebuildPolicy.judge(intent(), "P0ALLOW-XXXXXXXXXX", "ocr")

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

        val result = EvidenceRebuildPolicy.judge(approved, "现在框里的内容", "ocr")

        assertTrue(result is EvidenceRebuild.Mismatch)
    }

    @Test
    fun `length mismatch is reported even when it cannot happen with a matching digest`() {
        // 摘要相同、长度不同在密码学上不该发生；写这条是因为"两项都比"是判据的定义，
        // 而不是因为它常见——判据的完整性不该靠"不会发生"来维持。
        val result = EvidenceRebuildPolicy.judge(intent(length = text.length + 1), text, "ocr")

        assertTrue((result as EvidenceRebuild.Mismatch).reason.contains("长度"))
    }

    @Test
    fun `intent without locked content cannot be rebuilt`() {
        val result = EvidenceRebuildPolicy.judge(intent(sha256 = null, length = null), text, "ocr")

        assertTrue(result is EvidenceRebuild.Unverified)
    }

    @Test
    fun `channel is carried into every verdict so the field can tell which link failed`() {
        val unverified = EvidenceRebuildPolicy.judge(intent(), null, "a11y")
        val mismatch = EvidenceRebuildPolicy.judge(intent(), "别的内容", "a11y")

        assertTrue((unverified as EvidenceRebuild.Unverified).reason.contains("a11y"))
        assertTrue((mismatch as EvidenceRebuild.Mismatch).reason.contains("a11y"))
    }
}

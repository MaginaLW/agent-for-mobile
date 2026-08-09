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
        targetLabel: String = "文件传输助手",
    ) = ApprovalIntent(
        intentId = "intent-1",
        riskTier = RiskTier.RETRACTABLE,
        actionKind = "发送消息",
        targetPackage = "com.tencent.mm",
        targetLabel = targetLabel,
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
        surfaceChannel: String = channel,
    ) = EvidenceRebuildPolicy.judge(intent, readback, channel, surfaceLabel, norm, surfaceChannel)

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
    fun `letter O and digit zero identify different approved conversations`() {
        val result = judge(
            intent = intent(targetLabel = "AO"),
            readback = text,
            surfaceLabel = "A0",
            surfaceChannel = EvidenceRebuildPolicy.CHANNEL_OCR,
        )

        assertTrue(result.toString(), result is EvidenceRebuild.Unverified)
    }

    @Test
    fun `a title we cannot relate to the approved label is unverified, never an accusation`() {
        // **2026-08-09 第四跑：这条用例此前钉的是相反的行为。**
        // 用户全程没换过会话，网关把状态栏上每秒都在跳的实时网速读成了标题，
        // 于是告诉他「目标会话与已批准的不符：文件传输助手 → 7.70KB/s」。
        //
        // 判别式是「我能不能证明这是读错了」。标题通道**结构上给不出正证据**：带里可能
        // 同时站着多个候选、可能混进别的窗口、OCR 还会漏识多识。读回与已批准标签毫无关系时，
        // **更可能是我读错了，而不是他换了会话**——两者在这条通道上分不开，
        // 而分不开的两种处境不许长成同一个名字，更不许挑那个指责用户的名字。
        val result = judge(readback = text, surfaceLabel = "7.70KB/s")

        assertTrue(result.toString(), result is EvidenceRebuild.Unverified)
        val reason = (result as EvidenceRebuild.Unverified).reason
        assertTrue(reason, reason.contains("7.70KB/s"))
        assertTrue(reason, reason.contains("文件传输助手"))
        // 那句话里**不许出现"你换了会话"这个断言**。
        assertTrue(reason, reason.contains("不等于你换了会话"))
    }

    @Test
    fun `the surface check never produces a mismatch on either channel`() {
        // 这一条比上面那条更强：**不是"这个例子不判 Mismatch"，是标题这一处根本不产出它。**
        // 只钉一个例子的话，下次有人为某个"看起来能确证"的情形加回 Mismatch 分支，
        // 用例照样全绿——而那正是同一个伤害的下一次发作。
        for (label in listOf("7.70KB/s", "张三", "微信", "0.10 KB/s", "▲ 12:04")) {
            for (channel in listOf(EvidenceRebuildPolicy.CHANNEL_A11Y, EvidenceRebuildPolicy.CHANNEL_OCR)) {
                val result = judge(readback = text, surfaceLabel = label, surfaceChannel = channel)
                assertTrue("$channel/$label → $result", result !is EvidenceRebuild.Mismatch)
            }
        }
    }

    @Test
    fun `conversation is checked before content`() {
        // 内容对不对，只有在"还在同一个会话"成立之后才有意义。会话都判不了还去报内容摘要，
        // 会把现场引到错误的方向。
        val result = judge(readback = "别的内容", surfaceLabel = "张三")
        val reason = (result as EvidenceRebuild.Unverified).reason

        assertTrue(reason, reason.contains("已批准会话"))
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

    // —— 会话标题同样要两档比对（装配时才暴露：微信这条链上标题也只有 OCR 一条腿） ——

    private fun judgeTitleOcr(surfaceLabel: String?) = EvidenceRebuildPolicy.judge(
        intent = intent(),
        readback = text,
        channel = EvidenceRebuildPolicy.CHANNEL_A11Y,
        surfaceLabel = surfaceLabel,
        normalize = norm,
        surfaceChannel = EvidenceRebuildPolicy.CHANNEL_OCR,
    )

    @Test
    fun `ocr title with ambiguous tail noise is unverified rather than approved`() {
        // 「文件传输助手8」可能是 OCR 尾噪，也可能是真实的另一个会话；没有独立正证据时
        // 不能机械区分。Unverified 既不放行，也不诬告用户换了会话。
        val result = judgeTitleOcr("文件传输助手8")

        assertTrue(result.toString(), result is EvidenceRebuild.Unverified)
        assertTrue((result as EvidenceRebuild.Unverified).reason.contains("不精确相同"))
    }

    @Test
    fun `ocr title read as only part of the approved label is unverified not mismatch`() {
        val result = judgeTitleOcr("文件传输")

        assertTrue(result.toString(), result is EvidenceRebuild.Unverified)
        assertTrue((result as EvidenceRebuild.Unverified).reason.contains("像漏识"))
    }

    @Test
    fun `ocr title that shares nothing with the approved label still blocks, but as unverified`() {
        // **它仍然一步都不放行**——backlog §8 否决选项 B 的理由（包名一致而标题不校验，
        // 等于可能把已批准的内容发进另一个会话）一个字没变。变的只是那句话与错误码：
        // 从「你换了会话」(`E_STALE_REF`) 变成「我没敢认」(`E_VERIFY_FAIL`)。
        val result = judgeTitleOcr("微信")

        assertTrue(result.toString(), result is EvidenceRebuild.Unverified)
        assertTrue((result as EvidenceRebuild.Unverified).reason.contains("文件传输助手"))
    }

    @Test
    fun `title and content channels are judged independently`() {
        // 标题多半来自屏幕识别，而输入框在 a11y 可读的 App 上能拿到精确文本。混成一个通道
        // 会二选一地出错：按 a11y 比 OCR 读回是诬告，按 OCR 比 a11y 读回是白白放宽。
        val looseTitleStrictContent = EvidenceRebuildPolicy.judge(
            intent = intent(),
            readback = text.replace("A", ""),
            channel = EvidenceRebuildPolicy.CHANNEL_A11Y,
            surfaceLabel = "文 件·传输助手",
            normalize = norm,
            surfaceChannel = EvidenceRebuildPolicy.CHANNEL_OCR,
        )
        // 标题只用了明列的字符归一且精确相等；内容仍按 a11y 的逐位相等判。
        assertTrue(looseTitleStrictContent.toString(), looseTitleStrictContent is EvidenceRebuild.Mismatch)
        assertTrue(
            (looseTitleStrictContent as EvidenceRebuild.Mismatch).reason.contains("内容摘要"),
        )
    }

    @Test
    fun `surface channel defaults to the content channel`() {
        // 不传 surfaceChannel 时跟随内容通道：a11y 对原文逐位相等；OCR 则允许明列的字符归一，
        // 但归一之后仍必须逐位相同。两档差别用空白/分隔符构造，不再靠无界尾噪 tolerance。
        val normalizedEquivalent = "文 件·传输助手"
        val strict = judge(readback = text, surfaceLabel = normalizedEquivalent)
        assertTrue(strict.toString(), strict is EvidenceRebuild.Unverified)

        val normalizedExact = judge(
            readback = text,
            surfaceLabel = normalizedEquivalent,
            surfaceChannel = EvidenceRebuildPolicy.CHANNEL_OCR,
        )
        assertTrue(normalizedExact.toString(), normalizedExact is EvidenceRebuild.Rebuilt)
    }

    @Test
    fun `approved plaintext never appears in the intent toString`() {
        // data class 默认 toString 会把每个字段打出来，而它会被异常与日志顺手带走。
        val rendered = intent(normalized = "这是一条不该出现在日志里的消息").toString()

        assertTrue(rendered, !rendered.contains("不该出现在日志里"))
        assertTrue(rendered, rendered.contains("字符>"))
    }
}

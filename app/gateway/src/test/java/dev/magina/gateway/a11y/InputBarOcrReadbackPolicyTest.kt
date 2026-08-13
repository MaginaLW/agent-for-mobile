package dev.magina.gateway.a11y

import dev.magina.gateway.core.ApprovalIntent
import dev.magina.gateway.core.EvidenceRebuild
import dev.magina.gateway.core.EvidenceRebuildPolicy
import dev.magina.gateway.core.InputCommitEvidence
import dev.magina.gateway.core.RiskTier
import dev.magina.gateway.core.TextNorm
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class InputBarOcrReadbackPolicyTest {
    private val marker = "P0ALLOW-3479AHKMPTXY"
    private val normalize: (String) -> String = TextNorm::ocr

    private fun line(
        text: String,
        confidence: Float = 0.8f,
        left: Int = 10,
        top: Int = 10,
        right: Int = 310,
        bottom: Int = 60,
    ) = InputBarOcrLine(text, confidence, OcrBox(left, top, right, bottom))

    private fun compose(vararg lines: InputBarOcrLine): String? =
        InputBarOcrReadbackPolicy.compose(lines.toList(), normalize)

    private fun judge(readback: String?): EvidenceRebuild = EvidenceRebuildPolicy.judge(
        intent = ApprovalIntent(
            intentId = "input-overlap",
            riskTier = RiskTier.IRREVERSIBLE,
            actionKind = "send",
            targetPackage = "com.tencent.mm",
            targetLabel = "文件传输助手",
            contentSha256 = InputCommitEvidence.sha256(marker),
            contentLength = marker.length,
            contentNormalized = TextNorm.ocr(marker),
            createdAtMs = 1_000,
        ),
        readback = readback,
        channel = EvidenceRebuildPolicy.CHANNEL_OCR,
        surfaceLabel = "文件传输助手",
        normalize = normalize,
        surfaceChannel = EvidenceRebuildPolicy.CHANNEL_OCR,
    )

    @Test
    fun `现场同一 marker 的重叠替代识别只保留信息更完整的一行`() {
        val high = line(") $marker", confidence = 0.93f)
        val low = line(")) $marker", confidence = 0.71f, left = 12, top = 11, right = 312, bottom = 61)

        val readback = compose(low, high)

        assertEquals(low.text, readback)
        assertTrue(judge(readback) is EvidenceRebuild.Rebuilt)
    }

    @Test
    fun `归一结果相同时才用置信度选择`() {
        val high = line("P0ALL0W-3479AHKMPTXY", confidence = 0.93f)
        val low = line(marker, confidence = 0.71f, left = 12, top = 11, right = 312, bottom = 61)

        assertEquals(high.text, compose(low, high))
    }

    @Test
    fun `三成员 clique 在任意输入排列下都保留全局最长候选`() {
        val shortest = line(marker, confidence = 0.99f)
        val middle = line(") $marker", confidence = 0.80f, left = 11, top = 11, right = 311, bottom = 61)
        val longest = line(")) $marker", confidence = 0.61f, left = 12, top = 12, right = 312, bottom = 62)
        val permutations = listOf(
            arrayOf(shortest, middle, longest),
            arrayOf(shortest, longest, middle),
            arrayOf(middle, shortest, longest),
            arrayOf(middle, longest, shortest),
            arrayOf(longest, shortest, middle),
            arrayOf(longest, middle, shortest),
        )

        permutations.forEach { assertEquals(longest.text, compose(*it)) }
    }

    @Test
    fun `较长候选含超容差额外内容时不能被高置信 marker 子串覆盖`() {
        val approvedOnly = line(marker, confidence = 0.97f)
        val withExtra = line(
            "$marker-UNAPPROVED",
            confidence = 0.61f,
            left = 12,
            top = 11,
            right = 312,
            bottom = 61,
        )

        val readback = compose(withExtra, approvedOnly)

        assertEquals(withExtra.text, readback)
        assertTrue(judge(readback) is EvidenceRebuild.Mismatch)
    }

    @Test
    fun `非传递重叠链不能借中间候选吞掉两端的真实重复`() {
        val left = line(marker, confidence = 0.80f, left = 0, right = 300)
        val bridge = line(marker, confidence = 0.97f, left = 100, right = 400)
        val right = line(marker, confidence = 0.72f, left = 200, right = 500)

        val expected = "$marker $marker $marker"
        assertEquals(expected, compose(left, bridge, right))
        assertEquals(expected, compose(right, bridge, left))
        assertTrue(judge(compose(left, bridge, right)) is EvidenceRebuild.Mismatch)
    }

    @Test
    fun `不重叠的相同 marker 必须保留两行并继续触发长度门`() {
        val first = line(marker, top = 10, bottom = 50)
        val second = line(marker, top = 70, bottom = 110)

        val readback = compose(second, first)

        assertEquals("$marker $marker", readback)
        val verdict = judge(readback)
        assertTrue(verdict.toString(), verdict is EvidenceRebuild.Mismatch)
    }

    @Test
    fun `几何重叠但语义无关的文本不能仅凭位置被吞掉`() {
        val markerLine = line(marker, confidence = 0.92f)
        val other = line("OTHER-CONTENT", confidence = 0.75f, left = 12, top = 11, right = 312, bottom = 61)

        val readback = compose(markerLine, other)

        assertTrue(readback.orEmpty().contains(marker))
        assertTrue(readback.orEmpty().contains("OTHER-CONTENT"))
        assertTrue(judge(readback) is EvidenceRebuild.Mismatch)
    }

    @Test
    fun `IoU 不足阈值的同文必须保留而恰好达到阈值才可折叠`() {
        val first = line(marker, confidence = 0.91f)
        val belowThreshold = line(
            marker,
            confidence = 0.72f,
            left = 111,
            right = 411,
        )
        val atThreshold = line(
            marker,
            confidence = 0.72f,
            left = 110,
            right = 410,
        )

        assertEquals("$marker $marker", compose(first, belowThreshold))
        assertEquals(marker, compose(first, atThreshold))
    }

    @Test
    fun `规范化后不足两字的重叠候选不能被折叠`() {
        val upper = line("A", confidence = 0.91f)
        val lower = line("a", confidence = 0.72f, left = 12, top = 11, right = 312, bottom = 61)

        assertEquals("A a", compose(lower, upper))
    }

    @Test
    fun `非重复行按 top 再 left 稳定排序`() {
        val bottom = line("BOTTOM", left = 10, top = 80, right = 110, bottom = 110)
        val topRight = line("RIGHT", left = 140, top = 10, right = 240, bottom = 40)
        val topLeft = line("LEFT", left = 10, top = 10, right = 110, bottom = 40)

        assertEquals("LEFT RIGHT BOTTOM", compose(bottom, topRight, topLeft))
    }

    @Test
    fun `空候选返回 null`() {
        assertNull(compose())
        assertTrue(judge(null) is EvidenceRebuild.Unverified)

        val partial = marker.dropLast(3)
        assertEquals(partial, compose(line(partial)))
        assertTrue(judge(partial) is EvidenceRebuild.Unverified)
    }
}

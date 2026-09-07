package dev.magina.gateway.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class EvidenceRebuildTest {
    private val intent = IntentApprovalFixtures.intent().copy(approvedAtMs = 1_000)
    private val readback = IntentApprovalFixtures.readback()

    private fun judge(observed: IntentEvidenceReadback = readback) = EvidenceRebuildPolicy.judge(intent, observed)

    @Test
    fun `两处精确读回逐项等于确认卡摘要才能产出完整重建结论`() {
        assertEquals(EvidenceRebuild.Rebuilt(
            intent.targetPackage, intent.targetLabel, intent.contentSha256, intent.contentLength,
        ), judge())
    }

    @Test
    fun `尚未获批不能重建`() {
        assertTrue(EvidenceRebuildPolicy.judge(intent.copy(approvedAtMs = null), readback) is EvidenceRebuild.Unverified)
        assertTrue(EvidenceRebuildPolicy.judge(intent.copy(approvedAtMs = intent.createdAtMs - 1), readback)
            is EvidenceRebuild.Unverified)
    }

    @Test
    fun `目标包会话和内容任一读不到均为无法验证`() {
        val unreadable = listOf(
            readback.copy(packageName = null),
            readback.copy(packageName = ""),
            readback.copy(targetLabel = null),
            readback.copy(targetLabel = ""),
            readback.copy(content = null),
            readback.copy(content = ""),
        )
        unreadable.forEach { assertTrue(judge(it) is EvidenceRebuild.Unverified) }
    }

    @Test
    fun `明确不同的包被判不匹配但标题不确定不能诬告换了会话`() {
        assertTrue(judge(readback.copy(packageName = "different.package")) is EvidenceRebuild.Mismatch)
        assertTrue(judge(readback.copy(targetLabel = "另一个会话")) is EvidenceRebuild.Unverified)
    }

    @Test
    fun `内容长一点短一点或等长替换都不匹配`() {
        for (content in listOf(
            IntentApprovalFixtures.CONTENT + "追加",
            IntentApprovalFixtures.CONTENT.dropLast(1),
            "早" + IntentApprovalFixtures.CONTENT.drop(1),
        )) {
            assertTrue(judge(readback.copy(content = content)) is EvidenceRebuild.Mismatch)
        }
    }

    @Test
    fun `摘要相同但意图长度错误也不得通过`() {
        val inconsistent = intent.copy(contentLength = intent.contentLength + 1)
        assertTrue(EvidenceRebuildPolicy.judge(inconsistent, readback) is EvidenceRebuild.Mismatch)
    }

    @Test
    fun `精确通道不通过归一包含消掉空格标点或额外内容`() {
        assertTrue(judge(readback.copy(content = " " + IntentApprovalFixtures.CONTENT)) is EvidenceRebuild.Mismatch)
        assertTrue(judge(readback.copy(content = IntentApprovalFixtures.CONTENT.replace("，", ","))) is EvidenceRebuild.Mismatch)
        assertTrue(judge(readback.copy(targetLabel = intent.targetLabel + "备份")) is EvidenceRebuild.Unverified)
    }

    @Test
    fun `OCR 没有归一全文基线不能拿预览充当全文`() {
        val noBaseline = intent.copy(ocrBaseline = null)
        assertTrue(EvidenceRebuildPolicy.judge(noBaseline, readback.copy(contentChannel = IntentReadbackChannel.OCR))
            is EvidenceRebuild.Unverified)
    }

    @Test
    fun `预览不能替代已批准的完整摘要基线`() {
        val misleadingPreview = intent.copy(preview = "实际是另一条预览")
        assertTrue(EvidenceRebuildPolicy.judge(misleadingPreview, readback) is EvidenceRebuild.Rebuilt)
        assertTrue(EvidenceRebuildPolicy.judge(misleadingPreview, readback.copy(content = misleadingPreview.preview))
            is EvidenceRebuild.Mismatch)
    }

    @Test
    fun `读回对象和不匹配理由不输出私密内容`() {
        val privateInput = "private-input-marker"
        val observed = readback.copy(content = privateInput)
        assertFalse(observed.toString().contains(privateInput))
        assertFalse(judge(observed).toString().contains(privateInput))
    }

    @Test
    fun `OCR 内容归一包含且最多多四字可重建批准摘要`() {
        val content = "P0ALLOW-3479"
        val approved = intent.copy(
            contentSha256 = InputCommitEvidence.sha256(content),
            contentLength = content.length,
            ocrBaseline = IntentOcrBaseline.fromContent(content),
        )
        for (extra in 0..4) {
            val observed = readback.copy(content = "  ｐＯａｌｌｏｗ - 3479 " + "字".repeat(extra),
                contentChannel = IntentReadbackChannel.OCR)
            assertEquals(EvidenceRebuild.Rebuilt(
                approved.targetPackage, approved.targetLabel, approved.contentSha256, approved.contentLength,
            ), EvidenceRebuildPolicy.judge(approved, observed))
        }
    }

    @Test
    fun `OCR 超四字无论是否包含原文都不能放行`() {
        val ocr = readback.copy(contentChannel = IntentReadbackChannel.OCR)
        val normalized = checkNotNull(intent.contentNormalized)
        for (content in listOf(normalized + "新增五个字", "替".repeat(normalized.length + 5))) {
            assertTrue(judge(ocr.copy(content = content)) is EvidenceRebuild.Mismatch)
        }
    }

    @Test
    fun `OCR 少字等长替换及未包含但四字内的差异只能无法验证`() {
        val normalized = checkNotNull(intent.contentNormalized)
        for (content in listOf(normalized.dropLast(1), "改" + normalized.drop(1), "替".repeat(normalized.length + 4))) {
            assertTrue(judge(readback.copy(content = content, contentChannel = IntentReadbackChannel.OCR))
                is EvidenceRebuild.Unverified)
        }
    }

    @Test
    fun `OCR 空白内容及空归一基线不能利用包含空串放行`() {
        val ocr = readback.copy(contentChannel = IntentReadbackChannel.OCR)
        assertTrue(judge(ocr.copy(content = " \t\n　")) is EvidenceRebuild.Unverified)
        for (content in listOf("", " \t\n　")) {
            val baseline = IntentOcrBaseline.fromContent(content)
            val blankIntent = intent.copy(ocrBaseline = baseline, contentSha256 = baseline.sha256, contentLength = baseline.length)
            assertTrue(EvidenceRebuildPolicy.judge(blankIntent, ocr)
                is EvidenceRebuild.Unverified)
        }
    }

    @Test
    fun `OCR 不能在内容摘要缺失或格式不合法时制造重建证据`() {
        for (sha in listOf("", "invalid")) {
            assertTrue(EvidenceRebuildPolicy.judge(intent.copy(contentSha256 = sha),
                readback.copy(contentChannel = IntentReadbackChannel.OCR)) is EvidenceRebuild.Unverified)
        }
    }

    @Test
    fun `OCR 标题仅明列字符归一精确相等且返回已批准会话名`() {
        val observed = readback.copy(targetLabel = "文 件·传输：助手", targetChannel = IntentReadbackChannel.OCR)
        val result = judge(observed)
        assertTrue(result is EvidenceRebuild.Rebuilt)
        assertEquals(intent.targetLabel, (result as EvidenceRebuild.Rebuilt).targetLabel)
        for (label in listOf("文件传输", "文件传输助手8", "文件传输助手备份", "7.70KB/s")) {
            assertTrue(judge(observed.copy(targetLabel = label)) is EvidenceRebuild.Unverified)
        }
    }

    @Test
    fun `会话标题的 O 与零不能采用内容 OCR 的等价规则`() {
        val ao = intent.copy(targetLabel = "AO")
        val observed = readback.copy(targetLabel = "A0", targetChannel = IntentReadbackChannel.OCR)
        assertTrue(EvidenceRebuildPolicy.judge(ao, observed) is EvidenceRebuild.Unverified)
    }

    @Test
    fun `两个读回通道互不放宽且先验会话再验内容`() {
        val approximateTitle = readback.copy(targetLabel = "文 件·传输助手", targetChannel = IntentReadbackChannel.OCR)
        assertTrue(judge(approximateTitle.copy(content = " " + IntentApprovalFixtures.CONTENT)) is EvidenceRebuild.Mismatch)
        val exactTitle = approximateTitle.copy(targetChannel = IntentReadbackChannel.A11Y, contentChannel = IntentReadbackChannel.OCR)
        assertTrue(judge(exactTitle.copy(content = "不同的内容")) is EvidenceRebuild.Unverified)
    }

    @Test
    fun `新增归一明文和已有预览不会从意图字符串泄漏`() {
        val privateIntent = intent.copy(preview = "private-preview-marker",
            ocrBaseline = IntentOcrBaseline.fromContent("private-normalized-marker"))
        val normalized = checkNotNull(privateIntent.contentNormalized)
        assertFalse(privateIntent.toString().contains("private-preview-marker"))
        assertFalse(privateIntent.toString().contains(normalized))
        assertFalse(privateIntent.toString().contains(privateIntent.intentId))
        assertFalse(privateIntent.ocrBaseline.toString().contains(normalized))
    }

    @Test
    fun `另一份归一全文不能搭配原意图摘要制造重建成功`() {
        for (replacement in listOf("x", "替".repeat(intent.contentLength))) {
            val forged = intent.copy(ocrBaseline = IntentOcrBaseline.fromContent(replacement))
            val observed = readback.copy(content = replacement, contentChannel = IntentReadbackChannel.OCR)
            assertTrue(EvidenceRebuildPolicy.judge(forged, observed) is EvidenceRebuild.Unverified)
        }
    }

    @Test
    fun `OCR 基线长度与意图长度不符时也不得通过`() {
        val observed = readback.copy(contentChannel = IntentReadbackChannel.OCR)
        assertTrue(EvidenceRebuildPolicy.judge(intent.copy(contentLength = intent.contentLength + 1), observed)
            is EvidenceRebuild.Unverified)
    }
}

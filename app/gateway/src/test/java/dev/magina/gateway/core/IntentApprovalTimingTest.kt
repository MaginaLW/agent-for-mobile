package dev.magina.gateway.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class IntentApprovalTimingTest {
    @Test
    fun `默认三时钟与两档预算精确对应拍板值`() {
        val timing = IntentApprovalTiming()
        assertEquals(90_000L, timing.decisionTimeoutMs)
        assertEquals(360_000L, timing.intentTtlMs)
        assertEquals(0L, timing.foregroundWaitBudgetMs(RiskTier.IRREVERSIBLE))
        assertEquals(300_000L, timing.foregroundWaitBudgetMs(RiskTier.RETRACTABLE))
        assertEquals(120_000L, InputCommitEvidenceStore.DEFAULT_TTL_MS)
        assertEquals(120_000L, PreparedTargetEvidenceStore.DEFAULT_TTL_MS)
    }

    @Test
    fun `默认长等待路径必须实际提供读回对象`() {
        assertTrue(runCatching { IntentApprovalDependencies(RiskTier.RETRACTABLE) }
            .exceptionOrNull() is IllegalArgumentException)
        IntentApprovalDependencies(
            RiskTier.RETRACTABLE,
            evidenceReader = IntentEvidenceReader { IntentApprovalFixtures.readback() },
        )
    }

    @Test
    fun `零等待的一级路径可以没有重建依赖但不会声称重建成功`() {
        val timing = IntentApprovalTiming()
        assertFalse(timing.requiresEvidenceRebuild(RiskTier.IRREVERSIBLE))
        val dependencies = IntentApprovalDependencies(RiskTier.IRREVERSIBLE)
        val intent = IntentApprovalFixtures.intent().copy(riskTier = RiskTier.IRREVERSIBLE, approvedAtMs = 1_000)
        assertTrue(dependencies.rebuildEvidence(intent) is EvidenceRebuild.Unverified)
    }

    @Test
    fun `判断重建装配时把决策等待计入证据年龄`() {
        val beforeBoundary = IntentApprovalTiming(retractableForegroundWaitBudgetMs = 29_999)
        assertFalse(beforeBoundary.requiresEvidenceRebuild(RiskTier.RETRACTABLE))
        val atBoundary = IntentApprovalTiming(retractableForegroundWaitBudgetMs = 30_000)
        assertTrue(atBoundary.requiresEvidenceRebuild(RiskTier.RETRACTABLE))
        assertTrue(runCatching { IntentApprovalDependencies(RiskTier.RETRACTABLE, atBoundary) }
            .exceptionOrNull() is IllegalArgumentException)
    }

    @Test
    fun `决策等待本身耗尽证据 TTL 时一级也要求重建依赖`() {
        val timing = IntentApprovalTiming(decisionTimeoutMs = 120_000)
        assertTrue(timing.requiresEvidenceRebuild(RiskTier.IRREVERSIBLE))
        assertTrue(runCatching { IntentApprovalDependencies(RiskTier.IRREVERSIBLE, timing) }
            .exceptionOrNull() is IllegalArgumentException)
    }

    @Test
    fun `巨大预算不能通过相加溢出绕过重建断言`() {
        val timing = IntentApprovalTiming(
            decisionTimeoutMs = Long.MAX_VALUE,
            intentTtlMs = Long.MAX_VALUE,
            retractableForegroundWaitBudgetMs = Long.MAX_VALUE,
        )
        assertTrue(timing.requiresEvidenceRebuild(RiskTier.RETRACTABLE))
        assertTrue(timing.requiresEvidenceRebuild(RiskTier.IRREVERSIBLE))
    }

    @Test
    fun `零负时钟和覆盖不了等待的意图有效期均在构造时拒绝`() {
        val invalid = listOf<() -> IntentApprovalTiming>(
            { IntentApprovalTiming(decisionTimeoutMs = 0) },
            { IntentApprovalTiming(decisionTimeoutMs = -1) },
            { IntentApprovalTiming(intentTtlMs = 0) },
            { IntentApprovalTiming(intentTtlMs = -1) },
            { IntentApprovalTiming(retractableForegroundWaitBudgetMs = -1) },
            { IntentApprovalTiming(intentTtlMs = 299_999) },
        )
        invalid.forEach { make ->
            assertTrue(runCatching(make).exceptionOrNull() is IllegalArgumentException)
        }
        IntentApprovalTiming(intentTtlMs = 300_000) // 相等覆盖允许，不能误写成严格大于。
    }

    @Test
    fun `装配档位不能被调用时的另一档意图替换`() {
        var reads = 0
        val dependencies = IntentApprovalDependencies(RiskTier.IRREVERSIBLE,
            evidenceReader = IntentEvidenceReader {
                reads += 1
                IntentApprovalFixtures.readback()
            },
        )
        val intent = IntentApprovalFixtures.intent().copy(approvedAtMs = 1_000)
        assertTrue(dependencies.rebuildEvidence(intent) is EvidenceRebuild.Unverified)
        assertEquals(0, reads)
    }

    @Test
    fun `实际装配通道每次被调用且读回变化不能复用上次通过`() {
        var reads = 0
        var observed = IntentApprovalFixtures.readback()
        val dependencies = IntentApprovalDependencies(RiskTier.RETRACTABLE,
            evidenceReader = IntentEvidenceReader { reads += 1; observed },
        )
        val intent = IntentApprovalFixtures.intent().copy(approvedAtMs = 1_000)
        assertTrue(dependencies.rebuildEvidence(intent) is EvidenceRebuild.Rebuilt)
        observed = observed.copy(content = "等待期间手动输入的另一条消息")
        assertTrue(dependencies.rebuildEvidence(intent) is EvidenceRebuild.Mismatch)
        assertEquals(2, reads)
    }

    @Test
    fun `通道抛错是无法验证而不是通过且不传播敏感异常内容`() {
        val dependencies = IntentApprovalDependencies(RiskTier.RETRACTABLE,
            evidenceReader = IntentEvidenceReader { error("private-readback-marker") },
        )
        val result = dependencies.rebuildEvidence(IntentApprovalFixtures.intent().copy(approvedAtMs = 1_000))
        assertTrue(result is EvidenceRebuild.Unverified)
        assertFalse(result.toString().contains("private-readback-marker"))
    }
}
